import XCTest
import AppKit
@testable import CueCore

/// Task 4.3: trim, fades and pre-roll through the timeline. The render group needs no FFmpeg
/// (slate, trimmed overview, trim handles); the export group writes real clips and measures
/// their length, timecode, slate silence and fade envelopes.
final class TrimPreRollTests: XCTestCase {

    // MARK: - Helpers

    static let loudness = LoudnessMeasurement(integratedLUFS: -18.4, truePeakDBTP: -0.6, rangeLU: 7.3)

    /// Renders one image through the timeline entry point with the timeline's overview path,
    /// as the export and the monitor do.
    static func render(_ track: AudioTrack, timeline: ClipTimeline, position: Int, label: CueLabel,
                       appearance: CueAppearance = CueAppearance(),
                       loudness: LoudnessMeasurement? = nil) -> [UInt8] {
        let ctx = RenderTests.bitmap()
        let layout = appearance.layout
        CuePicture.draw(in: ctx, rect: CGRect(origin: .zero, size: CuePicture.size), track: track,
                        path: CuePicture.overviewPath(track, layout: layout, timeline: timeline), timeline: timeline,
                        layout: layout, position: position, label: label, appearance: appearance, loudness: loudness)
        return RenderTests.pixels(ctx)
    }

    /// A 30 s track: loud for 0–10 s, silent for 10–20 s, loud again for 20–30 s.
    static func steppedTrack() -> AudioTrack {
        let detail: [Float] = (0..<6000).map { i in (2000..<4000).contains(i) ? 0 : 0.9 }
        return AudioTrack(url: URL(fileURLWithPath: "/tmp/Stepped.wav"),
                          pcm: PreparedAudio(url: URL(fileURLWithPath: "/nonexistent/stepped.caf")),
                          seconds: 30, detailPeaks: detail, peaks: AudioTrack.reducePeaks(detail[...], columns: 1600))
    }

    /// Columns of row `y` (picture points) whose pixel is close to `color`.
    static func columns(matching color: CGColor, in pixels: [UInt8], row y: Int, x: ClosedRange<Int>) -> [Int] {
        let c = color.components!.map { Int(($0 * 255).rounded()) }
        let rowStart = (1079 - y) * 7680
        return x.filter { column in
            let i = rowStart + column * 4
            return abs(Int(pixels[i + 2]) - c[0]) < 12 && abs(Int(pixels[i + 1]) - c[1]) < 12
                && abs(Int(pixels[i]) - c[2]) < 12
        }
    }

    // MARK: - Identity (build 10 unchanged)

    func testIdentityTimelineKeepsBuild10OverviewAndPixels() {
        let track = BaselineTests.syntheticTrack()
        let layout = CueAppearance().layout
        let identity = ClipTimeline(duration: track.seconds)
        XCTAssertEqual(CuePicture.overviewPath(track, layout: layout, timeline: identity),
                       CuePicture.overviewPath(track, layout: layout))
        // A fade alone does not trim, so the picture is still the whole track.
        let faded = ClipTimeline(duration: track.seconds, trim: TrimSettings(fadeIn: 2, fadeOut: 5))
        XCTAssertEqual(CuePicture.overviewPath(track, layout: layout, timeline: faded),
                       CuePicture.overviewPath(track, layout: layout))
        let label = CueLabel(text: "Baseline Track")
        for frame in [0, 375, 625, 725] {
            XCTAssertEqual(Self.render(track, timeline: identity, position: frame, label: label),
                           [UInt8](BaselineTests.render(track, frame: frame, label: label, appearance: CueAppearance())),
                           "frame \(frame)")
            // Fades apply to audio only: the picture is identical with them.
            XCTAssertEqual(Self.render(track, timeline: faded, position: frame, label: label),
                           Self.render(track, timeline: identity, position: frame, label: label), "frame \(frame)")
        }
    }

    // MARK: - Slate

