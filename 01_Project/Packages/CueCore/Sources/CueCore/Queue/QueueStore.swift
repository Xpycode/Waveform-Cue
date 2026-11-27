import Foundation

// Persistence for the batch queue (spec B). The file is written atomically after every change.
// A file that cannot be read in full is copied to `queue-recovery-<UUID>.json` beside it before
// anything is written; if that copy fails, writes stay blocked so the only copy of the operator's
// queue is never overwritten.

/// What `queue.json` holds.
public struct QueueDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    /// Queue-wide output folder that wins over every job's own destination.
    public var destinationOverride: String?
    public var jobs: [CueJob]

    public init(jobs: [CueJob] = [], destinationOverride: String? = nil) {
        self.version = Self.currentVersion
        self.destinationOverride = destinationOverride
        self.jobs = jobs
    }

    private enum CodingKeys: String, CodingKey { case version, destinationOverride, jobs }

    /// Decodes job by job: one job that cannot be read is skipped, the others survive.
    /// `droppedJobs` counts the skipped ones (not saved).
    public private(set) var droppedJobs = 0

    public init(from decoder: Decoder) throws {
        // An early shape saved the jobs as a bare array.
        if var array = try? decoder.unkeyedContainer() {
            version = 0
            destinationOverride = nil
            (jobs, droppedJobs) = Self.decodeJobs(&array)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
        destinationOverride = (try? c.decodeIfPresent(String.self, forKey: .destinationOverride)) ?? nil
        if var array = try? c.nestedUnkeyedContainer(forKey: .jobs) {
            (jobs, droppedJobs) = Self.decodeJobs(&array)
        } else if c.contains(.jobs) {
            // `jobs` is there but not a list: nothing of it can be read.
            throw DecodingError.typeMismatch([CueJob].self, .init(
                codingPath: c.codingPath + [CodingKeys.jobs], debugDescription: "The job list is unreadable."))
        } else {
            jobs = []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encodeIfPresent(destinationOverride, forKey: .destinationOverride)
        try c.encode(jobs, forKey: .jobs)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.destinationOverride == rhs.destinationOverride && lhs.jobs == rhs.jobs
    }

    private struct FailableJob: Decodable {
        let job: CueJob?
        init(from decoder: Decoder) throws { job = try? CueJob(from: decoder) }
    }

    private static func decodeJobs(_ array: inout UnkeyedDecodingContainer) -> ([CueJob], Int) {
        var jobs: [CueJob] = []
        var dropped = 0
        while !array.isAtEnd {
            guard let element = try? array.decode(FailableJob.self) else { break }
            if let job = element.job { jobs.append(job) } else { dropped += 1 }
        }
        return (jobs, dropped)
    }
}

public enum QueueStoreError: LocalizedError, Equatable {
    /// The saved queue could not be read and its recovery copy failed, so saving is refused.
    case writesBlocked(file: URL)

    public var errorDescription: String? {
        switch self {
        case .writesBlocked(let file):
            return "The queue file \(file.lastPathComponent) could not be read or backed up, so changes are not being saved."
        }
    }
}

/// The result of reading the queue file.
public struct QueueLoadResult {
    public var document: QueueDocument
    /// Where the unreadable or partly unreadable original was copied, if it was.
    public var recoveryFile: URL?
    /// Jobs that could not be decoded (they remain in the recovery copy).
    public var droppedJobs: Int
    /// Set when the file could not be read; describes the problem.
    public var problem: String?
}

public final class QueueStore {
    public static let fileName = "queue.json"

    public let fileURL: URL
    /// True when the file on disk could not be read and could not be backed up. Saving then
    /// throws `QueueStoreError.writesBlocked` until the file is dealt with.
    public private(set) var isWriteBlocked = false
    public private(set) var lastRecoveryFile: URL?

    private let copyItem: (URL, URL) throws -> Void

    /// - Parameter copyItem: test seam for the recovery copy; defaults to `FileManager.copyItem`.
    public init(directory: URL, copyItem: ((URL, URL) throws -> Void)? = nil) {
        self.fileURL = directory.appendingPathComponent(Self.fileName)
        self.copyItem = copyItem ?? { try FileManager.default.copyItem(at: $0, to: $1) }
    }

    /// Reads the queue. A missing file is an empty queue. An unreadable file, or one with jobs
    /// that cannot be decoded, is first copied to a recovery file; if the copy fails, writes
    /// are blocked.
    public func load() -> QueueLoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            return QueueLoadResult(document: QueueDocument(), recoveryFile: nil, droppedJobs: 0, problem: nil)
        }
        let document: QueueDocument?
        let problem: String?
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(QueueDocument.self, from: data)
            document = decoded
            problem = decoded.droppedJobs > 0
                ? "\(decoded.droppedJobs) queued job\(decoded.droppedJobs == 1 ? "" : "s") could not be read."
                : nil
        } catch {
            document = nil
            problem = "The saved queue could not be read: \(error.localizedDescription)"
        }

        var result = QueueLoadResult(document: document ?? QueueDocument(), recoveryFile: nil,
                                     droppedJobs: document?.droppedJobs ?? 0, problem: problem)
        if problem != nil {
            let copy = fileURL.deletingLastPathComponent()
                .appendingPathComponent("queue-recovery-\(UUID().uuidString).json")
            do {
                try copyItem(fileURL, copy)
                result.recoveryFile = copy
                lastRecoveryFile = copy
            } catch {
                isWriteBlocked = true
                result.problem = (problem ?? "") + " It could not be backed up either, so changes will not be saved."
            }
        }
        return result
    }

    /// Writes the queue atomically (temporary file, then rename), creating the folder if needed.
    public func save(_ document: QueueDocument) throws {
        guard !isWriteBlocked else { throw QueueStoreError.writesBlocked(file: fileURL) }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: fileURL, options: .atomic)
    }
}
