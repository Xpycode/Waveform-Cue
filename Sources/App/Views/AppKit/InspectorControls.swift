import AppKit
import SwiftUI

// Small AppKit control wrappers for the inspector's SwiftUI layout (the UI rule forbids SwiftUI
// controls outside the toolbar). Each takes plain values and reports changes through closures;
// each follows SwiftUI's `.disabled(_:)` through `context.environment.isEnabled`.

/// Controls the editor's key monitor leaves alone: Space toggles a focused checkbox or opens a
/// focused pop-up instead of starting playback. (Text fields are covered by their field editor.)
protocol InspectorKeyControl: AnyObject {}

final class InspectorPopUpButton: NSPopUpButton, InspectorKeyControl {}
final class InspectorCheckbox: NSButton, InspectorKeyControl {}
final class InspectorPushButton: NSButton, InspectorKeyControl {}
final class InspectorSegmentedControl: NSSegmentedControl, InspectorKeyControl {}

// MARK: - Pop-up

/// A pop-up menu of fixed titles. `selection` is the selected index.
struct AppKitPopUp: NSViewRepresentable {
    let items: [String]
    let selection: Int
    var accessibilityLabel: String = ""
    var toolTip: String?
    let onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> InspectorPopUpButton {
        let popUp = InspectorPopUpButton(frame: .zero, pullsDown: false)
        popUp.target = context.coordinator
        popUp.action = #selector(Coordinator.chosen(_:))
        popUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        (popUp.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        return popUp
    }

    func updateNSView(_ popUp: InspectorPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        if popUp.itemTitles != items {
            popUp.removeAllItems()
            popUp.addItems(withTitles: items)
        }
        if popUp.indexOfSelectedItem != selection, items.indices.contains(selection) {
            popUp.selectItem(at: selection)
        }
        popUp.isEnabled = context.environment.isEnabled
        popUp.toolTip = toolTip
        popUp.setAccessibilityLabel(accessibilityLabel)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onSelect: (Int) -> Void
        init(onSelect: @escaping (Int) -> Void) { self.onSelect = onSelect }
        @objc func chosen(_ sender: NSPopUpButton) { onSelect(sender.indexOfSelectedItem) }
    }
}

// MARK: - Text field

/// A single-line text field. `onChange` runs on every keystroke, `onCommit` when editing ends
/// (Return, Tab or a click elsewhere). While the operator types, `text` from the model does not
/// overwrite the field; after editing ends the field shows `text` again, so a value the model
/// refused reverts.
struct AppKitTextField: NSViewRepresentable {
    let text: String
    var placeholder: String = ""
    var accessibilityLabel: String = ""
    var toolTip: String?
    var monospaced = false
    var onChange: ((String) -> Void)?
    var onCommit: ((String) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if monospaced { field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.onChange = onChange
        coordinator.onCommit = onCommit
        coordinator.text = text
        // A focused field the user has not typed in yet still follows the model: tabbing out of
        // Music end can move Fade start while focus lands in it.
        if field.currentEditor() == nil || !coordinator.isDirty, field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
        field.toolTip = toolTip
        field.setAccessibilityLabel(accessibilityLabel)
        let enabled = context.environment.isEnabled
        if field.isEnabled != enabled {
            if !enabled, field.currentEditor() != nil { field.window?.makeFirstResponder(nil) }
            field.isEnabled = enabled
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var field: NSTextField?
        var text = ""
        var onChange: ((String) -> Void)?
        var onCommit: ((String) -> Void)?
        /// True once the user has typed since focus arrived.
        var isDirty = false

        func controlTextDidBeginEditing(_ obj: Notification) { isDirty = false }

        func controlTextDidChange(_ obj: Notification) {
            guard let field else { return }
            isDirty = true
            onChange?(field.stringValue)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field else { return }
            isDirty = false
            onCommit?(field.stringValue)
            // Show the model's value; when it changed, SwiftUI's next update brings the new one.
            if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
        }
    }
}

// MARK: - Checkbox

struct AppKitCheckbox: NSViewRepresentable {
    let title: String
    let isOn: Bool
    var toolTip: String?
    var isSectionHeader = false
    var isOverridden = false
    var onReset: (() -> Void)?
    let onToggle: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToggle: onToggle) }

