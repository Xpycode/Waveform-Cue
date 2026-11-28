import AppKit
import SwiftUI

/// Build 10's transport row: an AppKit Play/Pause button and seek slider.
struct TransportRepresentable: NSViewRepresentable {
    let model: EditorModel
    let frame: Int
    let frames: Int
    let isPlaying: Bool
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSStackView {
        let coordinator = context.coordinator
        let play = coordinator.play
        play.title = "Play"
        play.bezelStyle = .rounded
        play.target = coordinator
        play.action = #selector(Coordinator.togglePlayback)
        play.toolTip = "Play or pause (Space)."
        play.widthAnchor.constraint(equalToConstant: 87).isActive = true
        let seekBar = coordinator.seekBar
        seekBar.minValue = 0
        seekBar.maxValue = 1
        seekBar.target = coordinator
        seekBar.action = #selector(Coordinator.slide)
        seekBar.isContinuous = true
        seekBar.setAccessibilityLabel("Playback position")
        seekBar.toolTip = "Scrub to a frame. Use Left Arrow and Right Arrow to step one frame."
        seekBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [play, seekBar])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    func updateNSView(_ row: NSStackView, context: Context) {
        let coordinator = context.coordinator
        let title = isPlaying ? "Pause" : "Play"
        if coordinator.play.title != title { coordinator.play.title = title }
        coordinator.play.isEnabled = isEnabled
        let maxValue = Double(max(1, frames))
        if coordinator.seekBar.maxValue != maxValue { coordinator.seekBar.maxValue = maxValue }
        if coordinator.seekBar.doubleValue != Double(frame) { coordinator.seekBar.doubleValue = Double(frame) }
        coordinator.seekBar.isEnabled = isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        let model: EditorModel
        let play = NSButton()
        let seekBar = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)

        init(model: EditorModel) { self.model = model }

        @objc func togglePlayback() { model.togglePlayback() }
        @objc func slide() { model.seek(frame: Int(seekBar.doubleValue.rounded())) }
    }
}
