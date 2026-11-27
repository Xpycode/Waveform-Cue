import AppKit
import AVFoundation
import CueCore
import Observation
import UniformTypeIdentifiers

/// The editor: the batch queue, plus loading, playback and label placement for the selected job.
///
/// Every track is a queue job. Dropping or opening audio adds jobs (decoded once on the way in,
/// so a file that cannot be decoded arrives as a Failed job); selecting a job loads it into the
/// monitor; text, position and appearance edits go to the selected job only. The running job is
/// locked while every other job stays editable. Export goes through `QueueManager`.
@MainActor
@Observable
final class EditorModel: NSObject, @preconcurrency AVAudioPlayerDelegate {
    static let anchors = ["Top left", "Top center", "Top right", "Middle left", "Center",
                          "Middle right", "Bottom left", "Bottom center", "Bottom right"]
    /// Index of the "Custom" item that follows the nine anchors in the position pop-up.
    static let customPositionIndex = anchors.count
    static let formatReadout = "1080p25   ·   MXF"
    static let formatDetail = "MXF OP1a · 1920 × 1080p25 · MPEG-2 4:2:2, 50 Mb/s · Rec. 709 · Stereo PCM, 48 kHz, 24-bit · Start TC 00:00:00:00"
    static let exportHelp = "Export the selected job beside its audio file (Command-E). Use File → Export Selected to Folder… to choose another location."

    // MARK: Observed state

    let queue: QueueManager
    private(set) var track: AudioTrack?
    /// Changes with every successful load, so views can tell a new track from a re-render.
    private(set) var trackID: UUID?
    private(set) var label = CueLabel()
    private(set) var appearance = CueAppearance.load()
    private(set) var frame = 0
    private(set) var isPlaying = false
    private(set) var positionIndex = 0
    private(set) var placeholder = "Drop audio files"
    private(set) var status = "Drop tracks or a folder on the queue to begin."
    private(set) var statusHelp: String?
    /// Files still waiting to be read and added, including the one being read.
    private(set) var pendingAdds = 0

    /// The queue is exporting (Start Queue or Export Selected).
    var isExporting: Bool { queue.isRunning }
    var selectedJobID: UUID? { queue.selectedJobID }
    var selectedJob: CueJob? { queue.selectedJob }
    /// The selected job can be edited: it is not the one being exported.
    var canEdit: Bool { selectedJobID.map { !queue.isLocked($0) } ?? true }
    var isReady: Bool { canEdit && track != nil }

    var toolbarReadout: String {
        guard let job = selectedJob else { return Self.formatReadout }
        return job.sourceURL.lastPathComponent + "   ·   " + Self.formatReadout
    }

    var canStartQueue: Bool { !queue.isRunning && queue.jobs.contains { $0.status == .pending } }
    var canExportSelected: Bool {
        guard let job = selectedJob, !job.status.isActive else { return false }
        if queue.isRunning && queue.isStopping { return false }
        switch job.status {
        case .pending, .failed, .cancelled: return true
        default: return false
        }
    }

    /// The bottom bar's line while the queue runs.
    var progressLine: String? {
        guard let progress = queue.overallProgress else { return nil }
        let percent = Int((progress * 100).rounded(.down))
        if queue.isStopping { return "Stopping queue…   \(percent)%" }
        if let id = queue.currentJobID, let job = queue.job(id) {
            return "Exporting " + job.sourceURL.lastPathComponent + "   ·   Queue \(percent)%"
        }
        return "Exporting queue   ·   \(percent)%"
    }

