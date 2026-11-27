import AppKit

public struct CueColor: Codable, Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }

    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    public var dimmed: CueColor {
        CueColor(red * 0.65, green * 0.65, blue * 0.65)
    }
    public var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    public static let warningRed = CueColor(1, 0.23, 0.20)

    public func blended(toward target: CueColor, fraction: Double) -> CueColor {
        if fraction <= 0 { return self }
        if fraction >= 1 { return target }
        return CueColor(red + (target.red - red) * fraction,
                        green + (target.green - green) * fraction,
                        blue + (target.blue - blue) * fraction)
    }
}

public enum ClockSize: String, Codable, Sendable, CaseIterable {
    case small = "Small", medium = "Medium", large = "Large", extraLarge = "Extra large"

    public var points: CGFloat {
        switch self {
        case .small: return 60
        case .medium: return 80
        case .large: return 103
        case .extraLarge: return 128
        }
    }
}

public struct ClockStyle: Codable, Sendable, Equatable {
    public var color: CueColor
    public var size: ClockSize
}

public enum ZoomWindow: Int, Codable, Sendable, CaseIterable {
    case off = -1, auto = 0, two = 2, five = 5, ten = 10, twenty = 20, thirty = 30, sixty = 60

    public var title: String {
        switch self {
        case .off: return "Off"
        case .auto: return "Auto"
        default: return "\(rawValue) seconds"
        }
    }

    public func frameCount(for total: Int) -> Int {
        if self == .off { return total }
        if self == .auto { return min(10 * AudioTrack.fps, max(1, total / 2)) }
        return min(total, rawValue * AudioTrack.fps)
    }
}

public enum CountdownWarning: Int, Codable, Sendable, CaseIterable {
    case off = 0, five = 5, ten = 10

    public var title: String { self == .off ? "Off" : "\(rawValue) seconds" }

    public func fraction(framesLeft: Int, solidAt: SolidRedThreshold) -> Double {
        let start = rawValue * AudioTrack.fps
        guard self != .off, framesLeft < start else { return 0 }
        guard framesLeft > solidAt.frames else { return 1 }
        return Double(start - framesLeft) / Double(start - solidAt.frames)
    }
}

public enum SolidRedThreshold: String, Codable, Sendable, CaseIterable {
    case lastFrame, oneSecond

    public var frames: Int { self == .lastFrame ? 1 : AudioTrack.fps }
    public var title: String { self == .lastFrame ? "Last frame" : "1 second" }
}

public enum CloseUpShading: String, Codable, CaseIterable, Sendable {
    case upcomingBrighter, playedBrighter
}

public struct CueAppearance: Codable, Sendable, Equatable {
    public static let defaultOverview = CueColor(0.44, 0.54, 0.55)
    public static let defaultDetail = CueColor(0.45, 0.74, 0.66)
    public var overviewColor: CueColor?
    public var detailColor: CueColor?
    public var warning: CountdownWarning = .off
    public var solidRedAt: SolidRedThreshold = .lastFrame
    public var fadeCloseUp = true
    public var fadeFullTrack = false
    public var zoom: ZoomWindow = .auto
    public var elapsed = ClockStyle(color: CueColor(0.84, 0.88, 0.88), size: .medium)
    public var remaining = ClockStyle(color: CueColor(0.93, 0.77, 0.52), size: .medium)
    /// Bands kept clear for a server overlay (spec F). None is build 10's layout.
    public var safeZones: SafeZones = .none
    /// Clocks below (build 10) or above the waveforms.
    public var clockPosition: ClockPosition = .below
    /// What Remaining counts down to. Rendering of Music end arrives in task 3.2.
    public var countdownTarget: CountdownTarget = .fileEnd
    /// Hatched safe-zone guides over the monitor only; never part of an export.
    public var showGuides = false

    /// PostScript names. A missing name selects the standard font for that role.
    public var titleFontName: String?
    public var clockFontName: String?

