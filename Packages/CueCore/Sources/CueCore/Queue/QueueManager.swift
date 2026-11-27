import Foundation
import Observation

// The batch queue's logic (spec B): a serial export loop over `CueJob`s with cancel, stop,
// retry, restore and pause-on-unwritable-folder. The export work and sleep prevention are
// injected, so the logic is tested without FFmpeg.

// MARK: - Injected work

/// Exports one job. The job arrives with `outputPath` resolved; the exporter writes there
/// (through a hidden temporary file, leaving nothing behind on failure or cancellation) and
/// returns the file it wrote. It must stop promptly when its task is cancelled, throwing
/// `CancellationError`. `progress` may be called from any thread, as often as it likes; the
/// queue coalesces it.
public protocol JobExporting: Sendable {
    func export(_ job: CueJob, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

/// Prevents idle sleep for the whole batch: `begin` when a queue run starts, `end` once it ends.
public protocol SleepPreventing: AnyObject {
    func begin(reason: String)
    func end()
}

/// A sleep preventer that does nothing (previews, tests).
public final class NoSleepPrevention: SleepPreventing {
    public init() {}
    public func begin(reason: String) {}
    public func end() {}
}

/// Errors an exporter throws so the queue can tell them apart.
public enum JobExportError: LocalizedError, Equatable {
    /// The destination folder cannot be written. The queue pauses every job that uses the
    /// folder instead of failing them.
    case destinationUnwritable(folder: URL, reason: String)
    /// The encoder failed; `log` is the tail of its output for the row's disclosure.
    case failed(reason: String, log: String)

    public var errorDescription: String? {
        switch self {
        case .destinationUnwritable(let folder, let reason):
            return "Cannot write to \(folder.lastPathComponent): \(reason)"
        case .failed(let reason, _):
            return reason
        }
    }
}

// MARK: - Progress coalescing (cookbook 177)

/// Throttles a hot progress callback to about 10 updates a second. Thread-safe; the clock is
/// injectable and monotonic so the rate is testable without sleeping.
public final class ProgressCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private let intervalNanos: UInt64
    private let now: @Sendable () -> UInt64
    private var lastEmit: UInt64?
    private var lastValue: Double = -1

    public init(interval: TimeInterval = 0.1,
                now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
        self.intervalNanos = UInt64(max(0, interval) * 1_000_000_000)
        self.now = now
    }

    /// Returns the value to publish, or `nil` to swallow this tick. The first tick and the
    /// first tick reaching 100 % always pass; values are clamped to 0…1 and never go back.
    public func offer(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        let clamped = min(1, max(0, value))
        lock.lock(); defer { lock.unlock() }
        guard clamped > lastValue else { return nil }
        let stamp = now()
        let due: Bool
        if let last = lastEmit {
            due = clamped >= 1 || (stamp &- last) >= intervalNanos
        } else {
            due = true
        }
        guard due else { return nil }
        lastEmit = stamp
        lastValue = clamped
        return clamped
    }
}

// MARK: - Manager

@MainActor
@Observable
public final class QueueManager {
    public static let sourceNotFound = "Source not found"
    /// The job's safe zones leave no room for the picture (spec F); it cannot be exported.
    public nonisolated static let tooLittleRoom = "Safe zones leave too little room"

    /// Why a job cannot be exported as it is set up, or `nil` when it can. Start Queue fails such
    /// a job with this reason instead of exporting it, and the app disables Export Selected.
    /// Checked: the appearance's layout fits, the start timecode is HH:MM:SS:FF at 25 fps, and a
    /// trim leaves at least one second ("Trim range too short"). The trim is checked against the
    /// source duration when it is known, otherwise against the in and out points alone.
    public nonisolated static func blockingReason(for job: CueJob) -> String? {
        if !job.appearance.layout.fits { return tooLittleRoom }
        if Timecode(job.startTimecode) == nil {
            return "Start timecode “\(job.startTimecode)” is not HH:MM:SS:FF at 25 fps."
        }
        if let seconds = job.analysis?.seconds ?? job.peaks?.seconds, seconds > 0 {
            if (try? ClipTimeline(duration: seconds, trim: job.trim).validate()) == nil {
                return ClipTimeline.trimTooShortMessage
            }
        } else if let start = job.trim.inPoint, let end = job.trim.outPoint,
                  end - start < ClipTimeline.minimumTrimSeconds - 1e-8 {
            return ClipTimeline.trimTooShortMessage
        }
        return nil
    }

