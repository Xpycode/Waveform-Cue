import AppKit
import CueCore
import SwiftUI

/// Hosts the existing `MonitorView` unchanged. Values arrive as plain properties so
/// SwiftUI re-runs `updateNSView` whenever one of them changes.
struct MonitorRepresentable: NSViewRepresentable {
    let model: EditorModel
    let track: AudioTrack?
    let trackID: UUID?
    /// A position of the selected job's 25 fps preview timeline (`EditorModel.previewTimeline`):
    /// the slate first with a pre-roll, then the trimmed music. Untrimmed, a track frame.
    let frame: Int
    let label: CueLabel
    let appearance: CueAppearance
    /// The selected job's markers (detection plus edits); set after `track`, which clears them.
    let markers: MusicMarkers?
    /// The selected job's trim, fades and pre-roll; set after `track`, which clears them.
    let trim: TrimSettings
    /// The selected job's loudness for the pre-roll slate; set after `track`, which clears it.
    let loudness: LoudnessMeasurement?
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
        if view.trim != trim { view.trim = trim }
        if view.loudness != loudness { view.loudness = loudness }
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
            // A timeline position; the monitor only scrubs inside the trimmed music.
            view.onSeek = { [weak model] position in model?.seek(frame: position) }
            view.onScrubChanged = { [weak model] began in model?.scrubChanged(began: began) }
            view.onPlace = { [weak model] point in model?.placeLabel(at: point) }
            // Each drag step is stored as the job's marker edit (saved once the drag settles);
            // the model keeps fade start at or before music end and the view shows its value.
            view.onMarkerChanged = { [weak model] kind, seconds in
                model?.setMarker(kind, to: seconds, deferringSave: true)
            }
            // Each in or out handle step is stored as the job's trim (saved once the drag settles).
            view.onTrimChanged = { [weak model] trim in
                model?.setTrim(trim, deferringSave: true)
            }
        }
    }
}
