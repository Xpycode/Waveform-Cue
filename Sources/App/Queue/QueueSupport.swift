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

    @MainActor
    static func makeManager() -> QueueManager {
        let manager = QueueManager(storageDirectory: storageDirectory, exporter: LegacyExportAdapter())
        manager.outputNamer = outputName
        return manager
    }

    /// The job's filename template resolved with `FilenameTemplate.resolve` in `folder`.
    static func outputName(for job: CueJob, in folder: URL, isTaken: (URL) -> Bool) -> URL {
        let name = FilenameTemplate.resolve(job.filenameTemplate, name: job.sourceName,
                                            preset: LegacyExportAdapter.preset.name) { candidate in
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
