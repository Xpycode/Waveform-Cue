import AppKit

/// A persistent arranged view. Its controls and field editor stay attached when the
/// containing stack moves the pane with insertArrangedSubview(_:at:).
final class SidebarPaneView: NSStackView, NSMenuDelegate {
    let body: NSView
    private let triangle = NSButton()
    private let grip: PaneGrip?
    private let moveMenu = NSMenu()
    var onGripDown: ((NSEvent) -> Void)?
    var willOpenMoveMenu: (() -> Void)?
    var onMove: ((Int) -> Bool)?
    var canMove: (Int) -> Bool = { _ in false }
    var canInteract: () -> Bool = { true }
    var willCollapse: (() -> Void)?
    var didToggle: ((Bool) -> Void)?

    var isCollapsed = false {
        didSet {
            guard oldValue != isCollapsed else { return }
            if isCollapsed { willCollapse?() }
            Self.updateLayout(in: self) { body.isHidden = isCollapsed }
            triangle.state = isCollapsed ? .off : .on
            triangle.setAccessibilityExpanded(!isCollapsed)
            didToggle?(isCollapsed)
        }
    }

    init(title: String, movable: Bool, body: NSView) {
        self.body = body
        grip = movable ? PaneGrip(title: title) : nil
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 5
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)

        triangle.bezelStyle = .disclosure
        triangle.setButtonType(.pushOnPushOff)
        triangle.title = ""
        triangle.state = .on
        triangle.setAccessibilityLabel(title)
        triangle.setAccessibilityExpanded(true)
        triangle.target = self
        triangle.action = #selector(toggle)
        triangle.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let name = NSButton(title: title, target: self, action: #selector(toggle))
        name.isBordered = false
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.setAccessibilityElement(false)
        let slot = grip ?? NSView()
        slot.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let header = NSStackView(views: [triangle, slot, name])
        header.spacing = 3
        header.alignment = .centerY
        addArrangedSubview(header)
        addArrangedSubview(body)
        if let grip {
            moveMenu.autoenablesItems = false
            for (index, title) in ["Move Up", "Move Down"].enumerated() {
                let item = moveMenu.addItem(withTitle: title, action: #selector(move(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index == 0 ? -1 : 1
            }
            moveMenu.delegate = self
            let trailing = NSView()
            header.addArrangedSubview(trailing)
            trailing.setContentHuggingPriority(.defaultLow, for: .horizontal)
            header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            for view in [header, triangle, name, grip, trailing] as [NSView] { view.menu = moveMenu }
            grip.pressed = { [weak self] event in self?.onGripDown?(event) }
            grip.showMenu = { [weak self] in self?.showMoveMenu() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func showMoveMenu() {
        guard let grip, canInteract() else { return }
        moveMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: grip.bounds.minY), in: grip)
    }

    func menuWillOpen(_ menu: NSMenu) { willOpenMoveMenu?() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items { item.isEnabled = canMove(item.tag) }
    }

    /// Moving existing arranged views and hiding bodies both change the stack's constraints.
    static func updateLayout(in view: NSView, changes: () -> Void) {
        guard let window = view.window, let root = window.contentView else { changes(); return }
        root.layoutSubtreeIfNeeded()
        NSAnimationContext.runAnimationGroup { context in
            context.allowsImplicitAnimation = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            context.duration = context.allowsImplicitAnimation ? 0.15 : 0
            changes()
            root.layoutSubtreeIfNeeded()
        }
        window.recalculateKeyViewLoop()
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard grip != nil, canInteract() else { return nil }
        return moveMenu.items.filter { canMove($0.tag) }.map { item in
            NSAccessibilityCustomAction(name: item.title) { [weak self] in
                guard let self, self.canMove(item.tag) else { return false }
                self.willOpenMoveMenu?()
                return self.onMove?(item.tag) ?? false
            }
        }
    }

    @objc private func toggle() {
        if canInteract() { isCollapsed.toggle() }
        triangle.state = isCollapsed ? .off : .on
    }
    @objc private func move(_ sender: NSMenuItem) { _ = onMove?(sender.tag) }
}

private final class PaneGrip: NSView {
    var pressed: ((NSEvent) -> Void)?
    var showMenu: (() -> Void)?
    private let symbol = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))

    init(title: String) {
        super.init(frame: .zero)
        toolTip = "Drag to reorder. Click for Move Up and Move Down."
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Reorder " + title)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: 20, height: 22) }
    override func draw(_ dirtyRect: NSRect) {
        symbol?.draw(in: NSRect(x: bounds.midX - 7, y: bounds.midY - 6, width: 14, height: 12))
    }

    override func mouseDown(with event: NSEvent) { pressed?(event) }
    override func accessibilityPerformPress() -> Bool { showMenu?(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
