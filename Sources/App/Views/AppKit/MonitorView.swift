import AppKit
import CueCore
import UniformTypeIdentifiers

final class MonitorView: NSView {
    var track: AudioTrack? {
        didSet {
            scrubRange = nil
            heldDetail = nil
            markerDrag = nil
            trimDrag = nil
            markers = nil
            trim = .none
            loudness = nil
            updateOverview()
            needsDisplay = true
        }
    }
    var cueAppearance: CueAppearance {
        didSet {
            // One layout per appearance change, shared by drawing, seek, scrub and title drag.
            let newLayout = cueAppearance.layout
            if newLayout != layout {
                let overviewMoved = newLayout.overview != layout.overview
                layout = newLayout
                if overviewMoved { updateOverview() }
            }
            needsDisplay = true
        }
    }
    private(set) var layout: CueLayout
    /// The job's markers when they differ from the track's (edited values); nil uses
    /// `track.markers`. Cleared when a new track is assigned, so set it after `track`.
    var markers: MusicMarkers? { didSet { if oldValue != markers { needsDisplay = true } } }
    /// The markers the picture shows.
    var effectiveMarkers: MusicMarkers { markers ?? track?.markers ?? .none }
    /// A marker was dragged: which one and its new time in source seconds. Called on every
    /// drag step; the monitor already shows the new position.
    var onMarkerChanged: ((MarkerKind, Double) -> Void)?

    /// The job's trim, fades and pre-roll. Cleared when a new track is assigned, so set it after
    /// `track`. With a trim the picture shows only the trimmed range, and with a pre-roll the
    /// first positions are the slate: `frameNumber` and `onSeek` are then positions of this
    /// 25 fps timeline (`ClipTimeline.position(at:)`), not frames of the whole track. With
    /// `.none` both are the whole track's frames, as in build 10.
    var trim: TrimSettings = .none {
        didSet {
            guard oldValue != trim else { return }
            if trimDrag == nil { updateOverview() }
            needsDisplay = true
        }
    }
    /// The job's loudness, shown on the pre-roll slate. Cleared with `track`.
    var loudness: LoudnessMeasurement? { didSet { if oldValue != loudness { needsDisplay = true } } }
    /// An in or out handle was dragged: the whole new trim (fades and pre-roll kept). Called on
    /// every drag step; the monitor already shows the new range. An edge dragged back to the
    /// source start or end is `nil`.
    var onTrimChanged: ((TrimSettings) -> Void)?

    /// The timeline the monitor draws and hit-tests with: the job's trim and pre-roll, its
    /// markers and the appearance's countdown target, at 25 fps.
    private var timeline: ClipTimeline? {
        track.map { CuePicture.timeline(for: $0, appearance: cueAppearance, markers: markers, trim: trim) }
    }

    /// While a trim handle moves the monitor shows the whole, untrimmed track.
    private var untrimmedTimeline: ClipTimeline? {
        track.map { CuePicture.timeline(for: $0, appearance: cueAppearance, markers: markers) }
    }

