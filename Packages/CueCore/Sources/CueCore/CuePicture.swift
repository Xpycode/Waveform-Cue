import AppKit
import CoreText

public struct CueLabel: Sendable, Equatable {
    public var text = ""
    // Fraction of available travel inside the title-safe margin, bottom-left origin.
    public var position = CGPoint(x: 0, y: 1)

    public init(text: String = "", position: CGPoint = CGPoint(x: 0, y: 1)) {
        self.text = text
        self.position = position
    }
}

/// The two music markers drawn on the waveforms.
public enum MarkerKind: String, Equatable, Hashable, Sendable, CaseIterable {
    case musicEnd, fadeStart
}

/// The two ends of a trim: the in point and the out point.
public enum TrimEdge: String, Equatable, Hashable, Sendable, CaseIterable {
    case inPoint, outPoint
}

extension MusicMarkers {
    /// The marker in force (edited, else detected).
    public func value(_ kind: MarkerKind) -> Double? { kind == .musicEnd ? musicEnd : fadeStart }

    /// Sets the operator's edited value for `kind`.
    public mutating func setEdited(_ kind: MarkerKind, to seconds: Double?) {
        if kind == .musicEnd { editedMusicEnd = seconds } else { editedFadeStart = seconds }
    }
}

/// Resolved immutable Core Text descriptors and their measurements, shared for a layout's lifetime.
struct PictureTypography: @unchecked Sendable, Equatable {
    typealias M = CueLayout.Metrics
    let title: CueFonts.Resolved
    let clock: CueFonts.Resolved
    let titleUnit: CueFonts.Metrics
    let clockUnit: CueFonts.Metrics
    let widths: [ClockSize: CGFloat]
    let labelWidths: [CGFloat]

    static let standard = Self(titleName: nil, clockName: nil)

    init(titleName: String?, clockName: String?) {
        let title = CueFonts.resolve(name: titleName, role: .title)
        let clock = CueFonts.resolve(name: clockName, role: .clock)
        self.title = title
        self.clock = clock
        titleUnit = CueFonts.metrics(for: title, size: 1)
        clockUnit = CueFonts.metrics(for: clock, size: 1)
        widths = Dictionary(uniqueKeysWithValues: ClockSize.allCases.map {
            ($0, CueFonts.metrics(for: clock, size: $0.points).clockWidth)
        })
        labelWidths = ["Elapsed", "Remaining"].map {
            let run = CuePicture.line($0, font: title.font(at: M.clockLabelSize), color: CuePicture.dim)
            return CGFloat(CTLineGetTypographicBounds(run, nil, nil, nil)) + M.antialias
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title.postScriptName == rhs.title.postScriptName && lhs.clock.postScriptName == rhs.clock.postScriptName
    }

    var usesLegacyTitle: Bool { title.postScriptName == "HelveticaNeue-Medium" }
    var usesLegacyClock: Bool { clock.postScriptName == "Menlo-Regular" }

    func titleBaselineInset(_ points: CGFloat) -> CGFloat {
        max(M.titleBaselineInset, points * titleUnit.descent + M.titleShadowSpread)
    }

    func titleBoxHeight(_ points: CGFloat) -> CGFloat {
        max(CueLayout.titleBoxHeight(points), titleBaselineInset(points) + points * titleUnit.ascent + M.titleShadowSpread)
    }

    func clockLabelRise(_ points: CGFloat) -> CGFloat {
        points * max(M.clockLabelRise, clockUnit.ascent)
            + max(M.clockLabelGap, M.clockLabelSize * titleUnit.descent + M.minimumGap)
    }

    func clockWidth(_ size: ClockSize, right: Bool) -> CGFloat {
        max(widths[size]!, labelWidths[right ? 1 : 0])
    }

    var detailBelow: CGFloat {
        max(M.cursorOverhang, M.tickLabelOffset + M.tickLabelSize * clockUnit.descent + M.antialias)
    }
    var detailAbove: CGFloat {
        max(M.cursorTriangleRise, M.detailLabelOffset + M.detailLabelSize * titleUnit.ascent + M.antialias)
    }
    var overviewAbove: CGFloat {
        max(M.cursorOverhang, M.overviewLabelOffset
            + max(M.overviewLabelSize * titleUnit.ascent, M.overviewDurationSize * clockUnit.ascent) + M.antialias)
    }
}

public enum CuePicture {
    public static let size = CGSize(width: 1920, height: 1080)
    /// Build 10 geometry (safe zones None). The renderer reads `CueLayout`; these remain for
    /// callers and tests that compare against build 10.
    public static let wave = CGRect(x: 96, y: 742, width: 1728, height: 100)
    public static let detail = CGRect(x: 96, y: 361, width: 1728, height: 265)

    /// Build 10's full-track rectangle (safe zones None). Prefer `CueLayout.overview`.
    public static func overviewRect(for zoom: ZoomWindow) -> CGRect {
        zoom == .off ? CGRect(x: wave.minX, y: detail.minY, width: wave.width, height: wave.maxY - detail.minY) : wave
    }

    /// Build 10's frame-based accessor, for whole-frame callers.
    public static func closeUp(frame: Int, total: Int, zoom: ZoomWindow) -> Range<Int> {
        guard total > 0 else { return 0..<0 }
        let fps = Double(ClipTimeline.clockRate)
        let timeline = ClipTimeline(duration: Double(total) / fps)
        var appearance = CueAppearance()
        appearance.zoom = zoom
        let range = closeUp(timeline: timeline, position: frame, appearance: appearance).visible
        return Int((range.lowerBound * fps).rounded())..<Int((range.upperBound * fps).rounded())
    }
    public static let paper = rgb(0.91, 0.94, 0.94)
    public static let dim = rgb(0.55, 0.63, 0.65)
    public static let mint = rgb(0.39, 0.89, 0.75)
    /// Picture background; the only colour inside a reserved band.
    public static let background = rgb(0.047, 0.067, 0.076)

