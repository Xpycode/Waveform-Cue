import AppKit

/// A persistent arranged view. Its controls and field editor stay attached when the
/// containing stack moves the pane with insertArrangedSubview(_:at:).
final class SidebarPaneView: NSStackView, NSMenuDelegate {
    let body: NSView
    private let triangle = NSButton()
    private let grip: PaneGrip?
    private let moveMenu = NSMenu()
    var onGripDown: ((NSEvent) -> Void)?
    var onMove: ((Int) -> Void)?
    var canMove: (Int) -> Bool = { _ in false }
    var willCollapse: (() -> Void)?

    var isCollapsed = false {
        didSet {
            guard oldValue != isCollapsed else { return }
            if isCollapsed { willCollapse?() }
            body.isHidden = isCollapsed
            triangle.state = isCollapsed ? .off : .on
            triangle.setAccessibilityExpanded(!isCollapsed)
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.recalculateKeyViewLoop()
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
        guard let grip else { return }
        moveMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: grip.bounds.minY), in: grip)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items { item.isEnabled = canMove(item.tag) }
    }

    @objc private func toggle() { isCollapsed.toggle() }
    @objc private func move(_ sender: NSMenuItem) { onMove?(sender.tag) }
}

private final class PaneGrip: NSView {
    var pressed: ((NSEvent) -> Void)?
    var showMenu: (() -> Void)?
    private let symbol = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)

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
