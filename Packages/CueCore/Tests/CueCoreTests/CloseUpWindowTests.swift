import XCTest
@testable import CueCore

final class CloseUpWindowTests: XCTestCase {
    private let zooms: [ZoomWindow] = [.two, .five, .ten, .twenty, .thirty, .sixty, .auto]
    private let tolerance = 1e-9

    private func startingWidth(_ zoom: ZoomWindow, frames: Int) -> Double {
        zoom == .auto ? Double(zoom.frameCount(for: frames)) / 25 : Double(zoom.rawValue)
    }

    func testLegacyFieldWindowSelectsTheSameFiveMillisecondPeakBuckets() {
        let timeline = ClipTimeline(duration: 30, standard: TimelineRate.fields50)
        var look = CueAppearance()
        look.zoom = .five
        // The upper bound of field 127 is 5.06 s. One ULP more selects an extra peak bucket.
        for field in 0..<timeline.positionCount {
            let lowerFrame = min(max(0, Double(field) / 2 - 62), 625)
            let window = CuePicture.closeUp(timeline: timeline, position: field, appearance: look)
            XCTAssertEqual(window.visible.lowerBound, lowerFrame / 25)
            XCTAssertEqual(window.visible.upperBound, (lowerFrame + 125) / 25)
        }
    }

    func testPicturePassesTheEffectiveSourceTargetAndEachFieldToTheInterval() {
        let timeline = ClipTimeline(duration: 30, trim: TrimSettings(inPoint: 3.28, outPoint: 23, preRoll: 1),
                                    markers: MusicMarkers(detectedMusicEnd: 17.21), target: .musicEnd, standard: TimelineRate.fields50)
        var look = CueAppearance()
        look.zoom = .five
        look.endZoom = .two
        for mode in PlayheadMode.allCases {
            look.playheadMode = mode
            for field in stride(from: 710, through: 600, by: -1) {
                let expected = CloseUpWindow.interval(playhead: 3.28 + Double(field - 50) / 50,
                                                      clip: 3.28...23, target: 17.21, startingWidth: 5,
                                                      mode: mode, endZoom: .two)
                let result = CuePicture.closeUp(timeline: timeline, position: field, appearance: look)
                XCTAssertEqual(result.visible.lowerBound, expected.visible.lowerBound, accuracy: tolerance)
                XCTAssertEqual(result.visible.upperBound, expected.visible.upperBound, accuracy: tolerance)
            }
        }
    }

    func testCenteredFiveSecondWindowHasBlankSpaceAtTrimBoundaries() {
        let clip = 8.0...12.0
        let first = CloseUpWindow.interval(playhead: 8, clip: clip, target: 12,
                                           startingWidth: 5, mode: .centered, endZoom: .off)
        XCTAssertEqual(first.visible, 5.5...10.5)
        XCTAssertEqual(first.intersection, 8...10.5)
        let last = CloseUpWindow.interval(playhead: 12, clip: clip, target: 12,
                                          startingWidth: 5, mode: .centered, endZoom: .off)
        XCTAssertEqual(last.visible, 9.5...14.5)
        XCTAssertEqual(last.intersection, 9.5...12)
    }

    func testOffMatchesBuild11AtEveryHalfFrameIncludingOddWidths() {
        // Keep the build 11 oracle independent of the renderer that will adopt this helper.
        for frames in [1, 100, 125, 201, 301, 750, 752] {
            let clip = 1.28...(1.28 + Double(frames) / 25)
            for zoom in zooms {
                let length = zoom.frameCount(for: frames)
                for field in 0...(frames * 2) {
                    let frame = Double(field) / 2
                    // Integer half-width is intentional. A five-second zoom has 125 frames.
                    let lower = min(max(0, frame - Double(length / 2)), Double(frames - length))
                    let window = CloseUpWindow.interval(playhead: clip.lowerBound + frame / 25,
                                                        clip: clip, target: clip.upperBound,
                                                        startingWidth: startingWidth(zoom, frames: frames),
                                                        mode: .edgeHeld, endZoom: .off)
                    XCTAssertEqual(window.visible.lowerBound, clip.lowerBound + lower / 25, accuracy: tolerance)
                    XCTAssertEqual(window.visible.upperBound, clip.lowerBound + (lower + Double(length)) / 25,
                                   accuracy: tolerance)
                }
            }
        }
    }

