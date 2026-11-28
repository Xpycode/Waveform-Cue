import Foundation

// One export job in the batch queue (spec B). Every field decodes tolerantly (cookbook 122) so a
// drifted or partial `queue.json` loses at most a field, never a job; run state (progress) is
// deliberately left out of the saved form.

// MARK: - Status

public enum JobStatus: Sendable, Equatable {
    case pending
    case preparing
    case exporting(progress: Double)
    case done(output: URL)
    case failed(reason: String, log: String)
    case cancelled
    /// Held because its destination folder became unwritable; waits for a new folder.
    case paused

    /// The job is the one being worked on right now.
    public var isActive: Bool {
        switch self {
        case .preparing, .exporting: return true
        default: return false
        }
    }

    /// Done, Failed or Cancelled: the queue will not run it again without a Retry.
    public var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: return true
        default: return false
        }
    }

    public var canRetry: Bool {
        switch self {
        case .failed, .cancelled: return true
        default: return false
        }
    }

    /// Export progress from 0 to 1 while exporting, otherwise `nil`.
    public var progress: Double? {
        if case .exporting(let value) = self { return value }
        return nil
    }

    public var title: String {
        switch self {
        case .pending: return "Pending"
        case .preparing: return "Preparing"
        case .exporting(let value): return "Exporting \(Int((value * 100).rounded(.down)))%"
        case .done: return "Done"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        case .paused: return "Paused"
        }
    }
}

extension JobStatus: Codable {
    private enum CodingKeys: String, CodingKey { case state, output, reason, log }

    private enum State: String, Codable {
        case pending, preparing, exporting, done, failed, cancelled, paused
    }

    /// Preparing and Exporting are run state: they are saved as Pending, so a job interrupted
    /// by a quit or crash comes back Pending and its progress is never written.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending, .preparing, .exporting:
            try c.encode(State.pending, forKey: .state)
        case .done(let output):
            try c.encode(State.done, forKey: .state)
            try c.encode(output.path, forKey: .output)
        case .failed(let reason, let log):
            try c.encode(State.failed, forKey: .state)
            try c.encode(reason, forKey: .reason)
            try c.encode(log, forKey: .log)
        case .cancelled:
            try c.encode(State.cancelled, forKey: .state)
        case .paused:
            try c.encode(State.paused, forKey: .state)
        }
    }

    /// Accepts the keyed form or a bare state string. Anything unreadable, or a Done without
    /// its output path, becomes Pending: the job can always run again, it is never dropped.
    public init(from decoder: Decoder) throws {
        let state: State?
        var container: KeyedDecodingContainer<CodingKeys>?
        if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            container = c
            state = (try? c.decodeIfPresent(State.self, forKey: .state)) ?? nil
        } else {
            let raw = try? decoder.singleValueContainer().decode(String.self)
            state = raw.flatMap(State.init(rawValue:))
        }
        func string(_ key: CodingKeys) -> String? {
            (try? container?.decodeIfPresent(String.self, forKey: key)) ?? nil
        }
        switch state {
        case .done:
            if let path = string(.output), !path.isEmpty {
                self = .done(output: URL(fileURLWithPath: path))
            } else {
                self = .pending
            }
        case .failed: self = .failed(reason: string(.reason) ?? "", log: string(.log) ?? "")
        case .cancelled: self = .cancelled
        case .paused: self = .paused
        case .pending, .preparing, .exporting, nil: self = .pending
        }
    }
}

// MARK: - Peaks summary

/// The overview peaks and duration from the job's analysis, saved so a restored job can be
/// listed and previewed without decoding its source again.
public struct PeaksSummary: Codable, Sendable, Equatable, Hashable {
    /// Source duration in seconds.
    public var seconds: Double
    /// Normalised overview peaks (0…1), as `AudioTrack.peaks`.
    public var overview: [Float]

    public init(seconds: Double, overview: [Float]) {
        self.seconds = seconds.isFinite ? max(0, seconds) : 0
        // JSON cannot hold NaN or infinity; an encoder would throw for the whole queue.
        self.overview = overview.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
    }

    private enum CodingKeys: String, CodingKey { case seconds, overview }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(seconds: (try? c.decodeIfPresent(Double.self, forKey: .seconds)) ?? 0,
                  overview: (try? c.decodeIfPresent([Float].self, forKey: .overview)) ?? [])
    }
}

// MARK: - Appearance snapshot

/// The queue stores each job's appearance by value, in the original unwrapped JSON shape.
public struct AppearanceSnapshot: Codable, Equatable, Sendable {
    public var value: CueAppearance

    public init(_ value: CueAppearance = CueAppearance()) { self.value = value }

    /// An unreadable appearance (for example a build 4 blob without clocks) falls back to the
    /// factory appearance.
    public init(from decoder: Decoder) throws {
        value = (try? decoder.singleValueContainer().decode(CueAppearance.self)) ?? CueAppearance()
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}

// MARK: - Job

public struct CueJob: Identifiable, Sendable, Equatable {
    public static let defaultStartTimecode = "00:00:00:00"
    public static let defaultFilenameTemplate = "{name} - Cue"

