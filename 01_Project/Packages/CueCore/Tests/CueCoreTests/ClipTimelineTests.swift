import XCTest
@testable import CueCore

final class ClipTimelineTests: XCTestCase {

    /// Build 10's frame count, as `AudioTrack.frames` computes it.
    static func build10Frames(_ seconds: Double) -> Int {
        let pcm = PreparedAudio(url: URL(fileURLWithPath: "/nonexistent/timeline.caf"))
        return AudioTrack(url: URL(fileURLWithPath: "/tmp/t.wav"), pcm: pcm, seconds: seconds,
                          detailPeaks: [0], peaks: [0]).frames
    }

    static let durations: [Double] = [0, 0.001, 0.04, 0.05, 1, 1.0000000001, 2.5, 7.99, 30, 30.02,
                                      179.987, 3600.04, 1 / 3]

    // MARK: - Identity (build 10 parity)

    func testIdentityFramesMatchBuild10() {
        for seconds in Self.durations {
            let timeline = ClipTimeline(duration: seconds)
            let frames = Self.build10Frames(seconds)
            XCTAssertEqual(timeline.outputFrames, frames, "duration \(seconds)")
            XCTAssertEqual(timeline.positionCount, frames)
            XCTAssertEqual(timeline.clockFrames, frames)
            XCTAssertEqual(timeline.totalSamples, frames * 1920)
            XCTAssertTrue(timeline.isIdentity)
        }
    }

    func testIdentityClocksMatchBuild10() {
        for seconds in Self.durations {
            let timeline = ClipTimeline(duration: seconds)
            let frames = Self.build10Frames(seconds)
            // CuePicture.draw: clamped = min(frames, max(0, frame)); remaining = frames - clamped.
            for frame in [-3, 0, 1, frames / 2, frames - 1, frames, frames + 7] {
                let clamped = min(frames, max(0, frame))
                let clocks = timeline.clocks(at: frame)
                XCTAssertEqual(clocks.elapsed, clamped, "duration \(seconds) frame \(frame)")
                XCTAssertEqual(clocks.remaining, frames - clamped, "duration \(seconds) frame \(frame)")
                XCTAssertEqual(clocks.elapsedText, AudioTrack.clock(clamped))
                XCTAssertEqual(clocks.remainingText, AudioTrack.clock(frames - clamped))
                XCTAssertFalse(clocks.isSlate)
                XCTAssertFalse(clocks.isPastTarget)
            }
        }
    }

    func testIdentityAudioFilterMatchesBuild10() {
        for seconds in Self.durations {
            let frames = Self.build10Frames(seconds)
            let build10 = "aresample=48000,apad=whole_len=\(frames * 1920),atrim=end_sample=\(frames * 1920)"
            XCTAssertEqual(ClipTimeline(duration: seconds).audioFilterChain, build10)
        }
    }

    func testIdentityPositionMapsToSourceTime() {
        let timeline = ClipTimeline(duration: 10)
        XCTAssertEqual(timeline.position(at: 0), .music(sourceSeconds: 0, clockFrame: 0))
        XCTAssertEqual(timeline.position(at: 25), .music(sourceSeconds: 1, clockFrame: 25))
        XCTAssertEqual(timeline.position(at: 250), .music(sourceSeconds: 10, clockFrame: 250))
        XCTAssertEqual(timeline.position(at: 9999), .music(sourceSeconds: 10, clockFrame: 250))
    }

    // MARK: - Pre-roll

    func testPreRollComesFirst() {
        let timeline = ClipTimeline(duration: 10, trim: TrimSettings(preRoll: 5))
        XCTAssertEqual(timeline.preRollFrames, 125)
        XCTAssertEqual(timeline.outputFrames, 125 + 250)
        XCTAssertEqual(timeline.position(at: 0), .slate(startsIn: 125))
        XCTAssertEqual(timeline.position(at: 124), .slate(startsIn: 1))
        XCTAssertEqual(timeline.position(at: 125), .music(sourceSeconds: 0, clockFrame: 0))
        XCTAssertFalse(timeline.isIdentity)

        let slate = timeline.clocks(at: 10)
        XCTAssertTrue(slate.isSlate)
        XCTAssertEqual(slate.elapsed, 0)
        XCTAssertEqual(slate.startsIn, 115)
        XCTAssertEqual(slate.remaining, 250)

        let first = timeline.clocks(at: 125)
        XCTAssertFalse(first.isSlate)
        XCTAssertEqual(first.elapsed, 0)
        XCTAssertEqual(first.remaining, 250)
        XCTAssertEqual(timeline.clocks(at: 374).remaining, 1)
    }

