import Foundation

/// Disk preflight for an export (spec edge case: fail before encoding when the destination
/// volume cannot hold the estimated output). Also probes that the folder can be written, so an
/// unwritable destination pauses the queue instead of failing inside FFmpeg.
public enum DiskSpace {
    /// The volume holding a folder and its free space.
    public struct Volume: Sendable, Equatable {
        public var name: String
        public var availableBytes: Int64
        /// Identifies the volume, so two folders can be compared (nil when unknown).
        public var identifier: String?

        public init(name: String, availableBytes: Int64, identifier: String? = nil) {
            self.name = name
            self.availableBytes = availableBytes
            self.identifier = identifier
        }
    }

    /// Bytes of a 48 kHz stereo 24-bit CAF of `seconds` (the decoded source), with a small header.
    public static func cafBytes(seconds: Double) -> Int64 {
        Int64((seconds.isFinite ? max(0, seconds) : 0) * 48_000 * 2 * 3) + 4096
    }

    /// Estimated bytes for one export: the MXF (video plus mono tracks plus overhead, from the
    /// preset) and, when given, a CAF still to be decoded onto the same volume.
    public static func requiredBytes(preset: ExportPreset, timeline: ClipTimeline, layout: AudioLayout,
                                     pendingCAFBytes: Int64 = 0) -> Int64 {
        preset.estimatedBytes(duration: timeline.outputSeconds, layout: layout) + max(0, pendingCAFBytes)
    }

    /// The volume of `folder`, read from the file system.
    public static func volume(of folder: URL) throws -> Volume {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeNameKey,
                                         .volumeAvailableCapacityForImportantUsageKey,
                                         .volumeAvailableCapacityKey, .volumeIdentifierKey]
        let values = try folder.resourceValues(forKeys: keys)
        let name = values.volumeLocalizedName ?? values.volumeName ?? folder.path
        // "Important usage" includes purgeable space; network volumes may report only the plain value.
        let important = values.volumeAvailableCapacityForImportantUsage ?? 0
        let plain = Int64(values.volumeAvailableCapacity ?? 0)
        let identifier = values.volumeIdentifier.map { String(describing: $0) }
        return Volume(name: name, availableBytes: max(important, plain), identifier: identifier)
    }

    /// Whether two locations are on the same volume. Missing paths are judged by their nearest
    /// existing folder; when either volume is unknown the answer is true (the cautious choice
    /// for a preflight that adds the CAF to the destination's requirement).
    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func identifier(_ url: URL) -> String? {
            var url = url.standardizedFileURL
            while !FileManager.default.fileExists(atPath: url.path), url.path != "/" { url.deleteLastPathComponent() }
            return (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier.map { String(describing: $0) }
        }
        guard let x = identifier(a), let y = identifier(b) else { return true }
        return x == y
    }

    /// "Not enough space on “Name”: 1.2 GB free, 3.4 GB needed."
    public static func message(volume: Volume, required: Int64) -> String {
        "Not enough space on “\(volume.name)”: \(format(volume.availableBytes)) free, \(format(required)) needed."
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Throws `JobExportError.destinationUnwritable` when `folder` is missing or cannot be
    /// written, and `JobExportError.failed` with the disk-space message when its volume has
    /// less than `required` bytes free. `volume` is injectable for tests.
    public static func preflight(folder: URL, required: Int64,
                                 volume: (URL) throws -> Volume = DiskSpace.volume(of:)) throws {
        try probeWritable(folder)
        let info: Volume
        do { info = try volume(folder) } catch {
            // Free space unknown (some network volumes): let the export try rather than block it.
            return
        }
        if info.availableBytes < required {
            throw JobExportError.failed(reason: message(volume: info, required: required), log: "")
        }
    }

    /// Creates and deletes a hidden probe file in `folder`. Permission bits alone miss ACLs,
    /// read-only mounts and ejected volumes; an actual create does not.
    public static func probeWritable(_ folder: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw JobExportError.destinationUnwritable(folder: folder, reason: "The folder does not exist.")
        }
        let probe = folder.appendingPathComponent(".waveform-cue-probe-" + UUID().uuidString)
        let fd = open(probe.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            throw JobExportError.destinationUnwritable(folder: folder, reason: reason + ".")
        }
        close(fd)
        unlink(probe.path)
    }
}