    public let id: UUID
    public var sourcePath: String
    /// Overlay title text; defaults to the source filename without extension.
    public var labelText: String
    public var appearanceSnapshot: AppearanceSnapshot
    /// An empty ID means "the app's default preset" (a legacy job saved before presets).
    public var presetID: PresetID
    public var layout: AudioLayout
    /// HH:MM:SS:FF, parsed by the export engine.
    public var startTimecode: String
    public var filenameTemplate: String
    public var trim: TrimSettings
    public var markers: MusicMarkers
    public var loudness: LoudnessMeasurement?
    /// Normalise to -23 LUFS on export: one linear gain from `Loudness.normalisation(for:)`,
    /// capped by the -1 dBTP true-peak limit. Off by default and for jobs saved before it existed.
    public var normalise: Bool
    public var peaks: PeaksSummary?
    /// The full analysis (detail peaks, detected markers, absolute peak), so a restored job draws
    /// its waveform with `AudioTrack(url:analysis:)` and needs no re-analysis when it is decoded.
    public var analysis: TrackAnalysis?
    /// Folder chosen for this job; `nil` means beside the source.
    public var destinationFolder: String?
    /// Destination file of the current or last attempt, resolved by the queue before export.
    public var outputPath: String?
    public var status: JobStatus

    public init(id: UUID = UUID(), source: URL, label: CueLabel? = nil,
                appearance: CueAppearance = CueAppearance(), presetID: PresetID = "",
                layout: AudioLayout = .default, startTimecode: String = CueJob.defaultStartTimecode,
                filenameTemplate: String = CueJob.defaultFilenameTemplate, trim: TrimSettings = .none,
                markers: MusicMarkers = .none, loudness: LoudnessMeasurement? = nil,
                normalise: Bool = false, peaks: PeaksSummary? = nil, analysis: TrackAnalysis? = nil,
                destinationFolder: URL? = nil, status: JobStatus = .pending) {
        self.id = id
        self.sourcePath = source.path
        self.labelText = label?.text ?? source.deletingPathExtension().lastPathComponent
        self.appearanceSnapshot = AppearanceSnapshot(appearance)
        self.presetID = presetID
        self.layout = layout
        self.startTimecode = startTimecode
        self.filenameTemplate = filenameTemplate
        self.trim = trim
        self.markers = markers
        self.loudness = loudness
        self.normalise = normalise
        self.peaks = peaks
        self.analysis = analysis
        self.destinationFolder = destinationFolder?.path
        self.outputPath = nil
        self.status = status
    }

    public var sourceURL: URL { URL(fileURLWithPath: sourcePath) }
    public var outputURL: URL? { outputPath.map { URL(fileURLWithPath: $0) } }
    /// The source filename without extension, the `{name}` of the filename template.
    public var sourceName: String { sourceURL.deletingPathExtension().lastPathComponent }

    public var label: CueLabel {
        get { CueLabel(text: labelText) }
        set { labelText = newValue.text }
    }

    public var appearance: CueAppearance {
        get { appearanceSnapshot.value }
        set { appearanceSnapshot = AppearanceSnapshot(newValue) }
    }

    public var effectiveAppearance: CueAppearance {
        var result = appearance
        if !result.markersEnabled { result.countdownTarget = .fileEnd }
        if !result.safeZonesEnabled {
            result.safeZones = .none
            result.showGuides = false
        }
        return result
    }

    public var effectiveMarkers: MusicMarkers {
        effectiveMarkers(detected: analysis?.markers ?? markers)
    }

    /// The exporter may have just decoded a legacy job without a saved track analysis.
    /// Always return an explicit value, so disabled markers cannot fall back to that detection.
    public func effectiveMarkers(detected: MusicMarkers) -> MusicMarkers {
        appearance.markersEnabled ? detected.applyingEdits(from: markers) : .none
    }

    public var effectiveTrim: TrimSettings {
        var result = appearance.trimAndFadesEnabled ? trim : .none
        result.preRoll = appearance.preRollEnabled ? trim.preRoll : 0
        return result
    }

    public var shouldMeasureLoudness: Bool {
        appearance.loudnessAnalysisEnabled && loudness == nil
    }

