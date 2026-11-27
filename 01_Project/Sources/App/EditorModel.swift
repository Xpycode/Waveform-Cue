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
///
/// Decoded audio goes through `JobAudioLifetime`: the selected job, the running job and the file
/// being added are the only ones that may hold a CAF, never more than two at once. A job restored
/// with stored analysis shows its waveform at once; its audio is decoded only when it is selected
/// (for playback) or run, and it is never re-analysed.
@MainActor
@Observable
final class EditorModel: NSObject, @preconcurrency AVAudioPlayerDelegate {
    static let anchors = ["Top left", "Top center", "Top right", "Middle left", "Center",
                          "Middle right", "Bottom left", "Bottom center", "Bottom right"]
    /// Index of the "Custom" item that follows the nine anchors in the position pop-up.
    static let customPositionIndex = anchors.count
    static let exportHelp = "Export the selected job beside its audio file (Command-E). Use File → Export Selected to Folder… to choose another location."

    // MARK: Observed state

    let queue: QueueManager
    /// Who may hold decoded audio (the selected job, the running job, a file being added).
    let audioLifetime: JobAudioLifetime
    private(set) var track: AudioTrack?
    /// The selected job's audio is decoded and the player is ready.
    private(set) var hasAudio = false
    /// Changes with every successful load, so views can tell a new track from a re-render.
    private(set) var trackID: UUID?
    private(set) var label = CueLabel()
    private(set) var appearance = CueAppearance.load()
    /// The playhead: a position of `previewTimeline` (see Playback).
    private(set) var frame = 0
    private(set) var isPlaying = false
    private(set) var positionIndex = 0
    private(set) var placeholder = "Drop audio files"
    private(set) var status = "Drop tracks or a folder on the queue to begin."
    private(set) var statusHelp: String?
    /// Files still waiting to be read and added, including the one being read.
    private(set) var pendingAdds = 0
    /// The job whose loudness is being measured in the background, if any.
    private(set) var measuringJobID: UUID?
    /// Why a job's loudness pass failed (shown in the Job tab until it is measured again).
    private(set) var loudnessFailures: [UUID: String] = [:]
    /// A marker time typed in the Job tab that could not be read.
    private(set) var markerMessage: String?
    /// An in or out time typed in the Job tab that could not be read.
    private(set) var trimMessage: String?

    /// The queue is exporting (Start Queue or Export Selected).
    var isExporting: Bool { queue.isRunning }
    var selectedJobID: UUID? { queue.selectedJobID }
    var selectedJob: CueJob? { queue.selectedJob }
    /// The selected job can be edited: it is not the one being exported.
    var canEdit: Bool { selectedJobID.map { !queue.isLocked($0) } ?? true }
    var isReady: Bool { canEdit && track != nil }
    /// Playback, seek and frame steps need the decoded audio, not just the stored waveform.
    var canPlay: Bool { isReady && hasAudio }

    /// The selected job's preset, or the default preset when nothing is selected. An empty or
    /// unknown preset ID means the default (AVC-Intra 100 1080i50).
    var selectedPreset: ExportPreset {
        selectedJob.flatMap { ExportPreset.preset(for: $0.presetID) } ?? .default
    }

    var toolbarReadout: String {
        let format = selectedPreset.formatReadout.replacingOccurrences(of: " · ", with: "   ·   ")
        guard let job = selectedJob else { return format }
        return job.sourceURL.lastPathComponent + "   ·   " + format
    }

    var formatDetail: String {
        selectedPreset.detailedReadout(layout: selectedJob?.layout ?? .default)
            + " · Start TC " + (selectedJob?.startTimecode ?? "00:00:00:00")
    }

