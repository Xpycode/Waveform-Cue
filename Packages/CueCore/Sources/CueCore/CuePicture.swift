import AppKit
import CoreText

public struct CueLabel {
    public var text = ""
    // Fraction of available travel inside the title-safe margin, bottom-left origin.
    public var position = CGPoint(x: 0, y: 1)

    public init(text: String = "", position: CGPoint = CGPoint(x: 0, y: 1)) {
        self.text = text
        self.position = position
    }
}

public enum CuePicture {
    public static let size = CGSize(width: 1920, height: 1080)
    public static let wave = CGRect(x: 96, y: 742, width: 1728, height: 100)
    public static let detail = CGRect(x: 96, y: 361, width: 1728, height: 265)

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

    public static func line(_ text: String, font: String, size: CGFloat, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    public static func caption(_ label: CueLabel) -> (CTLine, CGRect) {
        let titleSize: CGFloat = 48
        let color = rgb(0.83, 0.87, 0.87)
        let original = line(label.text, font: "HelveticaNeue-Medium", size: titleSize, color: color)
        let naturalWidth = CGFloat(CTLineGetTypographicBounds(original, nil, nil, nil))
        let adjustedSize = max(34, titleSize * min(1, wave.width / max(1, naturalWidth)))
        let adjusted = adjustedSize < titleSize ? line(label.text, font: "HelveticaNeue-Medium", size: adjustedSize, color: color) : original
        let ellipsis = line("…", font: "HelveticaNeue-Medium", size: adjustedSize, color: color)
        let fitted = CTLineCreateTruncatedLine(adjusted, wave.width, .end, ellipsis) ?? adjusted
        let width = min(wave.width, CGFloat(CTLineGetTypographicBounds(fitted, nil, nil, nil)))
        let height = adjustedSize + 22
        let rect = CGRect(x: wave.minX + (wave.width - width) * label.position.x,
                          y: 55 + (size.height - 110 - height) * label.position.y,
                          width: width, height: height)
        return (fitted, rect)
    }

    public static func draw(in ctx: CGContext, rect: CGRect, track: AudioTrack, path: CGPath,
                     frame: Int, label: CueLabel, appearance: CueAppearance = CueAppearance(), heldRange: Range<Int>? = nil) {
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
        let clamped = min(track.frames, max(0, frame))
        let framesLeft = track.frames - clamped
        let warningFraction = appearance.warning.fraction(framesLeft: framesLeft, solidAt: appearance.solidRedAt)
        let window = heldRange ?? closeUp(frame: clamped, total: track.frames, zoom: appearance.zoom)
        let fps = Double(AudioTrack.fps)
        func xForFrame(_ frame: Int, in range: Range<Int>, rect: CGRect) -> CGFloat {
            rect.minX + rect.width * CGFloat(frame - range.lowerBound) / CGFloat(range.count)
        }
        func paintEnvelope(_ path: CGPath, rect: CGRect, cursor: CGFloat, played: CueColor,
                           upcoming: CueColor, fadeToRed: Bool) {
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
            fill(CGRect(x: cursor - 3, y: rect.minY - 3, width: 6, height: rect.height + 6), paper)
        }

        let full = 0..<track.frames
        let overview = overviewRect(for: appearance.zoom)
        let lo = xForFrame(window.lowerBound, in: full, rect: overview)
        let hi = xForFrame(window.upperBound, in: full, rect: overview)
        let panel = rgb(0.071, 0.102, 0.111)
        fill(CGRect(origin: .zero, size: size), rgb(0.047, 0.067, 0.076))
        drawText("Full track", overview.minX, overview.maxY + 18, 26, dim)
        drawText(AudioTrack.clock(track.frames), overview.maxX, overview.maxY + 18, 25, dim, mono: true, right: true)
        fill(overview, panel)
        let highlight = CGRect(x: lo, y: overview.minY, width: hi - lo, height: overview.height)
        if appearance.zoom != .off { fill(highlight, rgb(0.14, 0.22, 0.22)) }
        paintEnvelope(path, rect: overview, cursor: xForFrame(clamped, in: full, rect: overview),
                      played: appearance.overviewColor ?? CueAppearance.defaultOverview,
                      upcoming: appearance.overviewColor?.dimmed ?? CueColor(0.31, 0.40, 0.41),
                      fadeToRed: appearance.fadeFullTrack)
        if appearance.zoom != .off {
            ctx.setStrokeColor(rgb(0.51, 0.69, 0.64))
            ctx.setLineWidth(2)
            ctx.stroke(highlight)
            drawText("Close-up", detail.minX, detail.maxY + 20, 26, dim)
            fill(detail, panel)
            // Align ticks to track time so a fade ending at 1:20 keeps its mark while scrolling.
            let tickStep = [1, 5, 10, 25, 50, 125, 250].first { $0 * 10 >= window.count } ?? 250
            let firstTick = ((window.lowerBound + tickStep - 1) / tickStep) * tickStep
            for tick in stride(from: firstTick, through: window.upperBound, by: tickStep) {
                let tickX = xForFrame(tick, in: window, rect: detail)
                fill(CGRect(x: tickX, y: detail.minY, width: 2, height: 8), dim)
                if (tick / tickStep).isMultiple(of: 2) {
                    fill(CGRect(x: tickX, y: detail.minY, width: 1.5, height: detail.height), rgb(0.12, 0.16, 0.17))
                    let value = tickStep >= AudioTrack.fps
                        ? String(format: "%d:%02d", tick / AudioTrack.fps / 60, tick / AudioTrack.fps % 60)
                        : AudioTrack.clock(tick)
                    let width = CGFloat(CTLineGetTypographicBounds(line(value, font: "Menlo", size: 26, color: dim), nil, nil, nil))
                    let left = min(detail.maxX - width, max(detail.minX, tickX - width / 2))
                    drawText(value, left, detail.minY - 37, 26, dim, mono: true)
                }
            }
            let timeRange = Double(window.lowerBound) / fps..<Double(window.upperBound) / fps
            let detailPath = waveform(track.peaks(in: timeRange, columns: 1600), in: detail, expandQuiet: true)
            let cursor = xForFrame(clamped, in: window, rect: detail)
            paintEnvelope(detailPath, rect: detail, cursor: cursor,
                          played: appearance.detailColor ?? CueAppearance.defaultDetail,
                          upcoming: appearance.detailColor?.dimmed ?? CueColor(0.32, 0.48, 0.47),
                          fadeToRed: appearance.fadeCloseUp)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: cursor, y: detail.maxY - 2))
            ctx.addLine(to: CGPoint(x: cursor - 11, y: detail.maxY + 14))
            ctx.addLine(to: CGPoint(x: cursor + 11, y: detail.maxY + 14))
            ctx.closePath()
            ctx.setFillColor(paper)
            ctx.fillPath()
        }
        func drawClock(_ name: String, frame: Int, style: ClockStyle, right: Bool) {
            let x = right ? wave.maxX : wave.minX
            let baseline: CGFloat = 100
            drawText(name, x, baseline + style.size.points * 0.77 + 26, 28, dim, right: right)
            drawText(AudioTrack.clock(frame), x, baseline, style.size.points, style.color.cgColor, mono: true, right: right)
        }
        drawClock("Elapsed", frame: clamped, style: appearance.elapsed, right: false)
        var remaining = appearance.remaining
        remaining.color = remaining.color.blended(toward: .warningRed, fraction: warningFraction)
        drawClock("Remaining", frame: framesLeft, style: remaining, right: true)
        if !label.text.isEmpty {
            let (run, box) = caption(label)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: CGColor(gray: 0, alpha: 0.65))
            ctx.textPosition = CGPoint(x: box.minX, y: box.minY + 17)
            CTLineDraw(run, ctx)
        }
    }
}
