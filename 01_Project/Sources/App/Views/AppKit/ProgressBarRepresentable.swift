import AppKit
import SwiftUI

/// A determinate AppKit progress bar (0…1) for the bottom bar.
struct ProgressBarRepresentable: NSViewRepresentable {
    let value: Double

    func makeNSView(context: Context) -> NSProgressIndicator {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.controlSize = .small
        bar.setAccessibilityLabel("Queue progress")
        return bar
    }

    func updateNSView(_ bar: NSProgressIndicator, context: Context) {
        if bar.doubleValue != value { bar.doubleValue = value }
    }
}
