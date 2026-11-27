import XCTest
@testable import CueCore

final class FeatureSwitchTests: XCTestCase {
    private let track = BaselineTests.syntheticTrack()

    private func makeJob() -> CueJob {
        var appearance = CueAppearance()
        appearance.countdownTarget = .musicEnd
        appearance.safeZones = SafeZones(preset: .custom, custom: .init(top: 11, bottom: 16))
        appearance.showGuides = true
        return CueJob(source: track.url, appearance: appearance,
                      trim: TrimSettings(inPoint: 2, outPoint: 24, fadeIn: 1, fadeOut: 2, preRoll: 3),
                      markers: MusicMarkers(editedMusicEnd: 20, editedFadeStart: 18),
                      loudness: LoudnessMeasurement(integratedLUFS: -28, truePeakDBTP: -10, rangeLU: 3),
                      normalise: true, analysis: track.analysis)
    }

    // Supply the job snapshot to both picture timelines as the app does. Editor event handling
    // and the background analyser live in the app target and are exercised in the helper.
    private func timelines(_ job: CueJob) -> [ClipTimeline] {
        let markers = job.effectiveMarkers(detected: track.markers)
        return [CuePicture.timeline(for: track, appearance: job.effectiveAppearance,
                                    markers: markers, trim: job.effectiveTrim),
                MXFExport.timeline(for: track, preset: .default, trim: job.effectiveTrim,
                                   markers: markers, target: job.effectiveAppearance.countdownTarget)]
    }

    func testMarkersOffRemovesDetectedAndEditedMarkersAndCountsToFileEnd() {
        var job = makeJob()
        let original = timelines(job)
        XCTAssertEqual(original[0].musicEndMarker?.seconds, 18)
        XCTAssertEqual(original[0].targetClockFrames, 18 * 25)
        job.appearance.markersEnabled = false
        for timeline in timelines(job) {
            XCTAssertEqual(timeline.target, .fileEnd)
            XCTAssertNil(timeline.musicEndMarker)
            XCTAssertNil(timeline.fadeStartMarker)
            XCTAssertEqual(timeline.targetClockFrames, 22 * 25)
        }
        job.appearance.markersEnabled = true
        XCTAssertEqual(timelines(job), original)
    }

    func testTrimAndPreRollCanBeDisabledIndependentlyThenRestored() {
        var job = makeJob()
        let original = timelines(job)
        job.appearance.trimAndFadesEnabled = false
        for timeline in timelines(job) {
            XCTAssertEqual(timeline.sourceRange, 0...track.seconds)
            XCTAssertEqual(timeline.trim, TrimSettings(preRoll: 3))
            XCTAssertTrue(timeline.isSlate(0))
        }
        job.appearance.preRollEnabled = false
        XCTAssertTrue(timelines(job).allSatisfy(\.isIdentity))
        job.appearance.trimAndFadesEnabled = true
        for timeline in timelines(job) {
            XCTAssertFalse(timeline.isSlate(0))
            XCTAssertEqual(timeline.trim, TrimSettings(inPoint: 2, outPoint: 24, fadeIn: 1, fadeOut: 2))
        }
        job.appearance.preRollEnabled = true
        XCTAssertEqual(timelines(job), original)
    }

    func testSafeZonesOffUsesUnreservedLayoutAndSuppressesPreviewGuides() {
        var job = makeJob()
        let stored = job.appearance
        var unreserved = stored
        unreserved.safeZones = .none
        job.appearance.safeZonesEnabled = false
        XCTAssertEqual(job.effectiveAppearance.layout, unreserved.layout)
        XCTAssertFalse(job.effectiveAppearance.showGuides)
        XCTAssertNil(QueueManager.blockingReason(for: job))
        job.appearance.safeZonesEnabled = true
        XCTAssertEqual(job.effectiveAppearance, stored)
    }

    func testLoudnessOffSkipsMeasurementAndGainWhilePreservingNormaliseAndResult() {
        var job = makeJob()
        let measurement = job.loudness
        XCTAssertEqual(job.effectiveGainDB, 5)
        job.appearance.loudnessAnalysisEnabled = false
        XCTAssertEqual(job.effectiveGainDB, 0)
        XCTAssertEqual(job.loudness, measurement)
        XCTAssertTrue(job.normalise)
        var unmeasured = job
        unmeasured.loudness = nil
        XCTAssertFalse(unmeasured.shouldMeasureLoudness)
        unmeasured.appearance.loudnessAnalysisEnabled = true
        XCTAssertTrue(unmeasured.shouldMeasureLoudness)
        job.appearance.loudnessAnalysisEnabled = true
        XCTAssertFalse(job.shouldMeasureLoudness)
        XCTAssertEqual(job.effectiveGainDB, 5)
    }
}
