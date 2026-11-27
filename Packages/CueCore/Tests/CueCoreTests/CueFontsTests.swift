import CoreText
import XCTest
@testable import CueCore

final class CueFontsTests: XCTestCase {
    private func font(_ name: String, at size: CGFloat = 100) -> CTFont {
        CTFontCreateWithName(name as CFString, size, nil)
    }

    private func width(_ text: String, in font: CTFont) -> CGFloat {
        let text = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil))
    }

    func testMissingAndAbsentNamesSelectLegacyFacesAndMeasurements() {
        typealias M = CueLayout.Metrics
        for name: String? in [nil, "WaveformCue-NonexistentFont"] {
            let title = CueFonts.resolve(name: name, role: .title)
            let clock = CueFonts.resolve(name: name, role: .clock)
            XCTAssertEqual(title.postScriptName, CTFontCopyPostScriptName(font("HelveticaNeue-Medium")) as String)
            XCTAssertEqual(clock.postScriptName, CTFontCopyPostScriptName(font("Menlo")) as String)
            for size in ClockSize.allCases {
                let label = CueFonts.metrics(for: title, size: size.points)
                let digits = CueFonts.metrics(for: clock, size: size.points)
                XCTAssertEqual(label.ascent, M.labelAscent * size.points)
                XCTAssertEqual(label.descent, M.labelDescent * size.points)
                XCTAssertEqual(digits.ascent, M.digitAscent * size.points)
                XCTAssertEqual(digits.descent, M.digitDescent * size.points)
                XCTAssertEqual(digits.clockWidth, CueLayout.clockWidth(size))
                XCTAssertEqual(width("00:12:24", in: clock.font(at: size.points)),
                               width("00:12:24", in: font("Menlo", at: size.points)))
            }
        }
    }

    func testClockEligibilityAndResolvedDigitWidths() {
        XCTAssertTrue(CueFonts.hasEqualWidthDigits(font("Menlo")))
        XCTAssertTrue(CueFonts.hasEqualWidthDigits(font("HelveticaNeue")))
        XCTAssertFalse(CueFonts.hasEqualWidthDigits(font("Georgia")))
        let selected = CueFonts.resolve(name: "HelveticaNeue", role: .clock)
        XCTAssertEqual(selected.postScriptName, "HelveticaNeue")
        let sized = selected.font(at: 84)
        let reference = width("00:00:00", in: sized)
        for digit in 1...9 {
            let pair = String(repeating: String(digit), count: 2)
            XCTAssertEqual(width([pair, pair, pair].joined(separator: ":"), in: sized), reference, accuracy: 0.001)
        }
        let metrics = CueFonts.metrics(for: selected, size: 84)
        XCTAssertEqual(metrics.clockWidth, reference + CueLayout.Metrics.antialias, accuracy: 0.001)
        XCTAssertEqual(metrics.capHeight, CTFontGetCapHeight(sized))
    }

    func testCandidatesExposeFamilyAndStyleAndOnlyEligibleClockFaces() throws {
        let titles = CueFonts.titleCandidates()
        let clocks = CueFonts.clockCandidates()
        let georgia = try XCTUnwrap(titles.first { $0.postScriptName == "Georgia" })
        XCTAssertEqual(georgia.family, "Georgia")
        XCTAssertFalse(georgia.style.isEmpty)
        XCTAssertFalse(clocks.contains(georgia))
        XCTAssertTrue(clocks.contains { $0.postScriptName == "Menlo-Regular" })
        XCTAssertEqual(Set(clocks.map(\.postScriptName)).count, clocks.count)
        XCTAssertTrue(Set(clocks).isSubset(of: Set(titles)))
    }

    func testClockRejectsFacesWhoseMixedReadingsShiftDespiteEqualIsolatedDigits() {
        let candidates = Set(CueFonts.clockCandidates().map(\.postScriptName))
        for (name, reading) in [("AmericanTypewriter", "00:00:01"), ("EuphemiaUCAS", "00:00:11")] {
            let raw = font(name)
            let descriptor = CTFontDescriptorCreateCopyWithFeature(CTFontCopyFontDescriptor(raw),
                kNumberSpacingType as NSNumber, kMonospacedNumbersSelector as NSNumber)
            let tabular = CTFontCreateWithFontDescriptor(descriptor, 100, nil)
            for digit in 1...9 {
                XCTAssertEqual(width(String(digit), in: tabular), width("0", in: tabular), accuracy: 0.001, name)
            }
            XCTAssertNotEqual(width(reading, in: tabular), width("00:00:00", in: tabular), accuracy: 0.001, name)
            XCTAssertFalse(CueFonts.hasEqualWidthDigits(raw), name)
            XCTAssertFalse(candidates.contains(name))
            let clock = CueFonts.resolve(name: name, role: .clock)
            XCTAssertEqual(clock.postScriptName, "Menlo-Regular")
            XCTAssertEqual(width(reading, in: clock.font(at: 100)), width("00:00:00", in: clock.font(at: 100)))
            XCTAssertEqual(CueFonts.resolve(name: name, role: .title).postScriptName, name)
        }
    }
}