    func testSlateContent() {
        let track = BaselineTests.syntheticTrack()
        let timeline = ClipTimeline(duration: 30, trim: TrimSettings(inPoint: 2, outPoint: 14.5, preRoll: 5))
        XCTAssertEqual(timeline.position(at: 0), .slate(startsIn: 125))
        let slate = CuePicture.slate(track: track, timeline: timeline, startsIn: 125, label: CueLabel(text: "Opener"),
                                     loudness: Self.loudness)
        XCTAssertEqual(slate.title, "Opener")
        XCTAssertEqual(slate.startsInLabel, "Starts in")
        XCTAssertEqual(slate.startsIn, "00:05:00")
        XCTAssertEqual(slate.duration, "Music duration 00:12:13")   // 12.5 s trimmed range
        XCTAssertEqual(slate.loudness, "\u{2212}18.4 LUFS \u{00B7} TP \u{2212}0.6 dBTP \u{00B7} LRA 7.3 LU")
        // No title: the file name. No loudness: no line.
        let bare = CuePicture.slate(track: track, timeline: timeline, startsIn: 1, label: CueLabel(), loudness: nil)
        XCTAssertEqual(bare.title, "Baseline Track")
        XCTAssertNil(bare.loudness)
        XCTAssertEqual(bare.lines.count, 4)
        XCTAssertEqual(CuePicture.loudnessText(LoudnessMeasurement(integratedLUFS: nil, truePeakDBTP: nil, rangeLU: 0)),
                       "Loudness: silent")
    }

    func testSlateFramesShowStartsInAndNoClocks() {
        let track = BaselineTests.syntheticTrack()
        let label = CueLabel(text: "Baseline Track")
        var referenceSlate: [UInt8]?
        for order in [PicturePane.defaultOrder, [.title, .clocks, .fullTrack, .closeUp]] {
            var appearance = CueAppearance()
            appearance.paneOrder = order
            appearance.titleAlignment = order == PicturePane.defaultOrder ? .left : .right
            let layout = appearance.layout
            let timeline = ClipTimeline(duration: track.seconds, trim: TrimSettings(preRoll: 5),
                                        standard: TimelineRate.fields50)
            XCTAssertEqual(timeline.preRollPositions, 250)
            let first = Self.render(track, timeline: timeline, position: 0, label: label, appearance: appearance,
                                    loudness: Self.loudness)
            let later = Self.render(track, timeline: timeline, position: 150, label: label, appearance: appearance,
                                    loudness: Self.loudness)
            let last = Self.render(track, timeline: timeline, position: 249, label: label, appearance: appearance,
                                   loudness: Self.loudness)
            let music = Self.render(track, timeline: timeline, position: 250, label: label, appearance: appearance,
                                    loudness: Self.loudness)
            if let referenceSlate { XCTAssertTrue(first.elementsEqual(referenceSlate)) }
            referenceSlate = first
            // No clocks and no waveforms on the slate.
            for element in [CueLayout.Element.elapsedClock, .remainingClock] {
                let extent = layout.extent(of: element)!
                XCTAssertEqual(RenderTests.foreignPixels(first, in: extent), 0, "\(order) \(element)")
                XCTAssertGreaterThan(RenderTests.foreignPixels(music, in: extent), 100, "\(order) \(element)")
            }
            // The countdown moves; the slate has content; music starts with Elapsed at zero.
            XCTAssertNotEqual(first, later)
            XCTAssertNotEqual(later, last)
            XCTAssertNotEqual(last, music)
            XCTAssertGreaterThan(RenderTests.foreignPixels(first, in: layout.safeFrame), 20_000)
            XCTAssertEqual(timeline.clocks(at: 250).elapsed, 0)
            XCTAssertFalse(timeline.clocks(at: 250).isSlate)
            XCTAssertEqual(timeline.clocks(at: 249).startsIn, 1)
            // The loudness line is drawn when known.
            XCTAssertNotEqual(first, Self.render(track, timeline: timeline, position: 0, label: label,
                                                 appearance: appearance))
        }
    }

