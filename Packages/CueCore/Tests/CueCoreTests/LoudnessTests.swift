import XCTest
@testable import CueCore

final class LoudnessTests: XCTestCase {
    /// Captured from FFmpeg 8.1: sine=frequency=1000:duration=5, volume=-20dB, ebur128=peak=true.
    static let toneSummary = """
    Input #0, lavfi, from 'sine=frequency=1000:duration=5':
      Duration: N/A, start: 0.000000, bitrate: 705 kb/s
      Stream #0:0: Audio: pcm_s16le, 44100 Hz, mono, s16, 705 kb/s
    Stream mapping:
      Stream #0:0 -> #0:0 (pcm_s16le (native) -> pcm_s16le (native))
    Press [q] to stop, [?] for help
    Output #0, null, to 'pipe:':
      Metadata:
        encoder         : Lavf62.12.100
      Stream #0:0: Audio: pcm_s16le, 44100 Hz, mono, s16, 705 kb/s
        Metadata:
          encoder         : Lavc62.28.100 pcm_s16le
    [Parsed_ebur128_1 @ 0x600000fd4180] Summary:

      Integrated loudness:
        I:         -41.1 LUFS
        Threshold: -51.1 LUFS

      Loudness range:
        LRA:         0.0 LU
        Threshold: -61.1 LUFS
        LRA low:   -41.1 LUFS
        LRA high:  -41.1 LUFS

      True peak:
        Peak:      -38.1 dBFS
    [out#0/null @ 0x600000fd8300] video:0KiB audio:431KiB subtitle:0KiB other streams:0KiB global headers:0KiB muxing overhead: unknown
    size=N/A time=00:00:05.00 bitrate=N/A speed= 490x elapsed=0:00:00.01
    """

    /// Captured from FFmpeg 8.1: anullsrc (digital silence), ebur128=peak=true.
    static let silentSummary = """
    Input #0, lavfi, from 'anullsrc=r=48000:cl=stereo':
      Duration: N/A, start: 0.000000, bitrate: 768 kb/s
      Stream #0:0: Audio: pcm_u8, 48000 Hz, stereo, u8, 768 kb/s
    Stream mapping:
      Stream #0:0 -> #0:0 (pcm_u8 (native) -> pcm_s16le (native))
    Press [q] to stop, [?] for help
    Output #0, null, to 'pipe:':
      Metadata:
        encoder         : Lavf62.12.100
      Stream #0:0: Audio: pcm_s16le, 48000 Hz, stereo, s16, 1536 kb/s
        Metadata:
          encoder         : Lavc62.28.100 pcm_s16le
    [Parsed_ebur128_0 @ 0x600000b0c6c0] Summary:

      Integrated loudness:
        I:         -70.0 LUFS
        Threshold:   0.0 LUFS

      Loudness range:
        LRA:         0.0 LU
        Threshold:   0.0 LUFS
        LRA low:     0.0 LUFS
        LRA high:    0.0 LUFS

      True peak:
        Peak:       -inf dBFS
    [out#0/null @ 0x600000b0c300] video:0KiB audio:938KiB subtitle:0KiB other streams:0KiB global headers:0KiB muxing overhead: unknown
    size=N/A time=00:00:05.00 bitrate=N/A speed= 264x elapsed=0:00:00.01
    """

    private func m(_ i: Double?, _ tp: Double?, _ lra: Double = 3) -> LoudnessMeasurement {
        LoudnessMeasurement(integratedLUFS: i, truePeakDBTP: tp, rangeLU: lra)
    }

    func testArguments() {
        let a = Loudness.arguments(input: "/tmp/a b.mxf")
        XCTAssertTrue(a.contains("-nostats"))
        XCTAssertEqual(a[a.firstIndex(of: "-i")! + 1], "/tmp/a b.mxf")
        XCTAssertEqual(a[a.firstIndex(of: "-af")! + 1], "ebur128=peak=true:framelog=quiet")
        XCTAssertEqual(Array(a.suffix(3)), ["-f", "null", "-"])
    }

    func testParsesRealToneSummary() {
        XCTAssertEqual(Loudness.parse(stderr: Self.toneSummary), m(-41.1, -38.1, 0.0))
    }

    func testParsesSilentSummary() {
        let r = Loudness.parse(stderr: Self.silentSummary)
        XCTAssertEqual(r, m(nil, nil, 0.0))
        XCTAssertEqual(r?.isSilent, true)
    }

    func testExplicitInfIsSilence() {
        let r = Loudness.parse(stderr: "Summary:\n  I:  -inf LUFS\n  LRA: 0.0 LU\n  True peak:\n    Peak: -inf dBFS\n")
        XCTAssertEqual(r, m(nil, nil, 0.0))
    }

    func testUsesLastSummary() {
        let r = Loudness.parse(stderr: Self.silentSummary + "\n" + Self.toneSummary)
        XCTAssertEqual(r?.integratedLUFS, -41.1)
    }

    func testGarbageReturnsNil() {
        XCTAssertNil(Loudness.parse(stderr: ""))
        XCTAssertNil(Loudness.parse(stderr: "no summary here, just noise"))
        XCTAssertNil(Loudness.parse(stderr: "Summary:\n I: abc LUFS\n LRA: x LU"))
        XCTAssertNil(Loudness.parse(stderr: "Summary:\n  I:  -23.0 LUFS\n"))
    }

    func testBadgeEdges() {
        XCTAssertFalse(Loudness.isFlagged(m(-23, -3)))
        XCTAssertFalse(Loudness.isFlagged(m(-24, -3)))
        XCTAssertFalse(Loudness.isFlagged(m(-22, -3)))
        XCTAssertTrue(Loudness.isFlagged(m(-24.1, -3)))
        XCTAssertTrue(Loudness.isFlagged(m(-21.9, -3)))
        XCTAssertFalse(Loudness.isFlagged(m(-23, -1)))
        XCTAssertTrue(Loudness.isFlagged(m(-23, -0.9)))
        XCTAssertTrue(Loudness.isFlagged(m(nil, nil)))
    }

    func testNormalisationLoudnessLimited() {
        let n = Loudness.normalisation(for: m(-30, -20))
        XCTAssertEqual(n.gainDB, 7, accuracy: 1e-9)
        XCTAssertEqual(n.achievedLUFS, -23, accuracy: 1e-9)
        XCTAssertFalse(n.limitedByPeak)
    }

    func testNormalisationPeakLimited() {
        let n = Loudness.normalisation(for: m(-30, -5))
        XCTAssertEqual(n.gainDB, 4, accuracy: 1e-9)
        XCTAssertEqual(n.achievedLUFS, -26, accuracy: 1e-9)
        XCTAssertTrue(n.limitedByPeak)
    }

    func testNormalisationAttenuatesLoudClip() {
        let n = Loudness.normalisation(for: m(-16, -2))
        XCTAssertEqual(n.gainDB, -7, accuracy: 1e-9)
        XCTAssertEqual(n.achievedLUFS, -23, accuracy: 1e-9)
        XCTAssertFalse(n.limitedByPeak)
    }

    func testNormalisationSilenceGetsNoGain() {
        let n = Loudness.normalisation(for: m(nil, nil))
        XCTAssertEqual(n.gainDB, 0)
        XCTAssertEqual(n.achievedLUFS, -.infinity)
        XCTAssertFalse(n.limitedByPeak)
    }
}
