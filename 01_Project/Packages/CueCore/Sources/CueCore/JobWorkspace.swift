import Foundation

/// Owns the decoded CAF of each queue job that currently needs one (the selected job and the
/// running job). A CAF is decoded on demand by `acquire(for:source:)` and deleted by `release`.
///
/// The workspace does not evict on its own: the queue decides which jobs hold audio, and the
/// counters (`liveCount`, `peakLiveCount`) let tests prove that never more than two CAFs exist.
/// An in-flight decode counts as live, because its file is already being written.
///
/// Concurrent `acquire` calls for one job share a single decode. Releasing a job while it decodes
/// cancels FFmpeg and returns only once FFmpeg has stopped and the partial file is deleted (until
/// then the decode still counts as live); the waiting `acquire` calls throw `CancellationError`. Cancelling a task that waits in `acquire` releases that job in the same way, since
/// one job has one owner.
public actor JobWorkspace {
    /// Where the CAFs are written.
    public nonisolated let directory: URL
    /// The FFmpeg executable used to decode.
    public nonisolated let encoder: URL

    private enum Slot {
        case decoding(Task<PreparedAudio, Error>, generation: UInt64)
        case ready(PreparedAudio)
    }

    private var slots: [UUID: Slot] = [:]
    private var generation: UInt64 = 0
    /// Cancelled decodes whose FFmpeg has not stopped yet (their partial CAF may still exist).
    private var stopping = 0

    /// Highest number of CAFs that existed at once since this workspace was made.
    public private(set) var peakLiveCount = 0
    /// Number of CAFs that may exist now: jobs holding (or decoding) one, plus cancelled decodes
    /// still stopping.
    public var liveCount: Int { slots.count + stopping }
    /// Jobs holding (or decoding) a CAF now.
    public var liveJobs: Set<UUID> { Set(slots.keys) }

    public init(directory: URL = PreparedAudio.sessionDirectory, encoder: URL = PreparedAudio.encoder) {
        self.directory = directory
        self.encoder = encoder
    }

    /// Whether `job` has a finished CAF (not just one being decoded).
    public func isReady(_ job: UUID) -> Bool {
        if case .ready? = slots[job] { return true }
        return false
    }

    /// The job's decoded audio, decoding `source` first if the job holds none.
    public func acquire(for job: UUID, source: URL) async throws -> PreparedAudio {
        switch slots[job] {
        case .ready(let audio)?:
            return audio
        case .decoding(let task, let generation)?:
            return try await wait(for: task, job: job, generation: generation)
        case nil:
            try Task.checkCancellation()
            generation += 1
            let directory = self.directory, encoder = self.encoder
            let task = Task.detached(priority: .userInitiated) {
                try PreparedAudio.decode(source, encoder: encoder, into: directory)
            }
            slots[job] = .decoding(task, generation: generation)
            peakLiveCount = max(peakLiveCount, liveCount)
            return try await wait(for: task, job: job, generation: generation)
        }
    }

    /// Deletes the job's CAF now, or cancels its decode and waits until FFmpeg has stopped and
    /// the partial file is gone. Does nothing for a job without one. A track still holding the
    /// released `PreparedAudio` points at a deleted file afterwards.
    public func release(_ job: UUID) async {
        switch slots.removeValue(forKey: job) {
        case .ready(let audio)?:
            audio.remove()
        case .decoding(let task, _)?:
            task.cancel()
            stopping += 1
            if case .success(let audio) = await task.result { audio.remove() }
            stopping -= 1
        case nil:
            break
        }
    }

    /// Releases every job (quit), waiting for every cancelled decode to stop.
    public func releaseAll() async {
        await withTaskGroup(of: Void.self) { group in
            for job in Array(slots.keys) { group.addTask { await self.release(job) } }
        }
    }

    private func wait(for task: Task<PreparedAudio, Error>, job: UUID, generation: UInt64) async throws -> PreparedAudio {
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            Task { await self.abandon(job, generation: generation) }
        }
        switch (slots[job], result) {
        case (.decoding(_, let current)?, .success(let audio)) where current == generation:
            slots[job] = .ready(audio)
            return audio
        case (.ready(let ready)?, .success(let audio)) where ready === audio:
            return audio   // another waiter of the same decode got here first
        case (.decoding(_, let current)?, .failure(let error)) where current == generation:
            slots[job] = nil
            throw error
        case (_, .success(let audio)):
            audio.remove()   // released (or re-acquired) while decoding
            throw CancellationError()
        case (_, .failure(let error)):
            throw error is CancellationError ? error : CancellationError()
        }
    }

    private func abandon(_ job: UUID, generation: UInt64) async {
        guard case .decoding(_, let current)? = slots[job], current == generation else { return }
        await release(job)
    }
}