    func testPreRollAudioIsDelayedAndPadded() {
        let timeline = ClipTimeline(duration: 10, trim: TrimSettings(preRoll: 2))
        XCTAssertEqual(timeline.audioFilters(), [
            "aresample=48000",
            "adelay=delays=96000S:all=1",
            "apad=whole_len=\(300 * 1920)",
            "atrim=end_sample=\(300 * 1920)"
        ])
        XCTAssertEqual(timeline.preRollSamples, 96000)
    }

    // MARK: - Trim and fades

    func testTrimCoversOnlyTheRange() {
        let trim = TrimSettings(inPoint: 10, outPoint: 20.5)
        let timeline = ClipTimeline(duration: 60, trim: trim)
        XCTAssertEqual(timeline.sourceRange, 10...20.5)
        XCTAssertEqual(timeline.musicDuration, 10.5)
        XCTAssertEqual(timeline.outputFrames, 263) // 262.5 rounds up
        XCTAssertEqual(timeline.clockFrames, 263)
        XCTAssertEqual(timeline.position(at: 0), .music(sourceSeconds: 10, clockFrame: 0))
        XCTAssertEqual(timeline.position(at: 50), .music(sourceSeconds: 12, clockFrame: 50))
        XCTAssertEqual(timeline.clocks(at: 0).remaining, 263)
        XCTAssertEqual(timeline.audioFilters(), [
            "aresample=48000",
            "atrim=start_sample=480000:end_sample=984000",
            "asetpts=PTS-STARTPTS",
            "apad=whole_len=\(263 * 1920)",
            "atrim=end_sample=\(263 * 1920)"
        ])
        XCTAssertNoThrow(try timeline.validate())
    }

    func testTrimWithFadesAndPreRoll() {
        let trim = TrimSettings(inPoint: 5, outPoint: nil, fadeIn: 0.5, fadeOut: 2, preRoll: 3)
        let timeline = ClipTimeline(duration: 15, trim: trim)
        XCTAssertEqual(timeline.outputFrames, 75 + 250)
        XCTAssertEqual(timeline.audioFilters(), [
            "aresample=48000",
            "atrim=start_sample=240000",
            "asetpts=PTS-STARTPTS",
            "afade=t=in:start_sample=0:nb_samples=24000",
            "afade=t=out:start_sample=384000:nb_samples=96000",
            "adelay=delays=144000S:all=1",
            "apad=whole_len=\(325 * 1920)",
            "atrim=end_sample=\(325 * 1920)"
        ])
    }

    func testFadesLongerThanRangeAreClamped() {
        let trim = TrimSettings(fadeIn: 5, fadeOut: 5)
        let filters = ClipTimeline(duration: 1, trim: trim).audioFilters()
        XCTAssertTrue(filters.contains("afade=t=in:start_sample=0:nb_samples=48000"))
        XCTAssertTrue(filters.contains("afade=t=out:start_sample=0:nb_samples=48000"))
    }

    func testOutOfRangeTrimPointsAreClamped() {
        let timeline = ClipTimeline(duration: 10, trim: TrimSettings(inPoint: -4, outPoint: 99))
        XCTAssertEqual(timeline.sourceRange, 0...10)
        XCTAssertFalse(timeline.isTrimmed)
        XCTAssertEqual(timeline.outputFrames, 250)

        let inverted = ClipTimeline(duration: 10, trim: TrimSettings(inPoint: 8, outPoint: 3))
        XCTAssertEqual(inverted.sourceRange, 8...8)
        XCTAssertEqual(inverted.outputFrames, 1)
        XCTAssertThrowsError(try inverted.validate())
    }

