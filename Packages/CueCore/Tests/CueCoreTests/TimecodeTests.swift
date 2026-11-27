import XCTest
@testable import CueCore

final class TimecodeTests: XCTestCase {
    func testParseAndFormat() {
        let tc = Timecode("10:20:30:24")
        XCTAssertEqual(tc?.hours, 10)
        XCTAssertEqual(tc?.minutes, 20)
        XCTAssertEqual(tc?.seconds, 30)
        XCTAssertEqual(tc?.frames, 24)
        XCTAssertEqual(tc?.formatted, "10:20:30:24")
        XCTAssertEqual(Timecode("1:2:3:4")?.formatted, "01:02:03:04")
        XCTAssertEqual(Timecode("00:00:00;12")?.formatted, "00:00:00:12")
        XCTAssertEqual(Timecode("  00:00:01:00 ")?.formatted, "00:00:01:00")
        XCTAssertEqual(Timecode.start.formatted, "00:00:00:00")
    }

    func testRejectsInvalidFields() {
        for bad in ["", "00:00:00", "00:00:00:00:00", "24:00:00:00", "00:60:00:00", "00:00:60:00",
                    "00:00:00:25", "ab:00:00:00", "-1:00:00:00", "000:00:00:00", "00:00:00:", "00 00 00 00"] {
            XCTAssertNil(Timecode(bad), bad)
        }
        XCTAssertNil(Timecode("00:00:00:50", fps: 25))
        XCTAssertNotNil(Timecode("00:00:00:49", fps: 50))
        XCTAssertNil(Timecode("00:00:00:50", fps: 50))
        XCTAssertNil(Timecode("00:00:00:00", fps: 30))
        XCTAssertNil(Timecode(hours: 0, minutes: 0, seconds: 0, frames: -1, fps: 25))
    }

    func testTotalFramesRoundTrip() {
        for fps in [25, 50] {
            let tc = Timecode("23:59:59:\(fps - 1)", fps: fps)!
            XCTAssertEqual(tc.totalFrames, 24 * 3600 * fps - 1)
            XCTAssertEqual(Timecode(totalFrames: tc.totalFrames, fps: fps), tc)
        }
        XCTAssertEqual(Timecode(totalFrames: 24 * 3600 * 25, fps: 25).formatted, "00:00:00:00")
    }

    func testSubtractPreRollWrapsPastMidnight() {
        XCTAssertEqual(Timecode.start.subtracting(seconds: 5).formatted, "23:59:55:00")
        XCTAssertEqual(Timecode("00:00:02:10")!.subtracting(seconds: 3).formatted, "23:59:59:10")
        XCTAssertEqual(Timecode("10:00:00:00")!.subtracting(seconds: 10).formatted, "09:59:50:00")
        XCTAssertEqual(Timecode("00:00:00:00", fps: 50)!.subtracting(seconds: 2).formatted, "23:59:58:00")
        XCTAssertEqual(Timecode.start.subtracting(seconds: 0).formatted, "00:00:00:00")
        XCTAssertEqual(Timecode.start.subtracting(seconds: 0.04).formatted, "23:59:59:24")
        XCTAssertEqual(Timecode("23:59:59:24")!.adding(seconds: 0.04).formatted, "00:00:00:00")
    }

    func testConversionBetweenRates() {
        XCTAssertEqual(Timecode("01:02:03:12")!.converted(toFPS: 50).formatted, "01:02:03:24")
        XCTAssertEqual(Timecode("01:02:03:24", fps: 50)!.converted(toFPS: 25).formatted, "01:02:03:12")
        XCTAssertEqual(Timecode("01:02:03:24")!.converted(toFPS: 50).fps, 50)
        let same = Timecode("01:02:03:04")!
        XCTAssertEqual(same.converted(toFPS: 25), same)
    }
}
