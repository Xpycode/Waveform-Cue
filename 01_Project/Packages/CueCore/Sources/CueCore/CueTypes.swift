import Foundation

// Shared value types exchanged by the batch round's tasks. Names and fields are frozen for
// Waves 1–5 (IMPLEMENTATION_PLAN 0.3); changes go through the coordinator.
//
// Every type decodes tolerantly (cookbook 122): a missing key takes its default and an unknown
// enum value falls back, so one drifted field can never wipe a saved queue or appearance.

// MARK: - Audio layout

/// Number of mono PCM tracks in the export. Left is on track 1, right on track 2, and any
/// further tracks are digital silence.
public enum AudioLayout: Int, Codable, Sendable, CaseIterable, Hashable {
    case two = 2, four = 4, eight = 8

    public static let `default` = AudioLayout.two
    public var trackCount: Int { rawValue }
    public var title: String { "\(rawValue) mono" }

    public init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(Int.self)
        self = raw.flatMap(AudioLayout.init(rawValue:)) ?? .default
    }
}

// MARK: - Music markers

/// Detected and operator-edited music end and fade start, in seconds of source time.
/// An edited value wins over the detected one; `nil` edits mean "use the detection".
public struct MusicMarkers: Codable, Sendable, Equatable, Hashable {
    public var detectedMusicEnd: Double?
    public var detectedFadeStart: Double?
    public var editedMusicEnd: Double?
    public var editedFadeStart: Double?
    /// The whole track stayed below the music threshold ("No music detected").
    public var noMusic: Bool

    public init(detectedMusicEnd: Double? = nil, detectedFadeStart: Double? = nil,
                editedMusicEnd: Double? = nil, editedFadeStart: Double? = nil, noMusic: Bool = false) {
        self.detectedMusicEnd = detectedMusicEnd
        self.detectedFadeStart = detectedFadeStart
        self.editedMusicEnd = editedMusicEnd
        self.editedFadeStart = editedFadeStart
        self.noMusic = noMusic
    }

    /// No analysis yet.
    public static let none = MusicMarkers()
    /// Analysis found nothing above the threshold.
    public static let silent = MusicMarkers(noMusic: true)

    public var musicEnd: Double? { noMusic ? nil : editedMusicEnd ?? detectedMusicEnd }
    public var fadeStart: Double? { noMusic ? nil : editedFadeStart ?? detectedFadeStart }
    public var isEdited: Bool { editedMusicEnd != nil || editedFadeStart != nil }

    /// These detected values with the operator's edits from `edits` laid on top. A queue job
    /// stores only edits (its detection lives in the track analysis), so exporters combine the
    /// two this way; passing the job's markers alone would drop the detected music end.
    public func applyingEdits(from edits: MusicMarkers) -> MusicMarkers {
        var merged = self
        merged.editedMusicEnd = edits.editedMusicEnd ?? editedMusicEnd
        merged.editedFadeStart = edits.editedFadeStart ?? editedFadeStart
        return merged
    }

    /// Discard the operator's edits and return to the detected values.
    public mutating func resetToDetected() {
        editedMusicEnd = nil
        editedFadeStart = nil
    }

    private enum CodingKeys: String, CodingKey {
        case detectedMusicEnd, detectedFadeStart, editedMusicEnd, editedFadeStart, noMusic
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        detectedMusicEnd = (try? c.decodeIfPresent(Double.self, forKey: .detectedMusicEnd)) ?? nil
        detectedFadeStart = (try? c.decodeIfPresent(Double.self, forKey: .detectedFadeStart)) ?? nil
        editedMusicEnd = (try? c.decodeIfPresent(Double.self, forKey: .editedMusicEnd)) ?? nil
        editedFadeStart = (try? c.decodeIfPresent(Double.self, forKey: .editedFadeStart)) ?? nil
        noMusic = (try? c.decodeIfPresent(Bool.self, forKey: .noMusic)) ?? false
    }
}

// MARK: - Loudness

/// An EBU R 128 measurement. JSON cannot hold infinity, so a silent result (FFmpeg prints
/// `-inf`) is stored as `nil`.
public struct LoudnessMeasurement: Codable, Sendable, Equatable, Hashable {
    /// Integrated loudness in LUFS; `nil` for silence.
    public var integratedLUFS: Double?
    /// True peak in dBTP; `nil` for silence.
    public var truePeakDBTP: Double?
    /// Loudness range in LU.
    public var rangeLU: Double

    public init(integratedLUFS: Double?, truePeakDBTP: Double?, rangeLU: Double) {
        self.integratedLUFS = integratedLUFS
        self.truePeakDBTP = truePeakDBTP
        self.rangeLU = rangeLU
    }

    public var isSilent: Bool { integratedLUFS == nil }

    private enum CodingKeys: String, CodingKey { case integratedLUFS, truePeakDBTP, rangeLU }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        integratedLUFS = (try? c.decodeIfPresent(Double.self, forKey: .integratedLUFS)) ?? nil
        truePeakDBTP = (try? c.decodeIfPresent(Double.self, forKey: .truePeakDBTP)) ?? nil
        rangeLU = (try? c.decodeIfPresent(Double.self, forKey: .rangeLU)) ?? 0
    }
}

// MARK: - Trim

