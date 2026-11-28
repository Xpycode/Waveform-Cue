import AppKit
import CueCore

private final class PaneInsertionLine: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        bounds.fill()
    }
}

/// Tracks a single grip without making the grip first responder or detaching any controls.
@MainActor
final class PaneDragController {
    private let scroll: NSScrollView
    private let document: NSView
    private let line = PaneInsertionLine()
    private let panes: () -> [SidebarPaneView]
    private let context: () -> PaneReorder.Context?
    private let completed: (Int, Int) -> Void
    var didEndTracking: (() -> Void)?
    private(set) var isTracking = false

    init(scroll: NSScrollView, document: NSView, panes: @escaping () -> [SidebarPaneView],
         context: @escaping () -> PaneReorder.Context?, completed: @escaping (Int, Int) -> Void) {
        self.scroll = scroll
        self.document = document
        self.panes = panes
        self.context = context
        self.completed = completed
        line.isHidden = true
        document.addSubview(line)
    }

    func track(from pane: SidebarPaneView, event down: NSEvent) {
        let initialPanes = panes()
        guard !isTracking, let window = pane.window, let from = initialPanes.firstIndex(of: pane),
              let initialContext = context(), initialContext.isEditable else { return }
        let start = down.locationInWindow
        var last = start
        var lastMotion = ProcessInfo.processInfo.systemUptime
        var dragging = false
        var click = false
        var chosenGap: Int?
        var mask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .periodic, .keyDown]
        if #available(macOS 26.0, *) { mask.insert(.mouseCancelled) }
        isTracking = true
        NSEvent.startPeriodicEvents(afterDelay: 0.08, withPeriod: 0.05)
        do {
            defer {
                NSEvent.stopPeriodicEvents()
                line.isHidden = true
                isTracking = false
                didEndTracking?()
            }
            window.trackEvents(matching: mask, timeout: 0.5, mode: .eventTracking) { event, stop in
                let now = ProcessInfo.processInfo.systemUptime
                guard window.isVisible, pane.window === window else { stop.pointee = true; return }
                guard let event else {
                    if NSEvent.pressedMouseButtons & 1 == 0 { stop.pointee = true }
                    return
                }
                switch event.type {
                case .leftMouseDragged, .leftMouseUp:
                    last = event.locationInWindow
                    lastMotion = now
                    dragging = dragging || hypot(last.x - start.x, last.y - start.y) >= 4
                    if event.type == .leftMouseUp {
                        if dragging { chosenGap = self.updateLine(at: last) }
                        else { click = true }
                        stop.pointee = true
                    } else if dragging {
                        _ = self.updateLine(at: last)
                    }
                case .keyDown:
                    if event.keyCode == 53 { stop.pointee = true }
                case .periodic:
                    if now - lastMotion > 1 && NSEvent.pressedMouseButtons & 1 == 0 {
                        stop.pointee = true
                    } else if dragging {
                        self.scrollNearEdge(at: last)
                        _ = self.updateLine(at: last)
                    }
                default: stop.pointee = true // mouseCancelled on macOS 26+
                }
            }
        }
        // didEndTracking may have applied a deferred job switch, lock or rearrangement.
        guard pane.window === window, initialPanes == panes(), initialContext.permitsMove(in: context()) else { return }
        if click { pane.showMoveMenu() }
        if let chosenGap { completed(from, chosenGap) }
    }

    private func scrollNearEdge(at location: NSPoint) {
        let clip = scroll.contentView
        let point = clip.convert(location, from: nil)
        let visible = clip.bounds
        guard visible.contains(point) else { return }
        let top = point.y - visible.minY
        let bottom = visible.maxY - point.y
        let step: CGFloat
        if top < 24 { step = -ceil((24 - top) / 2) }
        else if bottom < 24 { step = ceil((24 - bottom) / 2) }
        else { return }
        let next = clip.constrainBoundsRect(visible.offsetBy(dx: 0, dy: step))
        clip.scroll(to: next.origin)
        scroll.reflectScrolledClipView(clip)
    }

    private func updateLine(at location: NSPoint) -> Int? {
        let point = document.convert(location, from: nil)
        let frames = panes().map { document.convert($0.bounds, from: $0) }
        guard scroll.contentView.bounds.contains(scroll.contentView.convert(location, from: nil)),
              let first = frames.first, let last = frames.last,
              point.y >= first.minY - 6, point.y <= last.maxY + 6 else {
            line.isHidden = true
            return nil
        }
        let gap = PaneReorder.dropGap(pointerY: point.y, paneMidYs: frames.map(\.midY))
        let y: CGFloat
        if gap == 0 { y = first.minY - 3 }
        else if gap == frames.count { y = last.maxY + 3 }
        else { y = (frames[gap - 1].maxY + frames[gap].minY) / 2 }
        line.frame = NSRect(x: first.minX, y: round(y) - 1, width: first.width, height: 2)
        line.isHidden = false
        return gap
    }
}