    private func updateOverview() {
        guard let track, trimDrag == nil, let timeline else {
            path = CuePicture.waveform(track?.peaks ?? [], in: layout.overview)
            return
        }
        path = CuePicture.overviewPath(track, layout: layout, timeline: timeline)
    }
    var label = CueLabel() { didSet { needsDisplay = true } }
    var frameNumber = 0 { didSet { if oldValue != frameNumber { needsDisplay = true } } }
    var onOpen: ((URL) -> Void)?
    var onChoose: (() -> Void)?
    var onSeek: ((Int) -> Void)?
    var onScrubChanged: ((Bool) -> Void)?
    var onPlace: ((CGPoint) -> Void)?
    var editingEnabled = true
    var placeholder = "Drop an audio file" { didSet { needsDisplay = true } }
    private var path = CGMutablePath() as CGPath
    private var hovered = false
    private var labelOrigin: CGPoint?
    private var down: CGPoint?
    private var scrubRange: Range<Int>?
    private var heldDetail: Range<Int>?
    private var markerDrag: (kind: MarkerKind, range: Range<Int>)?
    private var trimDrag: (edge: TrimEdge, original: TrimSettings, down: CGPoint)?
    private var hoverTracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        let appearance = CueAppearance.load()
        cueAppearance = appearance
        layout = appearance.layout
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Waveform preview monitor")
    }
    required init?(coder: NSCoder) { fatalError() }

    var picture: CGRect {
        let viewport = bounds.insetBy(dx: 8, dy: 8)
        let scale = min(viewport.width / CuePicture.size.width, viewport.height / CuePicture.size.height)
        let width = CuePicture.size.width * scale
        let height = CuePicture.size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.13, green: 0.13, blue: 0.13, alpha: 1).setFill()
        bounds.fill()
        let picture = self.picture
        guard !picture.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        if let track, let timeline {
            if let trimDrag, let full = untrimmedTimeline {
                // The whole track, with the close-up on the edge being dragged.
                let edge = trimDrag.edge == .inPoint ? timeline.sourceRange.lowerBound : timeline.sourceRange.upperBound
                let frame = Int((edge * Double(ClipTimeline.clockRate)).rounded())
                CuePicture.draw(in: context, rect: picture, track: track, path: path, timeline: full,
                                layout: layout, position: full.position(ofClockFrame: frame), label: label,
                                appearance: cueAppearance)
            } else {
                CuePicture.draw(in: context, rect: picture, track: track, path: path, timeline: timeline,
                                layout: layout, position: frameNumber, label: label, appearance: cueAppearance,
                                heldRange: heldDetail, loudness: loudness)
            }
            if cueAppearance.showGuides { drawGuides(in: context, picture: picture) }
            if editingEnabled, onTrimChanged != nil { drawTrimHandles(in: context, picture: picture, timeline: timeline) }
        } else {
            NSColor(cgColor: CuePicture.rgb(0.047, 0.067, 0.076))?.setFill()
            picture.fill()
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            NSColor(cgColor: CuePicture.mint)?.setFill()
            for (i, h) in [12, 25, 45, 27, 51, 34, 17].enumerated() {
                NSBezierPath(roundedRect: NSRect(x: center.x + CGFloat(i - 3) * 7 - 2,
                    y: center.y + 28 - CGFloat(h)/2, width: 4, height: CGFloat(h)), xRadius: 2, yRadius: 2).fill()
            }
            let title = NSAttributedString(string: placeholder, attributes: [
                .font: NSFont.systemFont(ofSize: 21, weight: .medium), .foregroundColor: NSColor.white])
            title.draw(at: NSPoint(x: center.x-title.size().width/2, y: center.y-30))
            let hint = NSAttributedString(string: "WAV, AIFF, MP3 or M4A", attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.lightGray])
            hint.draw(at: NSPoint(x: center.x-hint.size().width/2, y: center.y-57))
        }
        // Draw the outline in the monitor matte, just outside the exported picture.
        NSColor(srgbRed: 0.50, green: 0.50, blue: 0.50, alpha: 1).setStroke()
        let outline = NSBezierPath(rect: picture.insetBy(dx: -0.5, dy: -0.5))
        outline.lineWidth = 1
        outline.stroke()
        if hovered {
            NSColor(cgColor: CuePicture.mint)?.setStroke()
            let border = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            border.lineWidth = 3
            border.stroke()
        }
    }

    /// Hatched tint over the reserved bands, in the monitor only; `CuePicture` never draws it,
    /// so an export never contains it.
    private func drawGuides(in context: CGContext, picture: CGRect) {
        let bands = layout.reserved.map { CuePicture.viewRect($0, in: picture).intersection(picture) }
            .filter { !$0.isEmpty }
        guard !bands.isEmpty else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let tint = CGColor(srgbRed: 1, green: 0.42, blue: 0.24, alpha: 1)
        for band in bands {
            context.saveGState()
            context.clip(to: band)
            context.setFillColor(tint.copy(alpha: 0.16)!)
            context.fill(band)
            context.setStrokeColor(tint.copy(alpha: 0.55)!)
            context.setLineWidth(1)
            let spacing: CGFloat = 10
            var x = band.minX - band.height
            while x < band.maxX {
                context.move(to: CGPoint(x: x, y: band.minY))
                context.addLine(to: CGPoint(x: x + band.height, y: band.maxY))
                x += spacing
            }
            context.strokePath()
            context.restoreGState()
            context.setStrokeColor(tint.copy(alpha: 0.8)!)
            context.stroke(band.insetBy(dx: 0.5, dy: 0.5), width: 1)
        }
    }

    /// In and out handles, in the monitor only (an export never contains them). At rest they
    /// are brackets in the margin beside the full-track overview, bright on a trimmed edge.
    /// While one moves, the overview shows the whole track with the cut-away parts dimmed.
    private func drawTrimHandles(in context: CGContext, picture: CGRect, timeline: ClipTimeline) {
        guard trimDrag != nil || !isSlate(timeline) else { return }
        let overview = CuePicture.viewRect(layout.overview, in: picture)
        let scale = picture.width / CuePicture.size.width
        let active = NSColor(cgColor: CuePicture.mint) ?? .systemTeal
        let idle = NSColor(white: 0.62, alpha: 0.7)
        context.saveGState()
        defer { context.restoreGState() }
        var edges: [(TrimEdge, CGFloat, Bool)]
        if trimDrag != nil, timeline.duration > 0 {
            func x(_ seconds: Double) -> CGFloat { overview.minX + overview.width * CGFloat(seconds / timeline.duration) }
            let lo = x(timeline.sourceRange.lowerBound), hi = x(timeline.sourceRange.upperBound)
            NSColor(white: 0, alpha: 0.6).setFill()
            CGRect(x: overview.minX, y: overview.minY, width: max(0, lo - overview.minX), height: overview.height).fill()
            CGRect(x: hi, y: overview.minY, width: max(0, overview.maxX - hi), height: overview.height).fill()
            edges = [(.inPoint, lo, true), (.outPoint, hi, true)]
        } else {
            edges = [(.inPoint, overview.minX - 6 * scale, timeline.sourceRange.lowerBound > 1e-8),
                     (.outPoint, overview.maxX + 6 * scale, timeline.sourceRange.upperBound < timeline.duration - 1e-8)]
        }
        let bar = max(2, 4 * scale), tick = max(4, 12 * scale)
        let top = overview.maxY + 6 * scale, bottom = overview.minY - 6 * scale
        for (edge, x, lit) in edges {
            (lit ? active : idle).setFill()
            let inward: CGFloat = edge == .inPoint ? 1 : -1
            let stem = CGRect(x: x - bar / 2, y: bottom, width: bar, height: top - bottom)
            stem.fill()
            // Bracket ticks point into the kept range.
            CGRect(x: inward > 0 ? stem.minX : stem.maxX - tick, y: top - bar, width: tick, height: bar).fill()
            CGRect(x: inward > 0 ? stem.minX : stem.maxX - tick, y: bottom, width: tick, height: bar).fill()
        }
    }

    private func isSlate(_ timeline: ClipTimeline) -> Bool {
        if case .slate = timeline.position(at: frameNumber) { return true }
        return false
    }

    /// The close-up window on screen, on the 25 base of the trimmed music.
    private func closeUpRange() -> Range<Int> {
        guard let timeline else { return 0..<1 }
        let playhead = Int(CuePicture.playheadFrame(timeline: timeline, position: frameNumber))
        return heldDetail ?? CuePicture.closeUp(frame: playhead, total: timeline.clockFrames, zoom: cueAppearance.zoom)
    }

    /// Click precedence: title, then a marker, then a trim handle (only once `onTrimChanged` is
    /// wired), then scrubbing (see `CuePicture.hitTarget`). A scrub from the slate seeks into
    /// the music.
    private func hitTarget(_ p: CGPoint) -> CuePicture.HitTarget {
        guard let timeline else { return .none }
        return CuePicture.hitTarget(at: p, label: label, layout: layout, timeline: timeline, closeUp: closeUpRange(),
                                    trimHandles: onTrimChanged != nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard editingEnabled, track != nil, markerDrag == nil, trimDrag == nil else { return }
        switch hitTarget(point(event)) {
        case .marker, .trim: NSCursor.resizeLeftRight.set()
        default: NSCursor.arrow.set()
        }
    }

    private func point(_ event: NSEvent) -> CGPoint {
        CuePicture.picturePoint(convert(event.locationInWindow, from: nil), in: picture)
    }
    override func mouseDown(with event: NSEvent) {
        guard editingEnabled else { return }
        window?.makeFirstResponder(self)
        guard track != nil, let timeline else { onChoose?(); return }
        let p = point(event)
        down = p
        switch hitTarget(p) {
        case .title:
            labelOrigin = label.position
            return
        case .marker(let kind, let onCloseUp):
            if onCloseUp {
                heldDetail = closeUpRange()
                markerDrag = (kind, heldDetail!)
            } else {
                markerDrag = (kind, 0..<timeline.clockFrames)
            }
            return
        case .trim(let edge):
            trimDrag = (edge, trim, p)
            updateOverview()
            needsDisplay = true
            return
        case .overview:
            scrubRange = 0..<timeline.clockFrames
        case .detail:
            heldDetail = closeUpRange()
            scrubRange = heldDetail
        case .none:
            break
        }
        if scrubRange != nil {
            onScrubChanged?(true)
            scrub(p)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if let drag = markerDrag {
            dragMarker(drag, to: p)
        } else if let drag = trimDrag, let track {
            let edited = CuePicture.draggedTrim(drag.edge, original: drag.original, down: drag.down, to: p,
                                                duration: track.seconds, layout: layout)
            if edited != trim {
                trim = edited
                onTrimChanged?(edited)
            }
        } else if let origin = labelOrigin, let down {
            onPlace?(CuePicture.draggedTitlePosition(origin: origin, down: down, to: p, label: label, layout: layout))
        } else if scrubRange != nil { scrub(p) }
    }
    override func mouseUp(with event: NSEvent) {
        labelOrigin = nil
        down = nil
        if trimDrag != nil {
            trimDrag = nil
            updateOverview()
            needsDisplay = true
            return
        }
        if markerDrag != nil {
            markerDrag = nil
            heldDetail = nil
            needsDisplay = true
            return
        }
        guard scrubRange != nil else { return }
        scrubRange = nil
        heldDetail = nil
        needsDisplay = true
        onScrubChanged?(false)
    }
    private func dragMarker(_ drag: (kind: MarkerKind, range: Range<Int>), to p: CGPoint) {
        guard let timeline else { return }
        let seconds = CuePicture.draggedMarkerSeconds(at: p, in: drag.range, timeline: timeline, layout: layout)
        var edited = effectiveMarkers
        edited.setEdited(drag.kind, to: seconds)
        markers = edited
        onMarkerChanged?(drag.kind, seconds)
    }
    private func scrub(_ p: CGPoint) {
        guard let scrubRange, let timeline else { return }
        // A clock frame of the trimmed music, as a timeline position (the same frame untrimmed).
        onSeek?(timeline.position(ofClockFrame: CuePicture.scrubFrame(at: p, in: scrubRange, layout: layout)))
    }
    private func file(_ info: NSDraggingInfo) -> URL? {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.count == 1 ? urls?.first : nil
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovered = editingEnabled && file(sender) != nil
        needsDisplay = true
        return hovered ? .copy : []
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = false; needsDisplay = true }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hovered = false
        needsDisplay = true
        guard editingEnabled, let url = file(sender) else { return false }
        onOpen?(url)
        return true
    }
}
