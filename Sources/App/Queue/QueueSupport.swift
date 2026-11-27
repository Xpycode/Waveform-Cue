import CueCore
import Foundation
import UniformTypeIdentifiers

/// App-side wiring for the batch queue: where it is stored and how outputs are named.
enum QueueSupport {
    /// `~/Library/Application Support/Waveform Cue/`, holding `queue.json`.
    static var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Waveform Cue", isDirectory: true)
    }

    /// The queue, saved in `storageDirectory`, holding a power assertion while it exports.
    ///
    /// `MXFJobExporter` decodes through `JobAudioLifetime.exportAudio(for:source:)`, so the
    /// running job's CAF lives in the same capped workspace as the selected job's. Its gain is
    /// the job's Normalise to -23 LUFS setting applied to its stored loudness.
    @MainActor
    static func makeManager(audio: JobAudioLifetime) -> QueueManager {
        let exporter = MXFJobExporter(audio: audio, gain: { MXFJobExporter.normalisationGain(for: $0) })
        let manager = QueueManager(storageDirectory: storageDirectory, exporter: exporter,
                                   sleep: SleepAssertion())
        manager.outputNamer = outputName
        return manager
    }

    /// The decoded-audio owner: one workspace in the session's temporary folder (deleted on quit),
    /// at most two CAFs (the selected job and the running job, or a file being added).
    @MainActor
    static func makeAudioLifetime() -> JobAudioLifetime {
        JobAudioLifetime(workspace: JobWorkspace())
    }

    /// Folders the restored queue writes to: each job's own folder (or its source's), the folder
    /// of a destination already chosen, and the queue-wide override.
    @MainActor
    static func exportFolders(of queue: QueueManager) -> [URL] {
        var folders = queue.jobs.flatMap { job -> [URL] in
            [job.destinationFolder.map { URL(fileURLWithPath: $0) } ?? job.sourceURL.deletingLastPathComponent(),
             job.outputURL?.deletingLastPathComponent()].compactMap { $0 }
        }
        if let override = queue.destinationOverride { folders.append(override) }
        return folders
    }

    /// At launch, off the main thread: claims this session's CAF folder, deletes CAF folders left
    /// by earlier launches that crashed, and hidden partial MXFs older than ten minutes in
    /// `exportFolders`.
    static func removeLeftovers(exportFolders: [URL]) {
        Task.detached(priority: .utility) {
            try? JobWorkspace.claimSessionDirectory()
            JobWorkspace.removeStaleSessionDirectories()
            JobWorkspace.removeStaleExportTemps(in: exportFolders, olderThan: 600)
        }
    }

    /// The job's filename template resolved with `FilenameTemplate.resolve` in `folder`.
    static func outputName(for job: CueJob, in folder: URL, isTaken: (URL) -> Bool) -> URL {
        let name = FilenameTemplate.resolve(job.filenameTemplate, name: job.sourceName,
                                            preset: (ExportPreset.preset(for: job.presetID) ?? .default).name) { candidate in
            isTaken(folder.appendingPathComponent(candidate))
        }
        return folder.appendingPathComponent(name)
    }
}

/// Turns dropped or opened items into the audio files to queue.
enum AudioIngest {
    struct Expansion: Equatable {
        /// Supported files in drop order; a folder contributes its contents sorted by name.
        var files: [URL] = []
        /// Items skipped because they are not audio.
        var skipped = 0
    }

    /// Files keep their order; a folder is replaced by its visible files (not its subfolders),
    /// sorted by name as Finder sorts them. Anything that is not audio is counted as skipped.
    static func expand(_ urls: [URL], fileManager: FileManager = .default) -> Expansion {
        var result = Expansion()
        for url in urls {
            if isDirectory(url) {
                let contents = (try? fileManager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentTypeKey],
                    options: [.skipsHiddenFiles])) ?? []
                let files = contents.filter { !isDirectory($0) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                for file in files { take(file, into: &result) }
            } else {
                take(url, into: &result)
            }
        }
        return result
    }

    static func isSupported(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .audio) ?? false
    }

    static func summary(skipped: Int) -> String? {
        guard skipped > 0 else { return nil }
        return skipped == 1 ? "Skipped 1 file that is not audio." : "Skipped \(skipped) files that are not audio."
    }

    private static func take(_ url: URL, into result: inout Expansion) {
        if isSupported(url) { result.files.append(url) } else { result.skipped += 1 }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}

/// FFmpeg processes this app started (decodes, loudness passes, exports), found by listing the
/// app's child processes, so quitting can wait until they have gone.
enum EncoderProcesses {
    /// PIDs of running children whose executable is named `ffmpeg`.
    static func running() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 256)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listchildpids(getpid(), buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return pids.prefix(Int(min(count, Int32(pids.count)))).filter { pid in
            guard pid > 0 else { return false }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            // A child that has exited (a zombie not yet reaped) has no path any more.
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            return URL(fileURLWithPath: String(cString: path)).lastPathComponent == "ffmpeg"
        }
    }

    static func anyRunning() -> Bool { !running().isEmpty }

    /// Polls until no FFmpeg child is left, or `timeout` seconds have passed.
    static func waitUntilNoneRunning(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while anyRunning(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
