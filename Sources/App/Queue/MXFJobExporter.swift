import CueCore
import Foundation

/// Exports queue jobs with the preset-driven engine (task 3.1). Replaces `LegacyExportAdapter`,
/// which always wrote build 10's MPEG-2.
///
/// For each job: resolve the preset (an empty or unknown ID means the default, AVC-Intra 100
/// 1080i50), check the destination before decoding (writable, and room for the MXF plus the
/// CAF when that will be decoded onto the same volume), acquire the CAF through the
/// `JobWorkspace`, re-analyse the peaks from it, build the timeline from the job's trim,
/// markers and countdown target, and write `job.outputURL`.
struct MXFJobExporter: JobExporting {
    let workspace: JobWorkspace
    let encoder: URL
    /// Loudness gain for a job in dB. The job has no Normalise setting yet (task 4.1), so the
    /// default leaves the audio untouched; 4.1 passes `Loudness.normalisation(for:).gainDB`
    /// for jobs with Normalise on.
    let gain: @Sendable (CueJob) -> Double
    /// Whether to delete the job's CAF after the export. The queue keeps it for the job shown
    /// in the monitor (task 3.3 owns that policy).
    let releasesAudio: @Sendable (UUID) async -> Bool

    init(workspace: JobWorkspace, encoder: URL = PreparedAudio.encoder,
         gain: @escaping @Sendable (CueJob) -> Double = { _ in 0 },
         releasesAudio: @escaping @Sendable (UUID) async -> Bool = { _ in true }) {
        self.workspace = workspace
        self.encoder = encoder
        self.gain = gain
        self.releasesAudio = releasesAudio
    }

    func export(_ job: CueJob, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let destination = job.outputURL else {
            throw JobExportError.failed(reason: "The job has no output file name.", log: "")
        }
        let preset = ExportPreset.preset(for: job.presetID) ?? .default
        guard let start = Timecode(job.startTimecode) else {
            throw JobExportError.failed(reason: "Start timecode “\(job.startTimecode)” is not HH:MM:SS:FF at 25 fps.", log: "")
        }
        let appearance = job.appearance
        let gainDB = gain(job)

        // Preflight before decoding, so a full or unwritable disk is reported without work.
        let folder = destination.deletingLastPathComponent()
        if let seconds = job.peaks?.seconds, seconds > 0 {
            let estimate = ClipTimeline(duration: seconds, trim: job.trim, markers: job.markers,
                                        target: appearance.countdownTarget, standard: preset.video.timelineRate)
            try estimate.validate()
            let decoded = await workspace.isReady(job.id)
            let caf = !decoded && DiskSpace.sameVolume(workspace.directory, folder) ? DiskSpace.cafBytes(seconds: seconds) : 0
            try DiskSpace.preflight(folder: folder, required: DiskSpace.requiredBytes(
                preset: preset, timeline: estimate, layout: job.layout, pendingCAFBytes: caf))
        } else {
            try DiskSpace.probeWritable(folder)
        }

        let audio = try await workspace.acquire(for: job.id, source: job.sourceURL)
        let encoder = self.encoder
        let worker = Task.detached(priority: .userInitiated) { () throws -> URL in
            let track = try AudioTrack.analyse(job.sourceURL, audio: audio)
            let timeline = MXFExport.timeline(for: track, preset: preset, trim: job.trim, markers: job.markers,
                                              target: appearance.countdownTarget)
            try timeline.validate()
            let snapshot = MXFExport.Snapshot(track: track, label: job.label, appearance: appearance,
                                              layout: job.layout, startTimecode: start, gainDB: gainDB)
            try MXFExport.run(snapshot: snapshot, preset: preset, timeline: timeline, encoder: encoder,
                              destination: destination, progress: progress)
            return destination
        }
        let result = await withTaskCancellationHandler {
            await worker.result
        } onCancel: {
            worker.cancel()
        }
        if await releasesAudio(job.id) { await workspace.release(job.id) }
        return try result.get()
    }
}