    var canStartQueue: Bool { !queue.isRunning && queue.jobs.contains { $0.status == .pending } }
    /// Export Selected to Folder… also needs a per-job destination: a queue-wide folder wins over it.
    var canExportSelectedToFolder: Bool { canExportSelected && queue.destinationOverride == nil }
    var canExportSelected: Bool {
        guard let job = selectedJob, !job.status.isActive else { return false }
        // "Safe zones leave too little room" (task 4.2), an invalid start timecode (4.1) or
        // "Trim range too short" (5.1) disables export for that job; Start Queue fails such a
        // job with the same reason.
        guard QueueManager.blockingReason(for: job) == nil else { return false }
        if queue.isRunning && queue.isStopping { return false }
        switch job.status {
        case .pending, .failed, .cancelled, .done: return true   // Done re-exports under a new name
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
    /// Playing from the slate: the player's device time at which the music starts.
    @ObservationIgnored private var slateStart: TimeInterval?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?
    @ObservationIgnored private var wasRunning = false
    /// True inside `selectJob`, so lifetime changes it causes are not handled twice.
    @ObservationIgnored private var isSelecting = false
    /// Unwritable folders already offered to the operator (standardised paths).
    @ObservationIgnored private var promptedFolders: Set<String> = []
    @ObservationIgnored private var isPromptingFolder = false
    @ObservationIgnored private var loudnessTask: Task<Void, Never>?
    @ObservationIgnored private var loudnessToken = UUID()
    /// Jobs whose loudness pass has run (or failed) this session, so each is measured once.
    @ObservationIgnored private var loudnessAttempted: Set<UUID> = []
    @ObservationIgnored private(set) weak var window: NSWindow?
    /// Registered by the AppKit wrappers so the key monitor can manage focus.
    @ObservationIgnored weak var monitorView: NSView?
    @ObservationIgnored weak var inspectorView: NSView?
    @ObservationIgnored weak var appearanceSidebar: CueAppearanceSidebar?
    /// Opens the main window when a file arrives from Finder before any window exists.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    override init() {
        audioLifetime = QueueSupport.makeAudioLifetime()
        queue = QueueSupport.makeManager(audio: audioLifetime)
        super.init()
        audioLifetime.onChange = { [weak self] in self?.audioEntitlementChanged() }
        if let problem = queue.persistenceProblem {
            status = "Queue file problem: " + problem
            statusHelp = queue.recoveryFile.map { "A copy was saved to " + $0.path }
        } else if !queue.jobs.isEmpty {
            let count = queue.jobs.count
            let missing = queue.jobs.filter {
                if case .failed(let reason, _) = $0.status { return reason == QueueManager.sourceNotFound }
                return false
            }.count
            status = "Restored \(count) job\(count == 1 ? "" : "s")."
                + (missing > 0 ? " \(missing) source\(missing == 1 ? "" : "s") not found." : "")
                + " Select one to preview it."
            placeholder = "Select a job in the queue"
        }
        // Decoded audio from a launch that crashed or was force quit skipped the quit-time cleanup.
        PreparedAudio.removeStaleSessionDirectories()
        observeQueueRun()
        observe({ [weak self] in self?.queue.currentJobID }) { [weak self] in self?.currentJobChanged() }
        observe({ [weak self] in self?.queue.unwritableFolders }) { [weak self] in self?.unwritableFoldersChanged() }
        observe({ [weak self] in self?.canEdit }) { [weak self] in self?.editLockChanged() }
        // The queue copies the job when it starts it; a half-typed commit-only field must land first.
        queue.willStartJob = { [weak self] id in
            guard let self, id == self.selectedJobID else { return }
            self.endEditing()
        }
        scheduleLoudness()
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

    /// Calls `changed` on the main actor after every change to what `value` reads.
    private func observe<T>(_ value: @escaping () -> T, _ changed: @escaping () -> Void) {
        withObservationTracking {
            _ = value()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                changed()
                self.observe(value, changed)
            }
        }
    }

    /// The running job holds the export slot of the audio lifetime from the moment it starts.
    private func currentJobChanged() {
        audioLifetime.assign(.running, to: queue.currentJobID)
    }

    /// The selected job locked (it started exporting): preview playback and the colour panel stop,
    /// since every edit is refused from here.
    private func editLockChanged() {
        guard !canEdit else { return }
        appearanceSidebar?.closeColorPicker()
        resumeAfterScrub = false
        haltPlayer()
        syncPlaying()
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
        // A job that was running when its loudness pass wanted to store a result is measured now.
        scheduleLoudness()
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

    /// Close (Command-W) asks to stop the queue first, as quitting does. The window's close button
    /// stays disabled while the queue runs; closing the last window quits the app.
    func requestClose() {
        guard let window else { return }
        guard queue.isRunning else { window.performClose(nil); return }
        guard window.attachedSheet == nil else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = "The queue is exporting."
        alert.informativeText = "Stop the queue and close the window? Closing it quits Waveform Cue. The current job is cancelled and leaves no file; the other jobs stay Pending and are restored next time."
        alert.addButton(withTitle: "Stop Queue and Close")
        alert.addButton(withTitle: "Keep Exporting")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else {
                self.status = "The queue keeps exporting."
                return
            }
            self.status = "Stopping the queue before closing…"
            self.queue.stopQueue()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.queue.waitUntilIdle()
                self.updateWindowClosable()
                self.window?.performClose(nil)
            }
        }
    }