    public static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    public static func waveform(_ peaks: [Float], in rect: CGRect = wave, expandQuiet: Bool = false) -> CGPath {
        let path = CGMutablePath()
        guard !peaks.isEmpty else { return path }
        let step = rect.width / CGFloat(peaks.count)
        func point(_ i: Int, side: CGFloat) -> CGPoint {
            // Fixed square-root display scale lifts quiet tails while preserving zero.
            let peak = expandQuiet ? peaks[i].squareRoot() : peaks[i]
            return CGPoint(x: rect.minX + (CGFloat(i) + 0.5) * step,
                           y: rect.midY + side * CGFloat(peak) * rect.height * 0.46)
        }
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        for i in peaks.indices { path.addLine(to: point(i, side: 1)) }
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        for i in peaks.indices.reversed() { path.addLine(to: point(i, side: -1)) }
        path.closeSubpath()
        return path
    }

    /// The full-track envelope for a layout: pass it as `path` to `draw`.
    public static func overviewPath(_ track: AudioTrack, layout: CueLayout) -> CGPath {
        layout.showFullTrack ? waveform(track.peaks, in: layout.overview) : CGMutablePath()
    }

    /// The full-track envelope for a timeline: only the trimmed range (in to out) spans the
    /// overview. Untrimmed it is exactly `overviewPath(_:layout:)`, so build 10 renders are
    /// unchanged. Pass it as `path` to the timeline `draw`.
    public static func overviewPath(_ track: AudioTrack, layout: CueLayout, timeline: ClipTimeline) -> CGPath {
        guard layout.showFullTrack else { return CGMutablePath() }
        // The native overview already contains the padded final buckets. A trimmed slice contains only the cut.
        guard timeline.isTrimmed else { return overviewPath(track, layout: layout) }
        let range = timeline.sourceRange
        let rect = audioRect(for: range, axis: overviewRange(timeline), in: layout.overview)
        guard range.upperBound > range.lowerBound else { return CGMutablePath() }
        let peaks = !track.detailPeaks.isEmpty
            ? track.peaks(in: range.lowerBound..<range.upperBound, columns: overviewColumns) : track.peaks
        return waveform(peaks, in: rect)
    }

    /// Columns in the full-track envelope (build 10's `AudioTrack.peaks` count).
    public static let overviewColumns = 1600

    public static func line(_ text: String, font: String, size: CGFloat, color: CGColor) -> CTLine {
        line(text, font: CTFontCreateWithName(font as CFString, size, nil), color: color)
    }

    fileprivate static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// The overlay title and its box. The box travels inside `layout.titleArea`; positions
    /// outside 0…1 are clamped so the title never enters a reserved band.
    public static func caption(_ label: CueLabel, layout: CueLayout = CueLayout()) -> (CTLine, CGRect) {
        let (run, box, _) = fittedCaption(label, layout: layout)
        return (run, box)
    }

    /// Include overhanging glyphs as well as advances when aligning a custom face, e.g. Zapfino's long swashes.
    private static func horizontalBounds(_ run: CTLine, includeInk: Bool) -> ClosedRange<CGFloat> {
        let advance = CGFloat(CTLineGetTypographicBounds(run, nil, nil, nil))
        let ink = includeInk ? CTLineGetBoundsWithOptions(run, .useGlyphPathBounds) : .null
        return min(0, ink.minX)...max(advance, ink.isNull ? 0 : ink.maxX)
    }

    private static func fittedCaption(_ label: CueLabel, layout: CueLayout) -> (CTLine, CGRect, CGPoint) {
        let titleSize = layout.titleSize
        let area = layout.titleArea
        let color = rgb(0.83, 0.87, 0.87)
        let font = layout.typography.title
        let custom = !layout.typography.usesLegacyTitle
        let original = line(label.text, font: font.font(at: titleSize), color: color)
        let natural = horizontalBounds(original, includeInk: custom)
        let adjustedSize = max(CueLayout.Metrics.titleMinimumSize,
                               titleSize * min(1, area.width / max(1, natural.upperBound - natural.lowerBound)))
        let adjusted = adjustedSize < titleSize ? line(label.text, font: font.font(at: adjustedSize), color: color) : original
        let ellipsis = line("…", font: font.font(at: adjustedSize), color: color)
        var limit = area.width
        var fitted = CTLineCreateTruncatedLine(adjusted, limit, .end, ellipsis) ?? adjusted
        var bounds = horizontalBounds(fitted, includeInk: custom)
        while custom && bounds.upperBound - bounds.lowerBound > area.width && limit > 0 {
            limit = max(0, limit - max(1, bounds.upperBound - bounds.lowerBound - area.width))
            fitted = CTLineCreateTruncatedLine(adjusted, limit, .end, ellipsis) ?? ellipsis
            bounds = horizontalBounds(fitted, includeInk: true)
        }
        let width = min(area.width, bounds.upperBound - bounds.lowerBound)
        let height = layout.typography.titleBoxHeight(adjustedSize)
        let x = min(1, max(0, label.position.x)), y = min(1, max(0, label.position.y))
        let rect = CGRect(x: area.minX + (area.width - width) * x,
                          y: area.minY + (area.height - height) * y,
                          width: width, height: height)
        let origin = CGPoint(x: rect.minX - bounds.lowerBound, y: rect.minY + layout.typography.titleBaselineInset(adjustedSize))
        return (fitted, rect, origin)
    }