// MARK: - Leftovers from earlier launches

extension JobWorkspace {
    /// Prefix of every session folder of decoded CAFs (`PreparedAudio.sessionDirectory`).
    public nonisolated static let sessionDirectoryPrefix = "WaveformCue-"
    /// Prefix of the hidden files `MXFExport` writes beside a destination (the partial MXF and
    /// the writability probe).
    public nonisolated static let exportTempPrefix = ".waveform-cue-"
    /// The file in a session folder naming the process that owns it.
    nonisolated static let ownerFileName = "owner.pid"

    /// Matches the spelling of UUID().uuidString between the writer's literal prefix and suffix.
    private nonisolated static func hasGeneratedName(_ name: String, prefix: String, suffix: String = "") -> Bool {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let id = String(name.dropFirst(prefix.count).dropLast(suffix.count))
        return UUID(uuidString: id)?.uuidString == id
    }

    /// Marks `directory` (the current session folder, created if needed) as owned by this
    /// process, so another instance's launch cleanup leaves it alone.
    public nonisolated static func claimSessionDirectory(_ directory: URL = PreparedAudio.sessionDirectory,
                                                         pid: Int32 = getpid()) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try String(pid).write(to: directory.appendingPathComponent(ownerFileName), atomically: true, encoding: .utf8)
    }

    /// Deletes session folders of decoded CAFs left by earlier launches. Keeps the current folder,
    /// live owners and recently created ownerless folders that another instance may be claiming.
    @discardableResult
    public nonisolated static func removeStaleSessionDirectories(
        in root: URL = FileManager.default.temporaryDirectory,
        keeping current: URL = PreparedAudio.sessionDirectory,
        isRunning: (Int32) -> Bool = JobWorkspace.processIsRunning) -> [URL] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { return [] }
        let keep = current.standardizedFileURL.path
        let unclaimedCutoff = Date().addingTimeInterval(-600)
        var removed: [URL] = []
        for entry in entries where hasGeneratedName(entry.lastPathComponent, prefix: sessionDirectoryPrefix) {
            guard let values = try? entry.resourceValues(forKeys: keys), values.isDirectory == true,
                  entry.standardizedFileURL.path != keep else { continue }
            do {
                let marker = try String(contentsOf: entry.appendingPathComponent(ownerFileName), encoding: .utf8)
                guard let owner = Int32(marker.trimmingCharacters(in: .whitespacesAndNewlines)), owner > 0 else { continue }
                if owner != getpid(), isRunning(owner) { continue }
            } catch CocoaError.fileReadNoSuchFile {
                guard let modified = values.contentModificationDate, modified < unclaimedCutoff else { continue }
            } catch {
                continue
            }
            if (try? fm.removeItem(at: entry)) != nil { removed.append(entry) }
        }
        return removed
    }

    /// Deletes hidden partial MXFs and writability probes with generated names older than `age` in `folders`.
    /// Missing or unreadable folders are skipped. Returns the files deleted.
    @discardableResult
    public nonisolated static func removeStaleExportTemps(in folders: [URL], olderThan age: TimeInterval = 600,
                                                          now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        var seen: Set<String> = []
        var removed: [URL] = []
        for folder in folders where seen.insert(folder.standardizedFileURL.path).inserted {
            guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [
                .contentModificationDateKey, .isRegularFileKey]) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                guard hasGeneratedName(name, prefix: exportTempPrefix, suffix: ".mxf")
                        || hasGeneratedName(name, prefix: exportTempPrefix + "probe-") else { continue }
                guard let values = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate, now.timeIntervalSince(modified) > age else { continue }
                if (try? fm.removeItem(at: entry)) != nil { removed.append(entry) }
            }
        }
        return removed
    }

    /// Whether a process with `pid` exists (`kill(pid, 0)`; EPERM means it exists under another user).
    public nonisolated static func processIsRunning(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
