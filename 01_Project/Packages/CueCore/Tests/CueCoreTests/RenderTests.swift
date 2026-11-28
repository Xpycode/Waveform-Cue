import XCTest
import CoreGraphics
import CoreText
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
                        path: CuePicture.overviewPath(track, layout: layout, timeline: timeline), timeline: timeline,
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

    func testOldDefaultUsesNewShadingAndExplicitlySavedLegacyShadingSurvives() throws {
        let suite = "CueAppearanceTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(CueAppearance.load(from: defaults).closeUpShading, .upcomingBrighter)
        let blob = Data(Self.build10JSON.utf8)
        defaults.set(blob, forKey: "ClockAppearance.v1")
        var expected = try JSONDecoder().decode(CueAppearance.self, from: blob)
        XCTAssertEqual(expected.closeUpShading, .upcomingBrighter)
        XCTAssertEqual(CueAppearance.load(from: defaults), expected)
        expected.closeUpShading = .playedBrighter
        expected.save(to: defaults)
        XCTAssertEqual(CueAppearance.load(from: defaults), expected)
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
        object["endZoom"] = 20
        object["playheadMode"] = "future mode"
        object["closeUpShading"] = "invalid"
        object["markersEnabled"] = "no"
        object["showTitle"] = NSNull()
        let poor = try JSONDecoder().decode(CueAppearance.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(poor.safeZones, .none)
        XCTAssertEqual(poor.clockPosition, .below)
        XCTAssertEqual(poor.countdownTarget, .fileEnd)
        XCTAssertFalse(poor.showGuides)
        XCTAssertEqual(poor.zoom, .five)
        XCTAssertEqual(poor.endZoom, .off)
        XCTAssertEqual(poor.playheadMode, .centered)
        XCTAssertEqual(poor.closeUpShading, .upcomingBrighter)
        XCTAssertTrue(poor.markersEnabled)
        XCTAssertTrue(poor.showTitle)
    }

    func testBuild17DefaultAppearanceAndDamagedPaneOrder() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "build17-job", withExtension: "json"))
        let job = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var saved = try XCTUnwrap(job["appearance"] as? [String: Any])
        func decode() throws -> CueAppearance {
            try JSONDecoder().decode(CueAppearance.self, from: JSONSerialization.data(withJSONObject: saved))
        }
        let legacy = try decode()
        XCTAssertEqual(legacy.paneOrder, [.title, .clocks, .fullTrack, .closeUp])
        XCTAssertEqual(legacy.titleAlignment, .left)
        XCTAssertEqual(legacy.leftClock, .elapsed)
        XCTAssertEqual(legacy.offsets, PaneOffsets())
        let modern = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil(modern["clockPosition"])
        XCTAssertEqual(modern["paneOrder"] as? [String], ["title", "clocks", "fullTrack", "closeUp"])

        saved["paneOrder"] = ["closeUp", "future", 17, "closeUp", "title"] as [Any]
        saved["offsets"] = ["clocks": -8, "fullTrack": "invalid"] as [String: Any]
        saved["leftClock"] = 2
        let partial = try decode()
        XCTAssertEqual(partial.paneOrder, [.closeUp, .title, .fullTrack, .clocks])
        XCTAssertEqual(partial.offsets, PaneOffsets(clocks: -8))
        XCTAssertEqual(partial.leftClock, .elapsed)
        saved["paneOrder"] = "broken"
        XCTAssertEqual(try decode().paneOrder, PicturePane.defaultOrder)
    }

    // MARK: - Timeline entry point

    func testHiddenPictureHasNoPixelsOrHitTargets() {
        let track = BaselineTests.syntheticTrack()
        var look = CueAppearance()
        look.zoom = .off
        look.showFullTrack = false
        look.showElapsed = false
        look.showRemaining = false
        look.showTitle = false
        let layout = look.layout
        let label = CueLabel(text: "Hidden")
        let timeline = ClipTimeline(duration: track.seconds, markers: MusicMarkers(detectedMusicEnd: 15))
        let pixels = Self.render(track, timeline: timeline, position: 375, label: label, appearance: look)
        XCTAssertEqual(Self.foreignPixels(pixels, in: layout.usable), 0)
        XCTAssertTrue(layout.extents.isEmpty)
        for x in [CuePicture.wave.midX, CuePicture.wave.minX - 5] {
            let target = CuePicture.hitTarget(at: CGPoint(x: x, y: CuePicture.wave.midY), label: label,
                                               layout: layout, timeline: timeline, closeUp: CuePicture.closeUp(timeline: timeline, position: 375, appearance: look), trimHandles: true)
            XCTAssertEqual(target, .none)
        }
    }

    func testPhysicalTrimBoundaryLeavesPaddedPartOfOverviewEmpty() {
        let track = BaselineTests.syntheticTrack()
        let look = CueAppearance()
        let layout = look.layout
        let timeline = ClipTimeline(duration: track.seconds, trim: TrimSettings(inPoint: 1, outPoint: 2.001))
        let expected = layout.overview.minX + layout.overview.width * 1.001 / 1.04
        let path = CuePicture.overviewPath(track, layout: layout, timeline: timeline)
        XCTAssertEqual(path.boundingBox.maxX, expected, accuracy: 0.001)
        let image = Self.render(track, timeline: timeline, position: 0, label: CueLabel(), appearance: look)
        let tail = CGRect(x: expected + 3, y: layout.overview.minY + 2, width: layout.overview.maxX - expected - 6,
                          height: layout.overview.height - 4)
        XCTAssertEqual(CountdownTests.count(CuePicture.rgb(0.071, 0.102, 0.111), in: image, tail),
                       Int(tail.maxX.rounded(.up) - tail.minX.rounded(.down)) * Int(tail.height))
    }

    func testCenteredTrimKeepsBlankHalvesAndScrubsInSourceTime() throws {
        let track = BaselineTests.syntheticTrack()
        var look = CueAppearance()
        look.zoom = .five
        look.playheadMode = .centered
        let timeline = ClipTimeline(duration: track.seconds, trim: TrimSettings(inPoint: 9, outPoint: 10.2),
                                    markers: MusicMarkers(detectedFadeStart: 9.6))
        let layout = look.layout
        let detail = try XCTUnwrap(layout.detail)
        let center = CGPoint(x: detail.midX, y: detail.midY)
        let label = CueLabel()
        for position in [0, timeline.positionCount] {
            let window = CuePicture.closeUp(timeline: timeline, position: position, appearance: look)
            let image = Self.render(track, timeline: timeline, position: position, label: label, appearance: look)
            let blank = CGRect(x: position == 0 ? detail.minX + 4 : detail.midX + 4, y: detail.minY + 2,
                               width: detail.width / 2 - 8, height: detail.height - 4)
            XCTAssertEqual(CountdownTests.count(CuePicture.rgb(0.071, 0.102, 0.111), in: image, blank),
                           Int(blank.width * blank.height))
            XCTAssertEqual(CountdownTests.count(CuePicture.paper, in: image,
                                               CGRect(x: floor(center.x), y: floor(center.y), width: 1, height: 1)), 1)
            XCTAssertEqual(CuePicture.scrubFrame(at: center, in: window.visible, timeline: timeline, layout: layout),
                           position)
            let width = window.visible.upperBound - window.visible.lowerBound
            XCTAssertEqual(width, 1.2, accuracy: 1e-8)
            let marker = CGPoint(x: detail.minX + detail.width * (9.6 - window.visible.lowerBound) / width, y: detail.midY)
            XCTAssertEqual(CuePicture.hitTarget(at: marker, label: label, layout: layout, timeline: timeline,
                                                closeUp: window), .marker(.fadeStart, onCloseUp: true))
            XCTAssertEqual(CuePicture.draggedMarkerSeconds(at: marker, in: window.visible, timeline: timeline,
                                                           layout: layout), 9.6, accuracy: 1e-8)
            for (x, frame) in [(detail.minX, max(0, position - 15)), (detail.maxX, min(position + 15, timeline.clockFrames))] {
                XCTAssertEqual(CuePicture.scrubFrame(at: CGPoint(x: x, y: detail.midY), in: window.visible,
                                                     timeline: timeline, layout: layout), frame)
            }
        }
    }

    func testHeldWindowDoesNotDrawAnOffscreenCursorInReservedBands() throws {
        let track = BaselineTests.syntheticTrack()
        var look = CueAppearance()
        look.zoom = .two
        look.safeZones = Self.zones(left: 10, right: 10)
        let layout = look.layout
        let detail = try XCTUnwrap(layout.detail)
        let timeline = ClipTimeline(duration: track.seconds)
        let held = CuePicture.closeUp(timeline: timeline, position: 0, appearance: look)
        let bitmap = Self.bitmap()
        // Just beyond two seconds the cursor would lie inside the right reserve.
        CuePicture.draw(in: bitmap, rect: CGRect(origin: .zero, size: CuePicture.size), track: track,
                        path: CuePicture.overviewPath(track, layout: layout), timeline: timeline, layout: layout,
                        position: 54, label: CueLabel(), appearance: look, holding: held)
        let pixels = Self.pixels(bitmap)
        for band in layout.reserved { XCTAssertEqual(Self.foreignPixels(pixels, in: band), 0) }
        XCTAssertEqual(CountdownTests.count(CuePicture.paper, in: pixels, detail), 0)
    }

    func testShadingSwapsTheCloseUpColorsAndWarningOnly() throws {
        let track = BaselineTests.syntheticTrack()
        let timeline = ClipTimeline(duration: track.seconds, markers: MusicMarkers(detectedMusicEnd: 16), target: .musicEnd)
        var look = CueAppearance()
        look.zoom = .five
        look.playheadMode = .centered
        look.detailColor = CueColor(0.4, 0.7, 0.9)
        let detail = try XCTUnwrap(look.layout.detail)
        let left = CGRect(x: detail.minX + 30, y: detail.midY + 4, width: detail.width / 2 - 60, height: 6)
        let right = left.offsetBy(dx: detail.width / 2, dy: 0)
        for warning in [CountdownWarning.off, .five] {
            look.warning = warning
            look.solidRedAt = .oneSecond
            let color = warning == .off ? look.detailColor! : CueColor.warningRed
            var fullTrack: [UInt8]?
            for shading in CloseUpShading.allCases {
                look.closeUpShading = shading
                let image = Self.render(track, timeline: timeline, position: 375, label: CueLabel(), appearance: look)
                let bright = shading == .playedBrighter ? left : right
                let dim = shading == .playedBrighter ? right : left
                XCTAssertGreaterThan(CountdownTests.count(color.cgColor, in: image, bright), 3_000)
                XCTAssertGreaterThan(CountdownTests.count(color.dimmed.cgColor, in: image, dim), 3_000)
                let overview = CountdownTests.region(image, look.layout.overview)
                if let fullTrack { XCTAssertTrue(fullTrack == overview) }
                fullTrack = overview
            }
        }
    }

    func testSwashTitleFitsAtTheLeftEdgeOfItsBand() {
        let track = BaselineTests.syntheticTrack()
        let timeline = ClipTimeline(duration: track.seconds)
        var look = CueAppearance()
        look.titleFontName = "Zapfino"
        look.safeZones = Self.zones(left: 10)
        let layout = look.layout
        let label = CueLabel(text: "f")
        let (line, box) = CuePicture.caption(label, layout: layout)
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        XCTAssertLessThan(ink.minX, -20)
        XCTAssertGreaterThanOrEqual(box.width, ink.width)
        XCTAssertEqual(CuePicture.hitTarget(at: CGPoint(x: box.minX + 2, y: box.midY), label: label,
                                            layout: layout), .none)
        let custom = Self.render(track, timeline: timeline, position: 0, label: label, appearance: look)
        for band in layout.reserved { XCTAssertEqual(Self.foreignPixels(custom, in: band), 0) }
        XCTAssertGreaterThan(Self.foreignPixels(custom, in: box), 50)
    }

    func testSelectedFontsDrawTheCaptionClockSectionsTicksAndSlate() throws {
        let track = BaselineTests.syntheticTrack()
        let label = CueLabel(text: "Test title")
        let timeline = ClipTimeline(duration: track.seconds, trim: TrimSettings(preRoll: 1))
        var look = CueAppearance()
        look.playheadMode = .edgeHeld // The first labelled tick is in the sampled left-hand region.
        let standard = Self.render(track, timeline: timeline, position: 25, label: label, appearance: look)
        let defaultSlate = Self.render(track, timeline: timeline, position: 0, label: label, appearance: look)
        look.titleFontName = "Georgia"
        look.clockFontName = "HelveticaNeue"
        let layout = look.layout
        let custom = Self.render(track, timeline: timeline, position: 25, label: label, appearance: look)
        let customSlate = Self.render(track, timeline: timeline, position: 0, label: label, appearance: look)
        XCTAssertFalse(defaultSlate == customSlate)
        for area in [CuePicture.caption(label, layout: layout).1, try XCTUnwrap(layout.extent(of: .elapsedClock)),
                     CGRect(x: layout.contentMinX, y: layout.overviewLabelBaseline, width: 280, height: 28),
                     CGRect(x: layout.contentMinX, y: try XCTUnwrap(layout.tickLabelBaseline), width: 280, height: 25)] {
            XCTAssertFalse(CountdownTests.region(standard, area) == CountdownTests.region(custom, area))
        }
        look.showTitle = false
        XCTAssertTrue(Self.render(track, timeline: timeline, position: 0, label: label, appearance: look)
                      == Self.render(track, timeline: timeline, position: 0, label: CueLabel(text: "Other title"), appearance: look))
        look.showTitle = true
        look.titleFontName = "WaveformCue-Unavailable"
        look.clockFontName = "Georgia" // This face cannot hold the clock digits on a fixed grid.
        XCTAssertTrue(standard == Self.render(track, timeline: timeline, position: 25, label: label, appearance: look))
    }

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

    func testTimelineEntryMatchesFrameEntryForTitleBand() {
        let track = BaselineTests.syntheticTrack()
        let timeline = ClipTimeline(duration: track.seconds)
        let item = BaselineTests.customTitle
        for frame in BaselineTests.frames(for: track) {
            let viaTimeline = Self.render(track, timeline: timeline, position: frame, label: item.label, appearance: item.appearance)
            let viaFrame = BaselineTests.render(track, frame: frame, label: item.label, appearance: item.appearance)
            XCTAssertTrue(viaTimeline.elementsEqual(viaFrame), "frame \(frame)")
        }
    }

    /// Settings this task adds but does not render yet leave build 10's picture unchanged.
    func testUnrenderedSettingsKeepBaseline() {
        let track = BaselineTests.syntheticTrack()
        var appearance = CueAppearance()
        appearance.dimPlayedCloseUp = false  // build 10's close-up colours; see DimPlayedCloseUpTests
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
        struct Setting { let name: String; let zones: SafeZones; let zoom: ZoomWindow
                         let elapsed: ClockSize; let remaining: ClockSize }
        let settings = [
            Setting(name: "EVS OSD", zones: SafeZones(preset: .evsOSD), zoom: .auto, elapsed: .medium, remaining: .medium),
            Setting(name: "EVS OSD, larger clocks", zones: SafeZones(preset: .evsOSD), zoom: .auto, elapsed: .large, remaining: .extraLarge),
            Setting(name: "asymmetric custom", zones: Self.zones(top: 4, bottom: 25, left: 9, right: 2), zoom: .five,
                    elapsed: .extraLarge, remaining: .small),
            Setting(name: "zoom Off, side reserves", zones: Self.zones(top: 18, bottom: 7, left: 12, right: 12),
                    zoom: .off, elapsed: .medium, remaining: .large),
            Setting(name: "zoom Off, bottom heavy", zones: Self.zones(bottom: 30, right: 15), zoom: .off,
                    elapsed: .extraLarge, remaining: .extraLarge),
        ]
        let labels = [CueLabel(text: "A Very Long Overlay Title That Has To Be Fitted And Truncated To The Width",
                               position: CGPoint(x: 0, y: 0)),
                      CueLabel(text: "Jüngste Ägypten Qy", position: CGPoint(x: 1, y: 1)),
                      CueLabel(text: "Out of range", position: CGPoint(x: -3, y: 4))]
        for setting in settings {
            var appearance = CueAppearance()
            appearance.safeZones = setting.zones
            appearance.zoom = setting.zoom
            appearance.elapsed.size = setting.elapsed
            appearance.remaining.size = setting.remaining
            appearance.warning = .ten
            appearance.fadeFullTrack = true
            let timeline = ClipTimeline(duration: track.seconds, standard: TimelineRate.fields50)
            let frames = [0, 1, timeline.positionCount / 2 + 1, timeline.positionCount - 20, timeline.positionCount]
            for (index, order) in CueLayoutTests.orders.enumerated() {
                appearance.paneOrder = order
                appearance.titleAlignment = TitleAlignment.allCases[index % TitleAlignment.allCases.count]
                let layout = appearance.layout
                XCTAssertTrue(layout.fits, "\(setting.name) \(order)")
                XCTAssertFalse(layout.reserved.isEmpty, setting.name)
                let position = frames[index % frames.count]
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

    func testCaptionAlignsInsideItsBandAcrossAllOrders() {
        var look = CueAppearance()
        look.safeZones = Self.zones(top: 12, bottom: 20, left: 6, right: 6)
        for order in CueLayoutTests.orders {
            look.paneOrder = order
            for alignment in TitleAlignment.allCases {
                look.titleAlignment = alignment
                let layout = look.layout
                let band = layout.titleBand
                let label = CueLabel(text: "Cue")
                let box = CuePicture.caption(label, layout: layout).1
                XCTAssertTrue(band.contains(box))
                XCTAssertEqual(box.maxY, band.maxY)
                switch alignment {
                case .left: XCTAssertEqual(box.minX, layout.contentMinX)
                case .center: XCTAssertEqual(box.midX, band.midX)
                case .right: XCTAssertEqual(box.maxX, layout.contentMaxX)
                }
                XCTAssertEqual(box, CuePicture.caption(CueLabel(text: label.text, position: .zero), layout: layout).1)
                XCTAssertEqual(CuePicture.hitTarget(at: CGPoint(x: box.midX, y: box.midY), label: label, layout: layout), .none)
            }
        }
    }

    func testOverwideTitleShrinksThenEndsWithAnEllipsis() throws {
        var look = CueAppearance()
        look.safeZones = Self.zones(left: 30, right: 30)
        look.titleAlignment = .right
        let layout = look.layout
        let text = String(repeating: "Wide title ", count: 25)
        let (line, box) = CuePicture.caption(CueLabel(text: text), layout: layout)
        XCTAssertTrue(layout.titleBand.contains(box))
        XCTAssertEqual(box.maxX, layout.contentMaxX)
        let runs = try XCTUnwrap(CTLineGetGlyphRuns(line) as? [CTRun])
        let token = try XCTUnwrap(runs.last)
        let attributes = CTRunGetAttributes(token) as NSDictionary
        let font = try XCTUnwrap(attributes[kCTFontAttributeName]) as! CTFont
        XCTAssertEqual(CTFontGetSize(font), CueLayout.Metrics.titleMinimumSize)
        var character: UniChar = 0x2026
        var ellipsis = CGGlyph(), lastGlyph = CGGlyph()
        XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &character, &ellipsis, 1))
        CTRunGetGlyphs(token, CFRange(location: CTRunGetGlyphCount(token) - 1, length: 1), &lastGlyph)
        XCTAssertEqual(lastGlyph, ellipsis)
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

        // A click on the title behaves like a click on the background.
        let title = CuePicture.caption(label, layout: layout).1
        XCTAssertEqual(CuePicture.hitTarget(at: CGPoint(x: title.midX, y: title.midY), label: label, layout: layout), .none)
        XCTAssertEqual(CuePicture.hitTarget(at: CGPoint(x: 960, y: 20), label: label, layout: layout), .none)

        // Zoom Off: the full-track waveform covers the close-up's place.
        var off = CueAppearance()
        off.zoom = .off
        XCTAssertEqual(CuePicture.hitTarget(at: q, label: label, layout: off.layout), .overview)
        // Ends clamp.
        XCTAssertEqual(CuePicture.scrubFrame(at: CGPoint(x: 0, y: 792), in: 0..<750, layout: layout), 0)
        XCTAssertEqual(CuePicture.scrubFrame(at: CGPoint(x: 1920, y: 792), in: 0..<750, layout: layout), 750)
    }

    func testTypingATitleOnlyChangesTheTitleBand() {
        let track = BaselineTests.syntheticTrack()
        var look = CueAppearance()
        look.paneOrder = [.closeUp, .title, .clocks, .fullTrack]
        let timeline = ClipTimeline(duration: track.seconds)
        let empty = Self.render(track, timeline: timeline, position: 375, label: CueLabel(), appearance: look)
        // Combining marks can stack beyond the family's measured ascent. Include a fallback glyph too.
        let text = "Q" + String(repeating: "\u{0302}", count: 12) + " 🎵"
        let titled = Self.render(track, timeline: timeline, position: 375, label: CueLabel(text: text), appearance: look)
        let band = look.layout.titleBand
        XCTAssertEqual(Self.foreignPixels(empty, in: band), 0)
        XCTAssertGreaterThan(Self.foreignPixels(titled, in: band), 0)
        let firstRow = (1080 - Int(ceil(band.maxY))) * 7680
        let pastLastRow = (1080 - Int(floor(band.minY))) * 7680
        XCTAssertTrue(empty[..<firstRow].elementsEqual(titled[..<firstRow]))
        XCTAssertTrue(empty[pastLastRow...].elementsEqual(titled[pastLastRow...]))
    }

    func testOffsetPictureMatchesAtBothRenderingEntryPoints() {
        let track = BaselineTests.syntheticTrack()
        let label = CueLabel(text: "Offset picture")
        var look = CueAppearance()
        look.paneOrder = [.closeUp, .title, .clocks, .fullTrack]
        look.offsets = PaneOffsets(title: -9, fullTrack: 5, closeUp: -15, clocks: 12)
        look.leftClock = .remaining
        XCTAssertEqual(look.layout.offsetsInUse, look.offsets)
        let timeline = CuePicture.timeline(for: track, appearance: look)
        let viewer = Self.render(track, timeline: timeline, position: 375, label: label, appearance: look)
        let frame = BaselineTests.render(track, frame: 375, label: label, appearance: look)
        XCTAssertTrue(frame.elementsEqual(viewer))
    }

    func testNearestWaveformWinsWhereTheHitMarginsOverlap() throws {
        let original = CueAppearance().layout
        let nearLabel = CGPoint(x: original.overview.midX, y: original.overviewLabelBaseline)
        XCTAssertEqual(CuePicture.hitTarget(at: nearLabel, label: CueLabel(), layout: original), .none)
        for fullTrackFirst in [true, false] {
            var look = CueAppearance()
            look.paneOrder = fullTrackFirst ? [.title, .fullTrack, .closeUp, .clocks]
                                            : [.title, .closeUp, .fullTrack, .clocks]
            let lowerPane: PicturePane = fullTrackFirst ? .closeUp : .fullTrack
            look.offsets[lowerPane] = Int.max
            let layout = look.layout
            let upper = try XCTUnwrap(layout.extent(of: fullTrackFirst ? .overview : .detail))
            let lower = try XCTUnwrap(layout.extent(of: fullTrackFirst ? .detail : .overview))
            let gap = upper.minY - lower.maxY
            XCTAssertGreaterThanOrEqual(gap, 12)
            XCTAssertLessThan(gap, 13) // Offset steps are whole pixels.
            let upperTarget: CuePicture.HitTarget = fullTrackFirst ? .overview : .detail
            let lowerTarget: CuePicture.HitTarget = fullTrackFirst ? .detail : .overview
            let middle = (upper.minY + lower.maxY) / 2
            for (y, target) in [(upper.minY - 0.25, upperTarget), (middle + 0.25, upperTarget),
                                (middle - 0.25, lowerTarget), (lower.maxY + 0.25, lowerTarget)] {
                let point = CGPoint(x: layout.contentMinX + 40, y: y)
                XCTAssertEqual(CuePicture.hitTarget(at: point, label: CueLabel(), layout: layout), target)
            }
        }
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

    // MARK: - Task 3.2: guides and markers in the export

    /// `CuePicture` output (what the export encodes) never contains the safe-zone guides: with
    /// guides on, every image equals the guides-off image, and the bands hold only background.
    func testExportHasNoGuidePixels() {
        var track = BaselineTests.syntheticTrack()
        track.markers = MusicMarkers(detectedMusicEnd: 26, detectedFadeStart: 24)
        for zones in [SafeZones(preset: .evsOSD), Self.zones(top: 12, bottom: 25, left: 8, right: 8)] {
            for order in [PicturePane.defaultOrder, [.title, .clocks, .fullTrack, .closeUp]] {
                var off = CueAppearance()
                off.safeZones = zones
                off.paneOrder = order
                off.countdownTarget = .musicEnd
                off.warning = .five
                var on = off
                on.showGuides = true
                let layout = on.layout
                XCTAssertTrue(layout.fits)
                let timeline = CuePicture.timeline(for: track, appearance: on)
                for frame in [0, 600, 640, 700, 750] {
                    let label = CueLabel(text: "Guides", position: CGPoint(x: 1, y: 0))
                    let withGuides = Self.render(track, timeline: timeline, position: frame, label: label, appearance: on)
                    XCTAssertEqual(withGuides, Self.render(track, timeline: timeline, position: frame, label: label,
                                                           appearance: off))
                    for band in layout.reserved {
                        XCTAssertEqual(Self.foreignPixels(withGuides, in: band), 0, "\(zones) \(order) \(frame) \(band)")
                    }
                }
            }
        }
    }

    /// Clocks Above and Below move as a pair: both clocks share one baseline, above the full
    /// track or below the close-up.
    func testClocksMoveAsAPair() {
        for zones in [SafeZones.none, SafeZones(preset: .evsOSD)] {
            var below = CueAppearance()
            below.safeZones = zones
            var above = below
            above.paneOrder = [.title, .clocks, .fullTrack, .closeUp]
            let b = below.layout, a = above.layout
            let bElapsed = b.extent(of: .elapsedClock)!, bRemaining = b.extent(of: .remainingClock)!
            let aElapsed = a.extent(of: .elapsedClock)!, aRemaining = a.extent(of: .remainingClock)!
            XCTAssertEqual(bElapsed.minY, bRemaining.minY)
            XCTAssertEqual(aElapsed.minY, aRemaining.minY)
            XCTAssertLessThan(bElapsed.maxY, b.extent(of: .detail)!.minY)
            XCTAssertGreaterThan(aElapsed.minY, a.extent(of: .overview)!.maxY)
        }
    }
}