    public var effectiveGainDB: Double {
        guard appearance.loudnessAnalysisEnabled, normalise, let loudness else { return 0 }
        return Loudness.normalisation(for: loudness).gainDB
    }
}

extension CueJob: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, sourcePath, labelText, appearance, presetID, layout
        case startTimecode, filenameTemplate, trim, markers, loudness, normalise, peaks, analysis
        case destinationFolder, outputPath, status
        // Decode-only legacy keys (build 10 era single-job shape).
        case source, label, title
        // Build 17 anchored the title by x and y. Only x affects its new top-band alignment.
        case labelX
    }

    /// Only the source path is required: without it a job cannot be run or even named.
    /// Every other field falls back to its default, so an older or partial job still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }

        guard let path = value(String.self, .sourcePath) ?? value(String.self, .source), !path.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.sourcePath, .init(
                codingPath: c.codingPath, debugDescription: "A queued job has no source path."))
        }
        let source = URL(fileURLWithPath: path)
        id = value(UUID.self, .id) ?? UUID()
        sourcePath = path
        labelText = value(String.self, .labelText) ?? value(String.self, .label) ?? value(String.self, .title)
            ?? source.deletingPathExtension().lastPathComponent
        appearanceSnapshot = value(AppearanceSnapshot.self, .appearance) ?? AppearanceSnapshot(CueAppearance())
        let savedLook = try? c.nestedContainer(keyedBy: CueAppearance.CodingKeys.self, forKey: .appearance)
        if savedLook?.contains(.titleAlignment) != true, let x = value(Double.self, .labelX), x.isFinite {
            appearanceSnapshot.value.titleAlignment = TitleAlignment(legacyX: x)
        }
        presetID = value(PresetID.self, .presetID) ?? ""
        layout = value(AudioLayout.self, .layout) ?? .default
        startTimecode = value(String.self, .startTimecode) ?? Self.defaultStartTimecode
        filenameTemplate = value(String.self, .filenameTemplate) ?? Self.defaultFilenameTemplate
        trim = value(TrimSettings.self, .trim) ?? .none
        markers = value(MusicMarkers.self, .markers) ?? .none
        loudness = value(LoudnessMeasurement.self, .loudness)
        normalise = value(Bool.self, .normalise) ?? false
        peaks = value(PeaksSummary.self, .peaks)
        // Unusable stored peaks (empty, odd byte count) drop only the analysis: the job re-analyses.
        analysis = value(TrackAnalysis.self, .analysis)
        destinationFolder = value(String.self, .destinationFolder)
        outputPath = value(String.self, .outputPath)
        status = value(JobStatus.self, .status) ?? .pending
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourcePath, forKey: .sourcePath)
        try c.encode(labelText, forKey: .labelText)
        try c.encode(appearanceSnapshot, forKey: .appearance)
        try c.encode(presetID, forKey: .presetID)
        try c.encode(layout, forKey: .layout)
        try c.encode(startTimecode, forKey: .startTimecode)
        try c.encode(filenameTemplate, forKey: .filenameTemplate)
        try c.encode(trim, forKey: .trim)
        try c.encode(markers, forKey: .markers)
        try c.encodeIfPresent(loudness, forKey: .loudness)
        try c.encode(normalise, forKey: .normalise)
        try c.encodeIfPresent(peaks, forKey: .peaks)
        try c.encodeIfPresent(analysis, forKey: .analysis)
        try c.encodeIfPresent(destinationFolder, forKey: .destinationFolder)
        try c.encodeIfPresent(outputPath, forKey: .outputPath)
        try c.encode(status, forKey: .status)
    }
}

// MARK: - Shared settings (Apply to All)

extension CueJob {
    /// Takes the settings Apply to All copies: everything that is not about this track's own
    /// audio. Look, preset, audio tracks, Normalise, start timecode, filename
    /// pattern, fades and pre-roll are copied; title text, trim in and out, and the music
    /// markers stay per track. A new preset or filename pattern drops the reserved output name.
    public mutating func adoptSharedSettings(from source: CueJob) {
        if presetID != source.presetID || filenameTemplate != source.filenameTemplate { outputPath = nil }
        appearanceSnapshot = source.appearanceSnapshot
        presetID = source.presetID
        layout = source.layout
        normalise = source.normalise
        startTimecode = source.startTimecode
        filenameTemplate = source.filenameTemplate
        trim.fadeIn = source.trim.fadeIn
        trim.fadeOut = source.trim.fadeOut
        trim.preRoll = source.trim.preRoll
    }

    /// True when this job already has every setting Apply to All would copy from `other`.
    /// An empty preset ID and the default preset's ID count as the same preset.
    public func sharesSettings(with other: CueJob) -> Bool {
        resolvedPreset == other.resolvedPreset
            && layout == other.layout
            && normalise == other.normalise
            && startTimecode == other.startTimecode
            && filenameTemplate == other.filenameTemplate
            && trim.fadeIn == other.trim.fadeIn
            && trim.fadeOut == other.trim.fadeOut
            && trim.preRoll == other.trim.preRoll
            && (appearanceSnapshot == other.appearanceSnapshot || appearance.matchesSettings(of: other.appearance))
    }

    /// The job's preset, or the default for an empty or unknown ID.
    public var resolvedPreset: ExportPreset { ExportPreset.preset(for: presetID) ?? .default }

    /// One short line of export settings for the queue, e.g. "AVC-I 100 1080p25 · 2 mono · −23 LUFS".
    public var settingsSummary: String {
        var parts = ["\(resolvedPreset.shortCodecName) \(resolvedPreset.video.shortName)", layout.title]
        if normalise && appearance.loudnessAnalysisEnabled { parts.append("−23 LUFS") }
        return parts.joined(separator: " · ")
    }
}
