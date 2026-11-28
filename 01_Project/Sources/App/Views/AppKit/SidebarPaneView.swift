import AppKit
import CueCore

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

/// The field commits on Return, Tab or loss of focus. The stepper sends every repeat.
final class PaneOffsetControl: NSStackView, NSTextFieldDelegate {
    private let pane: PicturePane
    private let field = NSTextField()
    private var stepper = NSStepper()
    private var fieldWasEdited = false
    private let formatter = OffsetFormatter()
    var onEdit: ((_ value: Int, _ deferringSave: Bool) -> Void)?

    init(pane: PicturePane) {
        self.pane = pane
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 4
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        field.alignment = .right
        field.delegate = self
        field.formatter = formatter
        field.objectValue = NSNumber(value: 0)
        field.cell?.sendsActionOnEndEditing = true
        field.action = #selector(commitField)
        addControl(field)
        installStepper()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func addControl(_ control: NSControl) {
        control.target = self
        control.controlSize = .small
        control.toolTip = "Moves only this element. Positive is up."
        control.setAccessibilityLabel(pane.displayName + " vertical offset")
        addArrangedSubview(control)
    }

    private func installStepper() {
        stepper.valueWraps = false
        stepper.increment = 1
        stepper.autorepeat = true
        stepper.isContinuous = true
        stepper.action = #selector(step(_:))
        addControl(stepper)
    }

    /// Retire the native sender synchronously. A held stepper can keep dispatching repeat
    /// actions across a selection change or even a rapid export lock and unlock.
    func invalidateEditing() {
        stepper.action = nil
        stepper.isEnabled = false
        fieldWasEdited = false
        field.abortEditing()
        field.isEnabled = false
    }

    func controlTextDidBeginEditing(_ notification: Notification) { fieldWasEdited = false }
    func controlTextDidChange(_ notification: Notification) { fieldWasEdited = true }

    func display(_ value: Int, limits: ClosedRange<Int>, editable: Bool) {
        if editable, stepper.action == nil {
            stepper.removeFromSuperview()
            stepper = NSStepper()
            installStepper()
            window?.recalculateKeyViewLoop()
        }
        if !editable, field.currentEditor() != nil {
            field.isEnabled = false
            fieldWasEdited = false
            field.abortEditing()
        }
        if formatter.valueInUse != value {
            formatter.valueInUse = value
            showFieldValue()
        }
        if stepper.minValue != Double(limits.lowerBound) { stepper.minValue = Double(limits.lowerBound) }
        if stepper.maxValue != Double(limits.upperBound) { stepper.maxValue = Double(limits.upperBound) }
        if stepper.integerValue != value { stepper.integerValue = value }
        field.isEnabled = editable
        stepper.isEnabled = editable
        let sign = value < 0 ? "minus " : (value > 0 ? "plus " : "")
        let units = value.magnitude == 1 ? "pixel" : "pixels"
        let spoken = "\(sign)\(value.magnitude) \(units)"
        field.setAccessibilityValueDescription(spoken)
        stepper.setAccessibilityValueDescription(spoken)
    }

    @objc private func commitField() {
        guard field.isEnabled, stepper.action != nil else { return }
        if let value = (field.objectValue as? NSNumber)?.intValue,
           fieldWasEdited || value != formatter.valueInUse {
            onEdit?(value, false)
        }
        showFieldValue()
    }

    @objc private func step(_ sender: NSStepper) {
        guard sender === stepper, sender.isEnabled else { return }
        onEdit?(stepper.integerValue, true)
        if stepper.integerValue != formatter.valueInUse { stepper.integerValue = formatter.valueInUse }
        showFieldValue()
    }

    /// Also canonicalise a rejected or clamped entry when the appearance didn't change.
    private func showFieldValue() {
        fieldWasEdited = false
        field.objectValue = NSNumber(value: formatter.valueInUse)
        if let editor = field.currentEditor() { editor.string = OffsetText.format(formatter.valueInUse) }
    }
}
