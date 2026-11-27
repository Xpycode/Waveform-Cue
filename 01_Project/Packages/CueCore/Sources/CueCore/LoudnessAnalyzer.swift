import Foundation
import ProcessKit

/// Runs FFmpeg's `ebur128` pass on an audio file (normally a job's decoded CAF) in the background.
public enum LoudnessAnalyzer {
    /// Lines of stderr kept; the summary is the last dozen, the rest is for error messages.
    static let keptLines = 200

    /// Measures integrated loudness, true peak and loudness range of `url`.
    /// Cancelling the calling task terminates FFmpeg (SIGTERM, then SIGKILL after one second)
    /// and throws `CancellationError`.
    public static func measure(_ url: URL, encoder: URL = PreparedAudio.encoder) async throws -> LoudnessMeasurement {
        try Task.checkCancellation()
        let spec = RunSpec(executablePath: encoder.path, arguments: Loudness.arguments(input: url.path),
                           terminationGrace: .seconds(1))
        var lines: [String] = []
        var exit: RunExit?
        for try await event in ProcessRunner().run(spec) {
            switch event {
            case .stderr(let line):
                lines.append(line)
                if lines.count > 2 * keptLines { lines.removeFirst(lines.count - keptLines) }
            case .stdout:
                break
            case .exit(let status):
                exit = status
            }
        }
        // A cancelled run ends its stream without an exit event.
        try Task.checkCancellation()
        let log = lines.suffix(keptLines).joined(separator: "\n")
        guard let exit else { throw CueError("The loudness pass for " + url.lastPathComponent + " ended unexpectedly.") }
        guard exit.isSuccess else {
            throw CueError("Cannot measure the loudness of " + url.lastPathComponent + ". " + String(log.suffix(600)))
        }
        guard let measurement = Loudness.parse(stderr: log) else {
            throw CueError("FFmpeg printed no loudness summary for " + url.lastPathComponent + ".")
        }
        return measurement
    }
}
