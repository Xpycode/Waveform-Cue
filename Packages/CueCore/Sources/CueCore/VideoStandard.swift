import Foundation

/// Picture format of an export: frame size, rates and scan order. Picture time on screen stays
/// on a 25-frame clock base; the render and encode rates come from here.
public struct VideoStandard: Codable, Sendable, Equatable, Hashable {
    public var width: Int
    public var height: Int
    /// Frames per second written to the file (25 for 1080i50 and 1080p25, 50 for 1080p50).
    public var encodeRate: Int
    /// Images per second drawn by the renderer. Interlaced output draws one image per field.
    public var renderRate: Int
    public var interlaced: Bool
    /// Top field first when interlaced; ignored for progressive pictures.
    public var topFieldFirst: Bool

    public init(width: Int, height: Int, encodeRate: Int, renderRate: Int, interlaced: Bool,
                topFieldFirst: Bool = true) {
        self.width = width
        self.height = height
        self.encodeRate = encodeRate
        self.renderRate = renderRate
        self.interlaced = interlaced
        self.topFieldFirst = topFieldFirst
    }

    public static let hd1080i50 = VideoStandard(width: 1920, height: 1080, encodeRate: 25, renderRate: 50, interlaced: true)
    public static let hd1080p25 = VideoStandard(width: 1920, height: 1080, encodeRate: 25, renderRate: 25, interlaced: false)
    public static let hd1080p50 = VideoStandard(width: 1920, height: 1080, encodeRate: 50, renderRate: 50, interlaced: false)

    public var size: (width: Int, height: Int) { (width, height) }
    public var sizeString: String { "\(width)x\(height)" }

    /// 48 kHz audio samples per encoded frame: 1920 at 25, 960 at 50.
    public var samplesPerFrame: Int { 48_000 / encodeRate }
    /// Rendered images per encoded frame (2 for interlaced 1080i50, otherwise 1).
    public var imagesPerFrame: Int { renderRate / encodeRate }
    /// Short name such as "1080i50" or "1080p25".
    public var shortName: String {
        let rate = interlaced ? renderRate : encodeRate
        return "\(height)\(interlaced ? "i" : "p")\(rate)"
    }
}
