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
            Button("Add Audio…") { model.chooseAudio() }
                .keyboardShortcut("o")
            Divider()
            Button("Export Selected") { model.exportSelected() }
                .keyboardShortcut("e")
                .disabled(!model.canExportSelected)
            Button("Export Selected to Folder…") { model.exportSelectedToFolder() }
                .disabled(!model.canExportSelectedToFolder)
            Divider()
            Button("Start Queue") { model.startQueue() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canStartQueue)
            Button("Stop Queue") { model.stopQueue() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!model.isExporting || model.queue.isStopping)
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

    /// Finder or Dock opens (files or folders). They join the queue, even before the window exists.
    func application(_ sender: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        model.open(fromFinder: urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.terminateReply { quit in sender.reply(toApplicationShouldTerminate: quit) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}