    // Optional storage keeps older snapshots readable. Callers always see a usable choice.
    private var storedShowTitle: Bool?
    private var storedShowElapsed: Bool?
    private var storedShowRemaining: Bool?
    private var storedShowFullTrack: Bool?
    private var storedPlayheadMode: PlayheadMode?
    private var storedEndZoom: EndZoom?
    private var storedCloseUpShading: CloseUpShading? = .upcomingBrighter
    private var storedMarkersEnabled: Bool?
    private var storedLoudnessAnalysisEnabled: Bool?
    private var storedTrimAndFadesEnabled: Bool?
    private var storedPreRollEnabled: Bool?
    private var storedSafeZonesEnabled: Bool?

    public var showTitle: Bool {
        get { storedShowTitle ?? true }
        set { storedShowTitle = newValue ? nil : false }
    }
    public var showElapsed: Bool {
        get { storedShowElapsed ?? true }
        set { storedShowElapsed = newValue ? nil : false }
    }
    public var showRemaining: Bool {
        get { storedShowRemaining ?? true }
        set { storedShowRemaining = newValue ? nil : false }
    }
    public var showFullTrack: Bool {
        get { storedShowFullTrack ?? true }
        set { storedShowFullTrack = newValue ? nil : false }
    }
    public var playheadMode: PlayheadMode {
        get { storedPlayheadMode ?? .edgeHeld }
        set { storedPlayheadMode = newValue == .edgeHeld ? nil : newValue }
    }
    public var endZoom: EndZoom {
        get { storedEndZoom ?? .off }
        set { storedEndZoom = newValue == .off ? nil : newValue }
    }
    public var closeUpShading: CloseUpShading {
        get { storedCloseUpShading ?? .upcomingBrighter }
        set { storedCloseUpShading = newValue }
    }
    public var markersEnabled: Bool {
        get { storedMarkersEnabled ?? true }
        set { storedMarkersEnabled = newValue ? nil : false }
    }
    public var loudnessAnalysisEnabled: Bool {
        get { storedLoudnessAnalysisEnabled ?? true }
        set { storedLoudnessAnalysisEnabled = newValue ? nil : false }
    }
    public var trimAndFadesEnabled: Bool {
        get { storedTrimAndFadesEnabled ?? true }
        set { storedTrimAndFadesEnabled = newValue ? nil : false }
    }
    public var preRollEnabled: Bool {
        get { storedPreRollEnabled ?? true }
        set { storedPreRollEnabled = newValue ? nil : false }
    }
    public var safeZonesEnabled: Bool {
        get { storedSafeZonesEnabled ?? true }
        set { storedSafeZonesEnabled = newValue ? nil : false }
    }

    /// The picture geometry for this appearance. Compute it once per appearance change and
    /// share it between the preview, hit-testing and the export.
    public var layout: CueLayout {
        CueLayout(appearance: self, clockPosition: clockPosition, safeZones: safeZones)
    }

    // Build 4 stored only the clocks under this key.
    private static let key = "ClockAppearance.v1"

    private enum CodingKeys: String, CodingKey {
        case overviewColor, detailColor, warning, solidRedAt, fadeCloseUp, fadeFullTrack, zoom
        case elapsed, remaining, safeZones, clockPosition, countdownTarget, showGuides
        case titleFontName, clockFontName
        case storedShowTitle = "showTitle"
        case storedShowElapsed = "showElapsed"
        case storedShowRemaining = "showRemaining"
        case storedShowFullTrack = "showFullTrack"
        case storedPlayheadMode = "playheadMode"
        case storedEndZoom = "endZoom"
        case storedCloseUpShading = "closeUpShading"
        case storedMarkersEnabled = "markersEnabled"
        case storedLoudnessAnalysisEnabled = "loudnessAnalysisEnabled"
        case storedTrimAndFadesEnabled = "trimAndFadesEnabled"
        case storedPreRollEnabled = "preRollEnabled"
        case storedSafeZonesEnabled = "safeZonesEnabled"
    }

