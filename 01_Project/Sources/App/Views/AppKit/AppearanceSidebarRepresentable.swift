import AppKit
import CueCore
import SwiftUI

/// Hosts the appearance panes and keeps the title field bound to the selected job.
struct AppearanceSidebarRepresentable: NSViewRepresentable {
    let model: EditorModel
    let appearance: CueAppearance
    let clockFrames: Int?
    let labelText: String
    let jobID: UUID?
    /// Editing title text needs a loaded track.
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
        coordinator.jobID = jobID
        let sidebar = CueAppearanceSidebar(settings: appearance, clockFrames: clockFrames, labelField: field,
                                            reorderTarget: { [weak model, weak coordinator] in
            guard let model, let coordinator, model.selectedJobID == coordinator.jobID else { return nil }
            return (model.selectedJobID, model.appearance, model.canEdit)
        }, reportLocked: { [weak model] in model?.reportLockedSettings() }) { [weak model, weak coordinator] appearance in
            guard let model else { return }
            if let coordinator, coordinator.jobID == model.selectedJobID { model.updateAppearance(appearance) }
            coordinator?.sidebar?.sync(to: model.appearance, clockFrames: model.inspectorClockFrames)
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
        coordinator.sidebar?.sync(to: appearance, clockFrames: clockFrames)
        if coordinator.jobID != jobID {
            coordinator.labelField.abortEditing()
            coordinator.jobID = jobID
        }
        if coordinator.labelField.currentEditor() == nil, coordinator.labelField.stringValue != labelText {
            coordinator.labelField.stringValue = labelText
        }
        coordinator.labelField.isEnabled = labelEditable && isInteractive
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
        var jobID: UUID?
        weak var sidebar: CueAppearanceSidebar?

        init(model: EditorModel) { self.model = model }

        func controlTextDidChange(_ obj: Notification) {
            guard jobID == model.selectedJobID else { return }
            model.setLabelText(labelField.stringValue)
        }
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
