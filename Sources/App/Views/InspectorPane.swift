import SwiftUI

/// The inspector. For now it hosts build 10's Appearance sidebar unchanged.
struct InspectorPane: View {
    let model: EditorModel

    var body: some View {
        AppearanceSidebarRepresentable(model: model,
                                       labelText: model.label.text,
                                       positionIndex: model.positionIndex,
                                       labelEditable: model.isReady,
                                       isInteractive: model.canEdit)
            .frame(width: CueAppearanceSidebar.sidebarWidth)
            .frame(maxHeight: .infinity)
    }
}