    /// Build 10 entry point: `frame` is a 25-base clock frame of the whole, untrimmed track.
    /// Forwards to the timeline entry point with an identity 25 fps timeline carrying the
    /// track's markers and the appearance's countdown target. Pass the cached `layout` when one
    /// is at hand; it defaults to `appearance.layout`.
    public static func draw(in ctx: CGContext, rect: CGRect, track: AudioTrack, path: CGPath,
                            frame: Int, label: CueLabel, appearance: CueAppearance = CueAppearance(),
                            layout: CueLayout? = nil, heldRange: Range<Int>? = nil) {
        draw(in: ctx, rect: rect, track: track, path: path, timeline: timeline(for: track, appearance: appearance),
             layout: layout ?? appearance.layout, position: frame, label: label, appearance: appearance,
             heldRange: heldRange)
    }

    /// The 25 fps preview timeline for a track: its markers and the appearance's countdown
    /// target. `markers` overrides the track's own (a job's edited values); `trim` adds the
    /// job's in and out points and pre-roll (none by default: the whole track, as in build 10).
    public static func timeline(for track: AudioTrack, appearance: CueAppearance,
                                markers: MusicMarkers? = nil, trim: TrimSettings = .none) -> ClipTimeline {
        ClipTimeline(duration: track.seconds, trim: trim, markers: markers ?? track.markers,
                     target: appearance.countdownTarget)
    }

    // Marker colours: distinct from the waveforms, the cursor and the warning red.
    /// Music end: warm yellow, solid 3 pt line.
    public static let musicEndColor = rgb(1.0, 0.80, 0.22)
    /// Fade start: sky blue, dashed 2 pt line.
    public static let fadeStartColor = rgb(0.45, 0.72, 1.0)

    /// Renders one output image. `position` is a `ClipTimeline` position at the encode rate, so
    /// 1080i50 fields and 1080p50 frames each get their own playhead; the clocks read
    /// `timeline.clocks(at:)`. `layout` must be `appearance.layout` (computed once and shared)
    /// and `path` must be `overviewPath(track, layout:)`.
    ///
    /// Markers come from `timeline.musicEndMarker` and `fadeStartMarker` and are drawn on both
    /// waveforms. Remaining, its fade to red and the waveform fades all measure to
    /// `timeline.target`; past a music-end target Remaining holds at 00:00:00 in red. With
    /// target File end (or no marker, or no tail) the clocks and fades are build 10's.
    /// Safe-zone guides are never drawn here (the monitor overlays them).
    ///
    /// With a trim, `path` must be `overviewPath(track, layout:, timeline:)`: the overview, the
    /// close-up, the clocks and the markers then cover only the trimmed range. During the
    /// pre-roll (`timeline.position(at:)` is `.slate`) the image is the slate instead: title,
    /// music duration, `loudness` when known and the "Starts in" countdown, with no waveforms
    /// and no clocks (`drawSlate`).
    public static func draw(in ctx: CGContext, rect: CGRect, track: AudioTrack, path: CGPath,
                            timeline: ClipTimeline, layout: CueLayout, position: Int, label: CueLabel,
                            appearance: CueAppearance = CueAppearance(), heldRange: Range<Int>? = nil,
                            loudness: LoudnessMeasurement? = nil) {
        let held = heldRange.map { frames in
            let start = timeline.sourceRange.lowerBound
            let fps = Double(ClipTimeline.clockRate)
            let range = (start + Double(frames.lowerBound) / fps)...(start + Double(frames.upperBound) / fps)
            return CloseUpWindow(visible: range, intersection: range.clamped(to: timeline.sourceRange))
        }
        draw(in: ctx, rect: rect, track: track, path: path, timeline: timeline, layout: layout, position: position,
             label: label, appearance: appearance, holding: held, loudness: loudness)
    }

