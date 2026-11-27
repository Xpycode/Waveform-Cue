import AppKit
import UniformTypeIdentifiers

final class MonitorView: NSView {
    var track: AudioTrack? {
        didSet {
            scrubRange = nil
            heldDetail = nil
            updateOverview()
            needsDisplay = true
        }
    }
    var cueAppearance = CueAppearance.load() {
        didSet {
            if (oldValue.zoom == .off) != (cueAppearance.zoom == .off) { updateOverview() }
            needsDisplay = true
        }
    }

    private func updateOverview() {
        path = CuePicture.waveform(track?.peaks ?? [], in: CuePicture.overviewRect(for: cueAppearance.zoom))
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
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
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
        if let track {
            CuePicture.draw(in: context, rect: picture, track: track, path: path, frame: frameNumber, label: label, appearance: cueAppearance, heldRange: heldDetail)
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

    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: (p.x - picture.minX) / picture.width * CuePicture.size.width,
                       y: (p.y - picture.minY) / picture.height * CuePicture.size.height)
    }
    override func mouseDown(with event: NSEvent) {
        guard editingEnabled else { return }
        window?.makeFirstResponder(self)
        guard let track else { onChoose?(); return }
        let p = point(event)
        down = p
        let box = CuePicture.caption(label).1
        if !label.text.isEmpty && box.insetBy(dx: -6, dy: -6).contains(p) {
            labelOrigin = label.position
            return
        }
        if CuePicture.overviewRect(for: cueAppearance.zoom).insetBy(dx: -8, dy: -12).contains(p) {
            scrubRange = 0..<track.frames
        } else if cueAppearance.zoom != .off, CuePicture.detail.insetBy(dx: -8, dy: -12).contains(p) {
            heldDetail = CuePicture.closeUp(frame: frameNumber, total: track.frames, zoom: cueAppearance.zoom)
            scrubRange = heldDetail
        }
        if scrubRange != nil {
            onScrubChanged?(true)
            scrub(p)
        }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = point(event)
        if let origin = labelOrigin, let down {
            let box = CuePicture.caption(label).1
            let dx = (p.x - down.x) / max(1, CuePicture.wave.width - box.width)
            let dy = (p.y - down.y) / (CuePicture.size.height - 110 - box.height)
            onPlace?(CGPoint(x: min(1, max(0, origin.x + dx)), y: min(1, max(0, origin.y + dy))))
        } else if scrubRange != nil { scrub(p) }
    }
    override func mouseUp(with event: NSEvent) {
        labelOrigin = nil
        down = nil
        guard scrubRange != nil else { return }
        scrubRange = nil
        heldDetail = nil
        needsDisplay = true
        onScrubChanged?(false)
    }
    private func scrub(_ p: CGPoint) {
        guard let scrubRange else { return }
        let fraction = min(1, max(0, (p.x - CuePicture.wave.minX) / CuePicture.wave.width))
        onSeek?(scrubRange.lowerBound + Int((fraction * CGFloat(scrubRange.count)).rounded()))
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
