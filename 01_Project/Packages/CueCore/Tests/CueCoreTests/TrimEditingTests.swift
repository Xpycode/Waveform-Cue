import CueCore
import XCTest

/// The Job tab's trim rules and the I and O keys (task 5.1), and the preview position mapping
/// the app's playback uses.
final class TrimEditingTests: XCTestCase {
    func testSettingInAndOutClampAndClearAtTheSourceEdges() {
        let trim = TrimSettings(fadeIn: 1, preRoll: 3)
        XCTAssertEqual(trim.settingIn(2.5, duration: 10).inPoint, 2.5)
        XCTAssertNil(trim.settingIn(0, duration: 10).inPoint, "the source start is no trim")
        XCTAssertNil(trim.settingIn(-4, duration: 10).inPoint)
        XCTAssertNil(trim.settingIn(nil, duration: 10).inPoint, "an empty field clears the point")
        XCTAssertEqual(trim.settingOut(7, duration: 10).outPoint, 7)
        XCTAssertNil(trim.settingOut(10, duration: 10).outPoint, "the source end is no trim")
        XCTAssertNil(trim.settingOut(25, duration: 10).outPoint)
        XCTAssertNil(trim.settingOut(.nan, duration: 10).outPoint)
        // Fades and pre-roll are kept.
        let edited = trim.settingIn(2, duration: 10).settingOut(8, duration: 10)
        XCTAssertEqual(edited, TrimSettings(inPoint: 2, outPoint: 8, fadeIn: 1, preRoll: 3))
    }

    func testAPointPastTheOtherClearsIt() {
        let trim = TrimSettings(inPoint: 2, outPoint: 6)
        XCTAssertEqual(trim.settingIn(7, duration: 10), TrimSettings(inPoint: 7), "in past out clears out")
        XCTAssertEqual(trim.settingIn(6, duration: 10), TrimSettings(inPoint: 6))
        XCTAssertEqual(trim.settingOut(1, duration: 10), TrimSettings(outPoint: 1), "out before in clears in")
        XCTAssertEqual(trim.settingIn(5.5, duration: 10), TrimSettings(inPoint: 5.5, outPoint: 6),
                       "a range under a second is kept; the queue blocks it")
    }

    func testPositionsMapToSourceTimeWithTrimAndPreRoll() {
        let timeline = ClipTimeline(duration: 10, trim: TrimSettings(inPoint: 2, outPoint: 6, preRoll: 3))
        XCTAssertEqual(timeline.preRollPositions, 75)
        XCTAssertEqual(timeline.positionCount, 75 + 100)
        XCTAssertTrue(timeline.isSlate(0))
        XCTAssertTrue(timeline.isSlate(74))
        XCTAssertFalse(timeline.isSlate(75))
        XCTAssertEqual(timeline.sourceSeconds(at: 0), 2, "the slate shows the in point")
        XCTAssertEqual(timeline.sourceSeconds(at: 75), 2)
        XCTAssertEqual(timeline.sourceSeconds(at: 100), 3, accuracy: 1e-9)
        XCTAssertEqual(timeline.sourceSeconds(at: 175), 6)
        XCTAssertEqual(timeline.position(ofSourceSeconds: 2), 75)
        XCTAssertEqual(timeline.position(ofSourceSeconds: 3), 100)
        XCTAssertEqual(timeline.position(ofSourceSeconds: 3.03), 100, "rounds down to the frame showing it")
        XCTAssertEqual(timeline.position(ofSourceSeconds: 0.5), 75, "before the in point clamps to it")
        XCTAssertEqual(timeline.position(ofSourceSeconds: 6), 175, "the out point is the end")
        XCTAssertEqual(timeline.position(ofSourceSeconds: 9), 175)
        // Round trip over every music position.
        for position in 75...175 {
            XCTAssertEqual(timeline.position(ofSourceSeconds: timeline.sourceSeconds(at: position)), position)
        }
    }

    func testUntrimmedPositionsAreTrackFrames() {
        let timeline = ClipTimeline(duration: 4.52)
        let track = AudioTrack(url: URL(fileURLWithPath: "/tmp/x.wav"),
                               analysis: TrackAnalysis(seconds: 4.52, detailPeaks: [0.5], markers: .none, absolutePeak: 1))
        XCTAssertEqual(timeline.positionCount, track.frames)
        XCTAssertEqual(timeline.position(ofSourceSeconds: 1.2), 30)
        XCTAssertEqual(timeline.sourceSeconds(at: 30), 1.2, accuracy: 1e-9)
    }
}
