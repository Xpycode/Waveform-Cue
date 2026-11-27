import AppShellKit
import SwiftUI

/// Placeholder for the batch queue (task 2.3, after gate U1).
struct QueueSidebar: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppMetrics.standardSpacing) {
            Text("Queue")
                .font(AppTypography.paneTitle)
                .foregroundStyle(Theme.primaryText)
            Text("Drop tracks here in a later build.")
                .font(AppTypography.caption)
                .foregroundStyle(Theme.secondaryText)
            Spacer(minLength: 0)
        }
        .padding(AppMetrics.sectionSpacing)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.secondaryBackground)
    }
}
