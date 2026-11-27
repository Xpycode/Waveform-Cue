import CueCore
import Foundation

/// Exports queue jobs with the preset-driven engine (task 3.1). Replaces `LegacyExportAdapter`,
/// which always wrote build 10's MPEG-2.
///
/// For each job: resolve the preset (an empty or unknown ID means the default, AVC-Intra 100
/// 1080i50), check the destination before decoding (writable, and room for the MXF plus the
/// CAF when that will be decoded onto the same volume), acquire the CAF through the
/// `JobAudioLifetime` (the running role, so the two-CAF cap holds), reuse the job's stored
/// analysis (analyse only a legacy job without one), build the timeline from the job's trim,
/// markers and countdown target, and write `job.outputURL`.
struct MXFJobExporter: JobExporting {
    let audio: JobAudioLifetime
    let encoder: URL
    /// Loudness gain for a job in dB. The job has no Normalise setting yet (task 4.1), so the
    /// default leaves the audio untouched; 4.1 passes `Loudness.normalisation(for:).gainDB`
    /// for jobs with Normalise on.
    let gain: @Sendable (CueJob) -> Double

    init(audio: JobAudioLifetime, encoder: URL = PreparedAudio.encoder,
         gain: @escaping @Sendable (CueJob) -> Double = { _ in 0 }) {
        self.audio = audio
        self.encoder = encoder
        self.gain = gain
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
            let workspace = audio.workspace
            let decoded = await workspace.isReady(job.id)
            let caf = !decoded && DiskSpace.sameVolume(workspace.directory, folder) ? DiskSpace.cafBytes(seconds: seconds) : 0
            try DiskSpace.preflight(folder: folder, required: DiskSpace.requiredBytes(
                preset: preset, timeline: estimate, layout: job.layout, pendingCAFBytes: caf))
        } else {
            try DiskSpace.probeWritable(folder)
        }

        let lifetime = self.audio
        defer { Task { @MainActor in lifetime.exportEnded(job.id) } }
        let pcm = try await lifetime.exportAudio(for: job.id, source: job.sourceURL)
        let encoder = self.encoder
        let stored = job.analysis
        let worker = Task.detached(priority: .userInitiated) { () throws -> URL in
            let track = try stored.map { AudioTrack(url: job.sourceURL, analysis: $0, audio: pcm) }
                ?? AudioTrack.analyse(job.sourceURL, audio: pcm)
            let timeline = MXFExport.timeline(for: track, preset: preset, trim: job.trim,
                                              markers: track.markers.applyingEdits(from: job.markers),
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
        return try result.get()
    }
}