    func shutdown() {
        queue.flushPendingSave()
        loadTask?.cancel()
        ingestTask?.cancel()
        loudnessTask?.cancel()
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
            requestClose()
            return nil
        }
        // Space belongs to a focused control (Full Keyboard Access) as well as to text editing.
        guard !(window.firstResponder is NSTextView), !(window.firstResponder is NSControl),
              !(window.firstResponder is InspectorKeyControl),
              modifiers.isEmpty, isReady else { return event }
        if let responder = window.firstResponder as? NSView, let inspectorView,
           responder.isDescendant(of: inspectorView) { return event }
        // I and O set the in and out points at the playhead (they need only the waveform).
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "i": setTrimPointAtPlayhead(.inPoint); return nil
        case "o": setTrimPointAtPlayhead(.outPoint); return nil
        default: break
        }
        guard canPlay else { return event }
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
            // The file is decoded into the workspace under the ingest role and analysed once; its
            // CAF goes when the next file takes the role, unless the job became the selected one.
            let id = UUID()
            audioLifetime.assign(.ingest, to: id)
            let lifetime = audioLifetime
            let outcome: Result<AudioTrack, Error>
            do {
                let pcm = try await lifetime.audio(for: id, source: url, as: .ingest)
                let worker = Task.detached(priority: .userInitiated) { try AudioTrack.analyse(url, audio: pcm) }
                outcome = .success(try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                       onCancel: { worker.cancel() }))
            } catch {
                outcome = .failure(error)
            }
            if Task.isCancelled { break }
            switch outcome {
            case .success(let track):
                let job = CueJob(id: id, source: url, appearance: appearance,
                                 peaks: PeaksSummary(seconds: track.seconds, overview: track.peaks),
                                 analysis: track.analysis)
                queue.add(job)
                scheduleLoudness()
                added += 1
                if queue.selectedJobID == nil {
                    ingestedTrack = (job.id, track)
                    selectJob(job.id)
                }
            case .failure(let error):
                queue.add(CueJob(id: id, source: url, appearance: appearance,
                                 status: .failed(reason: error.localizedDescription, log: "")))
                failed += 1
            }
        }
        // Held until the batch is read (the next file takes the role over directly), so a
        // squeezed-out selected job is not decoded and dropped again between files.
        audioLifetime.assign(.ingest, to: nil)
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
    /// A job with stored analysis shows its waveform at once; its audio is then decoded through
    /// the workspace for playback (no re-analysis). Selecting the already selected job does
    /// nothing, unless its audio is not loaded yet (for example after a failed read) or `force`.
    func selectJob(_ id: UUID?, force: Bool = false) {
        let unchanged = id == queue.selectedJobID && !(id != nil && !hasAudio && loadTask == nil)
        guard force || !unchanged else { return }
        isSelecting = true
        defer { isSelecting = false }
        queue.select(id)
        appearanceSidebar?.closeColorPicker()
        // A load in flight is abandoned, not cancelled: its job may still be entitled (it is also
        // running), and the lifetime releases it when it is not.
        loadID = UUID()
        loadTask = nil
        dropPlayer()
        track = nil
        trackID = nil
        frame = 0
        syncPlaying()
        audioLifetime.assign(.selected, to: queue.selectedJobID)
        guard let job = queue.selectedJob else {
            ingestedTrack = nil
            label = CueLabel()
            positionIndex = 0
            appearance = CueAppearance.load()
            placeholder = queue.jobs.isEmpty ? "Drop audio files" : "Select a job in the queue"
            return
        }
        label = job.label
        positionIndex = Self.positionIndex(for: job.label.position)
        appearance = job.appearance
        markerMessage = nil
        trimMessage = nil
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
        if let analysis = job.analysis {
            track = AudioTrack(url: url, analysis: analysis)
            trackID = UUID()
        }
        placeholder = "Reading waveform…"
        loadSelectedAudio()
    }

    /// Decodes the selected job's audio through the workspace, if the lifetime allows it now.
    /// A job without stored analysis is analysed once and the result kept with the job.
    private func loadSelectedAudio() {
        guard let job = queue.selectedJob, !hasAudio, loadTask == nil else { return }
        let url = job.sourceURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard audioLifetime.isEntitled(job.id) else {
            placeholder = "Waiting for audio…"
            status = "Preview audio returns once the files are added."
            return
        }
        let id = UUID()
        loadID = id
        let jobID = job.id
        let stored = job.analysis
        let lifetime = audioLifetime
        loadTask = Task { [weak self] in
            do {
                let pcm = try await lifetime.audio(for: jobID, source: url, as: .selected)
                let track: AudioTrack
                if let stored {
                    track = try AudioTrack(url: url, analysis: stored, audio: pcm)
                } else {
                    let worker = Task.detached(priority: .userInitiated) { try AudioTrack.analyse(url, audio: pcm) }
                    track = try await worker.value
                }
                guard let self, self.loadID == id else { return }
                self.loadTask = nil
                guard let job = self.queue.job(jobID), self.queue.selectedJobID == jobID else { return }
                if stored == nil {
                    self.queue.update(jobID) {
                        $0.analysis = track.analysis
                        $0.peaks = PeaksSummary(seconds: track.seconds, overview: track.peaks)
                    }
                }
                self.adopt(track, for: job)
            } catch {
                guard let self, self.loadID == id else { return }
                self.loadTask = nil
                // Squeezed out or deselected: `audioEntitlementChanged` loads it again when it may.
                if error is CancellationError { return }
                self.placeholder = "Couldn’t read this job’s audio"
                self.status = "Couldn’t open audio. " + error.localizedDescription
                self.statusHelp = error.localizedDescription
            }
        }
    }

    /// The selected job gained or lost its place in the audio lifetime (files being added while
    /// the queue runs take it). Without it, the waveform stays and playback waits.
    private func audioEntitlementChanged() {
        guard !isSelecting, let id = queue.selectedJobID else { return }
        if audioLifetime.isEntitled(id) {
            if !hasAudio { loadSelectedAudio() }
        } else if hasAudio || loadTask != nil {
            loadID = UUID()
            loadTask = nil
            dropPlayer()
            if let track {
                self.track = AudioTrack(url: track.url, analysis: track.analysis)
                trackID = UUID()
            } else {
                placeholder = "Waiting for audio…"
            }
            syncPlaying()
            status = "Preview audio is paused while files are added during the export."
        }
    }

    private func dropPlayer() {
        stopTimer()
        slateStart = nil
        player?.stop()
        player = nil
        hasAudio = false
    }

    private func adopt(_ track: AudioTrack, for job: CueJob) {
        guard let pcm = track.audio else {
            self.track = track
            trackID = UUID()
            return
        }
        do {
            let audio = try AVAudioPlayer(contentsOf: pcm.url)
            guard audio.prepareToPlay() else { throw CueError("Audio playback could not be prepared.") }
            audio.delegate = self
            player = audio
            self.track = track
            trackID = UUID()
            hasAudio = true
            // The playhead (the slate, or the in point) and the player agree from the start.
            if let timeline = previewTimeline {
                frame = min(frame, timeline.positionCount)
                audio.currentTime = min(audio.duration, timeline.sourceSeconds(at: frame))
            }
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
        if let measuring = measuringJobID, removed.contains(measuring) { restartLoudness() }
        for id in removed { loudnessFailures[id] = nil }
        if wasSelected, queue.selectedJobID == nil { selectJob(nil, force: true) }
    }

    static func positionIndex(for point: CGPoint) -> Int {
        anchors.indices.first { anchorPoint($0) == point } ?? customPositionIndex
    }

    private static func anchorPoint(_ index: Int) -> CGPoint {
        CGPoint(x: Double(index % 3) / 2, y: 1 - Double(index / 3) / 2)
    }

    // MARK: Playback
    //
    // `frame` is a position of `previewTimeline` (25 per second): with a pre-roll the slate
    // comes first, then the trimmed music; `positionCount` is the end. Without trim or pre-roll
    // the positions are the track's frames, as in build 10. The player plays the source, so
    // positions map to source time through the timeline. Playing from the slate counts it down
    // in silence (the player starts at the in point when it ends); playback stops at the out
    // point, and scrubbing and seeking never leave the trimmed range.

    /// The player is playing, or waiting out the slate before it starts at the in point.
    private var playerActive: Bool { player?.isPlaying == true || slateStart != nil }
    private func syncPlaying() { isPlaying = playerActive }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    /// Stops the player and a pending slate start; keeps the position.
    private func haltPlayer() {
        player?.pause()
        slateStart = nil
        stopTimer()
    }

    func togglePlayback() {
        guard let player, let timeline = previewTimeline else { return }
        if playerActive { haltPlayer() }
        else {
            if frame >= timeline.positionCount { seek(frame: 0) }
            if startPlayer(player, timeline: timeline) { startTimer() }
            else { status = "Audio playback could not start." }
        }
        syncPlaying()
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1.0/30, target: self, selector: #selector(tick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Starts the source audio for the current position: at once in the music, or at the in
    /// point once the rest of the slate has passed.
    private func startPlayer(_ player: AVAudioPlayer, timeline: ClipTimeline) -> Bool {
        player.currentTime = min(player.duration, timeline.sourceSeconds(at: frame))
        let slateLeft = timeline.preRollPositions - frame
        guard slateLeft > 0 else { return player.play() }
        let start = player.deviceCurrentTime + Double(slateLeft) / Double(timeline.positionRate)
        guard player.play(atTime: start) else { return false }
        slateStart = start
        return true
    }

    @objc private func tick() {
        guard let player, let timeline = previewTimeline else { return }
        if let start = slateStart {
            let wait = start - player.deviceCurrentTime
            if wait > 0 {
                let left = Int(ceil(wait * Double(timeline.positionRate)))
                frame = max(0, timeline.preRollPositions - left)
                return
            }
            slateStart = nil
        }
        let seconds = player.currentTime
        if timeline.sourceRange.upperBound < timeline.duration,
           seconds >= timeline.sourceRange.upperBound {
            // The out point: stop there, as the file ends there.
            haltPlayer()
            frame = timeline.positionCount
            syncPlaying()
            return
        }
        frame = timeline.position(ofSourceSeconds: seconds)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === self.player else { return }
        stopTimer()
        slateStart = nil
        frame = positionCount
        if !flag { status = "Audio playback ended with a decoder error." }
        syncPlaying()
    }

    /// Moves the playhead to a timeline position (monitor scrub, the seek slider, frame steps),
    /// clamped to the slate and the trimmed music. Playing continues from there.
    func seek(frame target: Int) {
        guard let player, let timeline = previewTimeline else { return }
        let f = min(timeline.positionCount, max(0, target))
        let wasActive = playerActive
        let slateInvolved = slateStart != nil || timeline.isSlate(f)
        if f == timeline.positionCount || (wasActive && slateInvolved) { haltPlayer() }
        frame = f
        player.currentTime = min(player.duration, timeline.sourceSeconds(at: f))
        // A seek into or out of the slate while playing restarts the player at the new place.
        if wasActive, slateInvolved, f < timeline.positionCount, startPlayer(player, timeline: timeline) {
            startTimer()
        }
        syncPlaying()
    }

    func step(_ count: Int) {
        haltPlayer()
        seek(frame: frame + count)
    }

    /// Pauses for the length of a monitor scrub and resumes afterwards if it was playing.
    func scrubChanged(began: Bool) {
        guard track != nil else { return }
        if began {
            resumeAfterScrub = playerActive
            haltPlayer()
            syncPlaying()
        } else if resumeAfterScrub {
            resumeAfterScrub = false
            if canPlay, frame < positionCount { togglePlayback() }
        }
    }

    // MARK: Label and appearance (selected job only)

    func setLabelText(_ text: String) {
        guard canEdit else { return }
        label.text = text
        storeLabel(deferringSave: true)
    }

    /// Title drag in the monitor.
    func placeLabel(at point: CGPoint) {
        guard canEdit else { return }
        label.position = point
        positionIndex = Self.customPositionIndex
        storeLabel(deferringSave: true)
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

    /// Typing and dragging defer the save (`queue.json` holds every job's waveform), so a burst
    /// of keystrokes writes the file once.
    private func storeLabel(deferringSave: Bool = false) {
        guard let id = selectedJobID else { return }
        let label = self.label
        if !queue.update(id, deferringSave: deferringSave, { $0.label = label }) {
            status = "This job is exporting. Its settings are locked."
        }
    }

    // MARK: Job settings (Job tab, selected job only)

    /// The selected job's detected markers (from its analysis), or `nil` before analysis.
    var detectedMarkers: MusicMarkers? { selectedJob?.analysis?.markers ?? track?.markers }

    /// The markers in force for the selected job: the detection with its edits on top.
    var selectedMarkers: MusicMarkers? {
        guard let job = selectedJob, let detected = detectedMarkers else { return nil }
        return detected.applyingEdits(from: job.markers)
    }

    /// The selected job's source duration in seconds, when known.
    private var selectedDuration: Double? {
        selectedJob?.analysis?.seconds ?? selectedJob?.peaks?.seconds ?? track?.seconds
    }

    /// The start timecode cannot be read: the inline message under the field.
    var timecodeProblem: String? {
        guard let job = selectedJob, Timecode(job.startTimecode) == nil else { return nil }
        return "Use HH:MM:SS:FF at 25 fps (frames 00–24). This job can’t be exported until it is fixed."
    }

    /// The output file name the template gives now. A clash with an existing file adds " 2",
    /// " 3"… when the job runs; a finished job shows the file it wrote.
    var resolvedFilename: String? {
        guard let job = selectedJob else { return nil }
        if case .done(let output) = job.status { return output.lastPathComponent }
        let preset = ExportPreset.preset(for: job.presetID) ?? .default
        return FilenameTemplate.expand(job.filenameTemplate, name: job.sourceName, preset: preset.name) + ".mxf"
    }

    /// Other Pending jobs that Apply to All would change.
    var applyToAllCount: Int {
        guard let id = selectedJobID else { return 0 }
        return queue.jobs.filter { $0.id != id && $0.status == .pending }.count
    }

    func selectPreset(_ preset: ExportPreset) {
        editSelected { $0.presetID = preset.id }
    }

    func selectAudioLayout(_ layout: AudioLayout) {
        editSelected { $0.layout = layout }
    }

    /// Stored as typed, so an invalid value is kept, shown with its message and blocks export.
    func setStartTimecode(_ text: String) {
        editSelected(deferringSave: true) { $0.startTimecode = text }
    }

    /// A valid timecode is written back in its canonical form (`1:2:3:4` → `01:02:03:04`).
    func commitStartTimecode(_ text: String) {
        let value = Timecode(text)?.formatted ?? text
        editSelected { $0.startTimecode = value }
    }

    func setFilenameTemplate(_ text: String) {
        editSelected(deferringSave: true) { $0.filenameTemplate = text }
    }

    /// An empty template returns to the default when editing ends.
    func commitFilenameTemplate(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? CueJob.defaultFilenameTemplate : text
        editSelected { $0.filenameTemplate = value }
    }

    func setNormalise(_ on: Bool) {
        editSelected { $0.normalise = on }
    }

    /// A marker time typed in the Job tab (seconds or M:SS.ff).
    func commitMarker(_ kind: MarkerKind, text: String) {
        // Leaving the field without changing it must not turn the detected value into an edit.
        if let current = selectedMarkers?.value(kind),
           MarkerTime.format(current) == text.trimmingCharacters(in: .whitespaces) {
            markerMessage = nil
            return
        }
        guard let seconds = MarkerTime.parse(text) else {
            markerMessage = "“\(text)” is not a time. Type seconds (83.5) or M:SS.ff (1:23.50)."
            return
        }
        markerMessage = nil
        setMarker(kind, to: seconds)
    }

    /// A marker dragged in the monitor (every drag step) or typed. The value is kept inside the
    /// track and fade start never passes music end: a fade start dragged past the end stops at
    /// it, and a music end dragged before the fade start takes the fade start with it.
    func setMarker(_ kind: MarkerKind, to seconds: Double, deferringSave: Bool = false) {
        guard canEdit, let job = selectedJob, let detected = detectedMarkers, !detected.noMusic else { return }
        var value = max(0, seconds.isFinite ? seconds : 0)
        if let duration = selectedDuration, duration > 0 { value = min(value, duration) }
        var merged = detected.applyingEdits(from: job.markers)
        merged.setEdited(kind, to: value)
        if kind == .fadeStart, let end = merged.musicEnd, value > end {
            merged.setEdited(.fadeStart, to: end)
        } else if kind == .musicEnd, let fade = merged.fadeStart, fade > value {
            merged.setEdited(.fadeStart, to: value)
        }
        editSelected(deferringSave: deferringSave) {
            $0.markers.editedMusicEnd = merged.editedMusicEnd
            $0.markers.editedFadeStart = merged.editedFadeStart
        }
    }

    /// Reset: both markers return to the detected values.
    func resetMarkers() {
        markerMessage = nil
        editSelected { $0.markers.resetToDetected() }
    }

    // MARK: Trim, fades and pre-roll (Job tab, I and O keys, monitor handles)

    /// The selected job's trim, fades and pre-roll.
    var selectedTrim: TrimSettings { selectedJob?.trim ?? .none }

    /// The 25 fps timeline the monitor shows for the selected job: its trim and pre-roll, its
    /// markers and the countdown target. `frame` and the monitor's positions are on it.
    var previewTimeline: ClipTimeline? {
        guard let track else { return nil }
        return CuePicture.timeline(for: track, appearance: appearance, markers: selectedMarkers, trim: selectedTrim)
    }

    /// The end position of the preview timeline (slate plus trimmed music); the slider's range.
    var positionCount: Int { previewTimeline?.positionCount ?? 0 }

    /// The trim leaves under one second: the inline message; the job can't be exported.
    var trimProblem: String? {
        guard let job = selectedJob, QueueManager.blockingReason(for: job) == ClipTimeline.trimTooShortMessage
        else { return nil }
        return ClipTimeline.trimTooShortMessage + ". Leave at least one second between In and Out; this job can’t be exported until then."
    }

    /// The trimmed music's length and the clip's, for the note under the Trim section.
    var trimSummary: String? {
        guard let job = selectedJob, let duration = selectedDuration, duration > 0 else { return nil }
        let timeline = ClipTimeline(duration: duration, trim: job.trim)
        var line = "Music " + MarkerTime.format(timeline.musicDuration)
        if timeline.isTrimmed { line += " of " + MarkerTime.format(duration) }
        if timeline.preRollFrames > 0 {
            line += " · clip " + MarkerTime.format(Double(timeline.preRollFrames) / Double(timeline.frameRate)
                                                   + timeline.musicDuration) + " with the slate"
        }
        return line
    }

    /// I or O: the point goes to the source time under the playhead (the in point on the slate).
    func setTrimPointAtPlayhead(_ edge: TrimEdge) {
        guard canEdit, let job = selectedJob, let duration = selectedDuration, let timeline = previewTimeline
        else { NSSound.beep(); return }
        let seconds = timeline.sourceSeconds(at: frame)
        trimMessage = nil
        setTrim(edge == .inPoint ? job.trim.settingIn(seconds, duration: duration)
                                 : job.trim.settingOut(seconds, duration: duration))
        status = (edge == .inPoint ? "In" : "Out") + " set at " + MarkerTime.format(seconds) + "."
        statusHelp = nil
    }

    /// An In or Out time typed in the Job tab (seconds or M:SS.ff); empty clears that point.
    func commitTrimPoint(_ edge: TrimEdge, text: String) {
        guard let job = selectedJob, let duration = selectedDuration else { return }
        let typed = text.trimmingCharacters(in: .whitespaces)
        let current = edge == .inPoint ? job.trim.inPoint : job.trim.outPoint
        // Leaving the field without changing it changes nothing.
        if typed == (current.map(MarkerTime.format) ?? "") { trimMessage = nil; return }
        var seconds: Double?
        if !typed.isEmpty {
            guard let value = MarkerTime.parse(typed) else {
                trimMessage = "“\(text)” is not a time. Type seconds (83.5) or M:SS.ff (1:23.50); leave it empty for the "
                    + (edge == .inPoint ? "start." : "end.")
                return
            }
            seconds = value
        }
        trimMessage = nil
        setTrim(edge == .inPoint ? job.trim.settingIn(seconds, duration: duration)
                                 : job.trim.settingOut(seconds, duration: duration))
    }

    func selectFade(_ edge: TrimEdge, seconds: Double) {
        guard let job = selectedJob else { return }
        var trim = job.trim
        if edge == .inPoint { trim.fadeIn = seconds } else { trim.fadeOut = seconds }
        setTrim(trim)
    }

    func selectPreRoll(_ seconds: Double) {
        guard let job = selectedJob else { return }
        var trim = job.trim
        trim.preRoll = seconds
        setTrim(trim)
    }

    /// Stores the selected job's trim (fields, keys, pop-ups, and every monitor handle drag step)
    /// and keeps the playhead on the same source time, inside the new range; on the slate it
    /// stays on the slate while there is one.
    func setTrim(_ trim: TrimSettings, deferringSave: Bool = false) {
        guard canEdit, let job = selectedJob, job.trim != trim else { return }
        let old = previewTimeline
        let onSlate = old?.isSlate(frame) ?? false
        let seconds = old?.sourceSeconds(at: frame)
        editSelected(deferringSave: deferringSave) { $0.trim = trim }
        guard let new = previewTimeline else {
            frame = 0
            return
        }
        let target: Int
        if onSlate, new.preRollPositions > 0 {
            target = min(frame, new.preRollPositions - 1)
        } else if let seconds {
            target = new.position(ofSourceSeconds: seconds)
        } else {
            target = 0
        }
        if hasAudio { seek(frame: target) } else { frame = min(new.positionCount, max(0, target)) }
    }

    /// Apply to All: the selected job's appearance and preset go to every Pending job.
    func applyToAll() {
        guard let id = selectedJobID else { NSSound.beep(); return }
        let pending = applyToAllCount
        let changed = queue.applyToAll(from: id)
        if pending == 0 {
            status = "No other Pending jobs. Apply to All never changes Done, Failed, Cancelled or running jobs."
        } else {
            status = "Applied this job’s appearance and preset to \(pending) Pending job\(pending == 1 ? "" : "s")"
                + (changed < pending ? " (\(pending - changed) already matched)." : ".")
        }
        statusHelp = nil
    }

    private func editSelected(deferringSave: Bool = false, _ change: (inout CueJob) -> Void) {
        guard let id = selectedJobID else { return }
        if !queue.update(id, deferringSave: deferringSave, change) {
            status = "This job is exporting. Its settings are locked."
        }
    }

    // MARK: Loudness (background)

    /// Measures, one at a time, every job that has no loudness yet: added, restored, or left
    /// over from a pass that could not store its result while the job was running.
    private func scheduleLoudness() {
        guard loudnessTask == nil, nextLoudnessJob() != nil else { return }
        let token = UUID()
        loudnessToken = token
        loudnessTask = Task { [weak self] in await self?.drainLoudness(token: token) }
    }

    /// Cancels the pass in flight (its job was removed) and carries on with the next job.
    private func restartLoudness() {
        loudnessTask?.cancel()
        loudnessTask = nil
        measuringJobID = nil
        scheduleLoudness()
    }

    /// Measure Again, after a failed pass.
    func measureLoudnessAgain() {
        guard let id = selectedJobID else { return }
        loudnessFailures[id] = nil
        loudnessAttempted.remove(id)
        scheduleLoudness()
    }

    private func nextLoudnessJob() -> CueJob? {
        queue.jobs.first { job in
            guard job.loudness == nil, !loudnessAttempted.contains(job.id), !job.status.isActive else { return false }
            if case .done = job.status { return false }
            if case .failed(let reason, _) = job.status, reason == QueueManager.sourceNotFound { return false }
            return FileManager.default.fileExists(atPath: job.sourcePath)
        }
    }

    /// The pass reads the source file. Its integrated loudness and range match the decoded CAF
    /// the export reads; for a mono source the stereo CAF's true peak is 3 dB lower than measured
    /// here, so a peak-limited gain errs on the quiet side.
    private func drainLoudness(token: UUID) async {
        while !Task.isCancelled, let job = nextLoudnessJob() {
            measuringJobID = job.id
            loudnessAttempted.insert(job.id)
            do {
                let measurement = try await LoudnessAnalyzer.measure(job.sourceURL)
                guard !Task.isCancelled else { break }
                // Refused while the job runs: measured again when the queue has finished.
                if !queue.update(job.id, { $0.loudness = measurement }) { loudnessAttempted.remove(job.id) }
            } catch is CancellationError {
                break
            } catch {
                guard !Task.isCancelled else { break }
                loudnessFailures[job.id] = error.localizedDescription
            }
        }
        guard loudnessToken == token else { return }
        measuringJobID = nil
        loudnessTask = nil
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
    /// A Done job is exported again under a new name; the file it wrote is never overwritten.
    func exportSelected() {
        guard let job = selectedJob, canExportSelected else { NSSound.beep(); return }
        if case .done = job.status {
            queue.reexport(job.id)
        } else if job.status.canRetry {
            queue.retry(job.id)
        }
        let fullRunActive = queue.isRunning
        prepareForExport()
        queue.start(only: [job.id])
        if let current = queue.selectedJob, current.status == .pending, queue.isRunning {
            // A full run in progress does not take a second scope; the job goes in list order.
            status = fullRunActive
                ? current.sourceURL.lastPathComponent + " will export in its turn."
                : "Exporting " + current.sourceURL.lastPathComponent + "…"
        }
    }

    /// Export Selected to Folder…: points the selected job at a folder, then exports it.
    func exportSelectedToFolder() {
        guard let job = selectedJob, canExportSelected else { NSSound.beep(); return }
        if let override = queue.destinationOverride {
            status = "Every job goes to “" + override.lastPathComponent + "”. Choose Beside source in the queue footer to pick a folder per job."
            NSSound.beep()
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        let id = job.id
        present(panel) { [weak self] urls in
            guard let self, let folder = urls.first else { return }
            guard self.queue.update(id, { $0.destinationFolder = folder.path }) else {
                self.status = "This job is exporting. Its settings are locked."
                NSSound.beep()
                return
            }
            self.exportSelected()
        }
    }

    func cancelJob(_ id: UUID) { queue.cancel(id) }

    func retryJob(_ id: UUID) {
        guard queue.retry(id) else { NSSound.beep(); return }
        scheduleLoudness()
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
        endEditing()
        // The previewed job may become the running one; its preview stops with the lock.
        resumeAfterScrub = false
        haltPlayer()
        syncPlaying()
    }

    /// Commits any field being edited, on whichever inspector tab is showing, so the job the
    /// queue copies has the typed value.
    private func endEditing() {
        window?.makeFirstResponder(nil)
    }

    // MARK: Destination

    /// The queue footer's destination: `nil` writes each job beside its source.
    func setQueueDestination(_ folder: URL?) {
        queue.setDestinationOverride(folder)
        if let folder {
            status = "Every job is written to " + folder.path + "."
        } else {
            status = "Each job is written beside its audio file."
        }
        statusHelp = nil
    }

    /// Destination pop-up → Choose Folder….
    func chooseQueueDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder every job in the queue is written to."
        if let current = queue.destinationOverride { panel.directoryURL = current }
        present(panel) { [weak self] urls in
            guard let folder = urls.first else { return }
            self?.setQueueDestination(folder)
        }
    }

    // MARK: Unwritable folders

    private static func folderKey(_ url: URL) -> String { url.standardizedFileURL.path }

    /// A folder became unwritable: its jobs are Paused and the operator is asked for a new one,
    /// once per folder. Further folders are asked about after the current prompt.
    private func unwritableFoldersChanged() {
        let folders = queue.unwritableFolders
        promptedFolders.formIntersection(folders.map(Self.folderKey))
        guard !isPromptingFolder,
              let folder = folders.first(where: { !promptedFolders.contains(Self.folderKey($0)) }) else { return }
        promptedFolders.insert(Self.folderKey(folder))
        let count = queue.pausedJobs(in: folder).count
        guard count > 0 else { return }
        isPromptingFolder = true
        status = "Paused \(count) job\(count == 1 ? "" : "s"): can’t write to " + folder.path
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Can’t write to “" + folder.lastPathComponent + "”."
        alert.informativeText = "\(count) job\(count == 1 ? " that exports" : "s that export") there \(count == 1 ? "is" : "are") paused. Choose another folder to resume \(count == 1 ? "it" : "them"), or leave \(count == 1 ? "it" : "them") paused and use Choose Folder… on a paused row later.\n\n" + folder.path
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Leave Paused")
        present(alert) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                // Let the alert's sheet end before the panel's begins.
                DispatchQueue.main.async { self.chooseReplacementFolder(for: folder) }
            } else {
                self.finishFolderPrompt()
            }
        }
    }

    /// A paused row's Choose Folder…: asks for a new folder for every job paused with it.
    func choosePausedFolder(for id: UUID) {
        guard let job = queue.job(id), job.status == .paused else { NSSound.beep(); return }
        guard !isPromptingFolder else { NSSound.beep(); return }
        isPromptingFolder = true
        chooseReplacementFolder(for: queue.effectiveFolder(for: job))
    }

    private func chooseReplacementFolder(for folder: URL) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Resume Here"
        panel.message = "Choose a folder for the jobs paused because “" + folder.lastPathComponent + "” can’t be written."
        present(panel, then: { [weak self] urls in
            guard let self else { return }
            if let newFolder = urls.first { self.resumePaused(in: folder, newFolder: newFolder) }
            self.finishFolderPrompt()
        }, cancelled: { [weak self] in
            self?.status = "The paused jobs wait for a folder. Use Choose Folder… on a paused row."
            self?.finishFolderPrompt()
        })
    }

    /// Points the paused jobs at `newFolder` and exports them: they join a running queue, or run
    /// on their own once it has ended.
    private func resumePaused(in folder: URL, newFolder: URL) {
        let resumed = queue.resumePaused(in: folder, newFolder: newFolder)
        promptedFolders.remove(Self.folderKey(folder))
        guard !resumed.isEmpty else { return }
        queue.start(only: Set(resumed))
        status = "Resumed \(resumed.count) job\(resumed.count == 1 ? "" : "s") in " + newFolder.path + "."
        statusHelp = nil
    }

    private func finishFolderPrompt() {
        isPromptingFolder = false
        unwritableFoldersChanged()
    }

    // MARK: Helpers

    private func present(_ alert: NSAlert, then handler: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }

    private func present(_ panel: NSOpenPanel, then handler: @escaping ([URL]) -> Void,
                         cancelled: @escaping () -> Void) {
        if let window, window.isVisible {
            panel.beginSheetModal(for: window) { response in
                if response == .OK { handler(panel.urls) } else { cancelled() }
            }
        } else if panel.runModal() == .OK {
            handler(panel.urls)
        } else {
            cancelled()
        }
    }

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
