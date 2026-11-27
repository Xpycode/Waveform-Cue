import AppShellKit
import CueCore
import SwiftUI

/// The batch queue: a heading, the AppKit job list (drop target for files and folders) and a
/// destination footer (Beside source, or one folder for the whole queue). Rows and their controls are AppKit (`QueueTableRepresentable`).
struct QueueSidebar: View {
    let model: EditorModel

    var body: some View {
        let queue = model.queue
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Queue")
                    .font(AppTypography.paneTitle)
                    .foregroundStyle(Theme.primaryText)
                Spacer(minLength: 0)
                Text(countLine(queue.jobs))
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, AppMetrics.sectionSpacing)
            .padding(.vertical, AppMetrics.standardSpacing)
            Divider()
            QueueTableRepresentable(model: model,
                                    jobs: queue.jobs,
                                    selectedID: queue.selectedJobID)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 6) {
                Text("Destination:")
                    .font(AppTypography.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize()
                DestinationPopUpRepresentable(model: model, folder: queue.destinationOverride, isEnabled: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, AppMetrics.sectionSpacing)
            .padding(.vertical, AppMetrics.standardSpacing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.secondaryBackground)
    }

    private func countLine(_ jobs: [CueJob]) -> String {
        guard !jobs.isEmpty else { return model.pendingAdds > 0 ? "Adding…" : "" }
        let done = jobs.filter { if case .done = $0.status { return true }; return false }.count
        var line = "\(done) of \(jobs.count) done"
        if model.pendingAdds > 0 { line += " · adding \(model.pendingAdds)" }
        return line
    }
}
