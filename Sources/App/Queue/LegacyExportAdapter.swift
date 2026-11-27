import CueCore
import Foundation

/// Exports a queued job through build 10's engine (`MXFExport.run`, MPEG-2 50 Mb/s 1080p25,
/// stereo PCM). Task 3.1 replaces it with the preset-driven `MXFJobExporter`.
///
/// The queue calls `export` on a detached task. The source is decoded here, so the decoded PCM
/// exists only for the running job and is deleted when the export ends. `MXFExport.run` writes
/// a hidden `.waveform-cue-<UUID>.mxf` beside the destination, removes it on every failure or
/// cancellation (its `defer`), checks cancellation once more after the encoder exits, and only
/// then moves the finished file into place, so a cancel never leaves a partial file.
struct LegacyExportAdapter: JobExporting {
    /// What this adapter writes, whatever the job's preset says (named in `{preset}`).
    static let preset = ExportPreset.mpeg2_1080p25
    static let encodingFailedPrefix = "MXF encoding failed."

    let encoder: URL

    init(encoder: URL = PreparedAudio.encoder) { self.encoder = encoder }

    func export(_ job: CueJob, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let destination = job.outputURL else {
            throw JobExportError.failed(reason: "No destination was chosen for this job.", log: "")
        }
        let folder = destination.deletingLastPathComponent()
        try Self.checkWritable(folder)
        try Task.checkCancellation()

        let track: AudioTrack
        do {
            track = try AudioTrack.read(job.sourceURL, encoder: encoder)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JobExportError.failed(reason: error.localizedDescription, log: "")
        }
        try Task.checkCancellation()

        do {
            try MXFExport.run(track: track, label: job.label, appearance: job.appearance,
                              encoder: encoder, destination: destination, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let unwritable = Self.unwritableReason(folder) {
                throw JobExportError.destinationUnwritable(folder: folder, reason: unwritable)
            }
            throw Self.mapped(error)
        }
        return destination
    }

    /// Splits `MXFExport`'s "MXF encoding failed. <log tail>" into a reason and the log.
    static func mapped(_ error: Error) -> JobExportError {
        let message = error.localizedDescription
        if message.hasPrefix(encodingFailedPrefix) {
            let log = message.dropFirst(encodingFailedPrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(reason: encodingFailedPrefix, log: log)
        }
        return .failed(reason: message, log: "")
    }

    static func checkWritable(_ folder: URL) throws {
        if let reason = unwritableReason(folder) {
            throw JobExportError.destinationUnwritable(folder: folder, reason: reason)
        }
    }

    /// `nil` when `folder` is an existing, writable folder.
    static func unwritableReason(_ folder: URL) -> String? {
        var isDirectory: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return "The folder does not exist."
        }
        guard fm.isWritableFile(atPath: folder.path) else {
            return "You do not have permission to write there."
        }
        return nil
    }
}