    /// The jobs in list order (export order).
    public private(set) var jobs: [CueJob] = []
    public private(set) var selectedJobID: UUID?
    /// Queue-wide output folder; wins over each job's own destination.
    public private(set) var destinationOverride: URL?
    /// True from Start Queue until the loop has ended (including after Stop, until the
    /// current job has wound down).
    public private(set) var isRunning = false
    /// Stop Queue was pressed and the current job is winding down.
    public private(set) var isStopping = false
    /// The job being exported right now.
    public private(set) var currentJobID: UUID?
    /// Folders that became unwritable; their jobs are Paused until `resumePaused(in:newFolder:)`.
    public private(set) var unwritableFolders: [URL] = []
    /// Set when the queue could not be read or saved (shown to the operator).
    public private(set) var persistenceProblem: String?
    /// Where an unreadable queue file was copied on launch.
    public private(set) var recoveryFile: URL?

    /// Builds the destination for a job in `folder`, choosing a name for which `isTaken` is
    /// false. The default expands `{name}` and `{preset}` and adds " 2", " 3"…; the app
    /// replaces it with `FilenameTemplate.resolve`.
    @ObservationIgnored
    public var outputNamer: (_ job: CueJob, _ folder: URL, _ isTaken: (URL) -> Bool) -> URL = QueueManager.defaultOutputName

    @ObservationIgnored private let store: QueueStore
    @ObservationIgnored private let exporter: any JobExporting
    @ObservationIgnored private let sleep: any SleepPreventing
    @ObservationIgnored private let fileExists: (URL) -> Bool
    @ObservationIgnored private let makeCoalescer: () -> ProgressCoalescer

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var producer: Task<URL, Error>?
    @ObservationIgnored private var runToken: UUID?
    @ObservationIgnored private var cancelRequested = false
    @ObservationIgnored private var saveFailed = false
    /// A save deferred by `update(_:deferringSave:_:)`, written by the next save or `flushPendingSave()`.
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    /// How long a deferred save waits for further edits (label keystrokes) before writing.
    @ObservationIgnored public var deferredSaveDelay: TimeInterval = 0.5
    /// Jobs the current run may export; `nil` means every pending job.
    @ObservationIgnored private var runScope: Set<UUID>?
    /// Jobs counted in the overall progress of the current run.
    private var runJobIDs: [UUID] = []

    /// - Parameters:
    ///   - storageDirectory: the folder holding `queue.json` (created on first save).
    ///   - fileExists: test seam for source and destination checks.
    ///   - progressCoalescer: test seam; a fresh coalescer is made for every job.
    public convenience init(storageDirectory: URL, exporter: any JobExporting,
                            sleep: any SleepPreventing = NoSleepPrevention(),
                            fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                            progressCoalescer: @escaping () -> ProgressCoalescer = { ProgressCoalescer() }) {
        self.init(store: QueueStore(directory: storageDirectory), exporter: exporter, sleep: sleep,
                  fileExists: fileExists, progressCoalescer: progressCoalescer)
    }

    /// Same, with a store built by the caller (tests use its copy seam).
    public init(store: QueueStore, exporter: any JobExporting,
                sleep: any SleepPreventing = NoSleepPrevention(),
                fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                progressCoalescer: @escaping () -> ProgressCoalescer = { ProgressCoalescer() }) {
        self.store = store
        self.exporter = exporter
        self.sleep = sleep
        self.fileExists = fileExists
        self.makeCoalescer = progressCoalescer
        restore()
    }

    public var storeFile: URL { store.fileURL }
    public var isWriteBlocked: Bool { store.isWriteBlocked }

    // MARK: Queries

    public func job(_ id: UUID) -> CueJob? { jobs.first { $0.id == id } }
    public var selectedJob: CueJob? { selectedJobID.flatMap(job) }

    /// The running job's settings are locked; every other job stays editable.
    public func isLocked(_ id: UUID) -> Bool { job(id)?.status.isActive ?? false }