    /// The monitor freezes the precise source interval while dragging a waveform or marker.
    public static func draw(in ctx: CGContext, rect: CGRect, track: AudioTrack, path: CGPath,
                            timeline: ClipTimeline, layout: CueLayout, position: Int, label: CueLabel,
                            appearance: CueAppearance, holding held: CloseUpWindow?, loudness: LoudnessMeasurement? = nil) {
        typealias M = CueLayout.Metrics
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / size.width, y: rect.height / size.height)
        ctx.textMatrix = .identity
        if case .slate(let startsIn) = timeline.position(at: position) {
            drawSlate(slate(track: track, timeline: timeline, startsIn: startsIn, label: label, loudness: loudness),
                      in: ctx, layout: layout)
            return
        }
        func fill(_ rect: CGRect, _ color: CGColor) {
            ctx.setFillColor(color)
            ctx.fill(rect)
        }
        func drawText(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
                      _ color: CGColor, mono: Bool = false, right: Bool = false) {
            let face = mono ? layout.typography.clock : layout.typography.title
            let run = line(text, font: face.font(at: size), color: color)
            let custom = mono ? !layout.typography.usesLegacyClock : !layout.typography.usesLegacyTitle
            let bounds = horizontalBounds(run, includeInk: custom)
            ctx.textPosition = CGPoint(x: x - (right ? bounds.upperBound : bounds.lowerBound), y: y)
            CTLineDraw(run, ctx)
        }
        let total = timeline.clockFrames
        let clocks = timeline.clocks(at: position)
        // Equals `toFileEnd` for target File end; counts to the music-end marker otherwise.
        let framesLeft = clocks.remaining
        let fps = Double(ClipTimeline.clockRate)
        let start = timeline.sourceRange.lowerBound
        let playhead = start + playheadFrame(timeline: timeline, position: position) / fps
        let warningFraction = appearance.warning.fraction(framesLeft: framesLeft, solidAt: appearance.solidRedAt)
        let window = held ?? closeUp(timeline: timeline, position: position, appearance: appearance)
        let markers: [(MarkerKind, Double)] = [
            (MarkerKind.fadeStart, timeline.fadeStartMarker), (MarkerKind.musicEnd, timeline.musicEndMarker)
        ].compactMap { kind, marker in marker.map { (kind, start + $0.seconds) } }
        func paintMarkers(in range: ClosedRange<Double>, rect: CGRect, labelSize: CGFloat) {
            for (kind, seconds) in markers {
                guard range.contains(seconds) else { continue }
                let x = min(rect.maxX - 1.5, max(rect.minX + 1.5, xPosition(seconds, in: range, rect: rect)))
                let color = kind == .musicEnd ? musicEndColor : fadeStartColor
                ctx.saveGState()
                ctx.setStrokeColor(color)
                ctx.setLineWidth(kind == .musicEnd ? 3 : 2)
                if kind == .fadeStart { ctx.setLineDash(phase: 0, lengths: [10, 6]) }
                ctx.move(to: CGPoint(x: x, y: rect.minY))
                ctx.addLine(to: CGPoint(x: x, y: rect.maxY))
                ctx.strokePath()
                ctx.restoreGState()
                // Tag inside the panel's top edge: End right of its line, Fade left of its line
                // (flipped at the panel edge), so the two read apart when they sit close.
                let text = kind == .musicEnd ? "End" : "Fade"
                let run = line(text, font: "HelveticaNeue-Bold", size: labelSize, color: color)
                let width = CGFloat(CTLineGetTypographicBounds(run, nil, nil, nil))
                let gap: CGFloat = 6
                var left = kind == .musicEnd ? x + gap : x - gap - width
                if left + width > rect.maxX - 4 { left = x - gap - width }
                if left < rect.minX + 4 { left = x + gap }
                let baseline = rect.maxY - labelSize - 2
                let tag = CGRect(x: left - 3, y: baseline - labelSize * 0.25, width: width + 6, height: labelSize * 1.2)
                fill(tag.intersection(rect), background.copy(alpha: 0.8) ?? background)
                ctx.textPosition = CGPoint(x: left, y: baseline)
                CTLineDraw(run, ctx)
            }
        }
        func paintEnvelope(_ path: CGPath, rect: CGRect, audioRect: CGRect, cursor: CGFloat, bright: CueColor,
                           dimmed: CueColor, shading: CloseUpShading, fadeToRed: Bool, markersIn range: ClosedRange<Double>,
                           showCursor: Bool = true) {
            let fraction = fadeToRed ? warningFraction : 0
            let fullColor = bright.blended(toward: .warningRed, fraction: fraction).cgColor
            let lowColor = dimmed.blended(toward: CueColor.warningRed.dimmed, fraction: fraction).cgColor
            fill(CGRect(x: audioRect.minX, y: rect.midY, width: audioRect.width, height: 1.5), rgb(0.30, 0.37, 0.37))
            ctx.setFillColor(shading == .upcomingBrighter ? fullColor : lowColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.saveGState()
            ctx.clip(to: CGRect(x: rect.minX, y: rect.minY, width: min(rect.width, max(0, cursor - rect.minX)), height: rect.height))
            ctx.setFillColor(shading == .upcomingBrighter ? lowColor : fullColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
            if !markers.isEmpty {
                paintMarkers(in: range, rect: rect, labelSize: rect.height >= 150 ? 20 : 16)
            }
            guard showCursor else { return }
            let overhang = M.cursorOverhang
            fill(CGRect(x: cursor - overhang, y: rect.minY - overhang, width: 2 * overhang,
                        height: rect.height + 2 * overhang), paper)
        }

        let full = overviewRange(timeline)
        let panel = rgb(0.071, 0.102, 0.111)
        fill(CGRect(origin: .zero, size: size), background)
        ctx.clip(to: layout.usable)
        if layout.showFullTrack {
            let overview = layout.overview
            drawText("Full track", overview.minX, layout.overviewLabelBaseline, M.overviewLabelSize, dim)
            drawText(AudioTrack.clock(total), overview.maxX, layout.overviewLabelBaseline, M.overviewDurationSize, dim,
                     mono: true, right: true)
            fill(overview, panel)
            let lo = xPosition(window.intersection.lowerBound, in: full, rect: overview)
            let hi = xPosition(window.intersection.upperBound, in: full, rect: overview)
            let highlight = CGRect(x: lo, y: overview.minY, width: hi - lo, height: overview.height)
            if layout.detail != nil { fill(highlight, rgb(0.14, 0.22, 0.22)) }
            let physical = audioRect(for: timeline.sourceRange, axis: full, in: overview)
            paintEnvelope(path, rect: overview, audioRect: physical, cursor: xPosition(playhead, in: full, rect: overview),
                          bright: appearance.overviewColor ?? CueAppearance.defaultOverview,
                          dimmed: appearance.overviewColor?.dimmed ?? CueColor(0.31, 0.40, 0.41),
                          shading: .playedBrighter, fadeToRed: appearance.fadeFullTrack, markersIn: full)
            if layout.detail != nil {
                ctx.setStrokeColor(rgb(0.51, 0.69, 0.64))
                ctx.setLineWidth(2)
                ctx.stroke(highlight)
            }
        }
        if let detail = layout.detail {
            drawText("Close-up", detail.minX, detail.maxY + M.detailLabelOffset, M.detailLabelSize, dim)
            fill(detail, panel)
            // Align ticks to track time so a fade ending at 1:20 keeps its mark while scrolling.
            let visible = window.visible
            let sampled = window.intersection
            let width = (visible.upperBound - visible.lowerBound) * fps
            let tickStep = [1, 5, 10, 25, 50, 125, 250].first { Double($0 * 10) >= width - 1e-8 } ?? 250
            let firstTick = Int(ceil(((sampled.lowerBound - start) * fps - 1e-8) / Double(tickStep))) * tickStep
            let lastTick = Int(floor((sampled.upperBound - start) * fps + 1e-8))
            let tickBaseline = detail.minY - M.tickLabelOffset
            for tick in stride(from: firstTick, through: lastTick, by: tickStep) {
                let tickX = xPosition(start + Double(tick) / fps, in: visible, rect: detail)
                fill(CGRect(x: tickX, y: detail.minY, width: 2, height: 8), dim)
                if (tick / tickStep).isMultiple(of: 2) {
                    fill(CGRect(x: tickX, y: detail.minY, width: 1.5, height: detail.height), rgb(0.12, 0.16, 0.17))
                    let value = tickStep >= AudioTrack.fps
                        ? String(format: "%d:%02d", tick / AudioTrack.fps / 60, tick / AudioTrack.fps % 60)
                        : AudioTrack.clock(tick)
                    let width = CGFloat(CTLineGetTypographicBounds(
                        line(value, font: layout.typography.clock.font(at: M.tickLabelSize), color: dim), nil, nil, nil))
                    let left = min(detail.maxX - width, max(detail.minX, tickX - width / 2))
                    drawText(value, left, tickBaseline, M.tickLabelSize, dim, mono: true)
                }
            }
            let audioRect = audioRect(for: sampled, axis: visible, in: detail)
            let peaks = sampled.upperBound > sampled.lowerBound && !track.detailPeaks.isEmpty
                ? track.peaks(in: sampled.lowerBound..<sampled.upperBound,
                              columns: max(1, Int((1600 * audioRect.width / detail.width).rounded()))) : []
            let detailPath = waveform(peaks, in: audioRect, expandQuiet: true)
            let cursor = xPosition(playhead, in: visible, rect: detail)
            paintEnvelope(detailPath, rect: detail, audioRect: audioRect, cursor: cursor,
                          bright: appearance.detailColor ?? CueAppearance.defaultDetail,
                          dimmed: appearance.detailColor?.dimmed ?? CueColor(0.32, 0.48, 0.47),
                          shading: appearance.closeUpShading, fadeToRed: appearance.fadeCloseUp, markersIn: visible,
                          showCursor: visible.contains(playhead))
            if visible.contains(playhead) {
                let triangleTop = detail.maxY + M.cursorTriangleRise
                let half = M.cursorTriangleHalfWidth
                ctx.beginPath()
                ctx.move(to: CGPoint(x: cursor, y: detail.maxY - 2))
                ctx.addLine(to: CGPoint(x: cursor - half, y: triangleTop))
                ctx.addLine(to: CGPoint(x: cursor + half, y: triangleTop))
                ctx.closePath()
                ctx.setFillColor(paper)
                ctx.fillPath()
            }
        }
        func drawClock(_ name: String, frame: Int, color: CueColor, size: ClockSize, labelBaseline: CGFloat, right: Bool) {
            let x = right ? layout.contentMaxX : layout.contentMinX
            drawText(name, x, labelBaseline, M.clockLabelSize, dim, right: right)
            drawText(AudioTrack.clock(frame), x, layout.clockBaseline, size.points, color.cgColor, mono: true, right: right)
        }
        if layout.showElapsed {
            drawClock("Elapsed", frame: clocks.elapsed, color: appearance.elapsed.color, size: layout.elapsedSize,
                  labelBaseline: layout.elapsedLabelBaseline, right: false)
        }
        // Past a music-end target Remaining holds at 00:00:00 in solid red until the clip ends.
        let remainingColor = clocks.isPastTarget ? CueColor.warningRed
            : appearance.remaining.color.blended(toward: .warningRed, fraction: warningFraction)
        if layout.showRemaining {
            drawClock("Remaining", frame: framesLeft, color: remainingColor, size: layout.remainingSize,
                  labelBaseline: layout.remainingLabelBaseline, right: true)
        }
        if layout.showTitle && !label.text.isEmpty {
            let (run, _, origin) = fittedCaption(label, layout: layout)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: CGColor(gray: 0, alpha: 0.65))
            ctx.textPosition = origin
            CTLineDraw(run, ctx)
        }
    }

