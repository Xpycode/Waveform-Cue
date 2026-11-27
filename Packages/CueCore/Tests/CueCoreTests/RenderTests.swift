import XCTest
import CoreGraphics
@testable import CueCore

/// Task 2.1: the renderer and the monitor's hit-testing read `CueLayout`.
final class RenderTests: XCTestCase {

    // MARK: - Helpers

    static func bitmap() -> CGContext {
        let flags = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 7680,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: flags)!
    }

    static func pixels(_ ctx: CGContext) -> [UInt8] {
        Array(UnsafeBufferPointer(start: ctx.data!.assumingMemoryBound(to: UInt8.self),
                                  count: ctx.bytesPerRow * ctx.height))
    }

    /// Renders through the timeline entry point with a layout computed once from the appearance.
    static func render(_ track: AudioTrack, timeline: ClipTimeline, position: Int, label: CueLabel,
                       appearance: CueAppearance) -> [UInt8] {
        let ctx = bitmap()
        let layout = appearance.layout
        CuePicture.draw(in: ctx, rect: CGRect(origin: .zero, size: CuePicture.size), track: track,
                        path: CuePicture.overviewPath(track, layout: layout), timeline: timeline,
                        layout: layout, position: position, label: label, appearance: appearance)
        return pixels(ctx)
    }

    /// The background colour as this bitmap format stores it (B, G, R, X).
    static let backgroundPixel: [UInt8] = {
        let flags = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: flags)!
        ctx.setFillColor(CuePicture.background)
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return [data[0], data[1], data[2]]
    }()

    /// Pixels inside `band` (picture points, bottom-left origin) that are not background.
    static func foreignPixels(_ pixels: [UInt8], in band: CGRect) -> Int {
        let bg = backgroundPixel
        var count = 0
        let x0 = max(0, Int(band.minX)), x1 = min(1920, Int(band.maxX.rounded(.up)))
        let y0 = max(0, Int(band.minY)), y1 = min(1080, Int(band.maxY.rounded(.up)))
        for y in y0..<y1 {
            let row = (1079 - y) * 7680   // bitmap rows run top to bottom
            for x in x0..<x1 {
                let i = row + x * 4
                if pixels[i] != bg[0] || pixels[i + 1] != bg[1] || pixels[i + 2] != bg[2] { count += 1 }
            }
        }
        return count
    }

    static func zones(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) -> SafeZones {
        SafeZones(preset: .custom, custom: .init(top: top, bottom: bottom, left: left, right: right))
    }

    // MARK: - Appearance persistence

    /// The JSON a build 10 `CueAppearance.save()` writes: no safe zones, clock position,
    /// countdown target or guides.
    static let build10JSON = """
    {"elapsed":{"color":{"red":0.84,"green":0.88,"blue":0.88},"size":"Large"},
     "remaining":{"color":{"red":0.93,"green":0.77,"blue":0.52},"size":"Extra large"},
     "overviewColor":{"red":0.5,"green":0.6,"blue":0.7},
     "warning":10,"solidRedAt":"oneSecond","fadeCloseUp":true,"fadeFullTrack":true,"zoom":5}
    """

    func testBuild10AppearanceDecodesWithDefaults() throws {
        let decoded = try JSONDecoder().decode(CueAppearance.self, from: Data(Self.build10JSON.utf8))
        XCTAssertEqual(decoded.elapsed.size, .large)
        XCTAssertEqual(decoded.remaining.size, .extraLarge)
        XCTAssertEqual(decoded.overviewColor, CueColor(0.5, 0.6, 0.7))
        XCTAssertNil(decoded.detailColor)
        XCTAssertEqual(decoded.warning, .ten)
        XCTAssertEqual(decoded.solidRedAt, .oneSecond)
        XCTAssertTrue(decoded.fadeCloseUp)
        XCTAssertTrue(decoded.fadeFullTrack)
        XCTAssertEqual(decoded.zoom, .five)
        XCTAssertEqual(decoded.safeZones, .none)
        XCTAssertEqual(decoded.clockPosition, .below)
        XCTAssertEqual(decoded.countdownTarget, .fileEnd)
        XCTAssertFalse(decoded.showGuides)
        XCTAssertEqual(decoded.layout, CueLayout(zoom: .five, elapsed: .large, remaining: .extraLarge))
    }

    func testNewSettingsRoundTripAndToleratePoorValues() throws {
        var appearance = CueAppearance()
        appearance.safeZones = Self.zones(top: 4, bottom: 22, left: 3, right: 9)
        appearance.clockPosition = .above
        appearance.countdownTarget = .musicEnd
        appearance.showGuides = true
        let data = try JSONEncoder().encode(appearance)
        XCTAssertEqual(try JSONDecoder().decode(CueAppearance.self, from: data), appearance)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.build10JSON.utf8)) as? [String: Any])
        object["safeZones"] = "garbage"
        object["clockPosition"] = "sideways"
        object["countdownTarget"] = 3
        object["showGuides"] = "yes"
        let poor = try JSONDecoder().decode(CueAppearance.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(poor.safeZones, .none)
        XCTAssertEqual(poor.clockPosition, .below)
        XCTAssertEqual(poor.countdownTarget, .fileEnd)
        XCTAssertFalse(poor.showGuides)
        XCTAssertEqual(poor.zoom, .five)
    }

    // MARK: - Timeline entry point

    func testTimelineEntryAt25MatchesFrameEntryAndBaseline() {
        let track = BaselineTests.syntheticTrack()
        let timeline = ClipTimeline(duration: track.seconds)
        XCTAssertEqual(timeline.positionCount, track.frames)
        for item in BaselineTests.cases {
            for frame in BaselineTests.frames(for: track) {
                let viaTimeline = Data(Self.render(track, timeline: timeline, position: frame,
                                                   label: item.label, appearance: item.appearance))
                XCTAssertEqual(BaselineTests.hash(viaTimeline), BaselineTests.expected["\(item.name)@\(frame)"],
                               "\(item.name)@\(frame)")
            }
        }
    }

    /// Settings this task adds but does not render yet leave build 10's picture unchanged.
    func testUnrenderedSettingsKeepBaseline() {
        let track = BaselineTests.syntheticTrack()
        var appearance = CueAppearance()
        appearance.showGuides = true
        appearance.countdownTarget = .musicEnd
        appearance.safeZones = SafeZones(preset: .none, custom: .init(top: 20, bottom: 20))
        let data = BaselineTests.render(track, frame: 625, label: CueLabel(text: "Baseline Track"), appearance: appearance)
        XCTAssertEqual(BaselineTests.hash(data), BaselineTests.expected["default@625"])
    }

    func testPlayheadMovesPerFieldAt50() {
        let track = BaselineTests.syntheticTrack()
        let label = CueLabel(text: "Fields")
        var appearance = CueAppearance()
        appearance.zoom = .two
        let at25 = ClipTimeline(duration: track.seconds)
        for rate in [TimelineRate.fields50, .fps50] {
            let at50 = ClipTimeline(duration: track.seconds, standard: rate)
            XCTAssertEqual(at50.positionCount, 2 * track.frames)
            XCTAssertEqual(CuePicture.playheadFrame(timeline: at50, position: 601), 300.5)
            XCTAssertEqual(CuePicture.playheadFrame(timeline: at50, position: -4), 0)
            XCTAssertEqual(CuePicture.playheadFrame(timeline: at50, position: 99_999), Double(track.frames))
            let even = Self.render(track, timeline: at50, position: 600, label: label, appearance: appearance)
            let odd = Self.render(track, timeline: at50, position: 601, label: label, appearance: appearance)
            let next = Self.render(track, timeline: at50, position: 602, label: label, appearance: appearance)
            // An even position is the 25 fps frame; the odd field between has its own playhead.
            XCTAssertEqual(even, Self.render(track, timeline: at25, position: 300, label: label, appearance: appearance))
            XCTAssertEqual(next, Self.render(track, timeline: at25, position: 301, label: label, appearance: appearance))
            XCTAssertNotEqual(odd, even)
            XCTAssertNotEqual(odd, next)
            // Clocks read the timeline: both images of a 25-base frame show the same reading.
            XCTAssertEqual(at50.clocks(at: 601).elapsed, 300)
        }
    }

    // MARK: - Reserved bands

    func testReservedBandsHoldOnlyBackground() {
        let track = BaselineTests.syntheticTrack()
        struct Setting { let name: String; let zones: SafeZones; let zoom: ZoomWindow; let position: ClockPosition
                         let elapsed: ClockSize; let remaining: ClockSize }
        let settings = [
            Setting(name: "EVS OSD", zones: SafeZones(preset: .evsOSD), zoom: .auto, position: .below,
                    elapsed: .medium, remaining: .medium),
            Setting(name: "EVS OSD, clocks above", zones: SafeZones(preset: .evsOSD), zoom: .auto, position: .above,
                    elapsed: .large, remaining: .extraLarge),
            Setting(name: "asymmetric custom", zones: Self.zones(top: 4, bottom: 25, left: 9, right: 2), zoom: .five,
                    position: .below, elapsed: .extraLarge, remaining: .small),
            Setting(name: "zoom Off, clocks above", zones: Self.zones(top: 18, bottom: 7, left: 12, right: 12),
                    zoom: .off, position: .above, elapsed: .medium, remaining: .large),
            Setting(name: "zoom Off, bottom heavy", zones: Self.zones(bottom: 30, right: 15), zoom: .off,
                    position: .below, elapsed: .extraLarge, remaining: .extraLarge),
        ]
        let labels = [CueLabel(text: "A Very Long Overlay Title That Has To Be Fitted And Truncated To The Width",
                               position: CGPoint(x: 0, y: 0)),
                      CueLabel(text: "Jüngste Ägypten Qy", position: CGPoint(x: 1, y: 1)),
                      CueLabel(text: "Out of range", position: CGPoint(x: -3, y: 4))]
        for setting in settings {
            var appearance = CueAppearance()
            appearance.safeZones = setting.zones
            appearance.zoom = setting.zoom
            appearance.clockPosition = setting.position
            appearance.elapsed.size = setting.elapsed
            appearance.remaining.size = setting.remaining
            appearance.warning = .ten
            appearance.fadeFullTrack = true
            let layout = appearance.layout
            XCTAssertTrue(layout.fits, setting.name)
            XCTAssertFalse(layout.reserved.isEmpty, setting.name)
            let timeline = ClipTimeline(duration: track.seconds, standard: TimelineRate.fields50)
            for (index, position) in [0, 1, timeline.positionCount / 2 + 1, timeline.positionCount - 20,
                                      timeline.positionCount].enumerated() {
                let label = labels[index % labels.count]
                let image = Self.render(track, timeline: timeline, position: position, label: label,
                                        appearance: appearance)
                for band in layout.reserved {
                    XCTAssertEqual(Self.foreignPixels(image, in: band), 0,
                                   "\(setting.name), position \(position), band \(band)")
                }
                // Sanity: the usable area does hold the picture.
                XCTAssertGreaterThan(Self.foreignPixels(image, in: layout.usable), 10_000, setting.name)
            }
        }
    }

    /// Control: build 10's layout does draw into the EVS OSD bands, so the check above can fail.
    func testBandCheckDetectsBuild10Intrusion() {
        let track = BaselineTests.syntheticTrack()
        let image = Self.render(track, timeline: ClipTimeline(duration: track.seconds), position: 375,
                                label: CueLabel(text: "Baseline Track"), appearance: CueAppearance())
        let bands = CueLayout(safeZones: SafeZones(preset: .evsOSD)).reserved
        XCTAssertEqual(bands.count, 2)
        for band in bands { XCTAssertGreaterThan(Self.foreignPixels(image, in: band), 100, "\(band)") }
    }

    func testTitleTravelClampedToUsableArea() {
        let layout = CueLayout(zoom: .auto, clockPosition: .above, safeZones: Self.zones(top: 12, bottom: 20, left: 6, right: 6))
        for position in [CGPoint(x: -1, y: -1), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 0.5)] {
            let box = CuePicture.caption(CueLabel(text: "Clamp me", position: position), layout: layout).1
            XCTAssertTrue(layout.titleArea.contains(box), "\(position)")
            XCTAssertTrue(layout.usable.contains(box), "\(position)")
        }
        let label = CueLabel(text: "Clamp me", position: CGPoint(x: 0.5, y: 0.5))
        let far = CuePicture.draggedTitlePosition(origin: label.position, down: CGPoint(x: 900, y: 500),
                                                  to: CGPoint(x: 5000, y: -5000), label: label, layout: layout)
        XCTAssertEqual(far, CGPoint(x: 1, y: 0))
    }

    // MARK: - Hit-testing

    /// Build 10's `MonitorView`: picture point from the view point, then
    /// `(p.x - wave.minX) / wave.width` across the scrub range.
    static func build10Seek(_ viewPoint: CGPoint, picture: CGRect, range: Range<Int>) -> Int {
        let p = CGPoint(x: (viewPoint.x - picture.minX) / picture.width * 1920,
                        y: (viewPoint.y - picture.minY) / picture.height * 1080)
        let fraction = min(1, max(0, (p.x - 96) / 1728))
        return range.lowerBound + Int((fraction * CGFloat(range.count)).rounded())
    }

    func testClickSeeksToBuild10Frame() {
        let layout = CueAppearance().layout
        let picture = CGRect(x: 8, y: 20, width: 960, height: 540)
        let label = CueLabel(text: "Baseline Track")
        // A click on the full-track waveform, 492 view points in: picture (984, 792).
        let click = CGPoint(x: 500, y: 416)
        let p = CuePicture.picturePoint(click, in: picture)
        XCTAssertEqual(p.x, 984, accuracy: 1e-9)
        XCTAssertEqual(p.y, 792, accuracy: 1e-9)
        XCTAssertEqual(CuePicture.hitTarget(at: p, label: label, layout: layout), .overview)
        let frame = CuePicture.scrubFrame(at: p, in: 0..<750, layout: layout)
        XCTAssertEqual(frame, 385)
        XCTAssertEqual(frame, Self.build10Seek(click, picture: picture, range: 0..<750))

        // The close-up scrubs inside the held window.
        let detailClick = CGPoint(x: 300, y: 260)
        let q = CuePicture.picturePoint(detailClick, in: picture)
        XCTAssertEqual(CuePicture.hitTarget(at: q, label: label, layout: layout), .detail)
        let held = CuePicture.closeUp(frame: 375, total: 750, zoom: .auto)
        XCTAssertEqual(CuePicture.scrubFrame(at: q, in: held, layout: layout),
                       Self.build10Seek(detailClick, picture: picture, range: held))

        // The title, at its default top-left position, takes the click first.
        let title = CuePicture.caption(label, layout: layout).1
        XCTAssertEqual(CuePicture.hitTarget(at: CGPoint(x: title.midX, y: title.midY), label: label, layout: layout), .title)
        XCTAssertEqual(CuePicture.hitTarget(at: CGPoint(x: 960, y: 20), label: label, layout: layout), .none)

        // Zoom Off: the full-track waveform covers the close-up's place.
        var off = CueAppearance()
        off.zoom = .off
        XCTAssertEqual(CuePicture.hitTarget(at: q, label: label, layout: off.layout), .overview)
        // Ends clamp.
        XCTAssertEqual(CuePicture.scrubFrame(at: CGPoint(x: 0, y: 792), in: 0..<750, layout: layout), 0)
        XCTAssertEqual(CuePicture.scrubFrame(at: CGPoint(x: 1920, y: 792), in: 0..<750, layout: layout), 750)
    }

    func testTitleDragMatchesBuild10() {
        let layout = CueLayout()
        let label = CueLabel(text: "Drag", position: CGPoint(x: 0.2, y: 0.7))
        let box = CuePicture.caption(label, layout: layout).1
        let down = CGPoint(x: 600, y: 700), to = CGPoint(x: 811, y: 433)
        let build10 = CGPoint(x: min(1, max(0, 0.2 + (to.x - down.x) / max(1, 1728 - box.width))),
                              y: min(1, max(0, 0.7 + (to.y - down.y) / (1080 - 110 - box.height))))
        XCTAssertEqual(CuePicture.draggedTitlePosition(origin: label.position, down: down, to: to,
                                                       label: label, layout: layout), build10)
    }

    func testScrubFollowsSafeZoneLayout() {
        var appearance = CueAppearance()
        appearance.safeZones = Self.zones(left: 10, right: 5)
        let layout = appearance.layout
        XCTAssertGreaterThan(layout.contentMinX, 96)
        let y = layout.overview.midY
        XCTAssertEqual(CuePicture.hitTarget(at: CGPoint(x: layout.overview.midX, y: y), label: CueLabel(), layout: layout), .overview)
        XCTAssertEqual(CuePicture.scrubFrame(at: CGPoint(x: layout.contentMinX, y: y), in: 0..<750, layout: layout), 0)
        XCTAssertEqual(CuePicture.scrubFrame(at: CGPoint(x: layout.overview.midX, y: y), in: 0..<750, layout: layout), 375)
        XCTAssertEqual(CuePicture.scrubFrame(at: CGPoint(x: layout.contentMaxX, y: y), in: 0..<750, layout: layout), 750)
    }
}