    func testSlateKeepsReservedBandsBackground() {
        let track = BaselineTests.syntheticTrack()
        let longTitle = CueLabel(text: "A Very Long Overlay Title That Has To Be Truncated On The Pre-roll Slate Too")
        let settings: [(String, SafeZones)] = [
            ("EVS OSD", SafeZones(preset: .evsOSD)),
            ("asymmetric", RenderTests.zones(top: 4, bottom: 25, left: 9, right: 2)),
            ("narrow", RenderTests.zones(top: 10, bottom: 10, left: 30, right: 30)),
            ("crowded", RenderTests.zones(top: 30, bottom: 30, left: 12, right: 12)),
        ]
        for (name, zones) in settings {
            var appearance = CueAppearance()
            appearance.safeZones = zones
            let layout = appearance.layout
            XCTAssertFalse(layout.reserved.isEmpty, name)
            let timeline = ClipTimeline(duration: track.seconds, trim: TrimSettings(preRoll: 10),
                                        standard: TimelineRate.fps50)
            for position in [0, 499] {
                for label in [longTitle, CueLabel(text: "Jüngste Ägypten Qy")] {
                    let image = Self.render(track, timeline: timeline, position: position, label: label,
                                            appearance: appearance, loudness: Self.loudness)
                    for band in layout.reserved {
                        XCTAssertEqual(RenderTests.foreignPixels(image, in: band), 0, "\(name) \(position) \(band)")
                    }
                    // Everything stays inside the safe frame.
                    let total = RenderTests.foreignPixels(image, in: CGRect(origin: .zero, size: CuePicture.size))
                    XCTAssertEqual(RenderTests.foreignPixels(image, in: layout.safeFrame), total, name)
                    XCTAssertGreaterThan(total, 5_000, name)
                }
            }
        }
    }

    // MARK: - Trimmed overview

    func testTrimmedOverviewCoversOnlyTheRange() {
        let track = Self.steppedTrack()
        let layout = CueAppearance().layout
        func height(_ trim: TrimSettings) -> CGFloat {
            CuePicture.overviewPath(track, layout: layout, timeline: ClipTimeline(duration: 30, trim: trim))
                .boundingBoxOfPath.height
        }
        let full = height(.none)
        XCTAssertGreaterThan(full, layout.overview.height * 0.8)
        // The silent middle alone: a flat line across the whole overview.
        XCTAssertLessThan(height(TrimSettings(inPoint: 10.2, outPoint: 19.8)), 1)
        XCTAssertEqual(CuePicture.overviewPath(track, layout: layout,
                                               timeline: ClipTimeline(duration: 30, trim: TrimSettings(inPoint: 10.2, outPoint: 19.8)))
                        .boundingBoxOfPath.width, layout.overview.width, accuracy: 0.5)
        XCTAssertEqual(height(TrimSettings(inPoint: 0, outPoint: 9.8)), full, accuracy: 0.5)
        XCTAssertEqual(height(TrimSettings(inPoint: 20.2)), full, accuracy: 0.5)
    }

    func testMarkersSitInsideTheTrimmedRange() {
        let track = BaselineTests.syntheticTrack()
        let layout = CueAppearance().layout
        let label = CueLabel()
        let row = Int(layout.overview.minY) + 10
        let span = Int(layout.overview.minX)...Int(layout.overview.maxX)
        // Music end at 17 s, trim 10–20 s: the line is 70 % across the overview (clear of the
        // close-up highlight, which ends half-way at position 0).
        let inside = ClipTimeline(duration: 30, trim: TrimSettings(inPoint: 10, outPoint: 20),
                                  markers: MusicMarkers(detectedMusicEnd: 17))
        XCTAssertEqual(inside.musicEndMarker?.seconds ?? -1, 7, accuracy: 1e-9)
        let image = Self.render(track, timeline: inside, position: 0, label: label)
        let hits = Self.columns(matching: CuePicture.musicEndColor, in: image, row: row, x: span)
        XCTAssertFalse(hits.isEmpty)
        let centre = Double(hits.reduce(0, +)) / Double(max(1, hits.count))
        XCTAssertEqual(centre, Double(layout.overview.minX + 0.7 * layout.overview.width), accuracy: 3)
        // A marker cut away by the trim is not drawn.
        let outside = ClipTimeline(duration: 30, trim: TrimSettings(inPoint: 10, outPoint: 20),
                                   markers: MusicMarkers(detectedMusicEnd: 25))
        XCTAssertNil(outside.musicEndMarker)
        XCTAssertEqual(Self.columns(matching: CuePicture.musicEndColor,
                                    in: Self.render(track, timeline: outside, position: 0, label: label),
                                    row: row, x: span), [])
        // The close-up reads the trimmed source: the first music frame of a 10 s in point
        // matches neither the untrimmed first frame nor is it blank.
        XCTAssertNotEqual(image, Self.render(track, timeline: ClipTimeline(duration: 30, markers: MusicMarkers(detectedMusicEnd: 17)),
                                             position: 0, label: label))
    }

