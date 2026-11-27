import AppKit
import AppShellKit
import SwiftUI

/// The inspector: a Job | Appearance switch (AppKit segmented control) over the selected job's
/// export settings (`JobInspector`) or build 10's Appearance sidebar. The chosen tab is remembered.
struct InspectorPane: View {
    enum Tab: Int, CaseIterable {
        case job, appearance
        var title: String { self == .job ? "Job" : "Appearance" }
    }

    let model: EditorModel

    @AppStorage("WaveformCue.inspectorTab") private var tabValue = Tab.job.rawValue

    private var tab: Tab { Tab(rawValue: tabValue) ?? .job }

    var body: some View {
        VStack(spacing: 0) {
            AppKitSegmented(labels: Tab.allCases.map(\.title), selection: tab.rawValue,
                            accessibilityLabel: "Inspector") { index in
                tabValue = (Tab(rawValue: index) ?? .job).rawValue
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) { separator }
            .overlay(alignment: .bottom) { Divider() }
            switch tab {
            case .job:
                JobInspector(model: model)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .leading) { separator }
            case .appearance:
                AppearanceSidebarRepresentable(model: model,
                                               labelText: model.label.text,
                                               positionIndex: model.positionIndex,
                                               labelEditable: model.isReady,
                                               isInteractive: model.canEdit)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(width: CueAppearanceSidebar.sidebarWidth)
        .frame(maxHeight: .infinity)
    }

    /// The 1 pt left border the Appearance sidebar draws for itself.
    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
    }
}
