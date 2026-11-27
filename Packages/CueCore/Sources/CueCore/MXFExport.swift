import Foundation
import CoreGraphics
import Darwin

/// Renders cue pictures and pipes them as raw BGRA frames to FFmpeg, which writes the MXF.
///
/// The engine is pure: it takes a snapshot of one job (track, title, look, audio layout,
/// timecode, gain), a preset and a timeline, and writes one file. The queue adapter
/// (`MXFJobExporter` in the app) builds those from a `CueJob`.
public enum MXFExport {
    /// What one export needs from a job, frozen at the moment it starts.
    public struct Snapshot: Sendable {
        /// The analysed track with its decoded PCM attached (`track.audio != nil`).
        public var track: AudioTrack
        public var label: CueLabel
        public var appearance: CueAppearance
        public var layout: AudioLayout
        /// Timecode of the first music frame (25-based as typed). With a pre-roll the file
        /// starts earlier by the pre-roll, so the music lands on this value (spec E).
        public var startTimecode: Timecode
        /// Linear loudness gain in dB; 0 leaves the audio untouched.
        public var gainDB: Double
        /// The source's measured loudness (before `gainDB`), shown on the pre-roll slate; nil
        /// when not measured.
        public var loudness: LoudnessMeasurement?

        public init(track: AudioTrack, label: CueLabel, appearance: CueAppearance = CueAppearance(),
                    layout: AudioLayout = .default, startTimecode: Timecode = .start, gainDB: Double = 0,
                    loudness: LoudnessMeasurement? = nil) {
            self.track = track
            self.label = label
            self.appearance = appearance
            self.layout = layout
            self.startTimecode = startTimecode
            self.gainDB = gainDB
            self.loudness = loudness
        }

        /// The loudness the clip carries: the measurement moved by the linear gain (integrated
        /// and true peak shift by `gainDB`; the range does not change).
        public var clipLoudness: LoudnessMeasurement? {
            guard var m = loudness else { return nil }
            guard gainDB.isFinite, gainDB != 0 else { return m }
            m.integratedLUFS = m.integratedLUFS.map { $0 + gainDB }
            m.truePeakDBTP = m.truePeakDBTP.map { $0 + gainDB }
            return m
        }
    }

    /// Characters of the encoder log kept on failure (spec error states).
    public static let logTailLength = 1500

    /// The timeline for exporting `track` with `preset`: rendered at the preset's render rate
    /// (50 images per second for 1080i50 fields and 1080p50) with its whole-frame padding.
    public static func timeline(for track: AudioTrack, preset: ExportPreset, trim: TrimSettings = .none,
                                markers: MusicMarkers? = nil, target: CountdownTarget = .fileEnd) -> ClipTimeline {
        ClipTimeline(duration: track.seconds, trim: trim, markers: markers ?? track.markers, target: target,
                     standard: preset.video.timelineRate)
    }

    /// Timecode written to the file: the music start moved earlier by the pre-roll, at the
    /// preset's timecode rate (25-based, or 0–49 for 1080p50), wrapping past midnight.
    public static func fileStartTimecode(_ start: Timecode, preset: ExportPreset, timeline: ClipTimeline) -> Timecode {
        let rate = preset.timecodeRate
        let music = start.converted(toFPS: rate)
        let preRoll = timeline.preRollFrames * rate / max(1, timeline.frameRate)
        return Timecode(totalFrames: music.totalFrames - preRoll, fps: rate)
    }

    /// The timeline's trim, fade and pre-roll steps without the resample and whole-frame
    /// padding the preset's audio graph already adds, so the final graph has one
    /// `aresample`, one `apad` and one `atrim=end_sample`.
    static func editFilters(_ timeline: ClipTimeline) -> [String] {
        var filters = timeline.audioFilters()
        if filters.first?.hasPrefix("aresample=") == true { filters.removeFirst() }
        while let last = filters.last, last.hasPrefix("apad") || last.hasPrefix("atrim=end_sample=") {
            filters.removeLast()
        }
        return filters
    }

    /// The complete FFmpeg arguments (without the executable) for one export.
    public static func arguments(snapshot: Snapshot, preset: ExportPreset, timeline: ClipTimeline,
                                 audioPath: String, output: String) -> [String] {
        preset.ffmpegArguments(audioPath: audioPath, outputFrames: timeline.outputFrames, layout: snapshot.layout,
                               timecode: fileStartTimecode(snapshot.startTimecode, preset: preset, timeline: timeline),
                               gainDB: snapshot.gainDB, audioFilters: editFilters(timeline), output: output)
    }

    /// Bytes the destination volume must have free for this export.
    public static func requiredBytes(snapshot: Snapshot, preset: ExportPreset, timeline: ClipTimeline) -> Int64 {
        DiskSpace.requiredBytes(preset: preset, timeline: timeline, layout: snapshot.layout)
    }