    // MARK: - Trim handles

    func testTrimHandleHitTestingAndPrecedence() {
        let layout = CueAppearance().layout
        let track = BaselineTests.syntheticTrack()
        let overview = layout.overview
        let plain = ClipTimeline(duration: track.seconds)
        let window = CuePicture.closeUp(timeline: plain, position: 0, appearance: CueAppearance())
        func hit(_ point: CGPoint, _ timeline: ClipTimeline = plain, handles: Bool = true) -> CuePicture.HitTarget {
            CuePicture.hitTarget(at: point, label: CueLabel(), layout: layout, timeline: timeline,
                                 closeUp: window, trimHandles: handles)
        }
        XCTAssertEqual(hit(CGPoint(x: overview.minX - 20, y: overview.midY)), .trim(.inPoint))
        XCTAssertEqual(hit(CGPoint(x: overview.minX + 4, y: overview.midY)), .trim(.inPoint))
        XCTAssertEqual(hit(CGPoint(x: overview.maxX + 20, y: overview.midY)), .trim(.outPoint))
        XCTAssertEqual(hit(CGPoint(x: overview.midX, y: overview.midY)), .overview)
        // Without handles (not wired) the edges scrub as before.
        XCTAssertEqual(hit(CGPoint(x: overview.minX + 4, y: overview.midY), handles: false), .overview)
        XCTAssertEqual(hit(CGPoint(x: overview.minX - 20, y: overview.midY), handles: false), .none)
        // A music-end marker at the file end wins near the edge; the outer zone still trims.
        let ending = ClipTimeline(duration: track.seconds, markers: MusicMarkers(detectedMusicEnd: track.seconds))
        XCTAssertEqual(hit(CGPoint(x: overview.maxX + 2, y: overview.midY), ending), .marker(.musicEnd, onCloseUp: false))
        XCTAssertEqual(hit(CGPoint(x: overview.maxX + 20, y: overview.midY), ending), .trim(.outPoint))
        // The title band behaves like the background, including when trim handles are enabled.
        let label = CueLabel(text: "Title")
        let box = CuePicture.caption(label, layout: layout).1
        XCTAssertEqual(CuePicture.hitTarget(at: CGPoint(x: box.midX, y: box.midY), label: label, layout: layout,
                                            timeline: plain, closeUp: window, trimHandles: true), .none)
    }

