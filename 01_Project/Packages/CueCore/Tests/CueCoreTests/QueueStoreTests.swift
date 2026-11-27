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
