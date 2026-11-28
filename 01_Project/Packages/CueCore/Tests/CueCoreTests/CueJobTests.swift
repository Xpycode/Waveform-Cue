import CueCore
import XCTest

final class CueJobTests: XCTestCase {
    private func sampleJob() -> CueJob {
        var appearance = CueAppearance()
        appearance.warning = .ten
        appearance.zoom = .twenty
        return CueJob(source: URL(fileURLWithPath: "/Volumes/Media/Cues/312A Rehearsal.wav"),
                      label: CueLabel(text: "312A Rehearsal", position: CGPoint(x: 0.25, y: 0.75)),
                      appearance: appearance, presetID: "avci100-1080i50", layout: .four,
                      startTimecode: "10:00:00:00", filenameTemplate: "{name} {preset}",
                      trim: TrimSettings(inPoint: 1, outPoint: 30, fadeIn: 0.5, fadeOut: 2, preRoll: 5),
                      markers: MusicMarkers(detectedMusicEnd: 28, detectedFadeStart: 24, editedMusicEnd: 27.5),
                      loudness: LoudnessMeasurement(integratedLUFS: -20.1, truePeakDBTP: -0.4, rangeLU: 6),
                      peaks: PeaksSummary(seconds: 31.2, overview: [0, 0.5, 1, 0.25]),
                      destinationFolder: URL(fileURLWithPath: "/Volumes/Media/Out"))
    }

    private func roundTrip(_ job: CueJob) throws -> CueJob {
        try JSONDecoder().decode(CueJob.self, from: JSONEncoder().encode(job))
    }