    // MARK: Unobserved plumbing

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var ingestTask: Task<Void, Never>?
    @ObservationIgnored private var ingestBacklog: [URL] = []
    @ObservationIgnored private var ingestSkipped = 0
    /// A track decoded while adding, kept so selecting that job needs no second decode.
    @ObservationIgnored private var ingestedTrack: (job: UUID, track: AudioTrack)?
    @ObservationIgnored private var resumeAfterScrub = false
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?
    @ObservationIgnored private var wasRunning = false
    @ObservationIgnored private(set) weak var window: NSWindow?
    /// Registered by the AppKit wrappers so the key monitor can manage focus.
    @ObservationIgnored weak var monitorView: NSView?
    @ObservationIgnored weak var inspectorView: NSView?
    @ObservationIgnored weak var appearanceSidebar: CueAppearanceSidebar?
    /// Opens the main window when a file arrives from Finder before any window exists.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    override init() {
        queue = QueueSupport.makeManager()
        super.init()
        if let problem = queue.persistenceProblem {
            status = "Queue file problem: " + problem
            statusHelp = queue.recoveryFile.map { "A copy was saved to " + $0.path }
        } else if !queue.jobs.isEmpty {
            status = "Restored \(queue.jobs.count) job\(queue.jobs.count == 1 ? "" : "s"). Select one to preview it."
            placeholder = "Select a job in the queue"
        }
        observeQueueRun()
    }

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

    /// While the queue runs, the window is not closable: the close button and File → Close are disabled.
    private func updateWindowClosable() {
        guard let window else { return }
        if queue.isRunning { window.styleMask.remove(.closable) } else { window.styleMask.insert(.closable) }
    }

    /// Follows `queue.isRunning` for the window's close button and the end-of-run status line.
    private func observeQueueRun() {
        withObservationTracking {
            _ = queue.isRunning
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.queueRunChanged()
                self.observeQueueRun()
            }
        }
    }

    private func queueRunChanged() {
        updateWindowClosable()
        let running = queue.isRunning
        defer { wasRunning = running }
        guard wasRunning, !running else { return }
        let jobs = queue.jobs
        let done = jobs.filter { if case .done = $0.status { return true }; return false }.count
        let failed = jobs.filter { if case .failed = $0.status { return true }; return false }.count
        status = "Queue finished. \(done) done" + (failed > 0 ? ", \(failed) failed." : ".")
        statusHelp = nil
    }

    func open(fromFinder urls: [URL]) {
        addAudio(urls)
        guard window == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window == nil else { return }
            self.openMainWindow?()
        }
    }

    /// Quit asks to stop the queue first. With the queue idle, quitting goes ahead at once.
    /// Otherwise an alert offers Stop Queue and Quit (the current job is cancelled and the
    /// app quits once it has wound down, through `reply(true)`) or Keep Exporting.
    func terminateReply(reply: @escaping (Bool) -> Void) -> NSApplication.TerminateReply {
        guard queue.isRunning else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "The queue is exporting."
        alert.informativeText = "Stop the queue and quit? The current job is cancelled and leaves no file; the other jobs stay Pending and are restored next time."
        alert.addButton(withTitle: "Stop Queue and Quit")
        alert.addButton(withTitle: "Keep Exporting")
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else {
                    self?.status = "Quit cancelled. The queue keeps exporting."
                    reply(false)
                    return
                }
                self.stopQueueThenQuit(reply)
            }
            return .terminateLater
        }
        guard alert.runModal() == .alertFirstButtonReturn else {
            status = "Quit cancelled. The queue keeps exporting."
            return .terminateCancel
        }
        stopQueueThenQuit(reply)
        return .terminateLater
    }

    private func stopQueueThenQuit(_ reply: @escaping (Bool) -> Void) {
        status = "Stopping the queue before quitting…"
        queue.stopQueue()
        Task { @MainActor [queue] in
            await queue.waitUntilIdle()
            reply(true)
        }
    }

    func shutdown() {
        loadTask?.cancel()
        ingestTask?.cancel()
        ingestedTrack = nil
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
        if queue.isRunning, modifiers == .command, event.charactersIgnoringModifiers == "w" {
            status = "The queue is exporting. Stop the queue before closing."
            NSSound.beep()
            return nil
        }
        guard !(window.firstResponder is NSTextView), modifiers.isEmpty, isReady else { return event }
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

    // MARK: Adding jobs

    /// Add Audio… (Command-O): files or folders.
    func chooseAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        present(panel) { [weak self] urls in self?.addAudio(urls) }
    }

    /// A single file dropped on the monitor joins the queue like any other.
    func load(url: URL) { addAudio([url]) }

    /// Adds files and folders to the queue in order. Each file is decoded once on the way in
    /// (its peaks are kept with the job); a decode failure is added as a Failed job.
    func addAudio(_ urls: [URL]) {
        let expansion = AudioIngest.expand(urls)
        ingestSkipped += expansion.skipped
        let skipped = AudioIngest.summary(skipped: expansion.skipped)
        guard !expansion.files.isEmpty else {
            status = skipped ?? "Nothing to add."
            statusHelp = nil
            if skipped != nil { NSSound.beep() }
            if ingestTask == nil { ingestSkipped = 0 }
            return
        }
        ingestBacklog += expansion.files
        pendingAdds = ingestBacklog.count + (ingestTask == nil ? 0 : 1)
        if let skipped { status = skipped; statusHelp = nil }
        guard ingestTask == nil else { return }
        ingestTask = Task { [weak self] in await self?.drainIngest() }
    }

    private func drainIngest() async {
        var added = 0
        var failed = 0
        let appearance = CueAppearance.load()
        while !ingestBacklog.isEmpty, !Task.isCancelled {
            let url = ingestBacklog.removeFirst()
            pendingAdds = ingestBacklog.count + 1
            status = "Reading " + url.lastPathComponent + (ingestBacklog.isEmpty ? "" : "   ·   \(ingestBacklog.count) more to add")
            let worker = Task.detached(priority: .userInitiated) { try AudioTrack.read(url) }
            let outcome: Result<AudioTrack, Error>
            do {
                outcome = .success(try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                       onCancel: { worker.cancel() }))
            } catch {
                outcome = .failure(error)
            }
            if Task.isCancelled { break }
            switch outcome {
            case .success(let track):
                let job = CueJob(source: url, appearance: appearance,
                                 peaks: PeaksSummary(seconds: track.seconds, overview: track.peaks))
                queue.add(job)
                added += 1
                if queue.selectedJobID == nil {
                    ingestedTrack = (job.id, track)
                    selectJob(job.id)
                }
            case .failure(let error):
                queue.add(CueJob(source: url, appearance: appearance,
                                 status: .failed(reason: error.localizedDescription, log: "")))
                failed += 1
            }
        }
        ingestTask = nil
        pendingAdds = 0
        var line = "Added \(added) job\(added == 1 ? "" : "s")"
        if failed > 0 { line += ", \(failed) could not be decoded" }
        line += "."
        if let skipped = AudioIngest.summary(skipped: ingestSkipped) { line += " " + skipped }
        ingestSkipped = 0
        status = line
        statusHelp = nil
    }

    // MARK: Selection

    /// Selects a job and loads it into the monitor with its own text, position and appearance.
    /// Selecting the already selected job does nothing, unless its audio is not loaded yet
    /// (for example after a failed read) or `force` is set.
    func selectJob(_ id: UUID?, force: Bool = false) {
        let unchanged = id == queue.selectedJobID && !(id != nil && trackID == nil && loadTask == nil)
        guard force || !unchanged else { return }
        queue.select(id)
        appearanceSidebar?.closeColorPicker()
        loadTask?.cancel()
        loadTask = nil
        stopTimer()
        player?.stop()
        player = nil
        track = nil
        trackID = nil
        frame = 0
        syncPlaying()
        guard let job = queue.selectedJob else {
            label = CueLabel()
            positionIndex = 0
            appearance = CueAppearance.load()
            placeholder = queue.jobs.isEmpty ? "Drop audio files" : "Select a job in the queue"
            return
        }
        label = job.label
        positionIndex = Self.positionIndex(for: job.label.position)
        appearance = job.appearance
        statusHelp = nil
        let url = job.sourceURL
        if let cached = ingestedTrack, cached.job == job.id {
            ingestedTrack = nil
            adopt(cached.track, for: job)
            return
        }
        ingestedTrack = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            placeholder = QueueManager.sourceNotFound
            status = QueueManager.sourceNotFound + ": " + url.path
            return
        }
        placeholder = "Reading waveform…"
        let id = UUID()
        loadID = id
        let jobID = job.id
        loadTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { try AudioTrack.read(url) }
            do {
                let track = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                  onCancel: { worker.cancel() })
                guard let self, self.loadID == id, !Task.isCancelled,
                      let job = self.queue.job(jobID), self.queue.selectedJobID == jobID else { return }
                self.loadTask = nil
                self.adopt(track, for: job)
            } catch {
                guard let self, self.loadID == id, !Task.isCancelled else { return }
                self.loadTask = nil
                self.placeholder = "Couldn’t read this job’s audio"
                self.status = "Couldn’t open audio. " + error.localizedDescription
                self.statusHelp = error.localizedDescription
            }
        }
    }

    private func adopt(_ track: AudioTrack, for job: CueJob) {
        do {
            let audio = try AVAudioPlayer(contentsOf: track.pcm.url)
            guard audio.prepareToPlay() else { throw CueError("Audio playback could not be prepared.") }
            audio.delegate = self
            player = audio
            self.track = track
            trackID = UUID()
            if !queue.isRunning, pendingAdds == 0 {
                status = "Click the waveform to cue. Drag the text to position it."
            }
        } catch {
            placeholder = "Couldn’t play this job’s audio"
            status = "Couldn’t open audio. " + error.localizedDescription
        }
        syncPlaying()
    }

    /// Removes jobs (Delete key or the row menu). The running job is kept.
    func removeJobs(_ ids: Set<UUID>) {
        let wasSelected = selectedJobID.map(ids.contains) ?? false
        let removed = queue.remove(ids)
        if removed.count < ids.count { status = "The running job can’t be removed. Cancel it first." }
        if wasSelected, queue.selectedJobID == nil { selectJob(nil, force: true) }
    }

    static func positionIndex(for point: CGPoint) -> Int {
        anchors.indices.first { anchorPoint($0) == point } ?? customPositionIndex
    }

    private static func anchorPoint(_ index: Int) -> CGPoint {
        CGPoint(x: Double(index % 3) / 2, y: 1 - Double(index / 3) / 2)
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

    // MARK: Label and appearance (selected job only)

    func setLabelText(_ text: String) {
        guard canEdit else { return }
        label.text = text
        storeLabel()
    }

    /// Title drag in the monitor.
    func placeLabel(at point: CGPoint) {
        guard canEdit else { return }
        label.position = point
        positionIndex = Self.customPositionIndex
        storeLabel()
    }

    /// Position pop-up: one of the nine anchors, or Custom.
    func selectPosition(_ index: Int) {
        guard canEdit else { return }
        positionIndex = index
        guard Self.anchors.indices.contains(index) else {
            status = "Drag the text in the monitor to position it."
            return
        }
        label.position = Self.anchorPoint(index)
        storeLabel()
    }

    /// The selected job takes the new appearance; it is also remembered as the look for jobs
    /// added later. Other jobs keep their own.
    func updateAppearance(_ appearance: CueAppearance) {
        guard canEdit else { return }
        self.appearance = appearance
        appearance.save()
        if let id = selectedJobID { queue.update(id) { $0.appearance = appearance } }
    }

    private func storeLabel() {
        guard let id = selectedJobID else { return }
        let label = self.label
        if !queue.update(id, { $0.label = label }) {
            status = "This job is exporting. Its settings are locked."
        }
    }

    // MARK: Queue actions

    func toggleQueue() {
        if queue.isRunning { stopQueue() } else { startQueue() }
    }

    /// Start Queue (Command-Return): every Pending job, one at a time, in list order.
    func startQueue() {
        guard canStartQueue else { NSSound.beep(); return }
        prepareForExport()
        queue.start()
        status = "Queue started."
        statusHelp = nil
    }

    func stopQueue() {
        guard queue.isRunning else { return }
        queue.stopQueue()
        status = "Stopping the queue. The current job is cancelled; the rest stay Pending."
    }

    /// Export Selected (Command-E): the selected job, beside its source or its chosen folder.
    func exportSelected() {
        guard let job = selectedJob else { NSSound.beep(); return }
        if case .done = job.status {
            status = "This job is already exported. Add the file again to make another version."
            NSSound.beep()
            return
        }
        guard canExportSelected else { NSSound.beep(); return }
        if job.status.canRetry { queue.retry(job.id) }
        prepareForExport()
        queue.start(only: [job.id])
        if let current = queue.selectedJob, current.status == .pending, queue.isRunning {
            status = "Exporting " + current.sourceURL.lastPathComponent + "…"
        }
    }

    /// Export Selected to Folder…: points the selected job at a folder, then exports it.
    func exportSelectedToFolder() {
        guard let job = selectedJob, canExportSelected else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        let id = job.id
        present(panel) { [weak self] urls in
            guard let self, let folder = urls.first else { return }
            self.queue.update(id) { $0.destinationFolder = folder.path }
            self.exportSelected()
        }
    }

    func cancelJob(_ id: UUID) { queue.cancel(id) }

    func retryJob(_ id: UUID) {
        guard queue.retry(id) else { NSSound.beep(); return }
    }

    func reveal(_ id: UUID) {
        guard let job = queue.job(id), case .done(let output) = job.status else { return }
        if FileManager.default.fileExists(atPath: output.path) {
            NSWorkspace.shared.activateFileViewerSelecting([output])
        } else {
            status = "The exported file is no longer at " + output.path
            NSSound.beep()
        }
    }

    private func prepareForExport() {
        appearanceSidebar?.closeColorPicker()
        if let window, let responder = window.firstResponder as? NSView, let inspectorView,
           responder.isDescendant(of: inspectorView), let monitorView {
            window.makeFirstResponder(monitorView)
        }
    }

    // MARK: Helpers

    private func present(_ panel: NSOpenPanel, then handler: @escaping ([URL]) -> Void) {
        if let window {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { handler(panel.urls) }
            }
        } else if panel.runModal() == .OK {
            handler(panel.urls)
        }
    }
}