    func testDraggedTrimIsRelativeSnappedAndClamped() {
        let layout = CueAppearance().layout
        let perSecond = layout.contentWidth / 30
        let down = CGPoint(x: layout.overview.minX, y: layout.overview.midY)
        func drag(_ edge: TrimEdge, _ original: TrimSettings, seconds: Double, duration: Double = 30) -> TrimSettings {
            CuePicture.draggedTrim(edge, original: original, down: down,
                                   to: CGPoint(x: down.x + CGFloat(seconds) * perSecond * CGFloat(30 / duration),
                                               y: down.y), duration: duration, layout: layout)
        }
        XCTAssertEqual(drag(.inPoint, .none, seconds: 2.01).inPoint ?? -1, 2.0, accuracy: 1e-9)
        XCTAssertEqual(drag(.outPoint, .none, seconds: -3.03).outPoint ?? -1, 26.96, accuracy: 1e-9)
        // Relative to where the handle was.
        let trimmed = TrimSettings(inPoint: 5, outPoint: 12, fadeIn: 1, preRoll: 3)
        let moved = drag(.inPoint, trimmed, seconds: 1)
        XCTAssertEqual(moved.inPoint ?? -1, 6, accuracy: 1e-9)
        XCTAssertEqual(moved.outPoint, 12)
        XCTAssertEqual(moved.fadeIn, 1)
        XCTAssertEqual(moved.preRoll, 3)
        // Never under one second.
        XCTAssertEqual(drag(.inPoint, trimmed, seconds: 20).inPoint ?? -1, 11, accuracy: 1e-9)
        XCTAssertEqual(drag(.outPoint, trimmed, seconds: -20).outPoint ?? -1, 6, accuracy: 1e-9)
        // Back to the source edges: nil, so the trim is the identity again.
        XCTAssertNil(drag(.inPoint, trimmed, seconds: -10).inPoint)
        XCTAssertNil(drag(.outPoint, trimmed, seconds: 40).outPoint)
        XCTAssertTrue(drag(.inPoint, TrimSettings(inPoint: 1), seconds: -1).isIdentity)
        // A track shorter than a second cannot be trimmed.
        XCTAssertTrue(drag(.inPoint, .none, seconds: 0.3, duration: 0.6).isIdentity)
        XCTAssertTrue(drag(.outPoint, .none, seconds: -0.3, duration: 0.6).isIdentity)
    }

    func testClipLoudnessFollowsGain() {
        let track = BaselineTests.syntheticTrack()
        var snapshot = MXFExport.Snapshot(track: track, label: CueLabel(), loudness: Self.loudness)
        XCTAssertEqual(snapshot.clipLoudness, Self.loudness)
        snapshot.gainDB = -4.6
        XCTAssertEqual(snapshot.clipLoudness?.integratedLUFS ?? 0, -23.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.clipLoudness?.truePeakDBTP ?? 0, -5.2, accuracy: 1e-9)
        XCTAssertEqual(snapshot.clipLoudness?.rangeLU, 7.3)
        snapshot.loudness = nil
        XCTAssertNil(snapshot.clipLoudness)
    }

    // MARK: - Exports (FFmpeg)

    static let amplitude = 0.5
    static let fullScale = 2_147_483_648.0   // 24-bit samples in the top bytes of Int32

    /// Peak level (fraction of full scale) of `samples[start..<start+count]`.
    static func peak(_ samples: [Int32], from start: Int, count: Int = 480) -> Double {
        let end = min(samples.count, start + count)
        guard start < end else { return 0 }
        return Double(samples[start..<end].map { abs(Int64($0)) }.max() ?? 0) / fullScale
    }