    func testValidateRejectsShortTrim() {
        let short = ClipTimeline(duration: 30, trim: TrimSettings(inPoint: 10, outPoint: 10.96))
        XCTAssertThrowsError(try short.validate()) { error in
            XCTAssertEqual(error.localizedDescription, "Trim range too short")
        }
        XCTAssertNoThrow(try ClipTimeline(duration: 30, trim: TrimSettings(inPoint: 10, outPoint: 11)).validate())
        // An untrimmed short source still exports, as in build 10.
        XCTAssertNoThrow(try ClipTimeline(duration: 0.3).validate())
        XCTAssertNoThrow(try ClipTimeline(duration: 0.3, trim: TrimSettings(inPoint: 0, outPoint: 0.3)).validate())
    }

    // MARK: - Markers and countdown target

    func testMusicEndTargetHoldsAtZero() {
        let markers = MusicMarkers(detectedMusicEnd: 8, detectedFadeStart: 6)
        let timeline = ClipTimeline(duration: 10, markers: markers, target: .musicEnd)
        XCTAssertEqual(timeline.targetClockFrames, 200)
        XCTAssertEqual(timeline.clocks(at: 0).remaining, 200)
        XCTAssertEqual(timeline.clocks(at: 199).remaining, 1)
        XCTAssertFalse(timeline.clocks(at: 199).isPastTarget)
        let at = timeline.clocks(at: 200)
        XCTAssertEqual(at.remaining, 0)
        XCTAssertTrue(at.isPastTarget)
        let after = timeline.clocks(at: 240)
        XCTAssertEqual(after.remaining, 0)
        XCTAssertEqual(after.toFileEnd, 10)
        XCTAssertTrue(after.isPastTarget)
        XCTAssertEqual(after.elapsed, 240)
    }

    func testFileEndTargetIgnoresMarkers() {
        let markers = MusicMarkers(detectedMusicEnd: 8)
        let timeline = ClipTimeline(duration: 10, markers: markers, target: .fileEnd)
        XCTAssertEqual(timeline.clocks(at: 200).remaining, 50)
        XCTAssertFalse(timeline.clocks(at: 249).isPastTarget)
    }

    func testNoTailMakesNoDifference() {
        for seconds in [10.0, 7.99, 30.02] {
            let markers = MusicMarkers(detectedMusicEnd: seconds, detectedFadeStart: seconds - 1)
            let fileEnd = ClipTimeline(duration: seconds, markers: markers, target: .fileEnd)
            let musicEnd = ClipTimeline(duration: seconds, markers: markers, target: .musicEnd)
            for frame in 0...fileEnd.outputFrames {
                XCTAssertEqual(fileEnd.clocks(at: frame), musicEnd.clocks(at: frame), "\(seconds) @ \(frame)")
            }
        }
    }

    func testNoMusicFallsBackToFileEnd() {
        let timeline = ClipTimeline(duration: 10, markers: .silent, target: .musicEnd)
        XCTAssertEqual(timeline.targetClockFrames, 250)
        XCTAssertNil(timeline.musicEndMarker)
        XCTAssertEqual(ClipTimeline(duration: 10, markers: .none, target: .musicEnd).targetClockFrames, 250)
    }

    /// The End line sits on the frame where a Music end countdown reads zero (rounded up), and
    /// on the last frame when the music ends inside it; the marker keeps its exact time.
    func testEndLineSnapsToTheFrameGrid() {
        func timeline(end: Double, duration: Double = 30.1, target: CountdownTarget = .musicEnd) -> ClipTimeline {
            ClipTimeline(duration: duration, markers: MusicMarkers(detectedMusicEnd: end), target: target)
        }
        XCTAssertEqual(timeline(end: 8).musicEndLineFrame, 200)
        XCTAssertEqual(timeline(end: 8.01).musicEndLineFrame, 201)
        XCTAssertEqual(timeline(end: 8.01).targetClockFrames, 201)
        XCTAssertEqual(timeline(end: 8.01).musicEndMarker?.seconds ?? 0, 8.01, accuracy: 1e-9)
        // 30.1 s is 753 clock frames; a music end inside the last frame meets the file end.
        XCTAssertEqual(timeline(end: 30.09).clockFrames, 753)
        XCTAssertEqual(timeline(end: 30.09).musicEndLineFrame, 753)
        XCTAssertEqual(timeline(end: 30.09, target: .fileEnd).musicEndLineFrame, 753)
        XCTAssertNil(timeline(end: 8, target: .fileEnd).fadeStartMarker)
        XCTAssertNil(ClipTimeline(duration: 10, markers: .silent, target: .musicEnd).musicEndLineFrame)
    }