    // MARK: Slate

    /// What the pre-roll slate shows, top to bottom.
    public struct Slate: Sendable, Equatable {
        /// The overlay title, or the file name when the title is empty.
        public var title: String
        public var startsInLabel: String
        /// The countdown to the first music frame, `MM:SS:FF` on the 25 base.
        public var startsIn: String
        /// "Music duration MM:SS:FF": the trimmed range.
        public var duration: String
        /// The loudness line, or nil when no measurement is known.
        public var loudness: String?

        /// The lines in drawing order.
        public var lines: [String] { [title, startsInLabel, startsIn, duration] + (loudness.map { [$0] } ?? []) }
    }

    public static let startsInLabel = "Starts in"

    /// The slate content for a position `startsIn` 25-base frames before the music.
    public static func slate(track: AudioTrack, timeline: ClipTimeline, startsIn: Int, label: CueLabel,
                             loudness: LoudnessMeasurement?) -> Slate {
        let trimmed = label.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? track.url.deletingPathExtension().lastPathComponent : trimmed
        return Slate(title: title, startsInLabel: startsInLabel, startsIn: AudioTrack.clock(startsIn),
                     duration: "Music duration " + AudioTrack.clock(timeline.clockFrames),
                     loudness: loudness.map(loudnessText))
    }