    /// Exports one clip to `destination`.
    ///
    /// Renders `timeline.positionCount` images (one per field for 1080i50) and writes each as
    /// one whole BGRA frame. Before FFmpeg starts it checks that the folder is writable
    /// (`JobExportError.destinationUnwritable`) and that its volume has room
    /// (`JobExportError.failed` naming the volume, free and required space). FFmpeg writes a
    /// hidden temporary file beside the destination, which is moved into place only on
    /// success; an existing file at `destination` is never replaced. An encoder failure throws
    /// `JobExportError.failed` with the last 1,500 characters of the log. Cancelling the
    /// calling task stops rendering and FFmpeg and throws `CancellationError`.
    public static func run(snapshot: Snapshot, preset: ExportPreset, timeline: ClipTimeline, encoder: URL,
                           destination: URL, volume: (URL) throws -> DiskSpace.Volume = DiskSpace.volume(of:),
                           progress: (Double) -> Void) throws {
        guard let audio = snapshot.track.audio else { throw CueError("The track's audio has not been decoded.") }
        guard timeline.rate == preset.video.timelineRate else {
            throw CueError("The export timeline does not match the \(preset.video.shortName) preset.")
        }
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        try Task.checkCancellation()
        try DiskSpace.preflight(folder: folder, required: requiredBytes(snapshot: snapshot, preset: preset, timeline: timeline),
                                volume: volume)
        if fm.fileExists(atPath: destination.path) { throw collision(destination) }

        let temp = folder.appendingPathComponent(".waveform-cue-" + UUID().uuidString + ".mxf")
        let log = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? fm.removeItem(at: temp); try? fm.removeItem(at: log) }
        guard fm.createFile(atPath: log.path, contents: nil) else { throw CueError("Cannot create an encoder log.") }
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close() }
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        let descriptor = writer.fileDescriptor
        guard fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else { throw POSIXError(.EIO) }
        let task = Process()
        task.executableURL = encoder
        task.arguments = arguments(snapshot: snapshot, preset: preset, timeline: timeline,
                                   audioPath: audio.url.path, output: temp.path)
        task.standardInput = pipe
        task.standardError = errors
        task.standardOutput = FileHandle.nullDevice
        let width = preset.video.width, height = preset.video.height
        let flags = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: flags), let pixels = bitmap.data else {
            throw CueError("Cannot allocate the export frame.")
        }
        try Task.checkCancellation()
        try task.run()
        defer {
            try? writer.close()
            if task.isRunning { task.terminate() }
            task.waitUntilExit()
        }
        // One layout for the whole export, the same value the preview computes.
        let track = snapshot.track
        let layout = snapshot.appearance.layout
        let path = CuePicture.overviewPath(track, layout: layout, timeline: timeline)
        let loudness = snapshot.clipLoudness
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let count = timeline.positionCount
        let bytes = bitmap.bytesPerRow * bitmap.height
        var brokenPipe = false
        for position in 0..<count {
            try Task.checkCancellation()
            autoreleasepool {
                CuePicture.draw(in: bitmap, rect: rect, track: track, path: path, timeline: timeline,
                                layout: layout, position: position, label: snapshot.label,
                                appearance: snapshot.appearance, loudness: loudness)
            }
            // One whole frame per image: a short write is resumed, never split across frames.
            var offset = 0
            while offset < bytes {
                let n = Darwin.write(descriptor, pixels + offset, bytes - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { brokenPipe = true; break }
                offset += n
            }
            if brokenPipe { break }
            if position % 10 == 0 { progress(Double(position + 1) / Double(count)) }
        }
        try writer.close()
        task.waitUntilExit()
        try Task.checkCancellation()
        guard !brokenPipe, task.terminationStatus == 0 else {
            let reason = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw JobExportError.failed(reason: "MXF encoding failed.", log: String(reason.suffix(logTailLength)))
        }
        // `moveItem` refuses an existing destination, so a collision (including one from a
        // second instance) leaves both files intact.
        do {
            try fm.moveItem(at: temp, to: destination)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            throw collision(destination)
        }
        progress(1)
    }

    static func collision(_ destination: URL) -> JobExportError {
        .failed(reason: "“\(destination.lastPathComponent)” already exists; nothing was overwritten.", log: "")
    }

    /// Build 10 entry point: MPEG-2 1080p25, the whole track, two mono tracks, timecode
    /// 00:00:00:00. An encoder failure keeps build 10's single message with the log tail.
    public static func run(track: AudioTrack, label: CueLabel, appearance: CueAppearance = CueAppearance(), encoder: URL,
                           destination: URL, progress: (Double) -> Void) throws {
        let preset = ExportPreset.mpeg2_1080p25
        let snapshot = Snapshot(track: track, label: label, appearance: appearance)
        do {
            try run(snapshot: snapshot, preset: preset, timeline: timeline(for: track, preset: preset),
                    encoder: encoder, destination: destination, progress: progress)
        } catch JobExportError.failed(let reason, let log) where !log.isEmpty {
            throw CueError(reason + " " + log)
        }
    }
}