    func testPartialLastClockFrameKeepsBuild11WindowAndClipsHighlightToSource() {
        for start in [0.0, 3.283] {
            let clip = start...(start + 6.01)
            let timeline = ClipTimeline(duration: 20, trim: TrimSettings(inPoint: start, outPoint: clip.upperBound),
                                        standard: TimelineRate.fields50)
            XCTAssertEqual(timeline.clockFrames, 151)
            let lastField = timeline.positionCount - 1
            XCTAssertEqual(CuePicture.playheadFrame(timeline: timeline, position: lastField), 150.5)
            // Build 11 freezes these windows at the end of the 151st clock frame (6.04 s).
            for (zoom, lower) in [(ZoomWindow.five, 1.04), (.auto, 3.04), (.ten, 0.0)] {
                for position in (lastField - 1)...timeline.positionCount {
                    let frame = CuePicture.playheadFrame(timeline: timeline, position: position)
                    let time = start + frame / 25
                    let window = CloseUpWindow.interval(playhead: time, clip: timeline.sourceRange,
                                                        target: clip.upperBound,
                                                        startingWidth: startingWidth(zoom, frames: timeline.clockFrames),
                                                        mode: .edgeHeld, endZoom: .off)
                    XCTAssertEqual(window.visible.lowerBound, start + lower, accuracy: tolerance)
                    XCTAssertEqual(window.visible.upperBound, start + 6.04, accuracy: tolerance)
                    XCTAssertEqual(window.intersection.upperBound, clip.upperBound, accuracy: tolerance)
                    XCTAssertTrue(window.visible.contains(time))
                }
            }
        }
    }

    func testPartialLastClockFrameRetainsFractionalPlayheadInBothModesWithEndZoom() {
        let clip = 3.283...9.293
        let target = clip.upperBound
        for offset in [5.98, 6, 6.01, 6.02, 6.04] {
            let time = clip.lowerBound + offset
            let edge = CloseUpWindow.interval(playhead: time, clip: clip, target: target, startingWidth: 5,
                                              mode: .edgeHeld, endZoom: .two)
            XCTAssertEqual(edge.visible.upperBound, max(time, target), accuracy: tolerance)
            XCTAssertEqual(edge.visible.lowerBound, max(time, target) - 2, accuracy: tolerance)
            XCTAssertEqual(edge.intersection.upperBound, clip.upperBound, accuracy: tolerance)
            let centered = CloseUpWindow.interval(playhead: time, clip: clip, target: target, startingWidth: 5,
                                                  mode: .centered, endZoom: .two)
            XCTAssertEqual(centered.visible.lowerBound, time - 1, accuracy: tolerance)
            XCTAssertEqual(centered.visible.upperBound, time + 1, accuracy: tolerance)
        }
    }

