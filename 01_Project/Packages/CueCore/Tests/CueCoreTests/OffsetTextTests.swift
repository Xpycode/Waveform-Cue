import XCTest
@testable import CueCore

final class OffsetTextTests: XCTestCase {
    func testDisplayUsesSignedWholePixels() {
        XCTAssertEqual(OffsetText.format(12), "+12 px")
        XCTAssertEqual(OffsetText.format(0), "0 px")
        XCTAssertEqual(OffsetText.format(-8), "−8 px")
        for value in [Int.min, -8, 0, 12, Int.max] {
            XCTAssertEqual(OffsetText.parse(OffsetText.format(value)), value)
        }
    }

    func testPlainSignedAndSuffixedInput() {
        for text in ["12", "+12", "12 px", "12px", " +12 px "] {
            XCTAssertEqual(OffsetText.parse(text), 12)
        }
        for text in ["-8", "−8", "−8 px", "-8px"] {
            XCTAssertEqual(OffsetText.parse(text), -8)
        }
        XCTAssertEqual(OffsetText.parse("0"), 0)
    }

    func testMalformedInputIsRejected() {
        for text in ["abc", "12.5", "", "   ", "px", "+", "−+8", "1 2 px", "12pxpx", "12 px more"] {
            XCTAssertNil(OffsetText.parse(text), text)
        }
    }
}
