import XCTest
@testable import CueCore

final class CueTypesTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(T.self, from: data), value, file: file, line: line)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: Round trips

    func testRoundTrips() throws {
        for layout in AudioLayout.allCases { try roundTrip(layout) }
        try roundTrip(MusicMarkers(detectedMusicEnd: 171.25, detectedFadeStart: 160.5, editedMusicEnd: 170))
        try roundTrip(MusicMarkers.silent)
        try roundTrip(LoudnessMeasurement(integratedLUFS: -18.4, truePeakDBTP: -0.3, rangeLU: 7.2))
        try roundTrip(LoudnessMeasurement(integratedLUFS: nil, truePeakDBTP: nil, rangeLU: 0))
        try roundTrip(TrimSettings(inPoint: 2.5, outPoint: 60, fadeIn: 0.5, fadeOut: 2, preRoll: 5))
        try roundTrip(SafeZones(preset: .custom, custom: .init(top: 12, bottom: 25, left: 3, right: 0)))
        for value in ClockPosition.allCases { try roundTrip(value) }
        for value in CountdownTarget.allCases { try roundTrip(value) }
        for value in SafeZonePreset.allCases { try roundTrip(value) }
        try roundTrip(PresetID("avci100-1080i50"))
    }

    func testPresetIDEncodesAsBareString() throws {
        let data = try JSONEncoder().encode(["id": PresetID("mpeg2-50")])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"id":"mpeg2-50"}"#)
    }

    // MARK: Missing keys take defaults

    func testEmptyObjectsDecodeToDefaults() throws {
        XCTAssertEqual(try decode(MusicMarkers.self, "{}"), .none)
        XCTAssertEqual(try decode(LoudnessMeasurement.self, "{}"),
                       LoudnessMeasurement(integratedLUFS: nil, truePeakDBTP: nil, rangeLU: 0))
        XCTAssertEqual(try decode(TrimSettings.self, "{}"), .none)
        XCTAssertEqual(try decode(SafeZones.self, "{}"), .none)
        XCTAssertEqual(try decode(SafeZones.Insets.self, "{}"), .zero)
    }

    func testPartialObjectsKeepPresentValues() throws {
        let markers = try decode(MusicMarkers.self, #"{"detectedMusicEnd": 90.5}"#)
        XCTAssertEqual(markers.musicEnd, 90.5)
        XCTAssertNil(markers.fadeStart)
        let trim = try decode(TrimSettings.self, #"{"preRoll": 5}"#)
        XCTAssertEqual(trim, TrimSettings(preRoll: 5))
        let zones = try decode(SafeZones.self, #"{"preset": "custom", "custom": {"bottom": 18}}"#)
        XCTAssertEqual(zones.insets, SafeZones.Insets(bottom: 18))
    }

    // MARK: Bad values fall back instead of throwing

    func testUnknownEnumValuesFallBack() throws {
        XCTAssertEqual(try decode([AudioLayout].self, "[4, 6, \"x\"]"), [.four, .two, .two])
        XCTAssertEqual(try decode([ClockPosition].self, #"["above", "left"]"#), [.above, .below])
        XCTAssertEqual(try decode([CountdownTarget].self, #"["musicEnd", "hitPoint"]"#), [.musicEnd, .fileEnd])
        XCTAssertEqual(try decode(SafeZones.self, #"{"preset": "bbcOSD"}"#).preset, SafeZonePreset.none)
    }

    func testWrongTypesFallBack() throws {
        let markers = try decode(MusicMarkers.self, #"{"detectedMusicEnd": "soon", "noMusic": 3}"#)
        XCTAssertEqual(markers, .none)
        let trim = try decode(TrimSettings.self, #"{"fadeIn": -2, "outPoint": "end"}"#)
        XCTAssertEqual(trim, .none)
        XCTAssertEqual(try decode(PresetID.self, "42"), PresetID(""))
    }

    // MARK: Behaviour

    func testMarkersPreferEditsAndHonourNoMusic() {
        var markers = MusicMarkers(detectedMusicEnd: 100, detectedFadeStart: 90)
        XCTAssertFalse(markers.isEdited)
        markers.editedFadeStart = 85
        XCTAssertEqual(markers.musicEnd, 100)
        XCTAssertEqual(markers.fadeStart, 85)
        XCTAssertTrue(markers.isEdited)
        markers.resetToDetected()
        XCTAssertEqual(markers.fadeStart, 90)
        XCTAssertNil(MusicMarkers(detectedMusicEnd: 5, noMusic: true).musicEnd)
    }

    func testSafeZoneInsetsAreClampedAndPerPreset() {
        let wild = SafeZones.Insets(top: -4, bottom: 55, left: 30, right: 31)
        XCTAssertEqual(wild, SafeZones.Insets(top: 0, bottom: 30, left: 30, right: 30))
        var zones = SafeZones(preset: .custom, custom: .init(top: 5))
        XCTAssertEqual(zones.insets.top, 5)
        zones.preset = .evsOSD
        XCTAssertEqual(zones.insets, SafeZones.evsOSDInsets)
        zones.preset = .none
        XCTAssertTrue(zones.insets.isZero)
        XCTAssertEqual(zones.custom.top, 5, "Custom values survive switching presets")
        let clamped = try? decode(SafeZones.Insets.self, #"{"top": 90}"#)
        XCTAssertEqual(clamped?.top, 30)
    }

    func testTrimIdentity() {
        XCTAssertTrue(TrimSettings().isIdentity)
        XCTAssertFalse(TrimSettings(preRoll: 2).isIdentity)
        XCTAssertEqual(AudioLayout.eight.trackCount, 8)
    }
}
