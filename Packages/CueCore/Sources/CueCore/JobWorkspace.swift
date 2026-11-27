import Foundation

/// Owns the decoded CAF of each queue job that currently needs one (the selected job and the
/// running job). A CAF is decoded on demand by `acquire(for:source:)` and deleted by `release`.
///
/// The workspace does not evict on its own: the queue decides which jobs hold audio, and the
/// counters (`liveCount`, `peakLiveCount`) let tests prove that never more than two CAFs exist.
/// An in-flight decode counts as live, because its file is already being written.
///
/// Concurrent `acquire` calls for one job share a single decode. Releasing a job while it decodes
/// cancels FFmpeg; the waiting `acquire` calls throw `CancellationError` and the partial file is
/// deleted. Cancelling a task that waits in `acquire` releases that job in the same way, since
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

    /// Highest number of CAFs that existed at once since this workspace was made.
    public private(set) var peakLiveCount = 0
    /// Number of jobs holding (or decoding) a CAF now.
    public var liveCount: Int { slots.count }
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
            peakLiveCount = max(peakLiveCount, slots.count)
            return try await wait(for: task, job: job, generation: generation)
        }
    }

    /// Deletes the job's CAF now, or cancels its decode. Does nothing for a job without one.
    /// A track still holding the released `PreparedAudio` points at a deleted file afterwards.
    public func release(_ job: UUID) {
        switch slots.removeValue(forKey: job) {
        case .ready(let audio)?: audio.remove()
        case .decoding(let task, _)?: task.cancel()
        case nil: break
        }
    }

    /// Releases every job, for example when the queue window closes.
    public func releaseAll() {
        for job in Array(slots.keys) { release(job) }
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

    private func abandon(_ job: UUID, generation: UInt64) {
        guard case .decoding(_, let current)? = slots[job], current == generation else { return }
        release(job)
    }
}
