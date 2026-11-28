import CoreText
import Foundation

/// Installed cue-picture fonts, the features used when shaping clocks, and layout measurements.
public enum CueFonts {
    public enum Role: Sendable {
        case title, clock

        fileprivate var defaultName: String {
            switch self {
            case .title: return "HelveticaNeue-Medium"
            case .clock: return "Menlo-Regular"
            }
        }
    }

    public struct Face: Hashable, Sendable {
        public let family: String
        public let style: String
        public let postScriptName: String
    }

    public struct Resolved {
        public let postScriptName: String
        public let role: Role
        fileprivate let descriptor: CTFontDescriptor

        public func font(at size: CGFloat) -> CTFont {
            CTFontCreateWithFontDescriptor(descriptor, size, nil)
        }
    }

    public struct Metrics: Equatable, Sendable {
        /// Layout extents above and below the baseline, both positive.
        public let ascent: CGFloat
        public let descent: CGFloat
        public let capHeight: CGFloat
        /// Width reserved for an eight-character timecode, including the layout's antialias allowance.
        public let clockWidth: CGFloat
    }

    public static func resolve(name: String?, role: Role) -> Resolved {
        let fallback = role == .clock ? defaultClock : defaultTitle
        guard let name, name != role.defaultName else { return fallback }
        let query = CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: name] as CFDictionary)
        guard let match = CTFontDescriptorCreateMatchingFontDescriptor(query, nil) else { return fallback }
        let font = CTFontCreateWithFontDescriptor(match, 100, nil)
        guard CTFontCopyPostScriptName(font) as String == name else { return fallback }
        let descriptor = role == .clock ? tabularDescriptor(for: font) : CTFontCopyFontDescriptor(font)
        if role == .clock, !clockFitsGrid(CTFontCreateWithFontDescriptor(descriptor, 100, nil)) {
            return fallback
        }
        return Resolved(postScriptName: name, role: role, descriptor: descriptor)
    }

    private static let defaultClock = Resolved(postScriptName: Role.clock.defaultName, role: .clock,
        descriptor: tabularDescriptor(for: CTFontCreateWithName("Menlo" as CFString, 100, nil)))
    private static let defaultTitle = Resolved(postScriptName: Role.title.defaultName, role: .title,
        descriptor: CTFontDescriptorCreateWithNameAndSize(Role.title.defaultName as CFString, 100))

    private static func tabularDescriptor(for font: CTFont) -> CTFontDescriptor {
        CTFontDescriptorCreateCopyWithFeature(CTFontCopyFontDescriptor(font),
                                              kNumberSpacingType as NSNumber, kMonospacedNumbersSelector as NSNumber)
    }

    private static func line(_ text: String, in font: CTFont) -> CTLine {
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func lineWidth(_ text: String, in font: CTFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, in: font), nil, nil, nil))
    }

    /// Check shaped digits at a common point size, with the same feature used by the renderer.
    public static func hasEqualWidthDigits(_ font: CTFont) -> Bool {
        clockFitsGrid(CTFontCreateWithFontDescriptor(tabularDescriptor(for: font), 100, nil))
    }

    private static let gridChecks = NSCache<CTFont, NSNumber>()

    private static func clockFitsGrid(_ font: CTFont) -> Bool {
        if let cached = gridChecks.object(forKey: font) { return cached.boolValue }
        let fits = digitsMatch(in: font)
        gridChecks.setObject(NSNumber(value: fits), forKey: font)
        return fits
    }

    // Ten shaped lines cover all 100 digit pairs, both sides of the colon, and each digit
    // at the start and end of a line. Rotating the units digit varies the final digit too.
    private static let pairRows = (0..<10).map { tens in
        (0..<10).map { "\(tens)\((tens + $0) % 10)" }.joined(separator: ":")
    }
    private static let referenceRow = Array(repeating: "00", count: 10).joined(separator: ":")

    private static func digitsMatch(in font: CTFont) -> Bool {
        // Core Text will otherwise substitute another face for missing digits or the colon.
        let characters = Array("0123456789:".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else { return false }
        let reference = lineWidth("0", in: font)
        guard reference > 0,
              (1...9).allSatisfy({ abs(lineWidth(String($0), in: font) - reference) < 0.001 }) else { return false }

        // Kerning and contextual glyph substitutions can still shift a timecode even when
        // isolated digits measure equally. Check every column so two shifts cannot cancel.
        let zeroLine = line(referenceRow, in: font)
        let offsets = (0...referenceRow.utf16.count).map { CTLineGetOffsetForStringIndex(zeroLine, $0, nil) }
        return pairRows.allSatisfy { row in
            let shaped = line(row, in: font)
            return offsets.enumerated().allSatisfy { index, expected in
                abs(CTLineGetOffsetForStringIndex(shaped, index, nil) - expected) < 0.001
            }
        }
    }

    public static func metrics(for resolved: Resolved, size: CGFloat) -> Metrics {
        typealias M = CueLayout.Metrics
        let font = resolved.font(at: size)
        let capHeight = CTFontGetCapHeight(font)
        // Retain the rounded measurements used by old jobs, including when their face was
        // explicitly reselected in the inspector or reached via fallback.
        if resolved.postScriptName == resolved.role.defaultName {
            if resolved.role == .clock {
                return Metrics(ascent: M.digitAscent * size, descent: M.digitDescent * size, capHeight: capHeight,
                               clockWidth: CGFloat(M.clockCharacters) * M.monoAdvance * size + M.antialias)
            }
            return Metrics(ascent: M.labelAscent * size, descent: M.labelDescent * size, capHeight: capHeight,
                           clockWidth: lineWidth("88:88:88", in: font) + M.antialias)
        }
        return Metrics(ascent: CTFontGetAscent(font), descent: CTFontGetDescent(font), capHeight: capHeight,
                       clockWidth: lineWidth("88:88:88", in: font) + M.antialias)
    }

    public static func titleCandidates() -> [Face] { installedFaces }
    public static func clockCandidates() -> [Face] { installedClockFaces }

    private static let installedFaces: [Face] = {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] ?? []
        var seen = Set<String>()
        let faces = descriptors.compactMap { descriptor -> Face? in
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String,
                  let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  let style = CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String,
                  !family.hasPrefix("."), !name.hasPrefix("."), seen.insert(name).inserted else { return nil }
            return Face(family: family, style: style, postScriptName: name)
        }
        return faces.sorted {
            if $0.family != $1.family { return $0.family.localizedStandardCompare($1.family) == .orderedAscending }
            if $0.style != $1.style { return $0.style.localizedStandardCompare($1.style) == .orderedAscending }
            return $0.postScriptName < $1.postScriptName
        }
    }()

    private static let installedClockFaces = installedFaces.filter {
        hasEqualWidthDigits(CTFontCreateWithName($0.postScriptName as CFString, 100, nil))
    }
}
