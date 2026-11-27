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
    /// Keep the close-up playhead centred over the first half-window, with empty space before
    /// the music. Off is build 10's behaviour: the window holds still and the playhead travels.
    public var centerAtStart = true
    /// As `centerAtStart`, for the last half-window, with empty space after the file end.
    public var centerAtEnd = true
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

    /// The picture geometry for this appearance. Compute it once per appearance change and
    /// share it between the preview, hit-testing and the export.
    public var layout: CueLayout {
        CueLayout(appearance: self, clockPosition: clockPosition, safeZones: safeZones)
    }

    // Build 4 stored only the clocks under this key.
    private static let key = "ClockAppearance.v1"

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
        // Added after build 12; saved appearances take the new centred default (operator, 2026-11-28).
        centerAtStart = (try? values.decodeIfPresent(Bool.self, forKey: .centerAtStart)) ?? true
        centerAtEnd = (try? values.decodeIfPresent(Bool.self, forKey: .centerAtEnd)) ?? true
        // Added in the batch round; build 10 appearances have none of these keys.
        safeZones = (try? values.decodeIfPresent(SafeZones.self, forKey: .safeZones)) ?? .none
        clockPosition = (try? values.decodeIfPresent(ClockPosition.self, forKey: .clockPosition)) ?? .below
        countdownTarget = (try? values.decodeIfPresent(CountdownTarget.self, forKey: .countdownTarget)) ?? .fileEnd
        showGuides = (try? values.decodeIfPresent(Bool.self, forKey: .showGuides)) ?? false
    }

    public static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return saved
    }

    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
