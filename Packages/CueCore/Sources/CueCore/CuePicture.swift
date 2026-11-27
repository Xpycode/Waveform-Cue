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

extension MusicMarkers {
    /// The marker in force (edited, else detected).
    public func value(_ kind: MarkerKind) -> Double? { kind == .musicEnd ? musicEnd : fadeStart }

    /// Sets the operator's edited value for `kind`.
    public mutating func setEdited(_ kind: MarkerKind, to seconds: Double?) {
        if kind == .musicEnd { editedMusicEnd = seconds } else { editedFadeStart = seconds }
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

    // Center the playhead in the travelling window. Against either end of
    // the clip the window holds still and the cursor crosses the waveform.
    public static func closeUp(frame: Int, total: Int, zoom: ZoomWindow) -> Range<Int> {
        let length = zoom.frameCount(for: total)
        let start = min(max(0, frame - length / 2), total - length)
        return start..<(start + length)
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
        waveform(track.peaks, in: layout.overview)
    }

    public static func line(_ text: String, font: String, size: CGFloat, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// The overlay title and its box. The box travels inside `layout.titleArea`; positions
    /// outside 0…1 are clamped so the title never enters a reserved band.
    public static func caption(_ label: CueLabel, layout: CueLayout = CueLayout()) -> (CTLine, CGRect) {
        let titleSize = layout.titleSize
        let area = layout.titleArea
        let color = rgb(0.83, 0.87, 0.87)
        let original = line(label.text, font: "HelveticaNeue-Medium", size: titleSize, color: color)
        let naturalWidth = CGFloat(CTLineGetTypographicBounds(original, nil, nil, nil))
        let adjustedSize = max(CueLayout.Metrics.titleMinimumSize, titleSize * min(1, area.width / max(1, naturalWidth)))
        let adjusted = adjustedSize < titleSize ? line(label.text, font: "HelveticaNeue-Medium", size: adjustedSize, color: color) : original
        let ellipsis = line("…", font: "HelveticaNeue-Medium", size: adjustedSize, color: color)
        let fitted = CTLineCreateTruncatedLine(adjusted, area.width, .end, ellipsis) ?? adjusted
        let width = min(area.width, CGFloat(CTLineGetTypographicBounds(fitted, nil, nil, nil)))
        let height = CueLayout.titleBoxHeight(adjustedSize)
        let x = min(1, max(0, label.position.x)), y = min(1, max(0, label.position.y))
        let rect = CGRect(x: area.minX + (area.width - width) * x,
                          y: area.minY + (area.height - height) * y,
                          width: width, height: height)
        return (fitted, rect)
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

    /// The untrimmed 25 fps timeline for a track: its markers and the appearance's countdown
    /// target. `markers` overrides the track's own (a job's edited values).
    public static func timeline(for track: AudioTrack, appearance: CueAppearance,
                                markers: MusicMarkers? = nil) -> ClipTimeline {
        ClipTimeline(duration: track.seconds, markers: markers ?? track.markers, target: appearance.countdownTarget)
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
    /// Not yet here: the pre-roll slate draws as the first music frame (task 4.3).
    public static func draw(in ctx: CGContext, rect: CGRect, track: AudioTrack, path: CGPath,
                            timeline: ClipTimeline, layout: CueLayout, position: Int, label: CueLabel,
                            appearance: CueAppearance = CueAppearance(), heldRange: Range<Int>? = nil) {
        typealias M = CueLayout.Metrics
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / size.width, y: rect.height / size.height)
        ctx.textMatrix = .identity
        func fill(_ rect: CGRect, _ color: CGColor) {
            ctx.setFillColor(color)
            ctx.fill(rect)
        }
        func drawText(_ text: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
                      _ color: CGColor, mono: Bool = false, right: Bool = false) {
            let run = line(text, font: mono ? "Menlo" : "HelveticaNeue-Medium", size: size, color: color)
            let width = right ? CGFloat(CTLineGetTypographicBounds(run, nil, nil, nil)) : 0
            ctx.textPosition = CGPoint(x: x - width, y: y)
            CTLineDraw(run, ctx)
        }
        let total = timeline.clockFrames
        let clocks = timeline.clocks(at: position)
        // Equals `toFileEnd` for target File end; counts to the music-end marker otherwise.
        let framesLeft = clocks.remaining
        // Playhead on the 25 base; it moves between clock frames at 50 images per second.
        let playhead = playheadFrame(timeline: timeline, position: position)
        let warningFraction = appearance.warning.fraction(framesLeft: framesLeft, solidAt: appearance.solidRedAt)
        let window = heldRange.map { Window(lower: Double($0.lowerBound), count: $0.count) }
            ?? Window.closeUp(playhead: playhead, total: total, zoom: appearance.zoom)
        let fps = Double(AudioTrack.fps)
        func xForFrame(_ frame: Double, in range: Window, rect: CGRect) -> CGFloat {
            rect.minX + rect.width * CGFloat(frame - range.lower) / CGFloat(range.count)
        }
        let markerFrames: [(MarkerKind, Double)] = [
            (MarkerKind.fadeStart, timeline.fadeStartMarker), (MarkerKind.musicEnd, timeline.musicEndMarker)
        ].compactMap { kind, marker in marker.map { (kind, $0.seconds * fps) } }
        func paintMarkers(in range: Window, rect: CGRect, labelSize: CGFloat) {
            for (kind, frame) in markerFrames {
                guard frame >= range.lower, frame <= range.upper else { continue }
                let x = min(rect.maxX - 1.5, max(rect.minX + 1.5, xForFrame(frame, in: range, rect: rect)))
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
        func paintEnvelope(_ path: CGPath, rect: CGRect, cursor: CGFloat, played: CueColor,
                           upcoming: CueColor, fadeToRed: Bool, markersIn range: Window) {
            let fraction = fadeToRed ? warningFraction : 0
            fill(CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: 1.5), rgb(0.30, 0.37, 0.37))
            ctx.setFillColor(upcoming.blended(toward: CueColor.warningRed.dimmed, fraction: fraction).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.saveGState()
            ctx.clip(to: CGRect(x: rect.minX, y: rect.minY, width: max(0, cursor - rect.minX), height: rect.height))
            ctx.setFillColor(played.blended(toward: .warningRed, fraction: fraction).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
            if !markerFrames.isEmpty {
                paintMarkers(in: range, rect: rect, labelSize: rect.height >= 150 ? 20 : 16)
            }
            let overhang = M.cursorOverhang
            fill(CGRect(x: cursor - overhang, y: rect.minY - overhang, width: 2 * overhang,
                        height: rect.height + 2 * overhang), paper)
        }

        let full = Window(lower: 0, count: total)
        let overview = layout.overview
        let lo = xForFrame(window.lower, in: full, rect: overview)
        let hi = xForFrame(window.upper, in: full, rect: overview)
        let panel = rgb(0.071, 0.102, 0.111)
        fill(CGRect(origin: .zero, size: size), background)
        drawText("Full track", overview.minX, layout.overviewLabelBaseline, M.overviewLabelSize, dim)
        drawText(AudioTrack.clock(total), overview.maxX, layout.overviewLabelBaseline, M.overviewDurationSize, dim,
                 mono: true, right: true)
        fill(overview, panel)
        let highlight = CGRect(x: lo, y: overview.minY, width: hi - lo, height: overview.height)
        if layout.detail != nil { fill(highlight, rgb(0.14, 0.22, 0.22)) }
        paintEnvelope(path, rect: overview, cursor: xForFrame(playhead, in: full, rect: overview),
                      played: appearance.overviewColor ?? CueAppearance.defaultOverview,
                      upcoming: appearance.overviewColor?.dimmed ?? CueColor(0.31, 0.40, 0.41),
                      fadeToRed: appearance.fadeFullTrack, markersIn: full)
        if let detail = layout.detail {
            ctx.setStrokeColor(rgb(0.51, 0.69, 0.64))
            ctx.setLineWidth(2)
            ctx.stroke(highlight)
            drawText("Close-up", detail.minX, detail.maxY + M.detailLabelOffset, M.detailLabelSize, dim)
            fill(detail, panel)
            // Align ticks to track time so a fade ending at 1:20 keeps its mark while scrolling.
            let tickStep = [1, 5, 10, 25, 50, 125, 250].first { $0 * 10 >= window.count } ?? 250
            let firstTick = Int((window.lower / Double(tickStep)).rounded(.up)) * tickStep
            let lastTick = Int(window.upper.rounded(.down))
            let tickBaseline = detail.minY - M.tickLabelOffset
            for tick in stride(from: firstTick, through: lastTick, by: tickStep) {
                let tickX = xForFrame(Double(tick), in: window, rect: detail)
                fill(CGRect(x: tickX, y: detail.minY, width: 2, height: 8), dim)
                if (tick / tickStep).isMultiple(of: 2) {
                    fill(CGRect(x: tickX, y: detail.minY, width: 1.5, height: detail.height), rgb(0.12, 0.16, 0.17))
                    let value = tickStep >= AudioTrack.fps
                        ? String(format: "%d:%02d", tick / AudioTrack.fps / 60, tick / AudioTrack.fps % 60)
                        : AudioTrack.clock(tick)
                    let width = CGFloat(CTLineGetTypographicBounds(
                        line(value, font: "Menlo", size: M.tickLabelSize, color: dim), nil, nil, nil))
                    let left = min(detail.maxX - width, max(detail.minX, tickX - width / 2))
                    drawText(value, left, tickBaseline, M.tickLabelSize, dim, mono: true)
                }
            }
            let start = timeline.sourceRange.lowerBound
            let timeRange = (start + window.lower / fps)..<(start + window.upper / fps)
            let detailPath = waveform(track.peaks(in: timeRange, columns: 1600), in: detail, expandQuiet: true)
            let cursor = xForFrame(playhead, in: window, rect: detail)
            paintEnvelope(detailPath, rect: detail, cursor: cursor,
                          played: appearance.detailColor ?? CueAppearance.defaultDetail,
                          upcoming: appearance.detailColor?.dimmed ?? CueColor(0.32, 0.48, 0.47),
                          fadeToRed: appearance.fadeCloseUp, markersIn: window)
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
        func drawClock(_ name: String, frame: Int, color: CueColor, size: ClockSize, labelBaseline: CGFloat, right: Bool) {
            let x = right ? layout.contentMaxX : layout.contentMinX
            drawText(name, x, labelBaseline, M.clockLabelSize, dim, right: right)
            drawText(AudioTrack.clock(frame), x, layout.clockBaseline, size.points, color.cgColor, mono: true, right: right)
        }
        drawClock("Elapsed", frame: clocks.elapsed, color: appearance.elapsed.color, size: layout.elapsedSize,
                  labelBaseline: layout.elapsedLabelBaseline, right: false)
        // Past a music-end target Remaining holds at 00:00:00 in solid red until the clip ends.
        let remainingColor = clocks.isPastTarget ? CueColor.warningRed
            : appearance.remaining.color.blended(toward: .warningRed, fraction: warningFraction)
        drawClock("Remaining", frame: framesLeft, color: remainingColor, size: layout.remainingSize,
                  labelBaseline: layout.remainingLabelBaseline, right: true)
        if !label.text.isEmpty {
            let (run, box) = caption(label, layout: layout)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: CGColor(gray: 0, alpha: 0.65))
            ctx.textPosition = CGPoint(x: box.minX, y: box.minY + M.titleBaselineInset)
            CTLineDraw(run, ctx)
        }
    }

    /// The playhead on the 25 clock base for a timeline position: whole frames at 25 images per
    /// second, half frames for 50 Hz fields and frames. Clamped to the music; 0 during the slate.
    public static func playheadFrame(timeline: ClipTimeline, position: Int) -> Double {
        let offset = max(0, timeline.musicOffset(position))
        let frame = Double(offset) * Double(ClipTimeline.clockRate) / Double(timeline.positionRate)
        return min(Double(timeline.clockFrames), frame)
    }

    /// A close-up window on the 25 base that may start between frames.
    struct Window {
        var lower: Double
        var count: Int
        var upper: Double { lower + Double(count) }

        /// `closeUp(frame:total:zoom:)` for a fractional playhead; identical for whole frames.
        static func closeUp(playhead: Double, total: Int, zoom: ZoomWindow) -> Window {
            let length = zoom.frameCount(for: total)
            let start = min(max(0, playhead - Double(length / 2)), Double(total - length))
            return Window(lower: start, count: length)
        }
    }
}

// MARK: - Hit-testing (monitor)

extension CuePicture {
    /// What a click in the picture lands on, in build 10's priority order; a marker line sits
    /// between the title and the waveforms.
    public enum HitTarget: Equatable, Sendable {
        case title, overview, detail, none
        case marker(MarkerKind, onCloseUp: Bool)
    }

    /// Horizontal grab tolerance either side of a marker line, in picture points.
    public static let markerHitTolerance: CGFloat = 10

    /// A picture rectangle (1920 × 1080 points) mapped back into the monitor view.
    public static func viewRect(_ rect: CGRect, in picture: CGRect) -> CGRect {
        let sx = picture.width / size.width, sy = picture.height / size.height
        return CGRect(x: picture.minX + rect.minX * sx, y: picture.minY + rect.minY * sy,
                      width: rect.width * sx, height: rect.height * sy)
    }

    /// The marker line under `point`, nearest first, on the full track (whole clip) or the
    /// close-up (`closeUp`, the 25-base window on screen). Nil when none is within tolerance.
    public static func markerHit(at point: CGPoint, timeline: ClipTimeline, layout: CueLayout,
                                 closeUp: Range<Int>) -> (kind: MarkerKind, onCloseUp: Bool)? {
        let fps = Double(ClipTimeline.clockRate)
        let markers: [(MarkerKind, Double)] = [
            (MarkerKind.musicEnd, timeline.musicEndMarker), (MarkerKind.fadeStart, timeline.fadeStartMarker)
        ].compactMap { kind, marker in marker.map { (kind, $0.seconds * fps) } }
        guard !markers.isEmpty else { return nil }
        var panes: [(rect: CGRect, lower: Double, upper: Double, onCloseUp: Bool)] = [
            (layout.overview, 0, Double(timeline.clockFrames), false)
        ]
        if let detail = layout.detail {
            panes.append((detail, Double(closeUp.lowerBound), Double(closeUp.upperBound), true))
        }
        for pane in panes where pane.rect.insetBy(dx: -markerHitTolerance, dy: -6).contains(point) {
            guard pane.upper > pane.lower else { continue }
            var best: (kind: MarkerKind, distance: CGFloat)?
            for (kind, frame) in markers where frame >= pane.lower && frame <= pane.upper {
                let x = pane.rect.minX + pane.rect.width * CGFloat((frame - pane.lower) / (pane.upper - pane.lower))
                let distance = abs(point.x - x)
                if distance <= markerHitTolerance, distance < (best?.distance ?? .infinity) { best = (kind, distance) }
            }
            if let best { return (best.kind, pane.onCloseUp) }
        }
        return nil
    }

    /// `hitTarget(at:label:layout:)` with marker lines: the title first, then a marker within
    /// tolerance, then scrubbing on either waveform.
    public static func hitTarget(at point: CGPoint, label: CueLabel, layout: CueLayout,
                                 timeline: ClipTimeline, closeUp: Range<Int>) -> HitTarget {
        let target = hitTarget(at: point, label: label, layout: layout)
        if target == .title { return .title }
        if let hit = markerHit(at: point, timeline: timeline, layout: layout, closeUp: closeUp) {
            return .marker(hit.kind, onCloseUp: hit.onCloseUp)
        }
        return target
    }

    /// The source time, in seconds, a marker dragged to `point` lands on: x maps across the
    /// content column over `range` (25-base frames of the trimmed music: the whole clip for the
    /// full track, the held window for the close-up), clamped inside the trimmed range.
    public static func draggedMarkerSeconds(at point: CGPoint, in range: Range<Int>, timeline: ClipTimeline,
                                            layout: CueLayout) -> Double {
        let fraction = Double(min(1, max(0, (point.x - layout.contentMinX) / layout.contentWidth)))
        let frame = Double(range.lowerBound) + fraction * Double(range.count)
        let seconds = timeline.sourceRange.lowerBound + frame / Double(ClipTimeline.clockRate)
        return min(timeline.sourceRange.upperBound, max(timeline.sourceRange.lowerBound, seconds))
    }

    /// A point in the monitor view mapped to picture points (1920 × 1080, bottom-left origin).
    public static func picturePoint(_ point: CGPoint, in picture: CGRect) -> CGPoint {
        CGPoint(x: (point.x - picture.minX) / picture.width * size.width,
                y: (point.y - picture.minY) / picture.height * size.height)
    }

    public static func hitTarget(at point: CGPoint, label: CueLabel, layout: CueLayout) -> HitTarget {
        if !label.text.isEmpty && caption(label, layout: layout).1.insetBy(dx: -6, dy: -6).contains(point) {
            return .title
        }
        if layout.overview.insetBy(dx: -8, dy: -12).contains(point) { return .overview }
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