    func testTrimFadesAndPreRollExport() throws {
        let ffmpeg = try TestAudio.ffmpeg()
        let dir = try TestAudio.temporaryDirectory("trim-preroll")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("tone.wav")
        try FFmpegRun.generate(left: "\(Self.amplitude)*sin(2*PI*440*t)", right: "0.25*sin(2*PI*660*t)",
                               seconds: 6, to: wav, ffmpeg: ffmpeg)
        let track = try AudioTrack.read(wav, encoder: ffmpeg)
        // 3.52 s range: not a whole frame at 25 or 50, so the round-up is exercised.
        let trim = TrimSettings(inPoint: 1.0, outPoint: 4.52, fadeIn: 0.5, fadeOut: 1, preRoll: 2)
        let start = try XCTUnwrap(Timecode("10:00:00:00"))
        let label = CueLabel(text: "Trim and pre-roll")
        let appearance = CueAppearance()
        for preset in [ExportPreset.avcIntra1080i50, .avcIntra1080p50] {
            let name = preset.id.rawValue
            let timeline = MXFExport.timeline(for: track, preset: preset, trim: trim)
            let snapshot = MXFExport.Snapshot(track: track, label: label, appearance: appearance, layout: .two,
                                              startTimecode: start, loudness: Self.loudness)
            let output = dir.appendingPathComponent(name + ".mxf")
            try MXFExport.run(snapshot: snapshot, preset: preset, timeline: timeline, encoder: ffmpeg,
                              destination: output, volume: ExportIntegrationTests.roomy) { _ in }

            // Length: pre-roll plus the trimmed range rounded up to a whole frame.
            let frameRate = 48_000 / preset.video.samplesPerFrame
            let preRollFrames = 2 * frameRate
            let musicFrames = Int((3.52 * Double(frameRate)).rounded(.up))
            XCTAssertEqual(timeline.outputFrames, preRollFrames + musicFrames, name)
            XCTAssertEqual(try FFmpegRun.videoPackets(output, ffmpeg: ffmpeg), preRollFrames + musicFrames, name)
            let left = try FFmpegRun.samples(output, track: 0, ffmpeg: ffmpeg)
            let right = try FFmpegRun.samples(output, track: 1, ffmpeg: ffmpeg)
            let perFrame = preset.video.samplesPerFrame
            XCTAssertEqual(left.count, (preRollFrames + musicFrames) * perFrame, name)
            XCTAssertEqual(right.count, left.count, name)

            // Timecode: the file starts 2 s early, so the first music frame reads the start.
            let info = try FFmpegRun.info(output, ffmpeg: ffmpeg)
            XCTAssertEqual(info.timecode, "09:59:58:00", name)
            let fileStart = try XCTUnwrap(Timecode(info.timecode ?? "", fps: frameRate), name)
            XCTAssertEqual(Timecode(totalFrames: fileStart.totalFrames + preRollFrames, fps: frameRate),
                           start.converted(toFPS: frameRate), name)

            // Silent slate, then the fades on the trimmed music, then silent padding.
            let music = preRollFrames * perFrame
            let length = 168_960   // round(4.52 × 48000) − 48000
            XCTAssertTrue(left[..<music].allSatisfy { $0 == 0 }, "\(name): slate not silent")
            XCTAssertTrue(right[..<music].allSatisfy { $0 == 0 }, "\(name): slate not silent")
            XCTAssertTrue(left[(music + length)...].allSatisfy { $0 == 0 }, "\(name): padding not silent")
            for t in [0.05, 0.15, 0.25, 0.35, 0.45] {   // fade-in: linear 0 → A over 0.5 s
                let measured = Self.peak(left, from: music + Int(t * 48_000))
                XCTAssertEqual(measured, Self.amplitude * (t + 0.005) / 0.5, accuracy: 0.015, "\(name) fade-in \(t)")
            }
            XCTAssertEqual(Self.peak(left, from: music + 72_000), Self.amplitude, accuracy: 0.01, "\(name) body")
            for t in [0.1, 0.5, 0.9] {   // fade-out: linear A → 0 over the last second
                let measured = Self.peak(left, from: music + length - 48_000 + Int(t * 48_000))
                XCTAssertEqual(measured, Self.amplitude * (1 - t - 0.005), accuracy: 0.015, "\(name) fade-out \(t)")
            }
            XCTAssertLessThan(Self.peak(left, from: music + length - 480), 0.012, "\(name) fade-out end")

            // Pictures: the slate and the first music frame equal the preview of the same timeline.
            let ppf = timeline.positionsPerFrame
            for frame in [0, preRollFrames] {
                let top = Self.render(track, timeline: timeline, position: frame * ppf, label: label,
                                      appearance: appearance, loudness: Self.loudness)
                let expected = ppf == 2
                    ? Preview.weave(top: top, bottom: Self.render(track, timeline: timeline, position: frame * ppf + 1,
                                                                  label: label, appearance: appearance,
                                                                  loudness: Self.loudness))
                    : top
                let decoded = try FFmpegRun.decodeFrame(output, index: frame, ffmpeg: ffmpeg)
                let mean = Preview.meanError(decoded, expected)
                let block = Preview.maxBlockError(decoded, expected)
                print("[4.3] \(name) frame \(frame): mean error \(String(format: "%.2f", mean)), worst block \(String(format: "%.1f", block))")
                XCTAssertLessThan(mean, 1.0, "\(name) frame \(frame)")
                XCTAssertLessThan(block, 9, "\(name) frame \(frame)")
            }
        }
    }

