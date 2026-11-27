import AppKit
import AppShellKit
import SwiftUI

@main
struct WaveformCueApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("WaveformCue.appearance") private var appearance: AppAppearancePreference = .dark

    var body: some Scene {
        // A single-window scene: one editor model, and Finder opens never spawn extra windows.
        Window("Waveform Cue", id: Self.mainWindowID) {
            MainWindow(model: appDelegate.model)
                .appAppearance(appearance)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 760)
        .commands {
            EditorCommands(model: appDelegate.model)
            AppAppearanceCommands(preference: $appearance)
        }
    }
}

/// File menu items. The standard Close and Edit menu come from SwiftUI.
private struct EditorCommands: Commands {
    let model: EditorModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = registerWindowOpener()
        CommandGroup(replacing: .newItem) {
            Button("Open Audio…") { model.chooseAudio() }
                .keyboardShortcut("o")
            Button("Export MXF to Folder…") { model.chooseExportFolder() }
                .keyboardShortcut("e")
        }
    }

    private func registerWindowOpener() {
        let openWindow = openWindow
        model.openMainWindow = { openWindow(id: WaveformCueApp.mainWindowID) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = EditorModel()

    /// Finder or Dock opens. The model loads immediately, even before the window exists.
    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        model.open(fromFinder: url)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.shouldTerminate() ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
