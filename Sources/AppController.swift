import AppKit
import CueCore
import AVFoundation
import UniformTypeIdentifiers

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate, NSToolbarDelegate, NSTextFieldDelegate, @preconcurrency AVAudioPlayerDelegate {
    private var window: NSWindow!
    private let monitor = MonitorView(frame: .zero)
    private let play = NSButton()
    private let seekBar = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let labelField = NSTextField()
    private let position = NSPopUpButton()
    private let appearanceButton = NSButton()
    private var monitorTrailing: NSLayoutConstraint!
    private lazy var appearanceSidebar = CueAppearanceSidebar(settings: monitor.cueAppearance,
                                                              labelField: labelField, position: position) { [weak self] appearance in
        self?.monitor.cueAppearance = appearance
        appearance.save()
    }
    private let export = NSButton()
    private let open = NSButton()
    private let status = NSTextField(labelWithString: "")
    private static let formatID = NSToolbarItem.Identifier("CueFormat")
    private static let openID = NSToolbarItem.Identifier("OpenAudio")
    private static let appearanceID = NSToolbarItem.Identifier("Appearance")
    private let format = NSTextField(labelWithString: "1080p25   ·   MXF")
    private var resumeAfterScrub = false
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var loadID = UUID()
    private var keyMonitor: Any?
    private var pendingFile: URL?
    private var lastExport: URL?
    private let reveal = NSButton()
    private let anchors = ["Top left", "Top center", "Top right", "Middle left", "Center",
                           "Middle right", "Bottom left", "Bottom center", "Bottom right"]
    private var source: AudioTrack? { monitor.track }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        makeMenu()
        makeWindow()
        updateControls()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window.isKeyWindow, self.window.attachedSheet == nil,
                  !(self.window.firstResponder is NSTextView),
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  self.source != nil, self.exportTask == nil else { return event }
            if let responder = self.window.firstResponder as? NSView,
               responder.isDescendant(of: self.appearanceSidebar) { return event }
            switch event.keyCode {
            case 49: self.togglePlayback()
            case 123: self.step(-1)
            case 124: self.step(1)
            default: return event
            }
            return nil
        }
        if let pendingFile { load(pendingFile); self.pendingFile = nil }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func application(_ sender: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if window == nil { pendingFile = url } else { load(url) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if exportTask != nil {
            status.stringValue = "Export in progress. Cancel the export before quitting."
            return .terminateCancel
        }
        return .terminateNow
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if exportTask != nil {
            status.stringValue = "Export in progress. Cancel the export before closing."
            return false
        }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        loadTask?.cancel()
        stopTimer()
        player?.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        try? FileManager.default.removeItem(at: PreparedAudio.sessionDirectory)
    }

    @objc private func toggleAppearance() {
        setAppearanceVisible(appearanceSidebar.isHidden)
    }

    private func setAppearanceVisible(_ visible: Bool) {
        if !visible {
            appearanceSidebar.closeColorPicker()
            window.makeFirstResponder(monitor)
        }
        appearanceSidebar.isHidden = !visible
        monitorTrailing.constant = visible ? -CueAppearanceSidebar.sidebarWidth : 0
        appearanceButton.state = visible ? .on : .off
    }

    func windowWillClose(_ notification: Notification) {
        appearanceSidebar.closeColorPicker()
    }

    private func makeMenu() {
        let bar = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            bar.addItem(item)
            let menu = NSMenu(title: title)
            item.submenu = menu
            return menu
        }
        let app = submenu("Waveform Cue")
        app.addItem(withTitle: "Quit Waveform Cue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = submenu("File")
        file.addItem(withTitle: "Open Audio…", action: #selector(choose), keyEquivalent: "o").target = self
        file.addItem(withTitle: "Export MXF to Folder…", action: #selector(chooseFolder), keyEquivalent: "e").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = submenu("Edit")
        for (name, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                    ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: name, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = bar
    }

    private func makeWindow() {
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 990, height: 745),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Waveform Cue"
        window.delegate = self
        window.contentMinSize = NSSize(width: 690, height: 530)
        window.center()
        let root = NSView()
        window.contentView = root
        func button(_ button: NSButton, _ title: String, _ action: Selector) {
            button.title = title
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        func row(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = spacing
            return stack
        }
        func spacer() -> NSView {
            let view = NSView()
            view.setContentHuggingPriority(.init(1), for: .horizontal)
            return view
        }
        button(open, "Open Audio…", #selector(choose))
        open.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        open.imagePosition = .imageLeading
        format.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        format.textColor = .secondaryLabelColor

        button(play, "Play", #selector(togglePlayback))
        play.widthAnchor.constraint(equalToConstant: 87).isActive = true
        seekBar.target = self
        seekBar.action = #selector(slide)
        seekBar.isContinuous = true
        seekBar.setAccessibilityLabel("Playback position")
        seekBar.toolTip = "Scrub to a frame. Use Left Arrow and Right Arrow to step one frame."
        play.toolTip = "Play or pause (Space)."
        format.toolTip = "MXF OP1a · 1920 × 1080p25 · MPEG-2 4:2:2, 50 Mb/s · Rec. 709 · Stereo PCM, 48 kHz, 24-bit · Start TC 00:00:00:00"
        let transport = row([play, seekBar])
        seekBar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        labelField.placeholderString = "Optional text to display"
        labelField.delegate = self
        labelField.setAccessibilityLabel("Overlay text")
        labelField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        position.addItems(withTitles: anchors + ["Custom"])
        position.lastItem?.toolTip = "Drag the text in the monitor to set a custom position."
        position.autoenablesItems = false
        position.target = self
        position.action = #selector(placeFromMenu)
        position.setAccessibilityLabel("Text position")
        button(appearanceButton, "Appearance", #selector(toggleAppearance))
        appearanceButton.setButtonType(.toggle)
        appearanceButton.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
        appearanceButton.imagePosition = .imageLeading
        appearanceButton.toolTip = "Show or hide appearance settings."
        let toolbar = NSToolbar(identifier: "WaveformCueToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbarStyle = .unified
        window.toolbar = toolbar

        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.stringValue = "Drop a track into the monitor to begin."
        button(export, "Export MXF", #selector(exportBesideSource))
        export.bezelColor = NSColor(cgColor: CuePicture.rgb(0.16, 0.38, 0.33))
        button(reveal, "Show in Finder", #selector(revealExport))
        reveal.isHidden = true
        let footer = row([status, spacer(), reveal, export])
        let separator = NSBox()
        separator.boxType = .separator
        let previewRow = NSView()
        for view in [monitor, appearanceSidebar] as [NSView] {
            previewRow.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            view.topAnchor.constraint(equalTo: previewRow.topAnchor).isActive = true
            view.bottomAnchor.constraint(equalTo: previewRow.bottomAnchor).isActive = true
        }
        monitorTrailing = monitor.trailingAnchor.constraint(equalTo: previewRow.trailingAnchor)
        NSLayoutConstraint.activate([
            monitor.leadingAnchor.constraint(equalTo: previewRow.leadingAnchor),
            monitorTrailing,
            appearanceSidebar.trailingAnchor.constraint(equalTo: previewRow.trailingAnchor)
        ])
        appearanceSidebar.isHidden = true
        for view in [previewRow, transport, separator, footer] as [NSView] {
            root.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            let margin: CGFloat = view === previewRow || view === separator ? 0 : 20
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin).isActive = true
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin).isActive = true
        }
        NSLayoutConstraint.activate([
            previewRow.topAnchor.constraint(equalTo: root.topAnchor),
            transport.topAnchor.constraint(equalTo: previewRow.bottomAnchor, constant: 10),
            transport.heightAnchor.constraint(equalToConstant: 30),
            separator.topAnchor.constraint(equalTo: transport.bottomAnchor, constant: 10),
            footer.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            footer.heightAnchor.constraint(equalToConstant: 29),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
        monitor.onOpen = { [weak self] in self?.load($0) }
        monitor.onChoose = { [weak self] in self?.choose() }
        monitor.onSeek = { [weak self] frame in self?.seek(frame: frame) }
        monitor.onScrubChanged = { [weak self] began in
            guard let self, let track = self.source else { return }
            if began {
                self.resumeAfterScrub = self.player?.isPlaying == true
                self.player?.pause()
                self.stopTimer()
            } else if self.resumeAfterScrub {
                self.resumeAfterScrub = false
                if self.monitor.frameNumber < track.frames { self.togglePlayback() }
            }
        }
        monitor.onPlace = { [weak self] point in
            self?.monitor.label.position = point
            self?.position.selectItem(withTitle: "Custom")
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.formatID, Self.openID, Self.appearanceID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case Self.formatID:
            item.label = "Export format"
            item.view = format
        case Self.openID:
            item.label = "Open Audio"
            item.view = open
        case Self.appearanceID:
            item.label = "Appearance"
            item.view = appearanceButton
        default: return nil
        }
        item.autovalidates = false
        return item
    }

    @objc private func choose() {
        guard exportTask == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url { self?.load(url) }
        }
    }
    private func load(_ url: URL) {
        guard exportTask == nil else { NSSound.beep(); return }
        loadTask?.cancel()
        stopTimer()
        player?.stop()
        player = nil
        monitor.track = nil
        monitor.frameNumber = 0
        seekBar.doubleValue = 0
        window.title = url.lastPathComponent
        monitor.placeholder = "Reading waveform…"
        status.stringValue = "Reading " + url.lastPathComponent
        lastExport = nil
        reveal.isHidden = true
        let id = UUID()
        loadID = id
        updateControls()
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
                self.monitor.track = track
                self.monitor.label = CueLabel(text: url.deletingPathExtension().lastPathComponent)
                self.labelField.stringValue = self.monitor.label.text
                self.position.selectItem(at: 0)
                self.seekBar.maxValue = Double(track.frames)
                self.status.stringValue = "Click the waveform to cue. Drag the text to position it."
            } catch {
                guard let self, self.loadID == id, !Task.isCancelled else { return }
                self.monitor.placeholder = "Drop another audio file"
                self.status.stringValue = "Couldn’t open audio. " + error.localizedDescription
                self.window.title = "Waveform Cue"
                self.labelField.stringValue = ""
            }
            self?.updateControls()
        }
    }

    private func updateControls() {
        let canEdit = exportTask == nil
        let ready = canEdit && source != nil
        appearanceButton.isEnabled = canEdit
        open.isEnabled = canEdit
        play.isEnabled = ready
        play.title = player?.isPlaying == true ? "Pause" : "Play"
        seekBar.isEnabled = ready
        labelField.isEnabled = ready
        position.isEnabled = ready
        monitor.editingEnabled = canEdit
        export.title = canEdit ? "Export MXF" : "Cancel Export"
        export.isEnabled = source != nil
        export.toolTip = "Save a new MXF beside the audio file. Use File → Export MXF to Folder to choose another location."
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    @objc private func togglePlayback() {
        guard let player, let track = source else { return }
        if player.isPlaying { player.pause(); stopTimer() }
        else {
            if monitor.frameNumber >= track.frames { seek(frame: 0) }
            if player.play() {
                stopTimer()
                let timer = Timer(timeInterval: 1.0/30, target: self, selector: #selector(tick),
                                  userInfo: nil, repeats: true)
                RunLoop.main.add(timer, forMode: .common)
                self.timer = timer
            } else { status.stringValue = "Audio playback could not start." }
        }
        updateControls()
    }
    @objc private func tick() {
        guard let player, let track = source else { return }
        let f = min(track.frames, max(0, Int(player.currentTime * Double(AudioTrack.fps))))
        monitor.frameNumber = f
        seekBar.doubleValue = Double(f)
    }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player, let track = source else { return }
        stopTimer()
        monitor.frameNumber = track.frames
        seekBar.doubleValue = Double(track.frames)
        if !flag { status.stringValue = "Audio playback ended with a decoder error." }
        updateControls()
    }
    private func seek(frame: Int) {
        guard let track = source, let player else { return }
        let f = min(track.frames, max(0, frame))
        if f == track.frames { player.pause(); stopTimer() }
        player.currentTime = min(player.duration, Double(f) / Double(AudioTrack.fps))
        monitor.frameNumber = f
        seekBar.doubleValue = Double(f)
        updateControls()
    }
    private func step(_ count: Int) {
        player?.pause()
        stopTimer()
        seek(frame: monitor.frameNumber + count)
    }
    @objc private func slide() { seek(frame: Int(seekBar.doubleValue.rounded())) }
    func controlTextDidChange(_ obj: Notification) { monitor.label.text = labelField.stringValue }
    @objc private func placeFromMenu() {
        let i = position.indexOfSelectedItem
        guard anchors.indices.contains(i) else {
            status.stringValue = "Drag the text in the monitor to position it."
            return
        }
        monitor.label.position = CGPoint(x: Double(i % 3)/2, y: 1 - Double(i / 3)/2)
    }

    @objc private func exportBesideSource() {
        if let exportTask {
            exportTask.cancel()
            export.isEnabled = false
            status.stringValue = "Cancelling export…"
        } else if let track = source {
            startExport(folder: track.url.deletingLastPathComponent())
        }
    }
    @objc private func chooseFolder() {
        guard source != nil, exportTask == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let folder = panel.url { self?.startExport(folder: folder) }
        }
    }
    private func startExport(folder: URL) {
        guard let track = source, exportTask == nil else { return }
        setAppearanceVisible(false)
        window.makeFirstResponder(monitor)
        player?.pause()
        stopTimer()
        let stem = track.url.deletingPathExtension().lastPathComponent + " - Cue"
        var target = folder.appendingPathComponent(stem + ".mxf")
        var copy = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(stem + " " + String(copy) + ".mxf")
            copy += 1
        }
        let destination = target
        let encoder = PreparedAudio.encoder
        let label = monitor.label
        let cueAppearance = monitor.cueAppearance
        reveal.isHidden = true
        status.stringValue = "Exporting MXF… 0%"
        exportTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                try MXFExport.run(track: track, label: label, appearance: cueAppearance, encoder: encoder, destination: destination) { value in
                    Task { @MainActor [weak self] in
                        guard let self, self.exportTask?.isCancelled == false else { return }
                        self.status.stringValue = "Exporting MXF… " + String(Int(value * 100)) + "%"
                    }
                }
            }
            do {
                try await withTaskCancellationHandler(operation: { try await worker.value },
                                                      onCancel: { worker.cancel() })
                self?.status.stringValue = "Saved " + destination.lastPathComponent
                self?.lastExport = destination
                self?.reveal.isHidden = false
            } catch is CancellationError {
                self?.status.stringValue = "Export cancelled."
            } catch {
                self?.status.stringValue = "Export failed. " + error.localizedDescription
                self?.status.toolTip = error.localizedDescription
                let alert = NSAlert()
                alert.messageText = "Couldn’t export MXF"
                alert.informativeText = error.localizedDescription + "\n\nChoose File → Export MXF to Folder to use another destination."
                if let window = self?.window { alert.beginSheetModal(for: window, completionHandler: nil) }
            }
            self?.exportTask = nil
            self?.updateControls()
        }
        updateControls()
    }
    @objc private func revealExport() {
        if let lastExport { NSWorkspace.shared.activateFileViewerSelecting([lastExport]) }
    }
}
