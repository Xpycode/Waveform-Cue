import AppShellKit
import CueCore
import SwiftUI

/// The AppKit monitor with the transport row (Play/Pause and the seek slider) under it.
struct MonitorPane: View {
    let model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            MonitorRepresentable(model: model,
                                 track: model.track,
                                 trackID: model.trackID,
                                 frame: model.frame,
                                 label: model.label,
                                 appearance: model.appearance,
                                 editingEnabled: model.canEdit,
                                 placeholder: model.placeholder)
            TransportRepresentable(model: model,
                                   frame: model.frame,
                                   frames: model.track?.frames ?? 0,
                                   isPlaying: model.isPlaying,
                                   isEnabled: model.isReady)
                .frame(height: 30)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .background(Theme.primaryBackground)
    }
}
