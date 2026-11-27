import XCTest
@testable import CueCore

final class MusicEndDetectorTests: XCTestCase {
    let b = 0.005

    func db(_ x: Double) -> Float { Float(pow(10, x / 20)) }

    func buckets(_ spec: [(Int, Float)]) -> [Float] { spec.flatMap { Array(repeating: $0.1, count: $0.0) } }

    func testFadeThenSilentTail() {
        // 2 s at -6 dB, 1 s at -30 dB, 1 s at -50 dB, then 2 s at -80 dB.
        let p = buckets([(400, db(-6)), (200, db(-30)), (200, db(-50)), (400, db(-80))])
        let m = MusicEndDetector.detect(peaks: p, bucketSeconds: b, duration: 6.0)
        XCTAssertFalse(m.noMusic)
        XCTAssertEqual(m.detectedMusicEnd!, 4.0, accuracy: 1e-9)
        // fade threshold = -6 - 40 = -46 dB: the -50 dB section is excluded.
        XCTAssertEqual(m.detectedFadeStart!, 3.0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(m.detectedFadeStart!, m.detectedMusicEnd!)
    }

    func testIsolatedClickInTailIgnored() {
        var p = buckets([(400, db(-6)), (400, db(-80))])
        p[600] = db(-3)
        p[601] = db(-3)   // 10 ms, under 50 ms
        let m = MusicEndDetector.detect(peaks: p, bucketSeconds: b, duration: 4.0)
        XCTAssertEqual(m.detectedMusicEnd!, 2.0, accuracy: 1e-9)
    }

    func testRunOfExactlyFiftyMillisecondsCounts() {
        var p = buckets([(100, db(-6)), (300, db(-80))])
        for i in 200..<210 { p[i] = db(-20) }   // 10 buckets = 50 ms
        let m = MusicEndDetector.detect(peaks: p, bucketSeconds: b, duration: 2.0)
        XCTAssertEqual(m.detectedMusicEnd!, 1.05, accuracy: 1e-9)
    }

    func testNoTailGivesDuration() {
        let p = buckets([(400, db(-6))])
        let m = MusicEndDetector.detect(peaks: p, bucketSeconds: b, duration: 2.0004)
        XCTAssertEqual(m.detectedMusicEnd, 2.0004)
        XCTAssertLessThanOrEqual(m.detectedFadeStart!, m.detectedMusicEnd!)
    }

    func testAllSilence() {
        let p = buckets([(400, db(-70))])
        XCTAssertEqual(MusicEndDetector.detect(peaks: p, bucketSeconds: b, duration: 2.0), .silent)
        XCTAssertEqual(MusicEndDetector.detect(peaks: [], bucketSeconds: b, duration: 0), .silent)
    }

    func testVeryShortTrack() {
        let loud = MusicEndDetector.detect(peaks: [db(-10), db(-10), db(-10)], bucketSeconds: b, duration: 0.015)
        XCTAssertEqual(loud.detectedMusicEnd, 0.015)
        let quiet = MusicEndDetector.detect(peaks: [db(-90), db(-90)], bucketSeconds: b, duration: 0.01)
        XCTAssertTrue(quiet.noMusic)
    }

    func testQuietTrackFadeNeverAfterMusicEnd() {
        // Peak at -30 dB: the fade threshold (-70 dB) is below the music threshold.
        let p = buckets([(200, db(-30)), (200, db(-65)), (200, db(-90))])
        let m = MusicEndDetector.detect(peaks: p, bucketSeconds: b, duration: 3.0)
        XCTAssertEqual(m.detectedMusicEnd!, 1.0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(m.detectedFadeStart!, m.detectedMusicEnd!)
    }

    func testClampsToDuration() {
        let p = buckets([(400, db(-6)), (10, db(-80))])
        let m = MusicEndDetector.detect(peaks: p, bucketSeconds: b, duration: 1.5)
        XCTAssertEqual(m.detectedMusicEnd!, 1.5, accuracy: 1e-9)
    }
}