    /// "−23.0 LUFS · TP −1.0 dBTP · LRA 6.2 LU"; "Loudness: silent" without integrated loudness.
    public static func loudnessText(_ m: LoudnessMeasurement) -> String {
        func number(_ value: Double) -> String {
            String(format: "%.1f", value).replacingOccurrences(of: "-", with: "\u{2212}")
        }
        guard let lufs = m.integratedLUFS else { return "Loudness: silent" }
        var parts = ["\(number(lufs)) LUFS"]
        if let tp = m.truePeakDBTP { parts.append("TP \(number(tp)) dBTP") }
        parts.append("LRA \(number(m.rangeLU)) LU")
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Slate type sizes at full scale (picture points).
    enum SlateMetrics {
        static let titleSize: CGFloat = 64
        static let labelSize: CGFloat = 36
        static let countdownSize: CGFloat = 190
        static let infoSize: CGFloat = 36
        /// Gaps above each row after the first: label, countdown, duration, loudness.
        static let gaps: [CGFloat] = [64, 8, 64, 16]
    }

    /// Draws the slate centred in `layout.safeFrame`, so nothing enters a reserved band. The
    /// stack scales down as a whole when the safe frame is too small; long lines are truncated
    /// to its width. Called with the context already in picture points.
    static func drawSlate(_ slate: Slate, in ctx: CGContext, layout: CueLayout) {
        typealias S = SlateMetrics
        ctx.setFillColor(background)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.clip(to: layout.usable)
        // Keep antialiasing off the safe frame's edges.
        let frame = layout.safeFrame.insetBy(dx: 2, dy: 2)
        guard frame.width > 4, frame.height > 4 else { return }
        let text = rgb(0.83, 0.87, 0.87)
        let title = layout.typography.title
        let clock = layout.typography.clock
        var rows: [(text: String, font: CueFonts.Resolved, points: CGFloat, color: CGColor)] = [
            (slate.startsInLabel, title, S.labelSize, dim),
            (slate.startsIn, clock, S.countdownSize, mint),
            (slate.duration, title, S.infoSize, text),
        ]
        if layout.showTitle { rows.insert((slate.title, title, S.titleSize, text), at: 0) }
        if let loudness = slate.loudness { rows.append((loudness, title, S.infoSize, dim)) }
        let gaps = layout.showTitle ? S.gaps : Array(S.gaps.dropFirst())
        func metrics(_ run: CTLine) -> (width: CGFloat, ascent: CGFloat, descent: CGFloat) {
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(run, &ascent, &descent, nil))
            return (width, ascent, descent)
        }
        func lines(scale: CGFloat) -> [CTLine] {
            rows.map { row in
                let run = line(row.text, font: row.font.font(at: row.points * scale), color: row.color)
                guard metrics(run).width > frame.width else { return run }
                let ellipsis = line("\u{2026}", font: row.font.font(at: row.points * scale), color: row.color)
                return CTLineCreateTruncatedLine(run, Double(frame.width), .end, ellipsis) ?? run
            }
        }
        func height(_ runs: [CTLine], scale: CGFloat) -> CGFloat {
            runs.map { let m = metrics($0); return m.ascent + m.descent }.reduce(0, +)
                + gaps.prefix(runs.count - 1).reduce(0, +) * scale
        }
        // The countdown is never truncated: the whole stack shrinks until it fits the width.
        let countdownWidth = metrics(line(slate.startsIn, font: clock.font(at: S.countdownSize), color: mint)).width
        var scale = min(1, frame.width / max(1, countdownWidth),
                        frame.height / max(1, height(lines(scale: 1), scale: 1)))
        var runs = lines(scale: scale)
        // Font metrics do not scale exactly linearly; shrink until the stack fits.
        while height(runs, scale: scale) > frame.height, scale > 0.05 {
            scale *= 0.95
            runs = lines(scale: scale)
        }
        var y = frame.midY + height(runs, scale: scale) / 2
        for (index, run) in runs.enumerated() {
            if index > 0 { y -= gaps[index - 1] * scale }
            let m = metrics(run)
            let baseline = y - m.ascent
            ctx.textPosition = CGPoint(x: frame.midX - min(m.width, frame.width) / 2, y: baseline)
            CTLineDraw(run, ctx)
            y = baseline - m.descent
        }
    }

    /// The playhead on the 25 clock base for a timeline position: whole frames at 25 images per
    /// second, half frames for 50 Hz fields and frames. Clamped to the music; 0 during the slate.
    public static func playheadFrame(timeline: ClipTimeline, position: Int) -> Double {
        let offset = max(0, timeline.musicOffset(position))
        let frame = Double(offset) * Double(ClipTimeline.clockRate) / Double(timeline.positionRate)
        return min(Double(timeline.clockFrames), frame)
    }

    /// The full-track time axis preserves the last padded clock frame, including its second field.
    public static func overviewRange(_ timeline: ClipTimeline) -> ClosedRange<Double> {
        let start = timeline.sourceRange.lowerBound
        return start...(start + Double(timeline.clockFrames) / Double(ClipTimeline.clockRate))
    }