    // Old queue snapshots and old import defaults have different shading migrations.
    private static let missingShadingKey = CodingUserInfoKey(rawValue: "WaveformCue.missingCloseUpShading")!

    static var legacyJobAppearance: Self {
        var appearance = Self()
        appearance.closeUpShading = .playedBrighter
        return appearance
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        elapsed = try values.decode(ClockStyle.self, forKey: .elapsed)
        remaining = try values.decode(ClockStyle.self, forKey: .remaining)
        overviewColor = try values.decodeIfPresent(CueColor.self, forKey: .overviewColor)
        detailColor = try values.decodeIfPresent(CueColor.self, forKey: .detailColor)
        warning = try values.decodeIfPresent(CountdownWarning.self, forKey: .warning) ?? .off
        solidRedAt = try values.decodeIfPresent(SolidRedThreshold.self, forKey: .solidRedAt) ?? .lastFrame
        // Older releases never tinted the close-up. Preserve their saved appearance.
        fadeCloseUp = try values.decodeIfPresent(Bool.self, forKey: .fadeCloseUp) ?? false
        fadeFullTrack = try values.decodeIfPresent(Bool.self, forKey: .fadeFullTrack) ?? false
        zoom = try values.decodeIfPresent(ZoomWindow.self, forKey: .zoom) ?? .auto
        // Added in the batch round; build 10 appearances have none of these keys.
        safeZones = (try? values.decodeIfPresent(SafeZones.self, forKey: .safeZones)) ?? .none
        clockPosition = (try? values.decodeIfPresent(ClockPosition.self, forKey: .clockPosition)) ?? .below
        countdownTarget = (try? values.decodeIfPresent(CountdownTarget.self, forKey: .countdownTarget)) ?? .fileEnd
        showGuides = (try? values.decodeIfPresent(Bool.self, forKey: .showGuides)) ?? false

        func optional<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            try? values.decodeIfPresent(type, forKey: key)
        }
        titleFontName = optional(String.self, .titleFontName)
        clockFontName = optional(String.self, .clockFontName)
        showTitle = optional(Bool.self, .storedShowTitle) ?? true
        showElapsed = optional(Bool.self, .storedShowElapsed) ?? true
        showRemaining = optional(Bool.self, .storedShowRemaining) ?? true
        showFullTrack = optional(Bool.self, .storedShowFullTrack) ?? true
        playheadMode = optional(PlayheadMode.self, .storedPlayheadMode) ?? .edgeHeld
        endZoom = optional(EndZoom.self, .storedEndZoom) ?? .off
        let legacyShading = decoder.userInfo[Self.missingShadingKey] as? CloseUpShading ?? .playedBrighter
        closeUpShading = optional(CloseUpShading.self, .storedCloseUpShading) ?? legacyShading
        markersEnabled = optional(Bool.self, .storedMarkersEnabled) ?? true
        loudnessAnalysisEnabled = optional(Bool.self, .storedLoudnessAnalysisEnabled) ?? true
        trimAndFadesEnabled = optional(Bool.self, .storedTrimAndFadesEnabled) ?? true
        preRollEnabled = optional(Bool.self, .storedPreRollEnabled) ?? true
        safeZonesEnabled = optional(Bool.self, .storedSafeZonesEnabled) ?? true
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        let decoder = JSONDecoder()
        decoder.userInfo[missingShadingKey] = CloseUpShading.upcomingBrighter
        guard let data = defaults.data(forKey: key),
              let saved = try? decoder.decode(Self.self, from: data) else { return Self() }
        return saved
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }
}

