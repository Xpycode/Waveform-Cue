import AppKit

struct CueColor: Codable {
    let red: Double
    let green: Double
    let blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init?(_ color: NSColor) {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        self.init(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }

    var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: 1) }
    var dimmed: CueColor {
        CueColor(red * 0.65, green * 0.65, blue * 0.65)
    }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: 1) }

    static let warningRed = CueColor(1, 0.23, 0.20)

    func blended(toward target: CueColor, fraction: Double) -> CueColor {
        if fraction <= 0 { return self }
        if fraction >= 1 { return target }
        return CueColor(red + (target.red - red) * fraction,
                        green + (target.green - green) * fraction,
                        blue + (target.blue - blue) * fraction)
    }
}

enum ClockSize: String, Codable, CaseIterable {
    case small = "Small", medium = "Medium", large = "Large", extraLarge = "Extra large"

    var points: CGFloat {
        switch self {
        case .small: return 60
        case .medium: return 80
        case .large: return 103
        case .extraLarge: return 128
        }
    }
}

struct ClockStyle: Codable {
    var color: CueColor
    var size: ClockSize
}

enum ZoomWindow: Int, Codable, CaseIterable {
    case off = -1, auto = 0, two = 2, five = 5, ten = 10, twenty = 20, thirty = 30, sixty = 60

    var title: String {
        switch self {
        case .off: return "Off"
        case .auto: return "Auto"
        default: return "\(rawValue) seconds"
        }
    }

    func frameCount(for total: Int) -> Int {
        if self == .off { return total }
        if self == .auto { return min(10 * AudioTrack.fps, max(1, total / 2)) }
        return min(total, rawValue * AudioTrack.fps)
    }
}

enum CountdownWarning: Int, Codable, CaseIterable {
    case off = 0, five = 5, ten = 10

    var title: String { self == .off ? "Off" : "\(rawValue) seconds" }

    func fraction(framesLeft: Int, solidAt: SolidRedThreshold) -> Double {
        let start = rawValue * AudioTrack.fps
        guard self != .off, framesLeft < start else { return 0 }
        guard framesLeft > solidAt.frames else { return 1 }
        return Double(start - framesLeft) / Double(start - solidAt.frames)
    }
}

enum SolidRedThreshold: String, Codable, CaseIterable {
    case lastFrame, oneSecond

    var frames: Int { self == .lastFrame ? 1 : AudioTrack.fps }
    var title: String { self == .lastFrame ? "Last frame" : "1 second" }
}

struct CueAppearance: Codable {
    static let defaultOverview = CueColor(0.44, 0.54, 0.55)
    static let defaultDetail = CueColor(0.45, 0.74, 0.66)
    var overviewColor: CueColor?
    var detailColor: CueColor?
    var warning: CountdownWarning = .off
    var solidRedAt: SolidRedThreshold = .lastFrame
    var fadeCloseUp = true
    var fadeFullTrack = false
    var zoom: ZoomWindow = .auto
    var elapsed = ClockStyle(color: CueColor(0.84, 0.88, 0.88), size: .medium)
    var remaining = ClockStyle(color: CueColor(0.93, 0.77, 0.52), size: .medium)

    // Build 4 stored only the clocks under this key.
    private static let key = "ClockAppearance.v1"

    init() {}

    init(from decoder: Decoder) throws {
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
    }

    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return saved
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