    private func object(_ job: CueJob) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
    }

    private func decode(_ dict: [String: Any]) throws -> CueJob {
        try JSONDecoder().decode(CueJob.self, from: JSONSerialization.data(withJSONObject: dict))
    }

    func testDefaultsFromSource() {
        let job = CueJob(source: URL(fileURLWithPath: "/tmp/My Cue.final.wav"))
        XCTAssertEqual(job.labelText, "My Cue.final")
        XCTAssertEqual(job.label.position, CGPoint(x: 0, y: 1))
        XCTAssertEqual(job.startTimecode, "00:00:00:00")
        XCTAssertEqual(job.filenameTemplate, "{name} - Cue")
        XCTAssertEqual(job.layout, .two)
        XCTAssertEqual(job.status, .pending)
        XCTAssertNil(job.destinationFolder)
    }

    func testRoundTripKeepsEveryField() throws {
        var job = sampleJob()
        job.outputPath = "/Volumes/Media/Out/312A Rehearsal avci100-1080i50.mxf"
        job.status = .failed(reason: "Encoder exited with status 1", log: "tail of log")
        let decoded = try roundTrip(job)
        XCTAssertEqual(decoded, job)
        XCTAssertEqual(decoded.appearance.warning, .ten)
        XCTAssertEqual(decoded.appearance.zoom, .twenty)
        XCTAssertEqual(decoded.label.text, "312A Rehearsal")
        XCTAssertEqual(decoded.label.position, CGPoint(x: 0.25, y: 0.75))
    }

    func testRunStateIsNotSaved() throws {
        var job = sampleJob()
        job.status = .exporting(progress: 0.42)
        let dict = try object(job)
        let status = try XCTUnwrap(dict["status"] as? [String: Any])
        XCTAssertEqual(status["state"] as? String, "pending")
        XCTAssertNil(status["progress"])
        XCTAssertEqual(try roundTrip(job).status, .pending)

        job.status = .preparing
        XCTAssertEqual(try roundTrip(job).status, .pending)
    }

    func testStatusRoundTrips() throws {
        let statuses: [JobStatus] = [
            .pending, .cancelled, .paused,
            .done(output: URL(fileURLWithPath: "/out/a.mxf")),
            .failed(reason: "Disk full", log: "…last lines")
        ]
        for status in statuses {
            var job = sampleJob()
            job.status = status
            XCTAssertEqual(try roundTrip(job).status, status)
        }
    }

    func testLegacyPartialJobLoadsWithDefaults() throws {
        // An older shape: no ID, the source under `source`, the title under `label`, status as a
        // bare string, a build 4 appearance (no clocks), and none of the newer fields.
        let legacy: [String: Any] = [
            "source": "/Volumes/Media/Old/Intro.aif",
            "label": "Intro",
            "status": "cancelled",
            "appearance": ["overviewColor": ["red": 1, "green": 0, "blue": 0]],
            "layout": 6,
            "unknownFutureField": true
        ]
        let job = try decode(legacy)
        XCTAssertEqual(job.sourcePath, "/Volumes/Media/Old/Intro.aif")
        XCTAssertEqual(job.labelText, "Intro")
        XCTAssertEqual(job.status, .cancelled)
        XCTAssertEqual(job.layout, .two, "an unknown layout falls back to the default")
        XCTAssertEqual(job.presetID, "")
        XCTAssertEqual(job.startTimecode, CueJob.defaultStartTimecode)
        XCTAssertEqual(job.filenameTemplate, CueJob.defaultFilenameTemplate)
        XCTAssertEqual(job.trim, .none)
        XCTAssertEqual(job.markers, .none)
        XCTAssertNil(job.loudness)
        XCTAssertNil(job.peaks)
        let legacyLook = CueAppearance()
        XCTAssertEqual(job.appearance, legacyLook)
        var missing = legacy
        missing.removeValue(forKey: "appearance")
        XCTAssertEqual(try decode(missing).appearance, legacyLook)
    }

    func testMalformedFieldsDegradeInsteadOfThrowing() throws {
        var dict = try object(sampleJob())
        dict["trim"] = "not a trim"
        dict["loudness"] = ["integratedLUFS": "loud"]
        dict["peaks"] = 12
        dict["status"] = ["state": "done"] // Done without its output path
        dict["labelX"] = "left"
        let job = try decode(dict)
        XCTAssertEqual(job.trim, .none)
        XCTAssertEqual(job.loudness, LoudnessMeasurement(integratedLUFS: nil, truePeakDBTP: nil, rangeLU: 0))
        XCTAssertNil(job.peaks)
        XCTAssertEqual(job.status, .pending)
        XCTAssertEqual(job.labelX, 0)
        XCTAssertEqual(job.sourcePath, sampleJob().sourcePath)
    }

    func testNormaliseDefaultsOffAndRoundTrips() throws {
        XCTAssertFalse(sampleJob().normalise)
        var dict = try object(sampleJob())
        XCTAssertEqual(dict["normalise"] as? Bool, false)
        dict.removeValue(forKey: "normalise")
        XCTAssertFalse(try decode(dict).normalise, "a job saved before Normalise existed decodes with it off")
        dict["normalise"] = "yes"
        XCTAssertFalse(try decode(dict).normalise, "a malformed value falls back to off")
        var job = sampleJob()
        job.normalise = true
        XCTAssertTrue(try roundTrip(job).normalise)
        XCTAssertEqual(try roundTrip(job), job)
    }

    func testUnknownStateBecomesPending() throws {
        var dict = try object(sampleJob())
        dict["status"] = ["state": "teleported"]
        XCTAssertEqual(try decode(dict).status, .pending)
    }

    func testJobWithoutSourceThrows() throws {
        var dict = try object(sampleJob())
        dict.removeValue(forKey: "sourcePath")
        XCTAssertThrowsError(try decode(dict))
    }

    func testPeaksSummarySanitisesNonFiniteValues() throws {
        let peaks = PeaksSummary(seconds: .nan, overview: [.nan, .infinity, 2, -1, 0.5])
        XCTAssertEqual(peaks.seconds, 0)
        XCTAssertEqual(peaks.overview, [0, 0, 1, 0, 0.5])
        var job = sampleJob()
        job.peaks = peaks
        XCTAssertEqual(try roundTrip(job).peaks, peaks)
    }

    func testAppearanceSnapshotEquality() {
        var a = CueAppearance()
        var b = CueAppearance()
        XCTAssertEqual(AppearanceSnapshot(a), AppearanceSnapshot(b))
        b.fadeFullTrack.toggle()
        XCTAssertNotEqual(AppearanceSnapshot(a), AppearanceSnapshot(b))
        a.fadeFullTrack = b.fadeFullTrack
        a.remaining.size = .large
        XCTAssertNotEqual(AppearanceSnapshot(a), AppearanceSnapshot(b))
    }

    func testFeatureSwitchesRestoreStoredSongSettings() throws {
        var job = sampleJob()
        job.normalise = true
        job.appearance.safeZones = SafeZones(preset: .custom, custom: .init(top: 11, bottom: 16))
        job.appearance.showGuides = true
        job.appearance.countdownTarget = .musicEnd
        let detected = MusicMarkers(detectedMusicEnd: 29, detectedFadeStart: 25)
        job.analysis = TrackAnalysis(seconds: 31, detailPeaks: [1], markers: detected, absolutePeak: 1)
        let original = job
        let gain = Loudness.normalisation(for: try XCTUnwrap(job.loudness)).gainDB

        job.appearance.markersEnabled = false
        job.appearance.safeZonesEnabled = false
        job.appearance.loudnessAnalysisEnabled = false
        job.appearance.trimAndFadesEnabled = false
        XCTAssertEqual(job.effectiveAppearance.countdownTarget, .fileEnd)
        XCTAssertEqual(job.effectiveAppearance.safeZones, .none)
        XCTAssertFalse(job.effectiveAppearance.showGuides)
        XCTAssertEqual(job.effectiveMarkers, .none)
        XCTAssertEqual(job.effectiveMarkers(detected: detected), .none)
        XCTAssertEqual(job.effectiveTrim, TrimSettings(preRoll: 5))
        XCTAssertEqual(job.effectiveGainDB, 0)
        XCTAssertFalse(job.shouldMeasureLoudness)

        job.appearance.preRollEnabled = false
        XCTAssertEqual(job.effectiveTrim, .none)
        job = try roundTrip(job)
        job.appearance.trimAndFadesEnabled = true
        var trimWithoutSlate = original.trim
        trimWithoutSlate.preRoll = 0
        XCTAssertEqual(job.effectiveTrim, trimWithoutSlate)
        job.appearance.preRollEnabled = true
        job.appearance.markersEnabled = true
        job.appearance.safeZonesEnabled = true
        job.appearance.loudnessAnalysisEnabled = true
        XCTAssertEqual(job, original)
        XCTAssertEqual(job.effectiveAppearance, original.appearance)
        XCTAssertEqual(job.effectiveMarkers, detected.applyingEdits(from: original.markers))
        XCTAssertEqual(job.effectiveTrim, original.trim)
        XCTAssertEqual(job.effectiveGainDB, gain)
        job.normalise = false
        XCTAssertEqual(job.effectiveGainDB, 0)
        XCTAssertFalse(job.shouldMeasureLoudness)
        job.loudness = nil
        XCTAssertTrue(job.shouldMeasureLoudness)
        job.appearance.loudnessAnalysisEnabled = false
        XCTAssertFalse(job.shouldMeasureLoudness)
    }

    func testFreshlyDetectedMarkersAreUsedForJobsWithoutStoredAnalysis() {
        var job = sampleJob()
        let fresh = MusicMarkers(detectedMusicEnd: 29, detectedFadeStart: 25)
        XCTAssertNil(job.analysis)
        XCTAssertEqual(job.effectiveMarkers, job.markers)
        XCTAssertEqual(job.effectiveMarkers(detected: fresh), fresh.applyingEdits(from: job.markers))
        job.appearance.markersEnabled = false
        XCTAssertEqual(job.effectiveMarkers(detected: fresh), .none)
    }

    func testStatusHelpers() {
        XCTAssertTrue(JobStatus.exporting(progress: 0.3).isActive)
        XCTAssertTrue(JobStatus.preparing.isActive)
        XCTAssertFalse(JobStatus.paused.isActive)
        XCTAssertTrue(JobStatus.cancelled.canRetry)
        XCTAssertFalse(JobStatus.done(output: URL(fileURLWithPath: "/a")).canRetry)
        XCTAssertEqual(JobStatus.exporting(progress: 0.426).title, "Exporting 42%")
        XCTAssertEqual(JobStatus.exporting(progress: 0.5).progress, 0.5)
        XCTAssertNil(JobStatus.pending.progress)
    }
}