    func testTrackShorterThanPreRollAndWarningExports() throws {
        let ffmpeg = try TestAudio.ffmpeg()
        let dir = try TestAudio.temporaryDirectory("short-preroll")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("blip.wav")
        try FFmpegRun.generate(left: "0.5*sin(2*PI*440*t)", right: "0.5*sin(2*PI*440*t)",
                               seconds: 0.6, to: wav, ffmpeg: ffmpeg)
        let track = try AudioTrack.read(wav, encoder: ffmpeg)
        var appearance = CueAppearance()
        appearance.warning = .ten
        appearance.solidRedAt = .oneSecond
        appearance.fadeFullTrack = true
        appearance.fadeCloseUp = true
        appearance.countdownTarget = .musicEnd
        // Fades longer than the track and a pre-roll five times its length.
        let trim = TrimSettings(fadeIn: 2, fadeOut: 5, preRoll: 3)
        for preset in [ExportPreset.mpeg2_1080p25, .avcIntra1080i50] {
            let name = preset.id.rawValue
            let timeline = MXFExport.timeline(for: track, preset: preset, trim: trim, target: .musicEnd)
            XCTAssertNoThrow(try timeline.validate(), name)   // untrimmed short tracks pass, as in build 10
            let snapshot = MXFExport.Snapshot(track: track, label: CueLabel(text: "Blip"), appearance: appearance,
                                              startTimecode: .start)
            let output = dir.appendingPathComponent(name + ".mxf")
            try MXFExport.run(snapshot: snapshot, preset: preset, timeline: timeline, encoder: ffmpeg,
                              destination: output, volume: ExportIntegrationTests.roomy) { _ in }
            XCTAssertEqual(try FFmpegRun.videoPackets(output, ffmpeg: ffmpeg), 75 + 15, name)
            let samples = try FFmpegRun.samples(output, track: 0, ffmpeg: ffmpeg)
            XCTAssertEqual(samples.count, 90 * 1920, name)
            XCTAssertTrue(samples[..<(75 * 1920)].allSatisfy { $0 == 0 }, name)
            XCTAssertTrue(samples[(75 * 1920)...].contains { $0 != 0 }, name)
            XCTAssertEqual(try FFmpegRun.info(output, ffmpeg: ffmpeg).timecode, "23:59:57:00", name)
        }
    }

    // MARK: - Slate preview for review

    /// Writes a slate PNG when `CUE_SLATE_PNG` names a file (for visual review).
    func testWriteSlatePreview() throws {
        guard let path = ProcessInfo.processInfo.environment["CUE_SLATE_PNG"], !path.isEmpty else {
            throw XCTSkip("Set CUE_SLATE_PNG to write a slate preview.")
        }
        let track = BaselineTests.syntheticTrack()
        var appearance = CueAppearance()
        appearance.safeZones = SafeZones(preset: .evsOSD)
        let timeline = ClipTimeline(duration: 30, trim: TrimSettings(inPoint: 1.5, outPoint: 27.2, preRoll: 5),
                                    standard: TimelineRate.fields50)
        for (suffix, position) in [("slate", 37), ("music", timeline.preRollPositions)] {
            let ctx = RenderTests.bitmap()
            let layout = appearance.layout
            CuePicture.draw(in: ctx, rect: CGRect(origin: .zero, size: CuePicture.size), track: track,
                            path: CuePicture.overviewPath(track, layout: layout, timeline: timeline), timeline: timeline,
                            layout: layout, position: position, label: CueLabel(text: "Baseline Track"),
                            appearance: appearance, loudness: Self.loudness)
            let image = try XCTUnwrap(ctx.makeImage())
            let base = (path as NSString).deletingPathExtension
            let file = URL(fileURLWithPath: base + (suffix == "slate" ? "" : "-music") + ".png")
            let rep = NSBitmapImageRep(cgImage: image)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: file)
        }
    }
}