    /// Overall progress of the current run (0…1), or `nil` when idle. A Paused job is still
    /// owed to the run (it returns to Pending on resume), so it counts as not started rather
    /// than finished; the bar never reaches 100 % and then goes back.
    public var overallProgress: Double? {
        guard isRunning, !runJobIDs.isEmpty else { return nil }
        let total = runJobIDs.reduce(0.0) { sum, id in
            guard let status = job(id)?.status else { return sum + 1 }
            switch status {
            case .done, .failed, .cancelled: return sum + 1
            case .exporting(let p): return sum + p
            case .pending, .preparing, .paused: return sum
            }
        }
        return min(1, total / Double(runJobIDs.count))
    }

    /// The folder a job will be written to: the queue override, else its own folder, else
    /// beside its source.
    public func effectiveFolder(for job: CueJob) -> URL {
        if let override = destinationOverride { return override }
        if let folder = job.destinationFolder { return URL(fileURLWithPath: folder) }
        return job.sourceURL.deletingLastPathComponent()
    }

    // MARK: Editing

    /// Appends jobs in order. A job arriving as Preparing or Exporting is reset to Pending;
    /// a Failed job (for example a decode failure while adding) is kept as it is.
    public func add(_ newJobs: [CueJob]) {
        let existing = Set(jobs.map(\.id))
        for var job in newJobs where !existing.contains(job.id) {
            if job.status.isActive { job.status = .pending }
            jobs.append(job)
            if isRunning, runScope == nil, job.status == .pending { runJobIDs.append(job.id) }
        }
        persist()
    }

    public func add(_ job: CueJob) { add([job]) }

    /// Removes jobs. The running job is not removed; cancel it first.
    @discardableResult
    public func remove(_ ids: Set<UUID>) -> Set<UUID> {
        let removable = Set(jobs.filter { ids.contains($0.id) && !$0.status.isActive }.map(\.id))
        guard !removable.isEmpty else { return [] }
        jobs.removeAll { removable.contains($0.id) }
        runJobIDs.removeAll { removable.contains($0) }
        if let selected = selectedJobID, removable.contains(selected) { selectedJobID = nil }
        persist()
        return removable
    }

    @discardableResult
    public func remove(_ id: UUID) -> Bool { !remove([id]).isEmpty }

    /// Moves jobs, as `Array.move(fromOffsets:toOffset:)`. List order is export order.
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.filter { jobs.indices.contains($0) }.map { jobs[$0] }
        guard !moving.isEmpty else { return }
        let target = destination - source.filter { $0 < destination }.count
        var rest = jobs
        for index in source.sorted(by: >) where rest.indices.contains(index) { rest.remove(at: index) }
        rest.insert(contentsOf: moving, at: min(max(0, target), rest.count))
        jobs = rest
        persist()
    }

    public func select(_ id: UUID?) {
        selectedJobID = id.flatMap { job($0) == nil ? nil : $0 }
    }