    func testEditedMarkerWins() {
        let markers = MusicMarkers(detectedMusicEnd: 8, editedMusicEnd: 9)
        XCTAssertEqual(ClipTimeline(duration: 10, markers: markers, target: .musicEnd).targetClockFrames, 225)
    }

    func testMarkersReferToTrimmedRange() {
        let markers = MusicMarkers(detectedMusicEnd: 18, detectedFadeStart: 4)
        let trim = TrimSettings(inPoint: 10, outPoint: 20, preRoll: 2)
        let timeline = ClipTimeline(duration: 30, trim: trim, markers: markers, target: .musicEnd)
        XCTAssertEqual(timeline.musicEndMarker, .init(seconds: 8, clockFrame: 200))
        XCTAssertNil(timeline.fadeStartMarker) // cut away by the in point
        XCTAssertEqual(timeline.targetClockFrames, 200)
        // Pre-roll does not shift the countdown: it starts at the first music frame.
        XCTAssertEqual(timeline.clocks(at: 50).remaining, 200)
        XCTAssertEqual(timeline.clocks(at: 250).remaining, 0)
        XCTAssertTrue(timeline.clocks(at: 250).isPastTarget)
    }

    func testMarkerAfterOutPointCountsToFileEnd() {
        let markers = MusicMarkers(detectedMusicEnd: 25)
        let trim = TrimSettings(inPoint: 10, outPoint: 20)
        let timeline = ClipTimeline(duration: 30, trim: trim, markers: markers, target: .musicEnd)
        XCTAssertNil(timeline.musicEndMarker)
        XCTAssertEqual(timeline.targetClockFrames, timeline.clockFrames)
        XCTAssertFalse(timeline.clocks(at: 249).isPastTarget)
    }

    func testMarkerBeforeInPointCountsToFileEnd() {
        let markers = MusicMarkers(detectedMusicEnd: 5)
        let timeline = ClipTimeline(duration: 30, trim: TrimSettings(inPoint: 10), markers: markers, target: .musicEnd)
        XCTAssertNil(timeline.musicEndMarker)
        XCTAssertEqual(timeline.targetClockFrames, timeline.clockFrames)
        XCTAssertFalse(timeline.clocks(at: 0).isPastTarget)
    }

    // MARK: - 50 Hz

    func testFields50() {
        let timeline = ClipTimeline(duration: 10, trim: TrimSettings(preRoll: 2), standard: TimelineRate.fields50)
        XCTAssertEqual(timeline.frameRate, 25)
        XCTAssertEqual(timeline.positionsPerFrame, 2)
        XCTAssertEqual(timeline.preRollFrames, 50)
        XCTAssertEqual(timeline.outputFrames, 300)
        XCTAssertEqual(timeline.positionCount, 600)
        XCTAssertEqual(timeline.preRollPositions, 100)
        XCTAssertEqual(timeline.totalSamples, 300 * 1920)
        XCTAssertEqual(timeline.position(at: 99), .slate(startsIn: 1))
        XCTAssertEqual(timeline.position(at: 100), .music(sourceSeconds: 0, clockFrame: 0))
        XCTAssertEqual(timeline.position(at: 101), .music(sourceSeconds: 0.02, clockFrame: 0))
        XCTAssertEqual(timeline.position(at: 102), .music(sourceSeconds: 0.04, clockFrame: 1))
        XCTAssertEqual(timeline.clocks(at: 0).startsIn, 50)
        XCTAssertEqual(timeline.clocks(at: 101).elapsed, 0)
        XCTAssertEqual(timeline.clocks(at: 599).remaining, 1)
        XCTAssertEqual(timeline.position(ofClockFrame: 1), 102)
        XCTAssertTrue(timeline.audioFilterChain.hasSuffix("apad=whole_len=576000,atrim=end_sample=576000"))
        XCTAssertTrue(timeline.audioFilterChain.contains("adelay=delays=96000S:all=1"))
    }