    func makeNSView(context: Context) -> InspectorCheckbox {
        let box = InspectorCheckbox(checkboxWithTitle: title, target: context.coordinator,
                                    action: #selector(Coordinator.toggled(_:)))
        box.setContentHuggingPriority(.required, for: .horizontal)
        return box
    }

    func updateNSView(_ box: InspectorCheckbox, context: Context) {
        context.coordinator.onToggle = onToggle
        let displayedTitle = isOverridden ? "• " + title : title
        if box.title != displayedTitle { box.title = displayedTitle }
        box.setAccessibilityLabel(title)
        if isSectionHeader { box.font = .systemFont(ofSize: 13, weight: .semibold) }
        context.coordinator.onReset = onReset
        if onReset != nil {
            if box.menu == nil {
                let menu = NSMenu()
                menu.autoenablesItems = false
                let item = menu.addItem(withTitle: "Reset", action: #selector(Coordinator.reset), keyEquivalent: "")
                item.target = context.coordinator
                box.menu = menu
            }
            box.menu?.items.first?.isEnabled = isOverridden && context.environment.isEnabled
        } else {
            box.menu = nil
        }
        let state: NSControl.StateValue = isOn ? .on : .off
        if box.state != state { box.state = state }
        box.isEnabled = context.environment.isEnabled
        box.toolTip = toolTip
    }

    @MainActor
    final class Coordinator: NSObject {
        var onReset: (() -> Void)?
        @objc func reset() { onReset?() }
        var onToggle: (Bool) -> Void
        init(onToggle: @escaping (Bool) -> Void) { self.onToggle = onToggle }
        @objc func toggled(_ sender: NSButton) { onToggle(sender.state == .on) }
    }
}

// MARK: - Push button

/// A rounded push button that follows `.disabled(_:)` (unlike `AppKitButton`).
struct AppKitPushButton: NSViewRepresentable {
    let title: String
    var toolTip: String?
    var controlSize: NSControl.ControlSize = .regular
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeNSView(context: Context) -> InspectorPushButton {
        let button = InspectorPushButton(title: title, target: context.coordinator,
                                         action: #selector(Coordinator.invoke))
        button.bezelStyle = .rounded
        button.controlSize = controlSize
        if controlSize == .small { button.font = .systemFont(ofSize: NSFont.smallSystemFontSize) }
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ button: InspectorPushButton, context: Context) {
        context.coordinator.action = action
        if button.title != title { button.title = title }
        button.isEnabled = context.environment.isEnabled
        button.toolTip = toolTip
    }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func invoke() { action() }
    }
}

// MARK: - Segmented control

/// A select-one segmented control (the inspector's Job | Appearance switch).
struct AppKitSegmented: NSViewRepresentable {
    let labels: [String]
    let selection: Int
    var accessibilityLabel: String = ""
    let onSelect: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> InspectorSegmentedControl {
        let control = InspectorSegmentedControl(labels: labels, trackingMode: .selectOne,
                                                target: context.coordinator,
                                                action: #selector(Coordinator.chosen(_:)))
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: InspectorSegmentedControl, context: Context) {
        context.coordinator.onSelect = onSelect
        if control.selectedSegment != selection { control.selectedSegment = selection }
        control.setAccessibilityLabel(accessibilityLabel)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onSelect: (Int) -> Void
        init(onSelect: @escaping (Int) -> Void) { self.onSelect = onSelect }
        @objc func chosen(_ sender: NSSegmentedControl) { onSelect(sender.selectedSegment) }
    }
}