    /// The window shared by the picture, monitor gestures and the two export fields.
    public static func closeUp(timeline: ClipTimeline, position: Int, appearance: CueAppearance) -> CloseUpWindow {
        let fps = Double(ClipTimeline.clockRate)
        let start = timeline.sourceRange.lowerBound
        let zoom = appearance.zoom
        let width = zoom.rawValue > 0 ? Double(zoom.rawValue) : Double(zoom.frameCount(for: timeline.clockFrames)) / fps
        let target: Double
        if timeline.target == .musicEnd, let end = timeline.markers.musicEnd, end.isFinite {
            target = min(timeline.sourceRange.upperBound, max(start, end))
        } else {
            target = timeline.sourceRange.upperBound
        }
        let interval = CloseUpWindow.interval(playhead: start + playheadFrame(timeline: timeline, position: position) / fps,
                                              clip: timeline.sourceRange, target: target, startingWidth: width,
                                              mode: appearance.playheadMode, endZoom: appearance.endZoom)
        guard appearance.playheadMode == .edgeHeld, appearance.endZoom == .off else { return interval }
        // Legacy edges land exactly on a field. Reconstruct their original seconds representation
        // before floor/ceil select a peak bucket (e.g. 5.06 versus 5.0600000000000005).
        func fieldTime(_ seconds: Double) -> Double {
            start + ((seconds - start) * (2 * fps)).rounded() / (2 * fps)
        }
        let visible = fieldTime(interval.visible.lowerBound)...fieldTime(interval.visible.upperBound)
        return CloseUpWindow(visible: visible, intersection: visible.clamped(to: timeline.sourceRange))
    }

    private static func audioRect(for audio: ClosedRange<Double>, axis: ClosedRange<Double>, in rect: CGRect) -> CGRect {
        let lo = xPosition(audio.lowerBound, in: axis, rect: rect)
        let hi = xPosition(audio.upperBound, in: axis, rect: rect)
        return CGRect(x: lo, y: rect.minY, width: hi - lo, height: rect.height)
    }

    private static func xPosition(_ seconds: Double, in range: ClosedRange<Double>, rect: CGRect) -> CGFloat {
        guard range.upperBound > range.lowerBound else { return rect.minX }
        return rect.minX + rect.width * CGFloat(seconds - range.lowerBound) / CGFloat(range.upperBound - range.lowerBound)
    }

}

// MARK: - Hit-testing (monitor)

extension CuePicture {
    /// What a click in the picture lands on, in build 10's priority order; a marker line sits
    /// between the title and the waveforms.
    public enum HitTarget: Equatable, Sendable {
        case title, overview, detail, none
        case marker(MarkerKind, onCloseUp: Bool)
        /// A trim handle at the left (in) or right (out) edge of the full-track overview.
        case trim(TrimEdge)
    }

    /// Horizontal grab tolerance either side of a marker line, in picture points.
    public static let markerHitTolerance: CGFloat = 10

    /// A picture rectangle (1920 × 1080 points) mapped back into the monitor view.
    public static func viewRect(_ rect: CGRect, in picture: CGRect) -> CGRect {
        let sx = picture.width / size.width, sy = picture.height / size.height
        return CGRect(x: picture.minX + rect.minX * sx, y: picture.minY + rect.minY * sy,
                      width: rect.width * sx, height: rect.height * sy)
    }

    /// The nearest marker on a visible waveform, using the same source-time axis as drawing.
    public static func markerHit(at point: CGPoint, timeline: ClipTimeline, layout: CueLayout,
                                 closeUp: CloseUpWindow) -> (kind: MarkerKind, onCloseUp: Bool)? {
        let markers: [(MarkerKind, Double)] = [
            (MarkerKind.musicEnd, timeline.musicEndMarker), (MarkerKind.fadeStart, timeline.fadeStartMarker)
        ].compactMap { kind, marker in marker.map { (kind, timeline.sourceRange.lowerBound + $0.seconds) } }
        var panes: [(CGRect, ClosedRange<Double>, Bool)] = []
        if layout.showFullTrack { panes.append((layout.overview, overviewRange(timeline), false)) }
        if let detail = layout.detail { panes.append((detail, closeUp.visible, true)) }
        for (rect, range, onCloseUp) in panes where rect.insetBy(dx: -markerHitTolerance, dy: -6).contains(point) {
            var best: (kind: MarkerKind, distance: CGFloat)?
            for (kind, seconds) in markers where range.contains(seconds) {
                let x = xPosition(seconds, in: range, rect: rect)
                let distance = abs(point.x - x)
                if distance <= markerHitTolerance, distance < (best?.distance ?? .infinity) { best = (kind, distance) }
            }
            if let best { return (best.kind, onCloseUp) }
        }
        return nil
    }

    /// `hitTarget(at:label:layout:)` with marker lines and trim handles: the title first, then a
    /// marker within tolerance, then a trim handle (`trimHandles`), then scrubbing on either
    /// waveform. Markers win over trim handles because a music-end marker with no silent tail
    /// sits on the overview's right edge; the out handle's grab zone reaches further into the
    /// margin than the marker tolerance, so it stays reachable there.
    public static func hitTarget(at point: CGPoint, label: CueLabel, layout: CueLayout,
                                 timeline: ClipTimeline, closeUp: CloseUpWindow, trimHandles: Bool = false) -> HitTarget {
        let target = hitTarget(at: point, label: label, layout: layout)
        if target == .title { return .title }
        if let hit = markerHit(at: point, timeline: timeline, layout: layout, closeUp: closeUp) {
            return .marker(hit.kind, onCloseUp: hit.onCloseUp)
        }
        if trimHandles, let edge = trimHandleHit(at: point, layout: layout) { return .trim(edge) }
        return target
    }

    // MARK: Trim handles (monitor)

    /// How far a trim handle's grab zone reaches outside the overview panel, and inside it.
    public static let trimHandleOutside: CGFloat = 30
    public static let trimHandleInside: CGFloat = 8

