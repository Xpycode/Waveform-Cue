import Foundation
import AudioToolbox

/// One PCM source gives waveform analysis, playback and export the same sample zero
/// and end sample, including encoder delay and padding on compressed music.
/// The CAF is deleted when the last reference goes away, or earlier by `JobWorkspace.release`.
public final class PreparedAudio: Sendable {
    public let url: URL
    public static let sessionDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(JobWorkspace.sessionDirectoryPrefix + UUID().uuidString, isDirectory: true)

    /// Deletes decoded-audio folders that earlier launches left behind (a crash skips the quit-time
    /// cleanup), preserving this session and other running instances.
    public static func removeStaleSessionDirectories() {
        removeStaleSessionDirectories(in: FileManager.default.temporaryDirectory, keeping: sessionDirectory)
    }

    static func removeStaleSessionDirectories(in base: URL, keeping current: URL) {
        JobWorkspace.removeStaleSessionDirectories(in: base, keeping: current)
    }

    public static var encoder: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg") }

    init(url: URL) { self.url = url }
    deinit { remove() }

    /// Deletes the CAF now. Safe to call more than once.
    func remove() { try? FileManager.default.removeItem(at: url) }

    // AAC packets may decode past a file's declared end. Honor a packet table
    // when it explicitly lists priming or remainder, before resampling to 48 kHz.
    private static func trimFilter(for source: URL) -> [String] {
        var file: AudioFileID?
        guard AudioFileOpenURL(source as CFURL, .readPermission, 0, &file) == noErr, let file else { return [] }
        defer { AudioFileClose(file) }
        var table = AudioFilePacketTableInfo()
        var bytes = UInt32(MemoryLayout.size(ofValue: table))
        guard AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &bytes, &table) == noErr,
              table.mNumberValidFrames > 0, table.mPrimingFrames > 0 || table.mRemainderFrames > 0
        else { return [] }
        return ["-af", "atrim=end_sample=" + String(table.mNumberValidFrames)]
    }

    /// Decodes `source` to a 48 kHz stereo 24-bit CAF in `directory` (default: the session directory,
    /// which the app deletes on quit). Synchronous; cancelling the calling task stops FFmpeg.
    public static func decode(_ source: URL, encoder: URL, into directory: URL = sessionDirectory) throws -> PreparedAudio {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = directory.appendingPathComponent(UUID().uuidString)
        let pcm = PreparedAudio(url: base.appendingPathExtension("caf"))
        let log = base.appendingPathExtension("log")
        guard fm.createFile(atPath: log.path, contents: nil) else { throw CueError("Cannot create the audio decoder log.") }
        defer { try? fm.removeItem(at: log) }
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }
        let process = Process()
        process.executableURL = encoder
        process.arguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-xerror", "-n",
                             "-i", source.path, "-map", "0:a:0", "-map_metadata", "-1"] + trimFilter(for: source) + [
                             "-ac", "2", "-ar", "48000", "-c:a", "pcm_s24le", "-f", "caf", pcm.url.path]
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        guard process.terminationStatus == 0 else {
            let detail = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw CueError("Cannot decode " + source.lastPathComponent + ". " + String(detail.suffix(600)))
        }
        return pcm
    }
}