    /// Edits one job. Refused (returns false) for the running job. The ID and status cannot
    /// be changed this way. A change to anything that shapes the output name clears the
    /// resolved destination so it is chosen again.
    /// With `deferringSave`, the change is saved after `deferredSaveDelay` without further deferred
    /// edits (or with the next ordinary save, or `flushPendingSave()`), so typing a label does not
    /// rewrite `queue.json`, stored waveforms and all, on every keystroke.
    @discardableResult
    public func update(_ id: UUID, deferringSave: Bool = false, _ change: (inout CueJob) -> Void) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].status.isActive else {
            return false
        }
        let before = jobs[index]
        var edited = before
        change(&edited)
        edited.status = before.status
        // A Done job keeps the path of the file it wrote; any other job chooses its name again
        // (so a Failed or Cancelled job's Retry does not reuse a name its settings no longer give).
        if Self.namingChanged(before, edited), !Self.isDone(before.status) { edited.outputPath = nil }
        guard edited != before else { return true }
        jobs[index] = edited
        if deferringSave { schedulePersist() } else { persist() }
        return true
    }

    /// Apply to All: copies the appearance and preset of `sourceID` to every Pending job
    /// (never Done, Failed, Cancelled, Paused or running jobs). Returns how many changed.
    @discardableResult
    public func applyToAll(from sourceID: UUID) -> Int {
        guard let source = job(sourceID) else { return 0 }
        var changed = 0
        for index in jobs.indices where jobs[index].id != sourceID && jobs[index].status == .pending {
            var job = jobs[index]
            job.appearanceSnapshot = source.appearanceSnapshot
            if job.presetID != source.presetID {
                job.presetID = source.presetID
                job.outputPath = nil
            }
            if job != jobs[index] {
                jobs[index] = job
                changed += 1
            }
        }
        if changed > 0 { persist() }
        return changed
    }

    /// Sets or clears the queue-wide destination. Pending jobs choose their name again.
    public func setDestinationOverride(_ folder: URL?) {
        guard destinationOverride != folder else { return }
        destinationOverride = folder
        for index in jobs.indices where jobs[index].status == .pending { jobs[index].outputPath = nil }
        persist()
    }

    // MARK: Running

    /// Start Queue: exports Pending jobs one at a time in list order. With `only`, exports just
    /// those jobs (Export Selected). While a run is going, `only` jobs join it.
    public func start(only ids: Set<UUID>? = nil) {
        if isRunning {
            guard !isStopping else { return }
            if let ids, runScope != nil {
                runScope?.formUnion(ids)
                runJobIDs += jobs.filter { ids.contains($0.id) && $0.status == .pending && !runJobIDs.contains($0.id) }.map(\.id)
            }
            return
        }
        runScope = ids
        runJobIDs = jobs.filter { $0.status == .pending && (ids?.contains($0.id) ?? true) }.map(\.id)
        guard !runJobIDs.isEmpty else { runScope = nil; return }
        isRunning = true
        isStopping = false
        sleep.begin(reason: "Waveform Cue is exporting a queue")
        loopTask = Task { [weak self] in await self?.runLoop() }
    }

    /// Cancels one job. The running job's exporter is cancelled and the queue moves on once it
    /// has ended; a Pending or Paused job becomes Cancelled at once.
    public func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if id == currentJobID {
            cancelRequested = true
            producer?.cancel()
        } else if jobs[index].status == .pending || jobs[index].status == .paused {
            jobs[index].status = .cancelled
            persist()
        }
    }

    /// Stop Queue: cancels the current job and leaves the rest Pending. The run ends once the
    /// current job's exporter has wound down.
    public func stopQueue() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        producer?.cancel()
    }

    /// Retry: returns a Failed or Cancelled job to Pending. It keeps its previous destination
    /// when nothing is there (a cancelled or failed attempt leaves no file) and no other job
    /// claims it; otherwise it gets the next free name (" 2", " 3"…).
    @discardableResult
    public func retry(_ id: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status.canRetry else { return false }
        jobs[index].status = .pending
        if let previous = jobs[index].outputURL, isFree(previous, for: jobs[index]) {
            jobs[index].outputPath = previous.path
        } else {
            jobs[index].outputPath = resolveOutput(for: jobs[index], avoiding: nil).path
        }
        enlistInRun(id)
        persist()
        return true
    }

    /// Re-export: returns a Done job to Pending with a fresh destination that collides with
    /// neither an existing file, another job nor the file it already wrote, so that file is never
    /// overwritten. The caller then starts it (Export Selected).
    @discardableResult
    public func reexport(_ id: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }), Self.isDone(jobs[index].status) else { return false }
        let previous = jobs[index].outputURL
        jobs[index].status = .pending
        jobs[index].outputPath = resolveOutput(for: jobs[index], avoiding: previous).path
        enlistInRun(id)
        persist()
        return true
    }

    /// Counts a job returned to Pending in the current run's progress when the run will export it.
    private func enlistInRun(_ id: UUID) {
        if isRunning, runScope == nil || runScope?.contains(id) == true, !runJobIDs.contains(id) {
            runJobIDs.append(id)
        }
    }

    /// The Paused jobs that write to `folder`, in list order.
    public func pausedJobs(in folder: URL) -> [UUID] {
        let key = Self.folderKey(folder)
        return jobs.filter { $0.status == .paused && Self.folderKey(effectiveFolder(for: $0)) == key }.map(\.id)
    }

    /// Returns the Paused jobs of `folder` to Pending. With `newFolder`, they (or the queue
    /// override, if that was the unwritable folder) are pointed at it first. Returns the jobs
    /// resumed, so the caller can export them if the queue has stopped meanwhile.
    @discardableResult
    public func resumePaused(in folder: URL, newFolder: URL? = nil) -> [UUID] {
        let key = Self.folderKey(folder)
        let matching = jobs.indices.filter {
            jobs[$0].status == .paused && Self.folderKey(effectiveFolder(for: jobs[$0])) == key
        }
        let resumed = matching.map { jobs[$0].id }
        let overrideWasUnwritable = destinationOverride.map(Self.folderKey) == key
        if let newFolder, overrideWasUnwritable { destinationOverride = newFolder }
        for index in matching {
            if let newFolder, !overrideWasUnwritable { jobs[index].destinationFolder = newFolder.path }
            jobs[index].outputPath = nil
            jobs[index].status = .pending
            enlistInRun(jobs[index].id)
        }
        unwritableFolders.removeAll { Self.folderKey($0) == key }
        persist()
        return resumed
    }

    /// Waits until the current run (if any) has ended.
    public func waitUntilIdle() async {
        await loopTask?.value
    }

    // MARK: Loop

    private func nextJobIndex() -> Int? {
        jobs.firstIndex { $0.status == .pending && (runScope?.contains($0.id) ?? true) }
    }

    private func runLoop() async {
        while !isStopping, let index = nextJobIndex() {
            await run(jobs[index].id)
        }
        isRunning = false
        isStopping = false
        runScope = nil
        runJobIDs = []
        loopTask = nil
        sleep.end()
    }

    private func run(_ id: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard fileExists(jobs[index].sourceURL) else {
            jobs[index].status = .failed(reason: Self.sourceNotFound, log: "")
            persist()
            return
        }
        // Skipped, not exported: the operator fixes the setting and presses Retry.
        if let reason = Self.blockingReason(for: jobs[index]) {
            jobs[index].status = .failed(reason: reason, log: "")
            persist()
            return
        }
        // Keep a destination already chosen (by Retry or an earlier run) while it is still free.
        if jobs[index].outputURL.map(fileExists) ?? true {
            jobs[index].outputPath = resolveOutput(for: jobs[index], avoiding: nil).path
        }
        jobs[index].status = .preparing
        persist()

        let job = jobs[index]
        let token = UUID()
        runToken = token
        currentJobID = id
        cancelRequested = false
        let coalescer = makeCoalescer()
        let sink: @Sendable (Double) -> Void = { [weak self] value in
            guard let value = coalescer.offer(value) else { return }
            Task { @MainActor [weak self] in self?.receive(progress: value, token: token, job: id) }
        }
        let exporter = self.exporter
        let task = Task.detached(priority: .userInitiated) {
            try await exporter.export(job, progress: sink)
        }
        producer = task
        if isStopping { task.cancel() }
        // Wait for the producer's own end, even after a cancel (cookbook 154).
        let result = await task.result

        let wasCancelled = cancelRequested || isStopping
        producer = nil
        runToken = nil
        currentJobID = nil
        cancelRequested = false
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let url):
            jobs[index].status = .done(output: url)
            jobs[index].outputPath = url.path
        case .failure(let error):
            if wasCancelled || error is CancellationError {
                jobs[index].status = .cancelled
            } else if case JobExportError.destinationUnwritable(let folder, _) = error {
                pause(folder: folder, current: index)
            } else if case JobExportError.failed(let reason, let log) = error {
                jobs[index].status = .failed(reason: reason, log: log)
            } else {
                jobs[index].status = .failed(reason: error.localizedDescription, log: "")
            }
        }
        persist()
    }

    private func receive(progress: Double, token: UUID, job id: UUID) {
        guard runToken == token, let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].status.isActive else { return }
        if let current = jobs[index].status.progress, current >= progress { return }
        jobs[index].status = .exporting(progress: progress)
    }

    /// Pauses the job that hit the unwritable folder and every Pending job that shares it.
    private func pause(folder: URL, current index: Int) {
        let failedFolder = effectiveFolder(for: jobs[index])
        let keys: Set<String> = [Self.folderKey(folder), Self.folderKey(failedFolder)]
        jobs[index].status = .paused
        jobs[index].outputPath = nil
        for other in jobs.indices where jobs[other].status == .pending
            && keys.contains(Self.folderKey(effectiveFolder(for: jobs[other]))) {
            jobs[other].status = .paused
            jobs[other].outputPath = nil
        }
        if !unwritableFolders.contains(where: { Self.folderKey($0) == Self.folderKey(failedFolder) }) {
            unwritableFolders.append(failedFolder)
        }
    }

    /// Folder identity for comparisons: a standardised path, so `/a/b` and `/a/b/` match.
    private static func folderKey(_ url: URL) -> String { url.standardizedFileURL.path }

    // MARK: Restore and save

    /// Loads the saved queue. Interrupted and Paused jobs return to Pending; an unfinished job
    /// whose source is missing becomes Failed "Source not found".
    private func restore() {
        let loaded = store.load()
        recoveryFile = loaded.recoveryFile
        persistenceProblem = loaded.problem
        destinationOverride = loaded.document.destinationOverride.map { URL(fileURLWithPath: $0) }
        var restored = loaded.document.jobs
        var seen = Set<UUID>()
        restored.removeAll { !seen.insert($0.id).inserted }
        for index in restored.indices {
            switch restored[index].status {
            case .preparing, .exporting, .paused: restored[index].status = .pending
            default: break
            }
            if case .done = restored[index].status { continue }
            if case .failed(let reason, _) = restored[index].status, reason == Self.sourceNotFound { continue }
            if !fileExists(restored[index].sourceURL) {
                restored[index].status = .failed(reason: Self.sourceNotFound, log: "")
            }
        }
        jobs = restored
        if loaded.problem != nil || restored != loaded.document.jobs { persist() }
    }

    /// Writes a deferred save now, if one is waiting (before quitting).
    public func flushPendingSave() {
        if pendingSave != nil { persist() }
    }

    /// True while a deferred save is waiting.
    public var hasPendingSave: Bool { pendingSave != nil }

    private func schedulePersist() {
        pendingSave?.cancel()
        let delay = UInt64(max(0, deferredSaveDelay) * 1_000_000_000)
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func persist() {
        pendingSave?.cancel()
        pendingSave = nil
        let document = QueueDocument(jobs: jobs, destinationOverride: destinationOverride?.path)
        do {
            try store.save(document)
            if saveFailed {
                saveFailed = false
                persistenceProblem = nil
            }
        } catch {
            saveFailed = true
            persistenceProblem = error.localizedDescription
        }
    }

    // MARK: Naming

    private func resolveOutput(for job: CueJob, avoiding previous: URL?) -> URL {
        let folder = effectiveFolder(for: job)
        let others = Set(jobs.filter { $0.id != job.id }.compactMap { $0.outputURL?.standardizedFileURL.path })
        let avoid = previous?.standardizedFileURL.path
        return outputNamer(job, folder) { [fileExists] candidate in
            let key = candidate.standardizedFileURL.path
            return key == avoid || others.contains(key) || fileExists(candidate)
        }
    }

    /// True when `url` is in the job's folder, absent on disk and claimed by no other job.
    private func isFree(_ url: URL, for job: CueJob) -> Bool {
        let key = url.standardizedFileURL.path
        guard Self.folderKey(url.deletingLastPathComponent()) == Self.folderKey(effectiveFolder(for: job)) else { return false }
        if fileExists(url) { return false }
        return !jobs.contains { $0.id != job.id && $0.outputURL?.standardizedFileURL.path == key }
    }

    private static func isDone(_ status: JobStatus) -> Bool {
        if case .done = status { return true }
        return false
    }

    private static func namingChanged(_ a: CueJob, _ b: CueJob) -> Bool {
        a.sourcePath != b.sourcePath || a.filenameTemplate != b.filenameTemplate
            || a.presetID != b.presetID || a.destinationFolder != b.destinationFolder
    }

    /// `{name}` and `{preset}` expanded, path separators removed, then " 2", " 3"… until free.
    public nonisolated static func defaultOutputName(for job: CueJob, in folder: URL,
                                                     isTaken: (URL) -> Bool) -> URL {
        var stem = job.filenameTemplate
            .replacingOccurrences(of: "{name}", with: job.sourceName)
            .replacingOccurrences(of: "{preset}", with: job.presetID.rawValue)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        if stem.isEmpty { stem = job.sourceName }
        var candidate = folder.appendingPathComponent(stem + ".mxf")
        var number = 2
        while isTaken(candidate) {
            candidate = folder.appendingPathComponent("\(stem) \(number).mxf")
            number += 1
        }
        return candidate
    }
}
