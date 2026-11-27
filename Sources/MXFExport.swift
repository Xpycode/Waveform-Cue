import Foundation
import CoreGraphics
import Darwin

enum MXFExport {
    static func run(track: AudioTrack, label: CueLabel, appearance: CueAppearance = CueAppearance(), encoder: URL, destination: URL,
                    progress: (Double) -> Void) throws {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
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
        task.arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-n",
                          "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", "1920x1080",
                          "-framerate", "25", "-i", "pipe:0", "-i", track.pcm.url.path,
                          "-map", "0:v:0", "-map", "1:a:0", "-map_metadata", "-1",
                          "-vf", "scale=out_color_matrix=bt709:out_range=tv,setsar=1",
                          "-c:v", "mpeg2video", "-pix_fmt", "yuv422p", "-b:v", "50M",
                          "-minrate", "50M", "-maxrate", "50M", "-bufsize", "17825792",
                          "-g", "12", "-bf", "2", "-colorspace", "bt709", "-color_primaries", "bt709",
                          "-color_trc", "bt709", "-c:a", "pcm_s24le", "-ar", "48000", "-ac", "2",
                          "-af", "aresample=48000,apad=whole_len=\(track.frames * 1920),atrim=end_sample=\(track.frames * 1920)",
                          "-timecode", "00:00:00:00", "-f", "mxf", temp.path]
        task.standardInput = pipe
        task.standardError = errors
        task.standardOutput = FileHandle.nullDevice
        let flags = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let bitmap = CGContext(data: nil, width: 1920, height: 1080, bitsPerComponent: 8,
                                     bytesPerRow: 7680, space: CGColorSpace(name: CGColorSpace.sRGB)!,
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
        let path = CuePicture.waveform(track.peaks, in: CuePicture.overviewRect(for: appearance.zoom))
        var brokenPipe = false
        for frame in 0..<track.frames {
            try Task.checkCancellation()
            autoreleasepool {
                CuePicture.draw(in: bitmap, rect: CGRect(origin: .zero, size: CuePicture.size),
                                track: track, path: path, frame: frame, label: label, appearance: appearance)
            }
            var offset = 0
            let bytes = bitmap.bytesPerRow * bitmap.height
            while offset < bytes {
                let n = Darwin.write(descriptor, pixels + offset, bytes - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { brokenPipe = true; break }
                offset += n
            }
            if brokenPipe { break }
            if frame % 10 == 0 { progress(Double(frame + 1) / Double(track.frames)) }
        }
        try writer.close()
        task.waitUntilExit()
        try Task.checkCancellation()
        guard !brokenPipe, task.terminationStatus == 0 else {
            let reason = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            throw CueError("MXF encoding failed. " + String(reason.suffix(1500)))
        }
        // A collision (including from a second instance) must leave both existing files intact.
        try fm.moveItem(at: temp, to: destination)
        progress(1)
    }
}
