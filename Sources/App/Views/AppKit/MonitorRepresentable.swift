import AppKit
import CueCore
import SwiftUI

/// Hosts the existing `MonitorView` unchanged. Values arrive as plain properties so
/// SwiftUI re-runs `updateNSView` whenever one of them changes.
struct MonitorRepresentable: NSViewRepresentable {
    let model: EditorModel
    let track: AudioTrack?
    let trackID: UUID?
    let frame: Int
    let label: CueLabel
    let appearance: CueAppearance
    /// The selected job's markers (detection plus edits); set after `track`, which clears them.
    let markers: MusicMarkers?
    let editingEnabled: Bool
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(frame: .zero)
        context.coordinator.wire(view)
        model.monitorView = view
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        let coordinator = context.coordinator
        // Assigning `track` resets scrub state and rebuilds the overview path, so only do it per load.
        if coordinator.appliedTrackID != trackID {
            coordinator.appliedTrackID = trackID
            view.track = track
        }
        if view.markers != markers { view.markers = markers }
        view.cueAppearance = appearance
        view.label = label
        view.frameNumber = frame
        view.editingEnabled = editingEnabled
        if view.placeholder != placeholder { view.placeholder = placeholder }
    }

    @MainActor
    final class Coordinator {
        let model: EditorModel
        var appliedTrackID: UUID?

        init(model: EditorModel) { self.model = model }

        func wire(_ view: MonitorView) {
            view.onOpen = { [weak model] url in model?.load(url: url) }
            view.onChoose = { [weak model] in model?.chooseAudio() }
            view.onSeek = { [weak model] frame in model?.seek(frame: frame) }
            view.onScrubChanged = { [weak model] began in model?.scrubChanged(began: began) }
            view.onPlace = { [weak model] point in model?.placeLabel(at: point) }
            // Each drag step is stored as the job's marker edit (saved once the drag settles);
            // the model keeps fade start at or before music end and the view shows its value.
            view.onMarkerChanged = { [weak model] kind, seconds in
                model?.setMarker(kind, to: seconds, deferringSave: true)
            }
        }
    }
}
