import AppKit
import AppShellKit
import SwiftUI

/// The inspector: a Job | Appearance switch (AppKit segmented control) over the selected job's
/// export settings (`JobInspector`) or build 10's Appearance sidebar, and an Apply to All footer
/// shown under both tabs. The chosen tab is remembered.
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
                                               appearance: model.appearance,
                                               clockFrames: model.inspectorClockFrames,
                                               labelText: model.label.text,
                                               positionIndex: model.positionIndex,
                                               labelEditable: model.isReady,
                                               isInteractive: model.canEdit)
                    .frame(maxHeight: .infinity)
            }
            applyToAllFooter
        }
        .frame(width: CueAppearanceSidebar.sidebarWidth)
        .frame(maxHeight: .infinity)
    }

    /// Apply to All, pinned under both tabs: it copies settings from both of them.
    @ViewBuilder
    private var applyToAllFooter: some View {
        let count = model.applyToAllCount
        VStack(alignment: .leading, spacing: 6) {
            AppKitPushButton(title: "Apply to All",
                             toolTip: "Copy this job’s look, title position and export settings to every other job that is not Done or exporting.") {
                model.applyToAll()
            }
            .disabled(count == 0 || !model.canEdit)
            Text(count == 0
                 ? "No other jobs to copy to. Done and exporting jobs are never changed."
                 : "Copies look, title position and export settings to \(count) other job\(count == 1 ? "" : "s"). Done and exporting jobs are left alone; title text, trim and markers stay per track.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .leading) { separator }
    }

    /// The 1 pt left border the Appearance sidebar draws for itself.
    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
    }
}
