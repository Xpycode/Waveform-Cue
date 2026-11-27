import AppKit
import AVFoundation
import CueCore
import Observation
import UniformTypeIdentifiers

/// The single-track editor: loading, playback, label placement and MXF export.
/// Carries everything build 10's `AppController` did, minus the window chrome,
/// which now lives in SwiftUI (`MainWindow`) and the AppKit wrappers.
@MainActor
@Observable
final class EditorModel: NSObject, @preconcurrency AVAudioPlayerDelegate {
    static let anchors = ["Top left", "Top center", "Top right", "Middle left", "Center",
                          "Middle right", "Bottom left", "Bottom center", "Bottom right"]
    /// Index of the "Custom" item that follows the nine anchors in the position pop-up.
    static let customPositionIndex = anchors.count
    static let formatReadout = "1080p25   ·   MXF"
    static let formatDetail = "MXF OP1a · 1920 × 1080p25 · MPEG-2 4:2:2, 50 Mb/s · Rec. 709 · Stereo PCM, 48 kHz, 24-bit · Start TC 00:00:00:00"
    static let exportHelp = "Save a new MXF beside the audio file. Use File → Export MXF to Folder to choose another location."

    // MARK: Observed state

    private(set) var track: AudioTrack?
    /// Changes with every successful load, so views can tell a new track from a re-render.
    private(set) var trackID: UUID?
    var label = CueLabel()
    private(set) var appearance = CueAppearance.load()
    private(set) var frame = 0
    private(set) var isPlaying = false
    private(set) var isExporting = false { didSet { updateWindowClosable() } }
    private(set) var isCancellingExport = false
    private(set) var positionIndex = 0
    private(set) var placeholder = "Drop an audio file"
    private(set) var status = "Drop a track into the monitor to begin."
    private(set) var statusHelp: String?
    private(set) var lastExport: URL?

    var canEdit: Bool { !isExporting }
    var isReady: Bool { canEdit && track != nil }

    // MARK: Unobserved plumbing

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?
    @ObservationIgnored private(set) weak var window: NSWindow?
    /// Registered by the AppKit wrappers so the key monitor and export can manage focus.
    @ObservationIgnored weak var monitorView: NSView?
    @ObservationIgnored weak var inspectorView: NSView?
    @ObservationIgnored weak var appearanceSidebar: CueAppearanceSidebar?
    /// Opens the main window when a file arrives from Finder before any window exists.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    // MARK: Window and app lifecycle