extension CueAppearance {
    public enum Setting: CaseIterable, Sendable {
        case overviewColor, detailColor, warning, solidRedAt, fadeCloseUp, fadeFullTrack, zoom
        case elapsedColor, elapsedSize, remainingColor, remainingSize
        case safeZonePreset, safeZoneTop, safeZoneBottom, safeZoneLeft, safeZoneRight
        case clockPosition, countdownTarget, showGuides
        case titleFontName, clockFontName, showTitle, showElapsed, showRemaining, showFullTrack
        case playheadMode, endZoom, closeUpShading
        case markersEnabled, loudnessAnalysisEnabled, trimAndFadesEnabled, preRollEnabled, safeZonesEnabled

        /// The same key path identifies the value for both comparison and reset.
        fileprivate func copy(from source: CueAppearance, to target: inout CueAppearance) -> Bool {
            func copy<Value: Equatable>(_ key: WritableKeyPath<CueAppearance, Value>) -> Bool {
                guard target[keyPath: key] != source[keyPath: key] else { return false }
                target[keyPath: key] = source[keyPath: key]
                return true
            }
            switch self {
            case .overviewColor: return copy(\.overviewColor)
            case .detailColor: return copy(\.detailColor)
            case .warning: return copy(\.warning)
            case .solidRedAt: return copy(\.solidRedAt)
            case .fadeCloseUp: return copy(\.fadeCloseUp)
            case .fadeFullTrack: return copy(\.fadeFullTrack)
            case .zoom: return copy(\.zoom)
            case .elapsedColor: return copy(\.elapsed.color)
            case .elapsedSize: return copy(\.elapsed.size)
            case .remainingColor: return copy(\.remaining.color)
            case .remainingSize: return copy(\.remaining.size)
            case .safeZonePreset: return copy(\.safeZones.preset)
            case .safeZoneTop: return copy(\.safeZones.custom.top)
            case .safeZoneBottom: return copy(\.safeZones.custom.bottom)
            case .safeZoneLeft: return copy(\.safeZones.custom.left)
            case .safeZoneRight: return copy(\.safeZones.custom.right)
            case .clockPosition: return copy(\.clockPosition)
            case .countdownTarget: return copy(\.countdownTarget)
            case .showGuides: return copy(\.showGuides)
            case .titleFontName: return copy(\.titleFontName)
            case .clockFontName: return copy(\.clockFontName)
            case .showTitle: return copy(\.showTitle)
            case .showElapsed: return copy(\.showElapsed)
            case .showRemaining: return copy(\.showRemaining)
            case .showFullTrack: return copy(\.showFullTrack)
            case .playheadMode: return copy(\.playheadMode)
            case .endZoom: return copy(\.endZoom)
            case .closeUpShading: return copy(\.closeUpShading)
            case .markersEnabled: return copy(\.markersEnabled)
            case .loudnessAnalysisEnabled: return copy(\.loudnessAnalysisEnabled)
            case .trimAndFadesEnabled: return copy(\.trimAndFadesEnabled)
            case .preRollEnabled: return copy(\.preRollEnabled)
            case .safeZonesEnabled: return copy(\.safeZonesEnabled)
            }
        }
    }

    /// A default colour or face selected explicitly has the same meaning as its omitted value.
    /// Preserve a requested face name even when the font is absent on the current machine.
    private var comparableSettings: Self {
        var copy = self
        copy.overviewColor = overviewColor ?? Self.defaultOverview
        copy.detailColor = detailColor ?? Self.defaultDetail
        copy.titleFontName = titleFontName ?? CueFonts.resolve(name: nil, role: .title).postScriptName
        copy.clockFontName = clockFontName ?? CueFonts.resolve(name: nil, role: .clock).postScriptName
        return copy
    }

    public func differences(from other: Self) -> Set<Setting> {
        var current = comparableSettings
        let reference = other.comparableSettings
        return Set(Setting.allCases.filter { $0.copy(from: reference, to: &current) })
    }

    public func resetting(_ setting: Setting, to saved: Self) -> Self {
        var result = self
        _ = setting.copy(from: saved, to: &result)
        return result
    }
}
