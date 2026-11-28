import XCTest
import CoreGraphics
@testable import CueCore

/// Task 3.2: markers on both waveforms, countdown target Music end, and marker hit-testing.
final class CountdownTests: XCTestCase {

    // MARK: - Fixtures

    /// The 30 s baseline track with its music ending at 26 s (650 clock frames) and the fade
    /// starting at 24 s (600).
    static let markers = MusicMarkers(detectedMusicEnd: 26, detectedFadeStart: 24)

    static func track(markers: MusicMarkers = CountdownTests.markers) -> AudioTrack {
        var track = BaselineTests.syntheticTrack()
        track.markers = markers
        return track
    }

    static func appearance(target: CountdownTarget, warning: CountdownWarning = .ten,
                           solidRedAt: SolidRedThreshold = .oneSecond) -> CueAppearance {
        var appearance = CueAppearance()
        appearance.countdownTarget = target
        appearance.warning = warning
        appearance.solidRedAt = solidRedAt
        appearance.fadeCloseUp = true
        appearance.fadeFullTrack = true
        return appearance
    }

    static func render(_ track: AudioTrack, timeline: ClipTimeline, position: Int,
                       appearance: CueAppearance, label: CueLabel = CueLabel(text: "Countdown")) -> [UInt8] {
        RenderTests.render(track, timeline: timeline, position: position, label: label, appearance: appearance)
    }

    static func timeline(_ track: AudioTrack, _ appearance: CueAppearance) -> ClipTimeline {
        CuePicture.timeline(for: track, appearance: appearance)
    }

    /// The pixels of one picture region (bottom-left origin), row by row.
    static func region(_ pixels: [UInt8], _ rect: CGRect) -> [UInt8] {
        var out: [UInt8] = []
        let x0 = max(0, Int(rect.minX)), x1 = min(1920, Int(rect.maxX.rounded(.up)))
        let y0 = max(0, Int(rect.minY)), y1 = min(1080, Int(rect.maxY.rounded(.up)))
        for y in y0..<y1 {
            let row = (1079 - y) * 7680
            out.append(contentsOf: pixels[(row + x0 * 4)..<(row + x1 * 4)])
        }
        return out
    }

