import AppKit
import CueCore
import SwiftUI

/// Hosts build 10's `CueAppearanceSidebar` in the inspector, together with the overlay
/// text field and position pop-up it lays out.
struct AppearanceSidebarRepresentable: NSViewRepresentable {
    let model: EditorModel
    let labelText: String
    let positionIndex: Int
    /// Overlay text and position need a loaded track.
    let labelEditable: Bool
    /// False while exporting: the sidebar is dimmed and ignores clicks.
    let isInteractive: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> InspectorContainerView {
        let coordinator = context.coordinator
        let field = coordinator.labelField
        field.placeholderString = "Optional text to display"
        field.delegate = coordinator
        field.setAccessibilityLabel("Overlay text")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let position = coordinator.position
        position.addItems(withTitles: EditorModel.anchors + ["Custom"])
        position.lastItem?.toolTip = "Drag the text in the monitor to set a custom position."
        position.autoenablesItems = false
        position.target = coordinator
        position.action = #selector(Coordinator.placeFromMenu)
        position.setAccessibilityLabel("Text position")

        let sidebar = CueAppearanceSidebar(settings: model.appearance, labelField: field,
                                           position: position) { [weak model] appearance in
            model?.updateAppearance(appearance)
        }
        let container = InspectorContainerView()
        container.addSubview(sidebar)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sidebar.topAnchor.constraint(equalTo: container.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        coordinator.sidebar = sidebar
        model.inspectorView = container
        model.appearanceSidebar = sidebar
        return container
    }

    func updateNSView(_ container: InspectorContainerView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.labelField.currentEditor() == nil, coordinator.labelField.stringValue != labelText {
            coordinator.labelField.stringValue = labelText
        }
        if coordinator.position.indexOfSelectedItem != positionIndex {
            coordinator.position.selectItem(at: positionIndex)
        }
        coordinator.labelField.isEnabled = labelEditable
        coordinator.position.isEnabled = labelEditable
        container.isInteractive = isInteractive
    }

    static func dismantleNSView(_ container: InspectorContainerView, coordinator: Coordinator) {
        coordinator.sidebar?.closeColorPicker()
        if let window = container.window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: container) {
            window.makeFirstResponder(coordinator.model.monitorView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: EditorModel
        let labelField = NSTextField()
        let position = NSPopUpButton()
        weak var sidebar: CueAppearanceSidebar?

        init(model: EditorModel) { self.model = model }

        func controlTextDidChange(_ obj: Notification) { model.setLabelText(labelField.stringValue) }

        @objc func placeFromMenu() { model.selectPosition(position.indexOfSelectedItem) }
    }
}

/// Wraps the sidebar so it can be dimmed and made click-through while exporting.
final class InspectorContainerView: NSView {
    var isInteractive = true {
        didSet {
            guard oldValue != isInteractive else { return }
            alphaValue = isInteractive ? 1 : 0.5
            if !isInteractive, let responder = window?.firstResponder as? NSView,
               responder.isDescendant(of: self) {
                window?.makeFirstResponder(nil)
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractive ? super.hitTest(point) : nil
    }
}