    func attach(window: NSWindow) {
        guard self.window !== window else { return }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        self.window = window
        updateWindowClosable()
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appearanceSidebar?.closeColorPicker() }
        }
        installKeyMonitor()
    }

    /// While exporting, the window is not closable: the close button and File → Close are disabled.
    private func updateWindowClosable() {
        guard let window else { return }
        if isExporting { window.styleMask.remove(.closable) } else { window.styleMask.insert(.closable) }
    }

    func open(fromFinder url: URL) {
        load(url: url)
        guard window == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window == nil else { return }
            self.openMainWindow?()
        }
    }

    func shouldTerminate() -> Bool {
        guard isExporting else { return true }
        status = "Export in progress. Cancel the export before quitting."
        return false
    }

    func shutdown() {
        loadTask?.cancel()
        stopTimer()
        player?.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        try? FileManager.default.removeItem(at: PreparedAudio.sessionDirectory)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard let window, window.isKeyWindow, window.attachedSheet == nil else { return event }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if isExporting, modifiers == .command, event.charactersIgnoringModifiers == "w" {
            status = "Export in progress. Cancel the export before closing."
            NSSound.beep()
            return nil
        }
        guard !(window.firstResponder is NSTextView), modifiers.isEmpty,
              track != nil, !isExporting else { return event }
        if let responder = window.firstResponder as? NSView, let inspectorView,
           responder.isDescendant(of: inspectorView) { return event }
        switch event.keyCode {
        case 49: togglePlayback()
        case 123: step(-1)
        case 124: step(1)
        default: return event
        }
        return nil
    }

    // MARK: Loading

    func chooseAudio() {
        guard !isExporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        present(panel) { [weak self] url in self?.load(url: url) }
    }

    func load(url: URL) {
        guard !isExporting else { NSSound.beep(); return }
        loadTask?.cancel()
        stopTimer()
        player?.stop()
        player = nil
        track = nil
        trackID = nil
        frame = 0
        syncPlaying()
        placeholder = "Reading waveform…"
        status = "Reading " + url.lastPathComponent
        statusHelp = nil
        lastExport = nil
        let id = UUID()
        loadID = id
        loadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try AudioTrack.read(url) }
            do {
                let track = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                  onCancel: { worker.cancel() })
                guard let self, self.loadID == id, !Task.isCancelled else { return }
                let audio = try AVAudioPlayer(contentsOf: track.pcm.url)
                guard audio.prepareToPlay() else { throw CueError("Audio playback could not be prepared.") }
                audio.delegate = self
                self.player = audio
                self.track = track
                self.trackID = id
                self.label = CueLabel(text: url.deletingPathExtension().lastPathComponent)
                self.positionIndex = 0
                self.status = "Click the waveform to cue. Drag the text to position it."
            } catch {
                guard let self, self.loadID == id, !Task.isCancelled else { return }
                self.placeholder = "Drop another audio file"
                self.status = "Couldn’t open audio. " + error.localizedDescription
                self.label = CueLabel()
            }
            self?.syncPlaying()
        }
    }

    // MARK: Playback

    private func syncPlaying() { isPlaying = player?.isPlaying == true }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    func togglePlayback() {
        guard let player, let track else { return }
        if player.isPlaying { player.pause(); stopTimer() }
        else {
            if frame >= track.frames { seek(frame: 0) }
            if player.play() {
                stopTimer()
                let timer = Timer(timeInterval: 1.0/30, target: self, selector: #selector(tick),
                                  userInfo: nil, repeats: true)
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            } else { status = "Audio playback could not start." }
        }
        syncPlaying()
    }

    @objc private func tick() {
        guard let player, let track else { return }
        frame = min(track.frames, max(0, Int(player.currentTime * Double(AudioTrack.fps))))
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player, let track else { return }
        stopTimer()
        frame = track.frames
        if !flag { status = "Audio playback ended with a decoder error." }
        syncPlaying()
    }

    func seek(frame target: Int) {
        guard let track, let player else { return }
        let f = min(track.frames, max(0, target))
        if f == track.frames { player.pause(); stopTimer() }
        player.currentTime = min(player.duration, Double(f) / Double(AudioTrack.fps))
        frame = f
        syncPlaying()
    }

    func step(_ count: Int) {
        player?.pause()
        stopTimer()
        seek(frame: frame + count)
    }

    /// Pauses for the length of a monitor scrub and resumes afterwards if it was playing.
    func scrubChanged(began: Bool) {
        guard let track else { return }
        if began {
            resumeAfterScrub = player?.isPlaying == true
            player?.pause()
            stopTimer()
            syncPlaying()
        } else if resumeAfterScrub {
            resumeAfterScrub = false
            if frame < track.frames { togglePlayback() }
        }
    }

    // MARK: Label and appearance

    func setLabelText(_ text: String) { label.text = text }

    /// Title drag in the monitor.
    func placeLabel(at point: CGPoint) {
        label.position = point
        positionIndex = Self.customPositionIndex
    }

    /// Position pop-up: one of the nine anchors, or Custom.
    func selectPosition(_ index: Int) {
        positionIndex = index
        guard Self.anchors.indices.contains(index) else {
            status = "Drag the text in the monitor to position it."
            return
        }
        label.position = CGPoint(x: Double(index % 3)/2, y: 1 - Double(index / 3)/2)
    }

    func updateAppearance(_ appearance: CueAppearance) {
        self.appearance = appearance
        appearance.save()
    }

    // MARK: Export

    /// The toolbar's Export MXF / Cancel Export button.
    func exportOrCancel() {
        if let exportTask {
            exportTask.cancel()
            isCancellingExport = true
            status = "Cancelling export…"
        } else if let track {
            startExport(folder: track.url.deletingLastPathComponent())
        }
    }

    func chooseExportFolder() {
        guard track != nil, !isExporting else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        present(panel) { [weak self] folder in self?.startExport(folder: folder) }
    }

    private func startExport(folder: URL) {
        guard let track, exportTask == nil else { return }
        appearanceSidebar?.closeColorPicker()
        if let monitorView { window?.makeFirstResponder(monitorView) }
        player?.pause()
        stopTimer()
        syncPlaying()
        let stem = track.url.deletingPathExtension().lastPathComponent + " - Cue"
        var target = folder.appendingPathComponent(stem + ".mxf")
        var copy = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(stem + " " + String(copy) + ".mxf")
            copy += 1
        }
        let destination = target
        let encoder = PreparedAudio.encoder
        let label = self.label
        let cueAppearance = appearance
        lastExport = nil
        statusHelp = nil
        status = "Exporting MXF… 0%"
        isExporting = true
        exportTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try MXFExport.run(track: track, label: label, appearance: cueAppearance, encoder: encoder, destination: destination) { value in
                    Task { @MainActor [weak self] in
                        guard let self, self.exportTask?.isCancelled == false else { return }
                        self.status = "Exporting MXF… " + String(Int(value * 100)) + "%"
                    }
                }
            }
            do {
                try await withTaskCancellationHandler(operation: { try await worker.value },
                                                      onCancel: { worker.cancel() })
                self?.status = "Saved " + destination.lastPathComponent
                self?.lastExport = destination
            } catch is CancellationError {
                self?.status = "Export cancelled."
            } catch {
                self?.status = "Export failed. " + error.localizedDescription
                self?.statusHelp = error.localizedDescription
                let alert = NSAlert()
                alert.messageText = "Couldn’t export MXF"
                alert.informativeText = error.localizedDescription + "\n\nChoose File → Export MXF to Folder to use another destination."
                if let window = self?.window { alert.beginSheetModal(for: window, completionHandler: nil) }
                else { alert.runModal() }
            }
            self?.exportTask = nil
            self?.isCancellingExport = false
            self?.isExporting = false
        }
    }

    func revealExport() {
        if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) }
    }

    // MARK: Helpers

    private func present(_ panel: NSOpenPanel, then handler: @escaping (URL) -> Void) {
        if let window {
            panel.beginSheetModal(for: window) { response in
                if response == .OK, let url = panel.url { handler(url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            handler(url)
        }
    }
}