    /// Pixels exactly the colour given (B, G, R in this bitmap format) inside a region.
    static func count(_ color: CGColor, in pixels: [UInt8], _ rect: CGRect) -> Int {
        let flags = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: flags)!
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let target = [d[0], d[1], d[2]]
        let data = region(pixels, rect)
        var n = 0
        for i in stride(from: 0, to: data.count, by: 4)
        where data[i] == target[0] && data[i + 1] == target[1] && data[i + 2] == target[2] { n += 1 }
        return n
    }

    static var red: CGColor { CueColor.warningRed.cgColor }

    // MARK: - Clocks

    func testRemainingCountsToMusicEnd() {
        let timeline = Self.timeline(Self.track(), Self.appearance(target: .musicEnd))
        XCTAssertEqual(timeline.targetClockFrames, 650)
        XCTAssertEqual(timeline.clocks(at: 400).remaining, 250)
        XCTAssertEqual(timeline.clocks(at: 649).remaining, 1)
        XCTAssertEqual(timeline.clocks(at: 650).remaining, 0)
        XCTAssertTrue(timeline.clocks(at: 650).isPastTarget)
        XCTAssertEqual(timeline.clocks(at: 720).remainingText, "00:00:00")
        XCTAssertEqual(timeline.clocks(at: 720).toFileEnd, 30)
        // File end ignores the marker.
        let fileEnd = Self.timeline(Self.track(), Self.appearance(target: .fileEnd))
        XCTAssertEqual(fileEnd.clocks(at: 400).remaining, 350)
        XCTAssertFalse(fileEnd.clocks(at: 720).isPastTarget)
    }

    // MARK: - Frame tests

    /// Up to the marker, Music end draws Remaining exactly as a clip whose file ended at the
    /// marker: same reading, same fade to red, same solid-red threshold.
    func testRemainingMatchesAClipEndingAtTheMarker() {
        let track = Self.track()
        let appearance = Self.appearance(target: .musicEnd)
        let musicEnd = Self.timeline(track, appearance)
        let cut = ClipTimeline(duration: track.seconds, trim: TrimSettings(outPoint: 26))
        var reference = appearance
        reference.countdownTarget = .fileEnd
        let clock = appearance.layout.extent(of: .remainingClock)!
        // 400: fade start (250 left, not yet tinted); 401: first tinted; 624 / 625: either side
        // of the 1 s solid-red threshold; 650: the marker.
        for frame in [0, 399, 400, 401, 500, 624, 625, 649, 650] {
            let a = Self.render(track, timeline: musicEnd, position: frame, appearance: appearance)
            let b = Self.render(track, timeline: cut, position: frame, appearance: reference)
            XCTAssertTrue(Self.region(a, clock) == Self.region(b, clock), "frame \(frame)")
        }
    }

    func testFadeStartAndSolidRedMeasureToTheMarker() {
        let track = Self.track()
        let musicEnd = Self.appearance(target: .musicEnd)
        let fileEnd = Self.appearance(target: .fileEnd)
        var untinted = musicEnd
        untinted.warning = .off
        let layout = musicEnd.layout
        let clock = layout.extent(of: .remainingClock)!
        let detail = layout.detail!
        let overview = layout.overview
        let mTimeline = Self.timeline(track, musicEnd)
        let fTimeline = Self.timeline(track, fileEnd)
        let uTimeline = Self.timeline(track, untinted)

        // Fade start (250 frames before the marker): untouched at 400, tinted from 401.
        let at400 = Self.render(track, timeline: mTimeline, position: 400, appearance: musicEnd)
        XCTAssertTrue(at400 == Self.render(track, timeline: uTimeline, position: 400, appearance: untinted))
        let at401 = Self.render(track, timeline: mTimeline, position: 401, appearance: musicEnd)
        let un401 = Self.render(track, timeline: uTimeline, position: 401, appearance: untinted)
        XCTAssertTrue(Self.region(at401, clock) != Self.region(un401, clock))
        XCTAssertTrue(Self.region(at401, detail) != Self.region(un401, detail), "close-up fade")
        XCTAssertTrue(Self.region(at401, overview) != Self.region(un401, overview), "full-track fade")
        // File end has not started its fade at 401 (349 left).
        let f401 = Self.render(track, timeline: fTimeline, position: 401, appearance: fileEnd)
        var fileEndUntinted = fileEnd
        fileEndUntinted.warning = .off
        XCTAssertTrue(f401 == Self.render(track, timeline: fTimeline, position: 401, appearance: fileEndUntinted))

        // Solid red (1 s before the marker): Remaining, the played close-up and full track are
        // the warning red at 625; with File end they are still blending (125 left).
        let at625 = Self.render(track, timeline: mTimeline, position: 625, appearance: musicEnd)
        XCTAssertGreaterThan(Self.count(Self.red, in: at625, clock), 200)
        XCTAssertGreaterThan(Self.count(Self.red, in: at625, detail), 2_000)
        XCTAssertGreaterThan(Self.count(Self.red, in: at625, overview), 500)
        let f625 = Self.render(track, timeline: fTimeline, position: 625, appearance: fileEnd)
        XCTAssertEqual(Self.count(Self.red, in: f625, clock), 0)
        XCTAssertEqual(Self.count(Self.red, in: f625, detail), 0)
        XCTAssertEqual(Self.count(Self.red, in: at400, clock), 0)
    }

    /// After the marker Remaining holds 00:00:00 in red until the clip ends, even with the
    /// warning off.
    func testRemainingHoldsInRedAfterTheMarker() {
        let track = Self.track()
        for warning in [CountdownWarning.off, .ten] {
            let appearance = Self.appearance(target: .musicEnd, warning: warning)
            let timeline = Self.timeline(track, appearance)
            let clock = appearance.layout.extent(of: .remainingClock)!
            let atMarker = Self.region(Self.render(track, timeline: timeline, position: 650, appearance: appearance), clock)
            for frame in [651, 700, 749, 750] {
                let image = Self.render(track, timeline: timeline, position: frame, appearance: appearance)
                XCTAssertTrue(Self.region(image, clock) == atMarker, "\(warning) frame \(frame)")
                XCTAssertGreaterThan(Self.count(Self.red, in: image, clock), 200, "\(warning) frame \(frame)")
            }
            if warning == .off {
                let before = Self.render(track, timeline: timeline, position: 649, appearance: appearance)
                XCTAssertEqual(Self.count(Self.red, in: before, clock), 0)
            }
        }
    }

    /// No marker, no music, or no tail: Music end and File end draw the same picture.
    func testTargetsMatchWithoutATail() {
        let cases: [(String, MusicMarkers)] = [
            ("no marker", .none),
            ("no music", .silent),
            ("no tail", MusicMarkers(detectedMusicEnd: 30, detectedFadeStart: 28)),
        ]
        for (name, markers) in cases {
            let track = Self.track(markers: markers)
            let musicEnd = Self.appearance(target: .musicEnd)
            let fileEnd = Self.appearance(target: .fileEnd)
            for frame in BaselineTests.frames(for: track) + [600, 740] {
                let a = Self.render(track, timeline: Self.timeline(track, musicEnd), position: frame, appearance: musicEnd)
                let b = Self.render(track, timeline: Self.timeline(track, fileEnd), position: frame, appearance: fileEnd)
                XCTAssertTrue(a == b, "\(name) frame \(frame)")
            }
        }
    }

    /// With no markers and File end the frame entry and the timeline entry stay build 10's.
    func testNoMarkersKeepsBaseline() {
        let track = BaselineTests.syntheticTrack()
        for frame in BaselineTests.frames(for: track) {
            let image = Self.render(track, timeline: CuePicture.timeline(for: track, appearance: .build10),
                                    position: frame, appearance: .build10, label: CueLabel(text: "Baseline Track"))
            XCTAssertEqual(BaselineTests.hash(Data(image)), BaselineTests.expected["default@\(frame)"])
        }
    }

    // MARK: - Markers in the picture

    func testMarkersDrawnOnBothWaveforms() {
        let track = Self.track()
        let appearance = CueAppearance.build10
        let layout = appearance.layout
        let timeline = Self.timeline(track, appearance)
        // Playhead 640: close-up window 500..<750 holds both markers.
        let image = Self.render(track, timeline: timeline, position: 640, appearance: appearance)
        let overview = layout.overview, detail = layout.detail!
        func column(_ rect: CGRect, frame: Double, lower: Double, count: Double) -> CGRect {
            let x = rect.minX + rect.width * CGFloat((frame - lower) / count)
            return CGRect(x: x - 3, y: rect.minY, width: 6, height: rect.height)
        }
        XCTAssertGreaterThan(Self.count(CuePicture.musicEndColor, in: image,
                                        column(overview, frame: 650, lower: 0, count: 750)), 50)
        XCTAssertGreaterThan(Self.count(CuePicture.fadeStartColor, in: image,
                                        column(overview, frame: 600, lower: 0, count: 750)), 20)
        XCTAssertGreaterThan(Self.count(CuePicture.musicEndColor, in: image,
                                        column(detail, frame: 650, lower: 500, count: 250)), 200)
        XCTAssertGreaterThan(Self.count(CuePicture.fadeStartColor, in: image,
                                        column(detail, frame: 600, lower: 500, count: 250)), 100)
        // Out of the close-up window (playhead 100: window 0..<250), no marker in the close-up.
        let early = Self.render(track, timeline: timeline, position: 100, appearance: appearance)
        XCTAssertEqual(Self.count(CuePicture.musicEndColor, in: early, detail), 0)
        XCTAssertGreaterThan(Self.count(CuePicture.musicEndColor, in: early, overview), 50)
        // An edited value wins over the detection.
        var edited = Self.markers
        edited.setEdited(.musicEnd, to: 18)
        let moved = Self.render(track, timeline: CuePicture.timeline(for: track, appearance: appearance, markers: edited),
                                position: 640, appearance: appearance)
        XCTAssertEqual(Self.count(CuePicture.musicEndColor, in: moved, column(overview, frame: 650, lower: 0, count: 750)), 0)
        XCTAssertGreaterThan(Self.count(CuePicture.musicEndColor, in: moved,
                                        column(overview, frame: 450, lower: 0, count: 750)), 50)
    }

    // MARK: - Hit-testing

    func testMarkerHitTest() {
        let track = Self.track()
        let appearance = CueAppearance.build10
        let layout = appearance.layout
        let timeline = Self.timeline(track, appearance)
        let label = CueLabel(text: "Countdown")
        let full = CuePicture.overviewRange(timeline)
        let endX = layout.overview.minX + layout.overview.width * 650 / 750   // 1593.6
        let y = layout.overview.midY
        let closeUp = CuePicture.closeUp(timeline: timeline, position: 640, appearance: appearance)
        XCTAssertEqual(closeUp.visible, 20...30)
        func hit(_ x: CGFloat, _ y: CGFloat) -> CuePicture.HitTarget {
            CuePicture.hitTarget(at: CGPoint(x: x, y: y), label: label, layout: layout, timeline: timeline, closeUp: closeUp)
        }
        XCTAssertEqual(hit(endX, y), .marker(.musicEnd, onCloseUp: false))
        XCTAssertEqual(hit(endX + 9, y), .marker(.musicEnd, onCloseUp: false))
        XCTAssertEqual(hit(endX - 9, layout.overview.maxY + 4), .marker(.musicEnd, onCloseUp: false))
        XCTAssertEqual(hit(endX + 12, y), .overview, "beyond tolerance it scrubs")
        let fadeX = layout.overview.minX + layout.overview.width * 600 / 750
        XCTAssertEqual(hit(fadeX + 2, y), .marker(.fadeStart, onCloseUp: false))
        // Close-up: window 500..<750.
        let detail = layout.detail!
        let detailEnd = detail.minX + detail.width * 150 / 250
        let detailFade = detail.minX + detail.width * 100 / 250
        XCTAssertEqual(hit(detailEnd - 3, detail.midY), .marker(.musicEnd, onCloseUp: true))
        XCTAssertEqual(hit(detailFade + 5, detail.midY), .marker(.fadeStart, onCloseUp: true))
        XCTAssertEqual(hit(detail.midX - 300, detail.midY), .detail)
        // The title is tested first; a waveform-free point is none.
        let title = CuePicture.caption(label, layout: layout).1
        XCTAssertEqual(hit(title.midX, title.midY), .title)
        XCTAssertEqual(hit(960, 20), CuePicture.HitTarget.none)
        // Without markers the hit-test is build 10's.
        let bare = CuePicture.timeline(for: BaselineTests.syntheticTrack(), appearance: appearance)
        XCTAssertEqual(CuePicture.hitTarget(at: CGPoint(x: endX, y: y), label: label, layout: layout,
                                            timeline: bare, closeUp: closeUp), .overview)

        // Dragging maps x to source seconds over the pane's range, clamped to the clip.
        XCTAssertEqual(CuePicture.draggedMarkerSeconds(at: CGPoint(x: layout.overview.midX, y: y), in: full,
                                                       timeline: timeline, layout: layout), 15, accuracy: 1e-9)
        XCTAssertEqual(CuePicture.draggedMarkerSeconds(at: CGPoint(x: -50, y: y), in: full,
                                                       timeline: timeline, layout: layout), 0)
        XCTAssertEqual(CuePicture.draggedMarkerSeconds(at: CGPoint(x: 5000, y: y), in: full,
                                                       timeline: timeline, layout: layout), 30)
        XCTAssertEqual(CuePicture.draggedMarkerSeconds(at: CGPoint(x: detailEnd, y: detail.midY), in: closeUp.visible,
                                                       timeline: timeline, layout: layout), 26, accuracy: 1e-9)
    }
}
