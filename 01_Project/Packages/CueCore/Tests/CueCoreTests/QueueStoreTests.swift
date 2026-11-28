import CueCore
import XCTest

final class QueueStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QueueStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func job(_ name: String) -> CueJob {
        CueJob(source: URL(fileURLWithPath: "/Volumes/Media/\(name).wav"), presetID: "mpeg2-50")
    }

    private func recoveryFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("queue-recovery-") && $0.pathExtension == "json" }
    }

    func testMissingFileIsEmptyQueue() {
        let result = QueueStore(directory: directory).load()
        XCTAssertEqual(result.document.jobs, [])
        XCTAssertNil(result.problem)
        XCTAssertNil(result.recoveryFile)
    }

    func testSaveThenLoad() throws {
        let store = QueueStore(directory: directory)
        var done = job("B")
        done.status = .done(output: URL(fileURLWithPath: "/Volumes/Media/B - Cue.mxf"))
        let document = QueueDocument(jobs: [job("A"), done], destinationOverride: "/Volumes/Out")
        try store.save(document)

        let loaded = QueueStore(directory: directory).load()
        XCTAssertEqual(loaded.document, document)
        XCTAssertNil(loaded.problem)
        XCTAssertEqual(try recoveryFiles(), [])
    }

    func testSaveCreatesMissingFolderAndLeavesNoTemporaryFiles() throws {
        let nested = directory.appendingPathComponent("Waveform Cue")
        let store = QueueStore(directory: nested)
        try store.save(QueueDocument(jobs: [job("A")]))
        try store.save(QueueDocument(jobs: [job("A"), job("B")]))
        let names = try FileManager.default.contentsOfDirectory(atPath: nested.path)
        XCTAssertEqual(names, [QueueStore.fileName])
    }

    func testCorruptFileIsCopiedBeforeAnyWrite() throws {
        let store = QueueStore(directory: directory)
        let garbage = Data("{ this is not json".utf8)
        try garbage.write(to: store.fileURL)

        let result = store.load()
        XCTAssertEqual(result.document.jobs, [])
        XCTAssertNotNil(result.problem)
        let recovery = try XCTUnwrap(result.recoveryFile)
        XCTAssertTrue(recovery.lastPathComponent.hasPrefix("queue-recovery-"))
        XCTAssertEqual(recovery.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: recovery), garbage)
        XCTAssertFalse(store.isWriteBlocked)

        // With a copy made, saving over the original is allowed.
        try store.save(QueueDocument(jobs: [job("A")]))
        XCTAssertEqual(QueueStore(directory: directory).load().document.jobs.count, 1)
        XCTAssertEqual(try Data(contentsOf: recovery), garbage, "the recovery copy is untouched")
    }

    func testFailedRecoveryCopyBlocksWrites() throws {
        struct CopyFailed: Error {}
        let fileURL = directory.appendingPathComponent(QueueStore.fileName)
        let garbage = Data("[[[".utf8)
        try garbage.write(to: fileURL)

        let store = QueueStore(directory: directory, copyItem: { _, _ in throw CopyFailed() })
        let result = store.load()
        XCTAssertNil(result.recoveryFile)
        XCTAssertTrue(store.isWriteBlocked)
        XCTAssertNotNil(result.problem)
        XCTAssertThrowsError(try store.save(QueueDocument(jobs: [job("A")]))) { error in
            XCTAssertEqual(error as? QueueStoreError, .writesBlocked(file: fileURL))
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), garbage, "the only copy is never overwritten")
        XCTAssertEqual(try recoveryFiles(), [])
    }

    func testOneBadJobDoesNotLoseTheOthers() throws {
        let store = QueueStore(directory: directory)
        try store.save(QueueDocument(jobs: [job("A"), job("B"), job("C")]))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        var jobs = try XCTUnwrap(root["jobs"] as? [Any])
        jobs[1] = ["labelText": "no source"]   // undecodable job
        jobs.insert(42, at: 2)                  // not even an object
        root["jobs"] = jobs
        try JSONSerialization.data(withJSONObject: root).write(to: store.fileURL)

        let result = QueueStore(directory: directory).load()
        XCTAssertEqual(result.document.jobs.map(\.sourceName), ["A", "C"])
        XCTAssertEqual(result.droppedJobs, 2)
        XCTAssertNotNil(result.problem)
        // The dropped jobs survive in the recovery copy.
        let recovery = try XCTUnwrap(result.recoveryFile)
        XCTAssertEqual(try Data(contentsOf: recovery), try Data(contentsOf: store.fileURL))
    }

    func testLegacyBareArrayFixture() throws {
        // An early shape: a bare array of jobs with only a few fields.
        let fixture = """
        [
          {"source": "/Volumes/Media/One.wav", "label": "One", "status": "pending"},
          {"sourcePath": "/Volumes/Media/Two.wav", "status": {"state": "done", "output": "/Volumes/Media/Two - Cue.mxf"},
           "presetID": "mpeg2-50", "trim": {"inPoint": 2}},
          {"sourcePath": "/Volumes/Media/Three.wav", "status": {"state": "exporting", "progress": 0.6}}
        ]
        """
        try Data(fixture.utf8).write(to: directory.appendingPathComponent(QueueStore.fileName))

        let result = QueueStore(directory: directory).load()
        XCTAssertNil(result.problem)
        let jobs = result.document.jobs
        XCTAssertEqual(jobs.map(\.sourceName), ["One", "Two", "Three"])
        XCTAssertEqual(jobs[0].labelText, "One")
        XCTAssertEqual(jobs[1].status, .done(output: URL(fileURLWithPath: "/Volumes/Media/Two - Cue.mxf")))
        XCTAssertEqual(jobs[1].trim, TrimSettings(inPoint: 2))
        XCTAssertEqual(jobs[2].status, .pending)
        XCTAssertNil(result.document.destinationOverride)
    }

    func testBuild17QueueSavesOnlyMigratedSettingsAndReloadsTheSamePicture() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "build17-job", withExtension: "json"))
        let legacy = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture))
        let store = QueueStore(directory: directory)
        try JSONSerialization.data(withJSONObject: ["version": 1, "jobs": [legacy]]).write(to: store.fileURL)

        let loaded = store.load()
        XCTAssertNil(loaded.problem)
        let job = try XCTUnwrap(loaded.document.jobs.first)
        XCTAssertEqual(job.appearance.titleAlignment, .right)
        XCTAssertEqual(job.appearance.paneOrder, [.title, .clocks, .fullTrack, .closeUp])
        let track = BaselineTests.syntheticTrack()
        let picture = BaselineTests.render(track, frame: 375, label: job.label, appearance: job.effectiveAppearance)

        try store.save(loaded.document)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        let savedJob = try XCTUnwrap((json["jobs"] as? [[String: Any]])?.first)
        let appearance = try XCTUnwrap(savedJob["appearance"] as? [String: Any])
        XCTAssertNil(savedJob["labelX"])
        XCTAssertNil(savedJob["labelY"])
        XCTAssertNil(appearance["clockPosition"])
        let reloaded = QueueStore(directory: directory).load()
        XCTAssertNil(reloaded.problem)
        XCTAssertEqual(reloaded.document, loaded.document)
        let restored = try XCTUnwrap(reloaded.document.jobs.first)
        XCTAssertTrue(picture == BaselineTests.render(track, frame: 375, label: restored.label,
                                                     appearance: restored.effectiveAppearance))
    }

    func testBuild11QueueKeepsItsAppearanceAndSongValuesAcrossSaveAndReload() throws {
        let fixture = """
        {"version":1,"destinationOverride":"/out","jobs":[{
          "id":"1337A672-5B86-45EA-B6F7-D8F4CBAFA72B","sourcePath":"/media/old.wav",
          "labelText":"Old title","labelX":0.2,"labelY":0.8,"presetID":"avci100-1080i50",
          "layout":4,"normalise":true,"trim":{"inPoint":1,"fadeOut":2,"preRoll":3},
          "markers":{"editedMusicEnd":18},"loudness":{"integratedLUFS":-21,"truePeakDBTP":-2,"rangeLU":4},
          "appearance":{"elapsed":{"color":{"red":1,"green":0,"blue":0},"size":"Small"},
            "remaining":{"color":{"red":0,"green":1,"blue":0},"size":"Large"},"zoom":-1,
            "warning":10,"fadeFullTrack":true,"fadeCloseUp":false,"solidRedAt":"oneSecond",
            "overviewColor":{"red":0.8,"green":0.3,"blue":0.1},
            "safeZones":{"preset":"custom","custom":{"top":11,"bottom":16}},
            "clockPosition":"above","countdownTarget":"musicEnd","showGuides":true}}]}
        """
        let store = QueueStore(directory: directory)
        try Data(fixture.utf8).write(to: store.fileURL)
        let first = store.load()
        XCTAssertNil(first.problem)
        let job = try XCTUnwrap(first.document.jobs.first)
        var expected = CueAppearance()
        expected.elapsed.color = CueColor(1, 0, 0)
        expected.elapsed.size = .small
        expected.remaining.color = CueColor(0, 1, 0)
        expected.remaining.size = .large
        expected.zoom = .off
        expected.warning = .ten
        expected.fadeFullTrack = true
        expected.fadeCloseUp = false
        expected.solidRedAt = .oneSecond
        expected.overviewColor = CueColor(0.8, 0.3, 0.1)
        expected.safeZones = SafeZones(preset: .custom, custom: .init(top: 11, bottom: 16))
        expected.paneOrder = [.title, .clocks, .fullTrack, .closeUp]
        expected.countdownTarget = .musicEnd
        expected.showGuides = true
        XCTAssertEqual(job.effectiveAppearance, expected)
        XCTAssertEqual(job.appearance.playheadMode, .centered)
        XCTAssertEqual(job.appearance.endZoom, .off)
        XCTAssertTrue(job.appearance.showTitle && job.appearance.showFullTrack)
        XCTAssertTrue(job.appearance.showElapsed && job.appearance.showRemaining)
        XCTAssertTrue(job.appearance.markersEnabled && job.appearance.safeZonesEnabled)
        XCTAssertTrue(job.appearance.loudnessAnalysisEnabled && job.appearance.trimAndFadesEnabled && job.appearance.preRollEnabled)
        XCTAssertEqual(job.effectiveTrim, TrimSettings(inPoint: 1, fadeOut: 2, preRoll: 3))
        XCTAssertEqual(job.effectiveMarkers.musicEnd, 18)
        XCTAssertEqual(job.effectiveGainDB, -2)
        XCTAssertEqual(job.labelText, "Old title")
        XCTAssertEqual(job.appearance.titleAlignment, .left)
        XCTAssertEqual(job.layout, .four)
        XCTAssertEqual(job.presetID, "avci100-1080i50")
        try store.save(first.document)
        let second = QueueStore(directory: directory).load()
        XCTAssertNil(second.problem)
        XCTAssertEqual(second.document, first.document)
    }

    func testLegacyDocumentWithoutVersion() throws {
        let fixture = #"{"jobs": [{"sourcePath": "/a/b.wav"}], "destinationOverride": "/out"}"#
        try Data(fixture.utf8).write(to: directory.appendingPathComponent(QueueStore.fileName))
        let result = QueueStore(directory: directory).load()
        XCTAssertNil(result.problem)
        XCTAssertEqual(result.document.jobs.count, 1)
        XCTAssertEqual(result.document.destinationOverride, "/out")
    }

    func testUnreadableJobListIsRecovered() throws {
        let fixture = #"{"version": 1, "jobs": "oops"}"#
        try Data(fixture.utf8).write(to: directory.appendingPathComponent(QueueStore.fileName))
        let result = QueueStore(directory: directory).load()
        XCTAssertNotNil(result.problem)
        XCTAssertNotNil(result.recoveryFile)
        XCTAssertEqual(try recoveryFiles().count, 1)
    }
}