    /// The grab zone of a trim handle in picture points: a strip at the overview's left (in) or
    /// right (out) edge, mostly in the side margin so it does not steal scrubbing.
    public static func trimHandleRect(_ edge: TrimEdge, layout: CueLayout) -> CGRect {
        guard layout.showFullTrack else { return .null }
        let overview = layout.overview
        let width = trimHandleOutside + trimHandleInside
        let x = edge == .inPoint ? overview.minX - trimHandleOutside : overview.maxX - trimHandleInside
        return CGRect(x: x, y: overview.minY - 12, width: width, height: overview.height + 24)
    }

    /// The trim handle under `point`, if any.
    public static func trimHandleHit(at point: CGPoint, layout: CueLayout) -> TrimEdge? {
        TrimEdge.allCases.first { trimHandleRect($0, layout: layout).contains(point) }
    }

    /// The trim after dragging `edge` from `down` to `point`, starting from `original`.
    ///
    /// The drag is relative and maps the content column to the whole source (`duration`), since
    /// the monitor shows the untrimmed track while a handle moves. Points snap to whole 25-base
    /// frames, the range never shrinks below `ClipTimeline.minimumTrimSeconds` (or the whole
    /// source when shorter), and an edge dragged to the source start or end becomes `nil`, so
    /// an undone trim is the identity again. Fades and pre-roll are kept.
    public static func draggedTrim(_ edge: TrimEdge, original: TrimSettings, down: CGPoint, to point: CGPoint,
                                   duration: Double, layout: CueLayout) -> TrimSettings {
        guard duration.isFinite, duration > 0 else { return original }
        let fps = Double(ClipTimeline.clockRate)
        let minimum = min(ClipTimeline.minimumTrimSeconds, duration)
        let lower = min(duration, max(0, original.inPoint ?? 0))
        let upper = min(duration, max(lower, original.outPoint ?? duration))
        let axis = overviewRange(ClipTimeline(duration: duration))
        let delta = Double((point.x - down.x) / max(1, layout.contentWidth)) * axis.upperBound
        var trim = original
        switch edge {
        case .inPoint:
            let limit = max(0, upper - minimum)
            let value = min(limit, max(0, ((lower + delta) * fps).rounded() / fps))
            trim.inPoint = value <= ClipTimeline.epsilon ? nil : value
        case .outPoint:
            let limit = min(duration, lower + minimum)
            let value = max(limit, min(duration, ((upper + delta) * fps).rounded() / fps))
            trim.outPoint = value >= duration - ClipTimeline.epsilon ? nil : value
        }
        return trim
    }

    /// Invert the picture's time axis, including fractional and off-clip edges of a held window.
    public static func draggedMarkerSeconds(at point: CGPoint, in range: ClosedRange<Double>, timeline: ClipTimeline,
                                            layout: CueLayout) -> Double {
        let fraction = min(1, max(0, (point.x - layout.contentMinX) / layout.contentWidth))
        let seconds = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
        return min(timeline.sourceRange.upperBound, max(timeline.sourceRange.lowerBound, seconds))
    }

    public static func scrubFrame(at point: CGPoint, in range: ClosedRange<Double>, timeline: ClipTimeline,
                                  layout: CueLayout) -> Int {
        let seconds = draggedMarkerSeconds(at: point, in: range, timeline: timeline, layout: layout)
        if seconds >= timeline.sourceRange.upperBound { return timeline.clockFrames }
        return Int(((seconds - timeline.sourceRange.lowerBound) * Double(ClipTimeline.clockRate)).rounded())
    }

    /// A point in the monitor view mapped to picture points (1920 × 1080, bottom-left origin).
    public static func picturePoint(_ point: CGPoint, in picture: CGRect) -> CGPoint {
        CGPoint(x: (point.x - picture.minX) / picture.width * size.width,
                y: (point.y - picture.minY) / picture.height * size.height)
    }

    public static func hitTarget(at point: CGPoint, label: CueLabel, layout: CueLayout) -> HitTarget {
        if layout.showTitle && !label.text.isEmpty && caption(label, layout: layout).1.insetBy(dx: -6, dy: -6).contains(point) {
            return .title
        }
        if layout.showFullTrack && layout.overview.insetBy(dx: -8, dy: -12).contains(point) { return .overview }
        if let detail = layout.detail, detail.insetBy(dx: -8, dy: -12).contains(point) { return .detail }
        return .none
    }

    /// The frame a scrub at `point` seeks to within `range`: the whole track for the full-track
    /// waveform, the held close-up window for the close-up. Both waveforms span the content
    /// column, so x maps across `layout.contentMinX…contentMaxX`.
    public static func scrubFrame(at point: CGPoint, in range: Range<Int>, layout: CueLayout) -> Int {
        let fraction = min(1, max(0, (point.x - layout.contentMinX) / layout.contentWidth))
        return range.lowerBound + Int((fraction * CGFloat(range.count)).rounded())
    }

    /// The title position after a drag from `down` to `point` that started at `origin`.
    /// Clamped to 0…1, which keeps the box inside `layout.titleArea` and so the usable area.
    public static func draggedTitlePosition(origin: CGPoint, down: CGPoint, to point: CGPoint,
                                            label: CueLabel, layout: CueLayout) -> CGPoint {
        let box = caption(label, layout: layout).1
        let area = layout.titleArea
        let dx = (point.x - down.x) / max(1, area.width - box.width)
        let dy = (point.y - down.y) / max(1, area.height - box.height)
        return CGPoint(x: min(1, max(0, origin.x + dx)), y: min(1, max(0, origin.y + dy)))
    }
}