    func testOneSecondEaseInterpolatesBothEdgesToTargetThenFollowsSilentTail() {
        let clip = 2.0...32.0
        let target = 22.0
        for endZoom in [EndZoom.two, .three, .five] {
            let final = Double(endZoom.rawValue)
            let onset = target - 0.75 * final - 1
            for progress in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let playhead = onset + progress
                let eased = progress * progress * (3 - 2 * progress)
                let original = playhead - 5
                let window = CloseUpWindow.interval(playhead: playhead, clip: clip, target: target,
                                                    startingWidth: 10, mode: .edgeHeld, endZoom: endZoom)
                XCTAssertEqual(window.visible.lowerBound, original + (target - final - original) * eased,
                               accuracy: tolerance)
                XCTAssertEqual(window.visible.upperBound, original + 10 + (target - original - 10) * eased,
                               accuracy: tolerance)
            }
            for playhead in [target, target + 0.02, target + 4, clip.upperBound] {
                let window = CloseUpWindow.interval(playhead: playhead, clip: clip, target: target,
                                                    startingWidth: 10, mode: .edgeHeld, endZoom: endZoom)
                XCTAssertEqual(window.visible.lowerBound, playhead - final, accuracy: tolerance)
                XCTAssertEqual(window.visible.upperBound, playhead, accuracy: tolerance)
            }
        }
    }

    func testHalfFrameSweepOverWidthsTargetsTrimsAndReverseJog() {
        for duration in [4, 6, 8, 12, 30] {
            let clip = 3.28...(3.28 + Double(duration))
            // A marker just after trim-in also exercises easing already in progress at the head.
            var targets = [clip.upperBound, clip.lowerBound + 2.4]
            if duration > 10 { targets.append(clip.upperBound - 10) }
            for target in targets {
                for zoom in zooms {
                    for mode in PlayheadMode.allCases {
                        for endZoom in EndZoom.allCases {
                            checkSweep(clip: clip, duration: duration, target: target, zoom: zoom,
                                       mode: mode, endZoom: endZoom)
                        }
                    }
                }
            }
        }
    }

    private func checkSweep(clip: ClosedRange<Double>, duration: Int, target: Double, zoom: ZoomWindow,
                            mode: PlayheadMode, endZoom: EndZoom) {
        let start = startingWidth(zoom, frames: duration * 25)
        let initial = mode == .edgeHeld ? min(start, Double(duration)) : start
        let final = endZoom == .off ? initial : min(initial, Double(endZoom.rawValue))
        let active = final < initial
        let step = 0.02
        // Both uneased edges move at most 1 s/s. Blending adds at most 1.5 (peak
        // smoothstep slope over one second) times their separation, at most the start width
        // while interpolating: both source windows contain the playhead, or the approaching
        // target lies up to one further second away. The final containment clamp is 1-Lipschitz.
        let bound = active ? 1 + 1.5 * (initial + 1) : 1
        func window(_ field: Int) -> CloseUpWindow {
            CloseUpWindow.interval(playhead: clip.lowerBound + Double(field) / 50, clip: clip,
                                   target: target, startingWidth: start, mode: mode, endZoom: endZoom)
        }
        let fields = 0...(duration * 50)
        let forward = fields.map(window)
        var previousWidth = initial
        for field in fields {
            let playhead = clip.lowerBound + Double(field) / 50
            let visible = forward[field].visible
            let width = visible.upperBound - visible.lowerBound
            let progress = min(1, max(0, playhead - target + 0.75 * final + 1))
            let expectedWidth = initial + (final - initial) * progress * progress * (3 - 2 * progress)
            let stepLimit = step * bound + tolerance
            let previous = forward[max(0, field - 1)].visible
            let valid = abs(width - expectedWidth) < tolerance && width <= previousWidth + tolerance
                && visible.lowerBound <= playhead + tolerance && visible.upperBound >= playhead - tolerance
                && abs(visible.lowerBound - previous.lowerBound) <= stepLimit
                && abs(visible.upperBound - previous.upperBound) <= stepLimit
                && forward[field].intersection == visible.clamped(to: clip)
            let centered = abs((visible.lowerBound + visible.upperBound) / 2 - playhead) < tolerance
            let targetHeld = visible.lowerBound <= target + tolerance && visible.upperBound >= target - tolerance
            let shouldHold = active && progress == 1 && playhead <= target
            guard valid, mode == .centered ? centered : (visible == forward[field].intersection && (!shouldHold || targetHeld)) else {
                XCTFail("Window \(visible) at \(playhead), clip \(clip), target \(target), \(zoom), \(mode), \(endZoom)")
                return
            }
            previousWidth = width
        }
        for field in fields.reversed() {
            XCTAssertEqual(window(field), forward[field])
        }
    }
}
