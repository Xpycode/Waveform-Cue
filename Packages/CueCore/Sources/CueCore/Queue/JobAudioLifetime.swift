import Foundation

/// Decides which queue jobs may hold a decoded CAF and drives a `JobWorkspace` accordingly
/// (spec B edge case: 50 queued jobs never hold more than two decoded files).
///
/// Three roles can ask for audio: the job being exported (`running`), a file being analysed
/// while it is added (`ingest`) and the job shown in the monitor (`selected`). At most
/// `capacity` (two) distinct jobs are *entitled* at once, in that priority order: the running
/// job always is, an added file comes next, and the selected job takes what is left. A selected
/// job squeezed out (a queue running while files are added) keeps its waveform from stored
/// analysis and gets its audio back as soon as a slot frees; `onChange` tells the app.
///
/// Every role change is synchronous on the main actor. A job that loses its entitlement is
/// released through one serial chain, and an acquire starts only once every release scheduled
/// before it has finished, so the workspace never holds more than `capacity` CAFs. A job whose
/// entitlement ends while it decodes has its decode cancelled; the waiting `audio(for:source:)`
/// throws `CancellationError`.
@MainActor
public final class JobAudioLifetime {
    public enum Role: CaseIterable, Sendable {
        case running, ingest, selected
    }

    public nonisolated let workspace: JobWorkspace
    public nonisolated let capacity: Int

    /// Called after the entitled set changes (for example the selected job lost or regained its slot).
    public var onChange: (() -> Void)?

    public private(set) var roles: [Role: UUID] = [:]
    /// The jobs that may hold audio now, in priority order (at most `capacity`).
    public private(set) var entitled: [UUID] = []

    /// Jobs this lifetime has asked the workspace for and not yet released.
    private var held: Set<UUID> = []
    private var chain: Task<Void, Never>?
    private var chainGeneration = 0

    public init(workspace: JobWorkspace, capacity: Int = 2) {
        self.workspace = workspace
        self.capacity = max(1, capacity)
    }

    /// The entitled jobs for a set of role holders: running first, then ingest, then selected,
    /// de-duplicated (one job in two roles needs one CAF) and cut at `capacity`.
    public nonisolated static func entitled(running: UUID?, ingest: UUID?, selected: UUID?,
                                            capacity: Int = 2) -> [UUID] {
        var result: [UUID] = []
        for id in [running, ingest, selected].compactMap({ $0 }) where !result.contains(id) {
            guard result.count < capacity else { break }
            result.append(id)
        }
        return result
    }

    public func isEntitled(_ job: UUID) -> Bool { entitled.contains(job) }

    /// Gives `role` to `job` (or takes it away with `nil`). Jobs no longer entitled are released.
    public func assign(_ role: Role, to job: UUID?) {
        guard roles[role] != job else { return }
        roles[role] = job
        recompute()
    }

    /// The job's decoded audio. Throws `CancellationError` if no role entitles the job, or if it
    /// loses its entitlement before the decode finishes.
    ///
    /// Cancelling the calling task gives up `role` for the job (if it still has it); the decode
    /// itself is cancelled only when no other role keeps the job, so one caller giving up never
    /// breaks another that shares the job's CAF (the selected job that is also running).
    public func audio(for job: UUID, source: URL, as role: Role? = nil) async throws -> PreparedAudio {
        guard entitled.contains(job) else { throw CancellationError() }
        // Let every release scheduled so far finish first, including ones added while waiting.
        await settle()
        guard entitled.contains(job) else { throw CancellationError() }
        try Task.checkCancellation()
        held.insert(job)
        let workspace = self.workspace
        let decode = Task { try await workspace.acquire(for: job, source: source) }
        let result = await withTaskCancellationHandler {
            await decode.result
        } onCancel: {
            Task { @MainActor [weak self] in self?.callerCancelled(job, role: role) }
        }
        switch result {
        case .success(let audio):
            guard entitled.contains(job) else {
                scheduleRelease(job)
                throw CancellationError()
            }
            try Task.checkCancellation()
            return audio
        case .failure(let error):
            // `held` may over-count a job whose decode failed; releasing it later is a no-op.
            if !entitled.contains(job) { scheduleRelease(job) }
            throw error
        }
    }

    /// For an exporter: takes the running role for `job` and returns its audio.
    public func exportAudio(for job: UUID, source: URL) async throws -> PreparedAudio {
        assign(.running, to: job)
        return try await audio(for: job, source: source, as: .running)
    }

    /// For an exporter: gives up the running role if `job` still has it. Its CAF is deleted
    /// unless the job is also selected.
    public func exportEnded(_ job: UUID) {
        if roles[.running] == job { assign(.running, to: nil) }
    }

    /// Clears every role and deletes every CAF (quit).
    public func releaseAll() async {
        roles = [:]
        recompute()
        await chain?.value
        await workspace.releaseAll()
        held = []
    }

    /// Waits until every scheduled release has finished.
    public func settle() async {
        var generation: Int
        repeat {
            generation = chainGeneration
            await chain?.value
        } while generation != chainGeneration
    }

    private func callerCancelled(_ job: UUID, role: Role?) {
        guard let role, roles[role] == job else { return }
        assign(role, to: nil)
    }

    private func recompute() {
        let now = Self.entitled(running: roles[.running], ingest: roles[.ingest],
                                selected: roles[.selected], capacity: capacity)
        guard now != entitled else { return }
        entitled = now
        for job in held where !now.contains(job) { scheduleRelease(job) }
        onChange?()
    }

    private func scheduleRelease(_ job: UUID) {
        held.remove(job)
        let previous = chain
        let workspace = self.workspace
        chainGeneration += 1
        chain = Task {
            await previous?.value
            await workspace.release(job)
        }
    }
}