/// In and out points, audio fades and pre-roll, all in seconds. `nil` points mean the start
/// or end of the source.
public struct TrimSettings: Codable, Sendable, Equatable, Hashable {
    public var inPoint: Double?
    public var outPoint: Double?
    public var fadeIn: Double
    public var fadeOut: Double
    public var preRoll: Double

    public init(inPoint: Double? = nil, outPoint: Double? = nil, fadeIn: Double = 0,
                fadeOut: Double = 0, preRoll: Double = 0) {
        self.inPoint = inPoint
        self.outPoint = outPoint
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
        self.preRoll = preRoll
    }

    public static let none = TrimSettings()
    /// Longest time value accepted from stored data (24 hours), so later `Int` conversions of
    /// seconds, frames and samples cannot overflow.
    public static let maximumSeconds = 86_400.0
    /// Fade lengths offered in the Job tab.
    public static let fadeChoices: [Double] = [0, 0.5, 1, 2, 5]
    /// Pre-roll lengths offered in the Job tab (0 is Off).
    public static let preRollChoices: [Double] = [0, 2, 3, 5, 10]

    /// No trim, no fades, no pre-roll: the clip is the whole source, as in build 10.
    public var isIdentity: Bool { self == .none }

    private enum CodingKeys: String, CodingKey { case inPoint, outPoint, fadeIn, fadeOut, preRoll }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let limit = Self.maximumSeconds
        inPoint = ((try? c.decodeIfPresent(Double.self, forKey: .inPoint)) ?? nil).map { min(limit, max(-limit, $0)) }
        outPoint = ((try? c.decodeIfPresent(Double.self, forKey: .outPoint)) ?? nil).map { min(limit, max(-limit, $0)) }
        fadeIn = min(limit, max(0, (try? c.decodeIfPresent(Double.self, forKey: .fadeIn)) ?? 0))
        fadeOut = min(limit, max(0, (try? c.decodeIfPresent(Double.self, forKey: .fadeOut)) ?? 0))
        preRoll = min(limit, max(0, (try? c.decodeIfPresent(Double.self, forKey: .preRoll)) ?? 0))
    }
}

// MARK: - Safe zones

public enum SafeZonePreset: String, Codable, Sendable, CaseIterable, Hashable {
    case none, evsOSD, custom

    public var title: String {
        switch self {
        case .none: return "None"
        case .evsOSD: return "EVS OSD"
        case .custom: return "Custom"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(SafeZonePreset.init(rawValue:)) ?? .none
    }
}

/// Reserved bands where a server overlay draws, in whole percent of picture height (top,
/// bottom) or width (left, right), so they hold for every resolution.
public struct SafeZones: Codable, Sendable, Equatable, Hashable {
    public struct Insets: Codable, Sendable, Equatable, Hashable {
        public var top: Int
        public var bottom: Int
        public var left: Int
        public var right: Int

        public init(top: Int = 0, bottom: Int = 0, left: Int = 0, right: Int = 0) {
            self.top = SafeZones.clamp(top)
            self.bottom = SafeZones.clamp(bottom)
            self.left = SafeZones.clamp(left)
            self.right = SafeZones.clamp(right)
        }

        public static let zero = Insets()
        public var isZero: Bool { self == .zero }

        private enum CodingKeys: String, CodingKey { case top, bottom, left, right }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func value(_ key: CodingKeys) -> Int { (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0 }
            self.init(top: value(.top), bottom: value(.bottom), left: value(.left), right: value(.right))
        }
    }

    public static let range = 0...30
    static func clamp(_ value: Int) -> Int { min(range.upperBound, max(range.lowerBound, value)) }

    /// Provisional until gate X1 measures the EVS OSD from a still of the cue output.
    public static let evsOSDInsets = Insets(top: 10, bottom: 20)

    public var preset: SafeZonePreset
    /// The operator's Custom values, kept while another preset is selected.
    public var custom: Insets

    public init(preset: SafeZonePreset = .none, custom: Insets = .zero) {
        self.preset = preset
        self.custom = custom
    }

    public static let none = SafeZones()

    /// The bands in force for the selected preset.
    public var insets: Insets {
        switch preset {
        case .none: return .zero
        case .evsOSD: return Self.evsOSDInsets
        case .custom: return custom
        }
    }

    private enum CodingKeys: String, CodingKey { case preset, custom }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = (try? c.decodeIfPresent(SafeZonePreset.self, forKey: .preset)) ?? .none
        custom = (try? c.decodeIfPresent(Insets.self, forKey: .custom)) ?? .zero
    }
}

// MARK: - Clock position and countdown target

public enum ClockPosition: String, Codable, Sendable, CaseIterable, Hashable {
    case below, above

    public var title: String { self == .below ? "Below waveforms" : "Above waveforms" }

    public init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(ClockPosition.init(rawValue:)) ?? .below
    }
}

public enum CountdownTarget: String, Codable, Sendable, CaseIterable, Hashable {
    case fileEnd, musicEnd

    public var title: String { self == .fileEnd ? "File end" : "Music end" }

    public init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(CountdownTarget.init(rawValue:)) ?? .fileEnd
    }
}

// MARK: - Preset identity

/// Stable identifier of an export preset. Encoded as a bare string.
public struct PresetID: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral,
                        CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}