    func testFps50() {
        let timeline = ClipTimeline(duration: 10.01, standard: TimelineRate.fps50)
        XCTAssertEqual(timeline.frameRate, 50)
        XCTAssertEqual(timeline.positionsPerFrame, 1)
        XCTAssertEqual(timeline.samplesPerFrame, 960)
        XCTAssertEqual(timeline.outputFrames, 501) // 500.5 rounds up
        XCTAssertEqual(timeline.positionCount, 501)
        XCTAssertEqual(timeline.totalSamples, 501 * 960)
        XCTAssertEqual(timeline.clockFrames, 251) // the 25 base still rounds up
        XCTAssertEqual(timeline.clocks(at: 0).remaining, 251)
        XCTAssertEqual(timeline.clocks(at: 500).remaining, 1)
        XCTAssertEqual(timeline.clocks(at: 501).remaining, 1) // end position, elapsed 250
        XCTAssertEqual(ClipTimeline(duration: 2, trim: TrimSettings(preRoll: 3), standard: TimelineRate.fps50).preRollFrames, 150)
    }

    func testFiftyHertzRemainingNeverZeroBeforeLastImage() {
        for rate in [TimelineRate.fields50, .fps50] {
            for seconds in Self.durations {
                let timeline = ClipTimeline(duration: seconds, standard: rate)
                let last = timeline.clocks(at: timeline.positionCount - 1)
                XCTAssertGreaterThanOrEqual(last.remaining, 1, "\(rate) \(seconds)")
                XCTAssertLessThan(last.elapsed, timeline.clockFrames)
                XCTAssertEqual(timeline.totalSamples % rate.samplesPerFrame, 0)
            }
        }
    }

    func testCustomProviderConforms() {
        struct Standard: TimelineRateProviding {
            let encodeRate = 50
            let samplesPerFrame = 1920
        }
        XCTAssertEqual(ClipTimeline(duration: 4, standard: Standard()).rate, .fields50)
    }

    // MARK: - Short tracks

    func testShortTracksDoNotCrash() {
        let markers = MusicMarkers(detectedMusicEnd: 0.1, detectedFadeStart: 0.05)
        for rate in [TimelineRate.fps25, .fields50, .fps50] {
            for seconds in [0, 0.001, 0.2, 1.5, 4] {
                for preRoll in TrimSettings.preRollChoices {
                    let trim = TrimSettings(fadeIn: 5, fadeOut: 5, preRoll: preRoll)
                    for target in CountdownTarget.allCases {
                        let timeline = ClipTimeline(duration: seconds, trim: trim, markers: markers,
                                                    target: target, standard: rate)
                        XCTAssertGreaterThanOrEqual(timeline.musicFrames, 1)
                        for position in [-1, 0, timeline.preRollPositions, timeline.positionCount - 1,
                                         timeline.positionCount, timeline.positionCount + 100] {
                            let clocks = timeline.clocks(at: position)
                            XCTAssertGreaterThanOrEqual(clocks.remaining, 0)
                            XCTAssertGreaterThanOrEqual(clocks.elapsed, 0)
                            XCTAssertLessThanOrEqual(clocks.elapsed, timeline.clockFrames)
                            _ = timeline.position(at: position)
                        }
                        XCTAssertFalse(timeline.audioFilters().isEmpty)
                    }
                }
            }
        }
    }

    func testNonFiniteInputsAreSanitised() {
        let trim = TrimSettings(inPoint: .nan, outPoint: .infinity, fadeIn: .nan, fadeOut: .infinity, preRoll: .nan)
        let timeline = ClipTimeline(duration: .nan, trim: trim, markers: MusicMarkers(detectedMusicEnd: .nan),
                                    target: .musicEnd)
        XCTAssertEqual(timeline.outputFrames, 1)
        XCTAssertEqual(timeline.audioFilterChain, "aresample=48000,apad=whole_len=1920,atrim=end_sample=1920")
    }
}
