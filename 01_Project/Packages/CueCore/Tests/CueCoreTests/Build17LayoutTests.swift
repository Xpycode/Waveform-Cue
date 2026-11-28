import XCTest
@testable import CueCore

final class Build17LayoutTests: XCTestCase {
    /// Measured with the original build 17 renderer. Exclude glyph widths, which can vary by OS.
    private struct Geometry: Codable, Equatable {
        let fullTrack: CGRect
        let closeUp: CGRect?
        let clockBaseline, elapsedPoints, remainingPoints: CGFloat
        let titlePoints: CGFloat
        let titleOrigin: CGPoint
        let titleHeight: CGFloat
        let fits: Bool

        init(_ layout: CueLayout) {
            let (_, box) = CuePicture.caption(CueLabel(text: "Cue", position: CGPoint(x: 0, y: 1)), layout: layout)
            fullTrack = layout.overview
            closeUp = layout.detail
            clockBaseline = layout.clockBaseline
            elapsedPoints = layout.elapsedSize.points
            remainingPoints = layout.remainingSize.points
            titlePoints = layout.titleSize
            titleOrigin = box.origin
            titleHeight = box.height
            fits = layout.fits
        }
    }

    private func measurements() -> [String: Geometry] {
        let zones: [(String, SafeZones)] = [
            ("none", .none),
            ("evs", .init(preset: .evsOSD)),
            ("asymmetric", .init(preset: .custom, custom: .init(top: 5, bottom: 12, left: 3, right: 8))),
            ("narrow", .init(preset: .custom, custom: .init(left: 30, right: 30))),
            ("compressed", .init(preset: .custom, custom: .init(top: 30, bottom: 30, left: 30, right: 30)))
        ]
        var rows: [String: Geometry] = [:]
        for position in ClockPosition.allCases {
            for zoom in [ZoomWindow.off, .auto] {
                for elapsed in ClockSize.allCases {
                    for remaining in ClockSize.allCases {
                        for (zone, safe) in zones {
                            var appearance = CueAppearance()
                            appearance.clockPosition = position
                            appearance.zoom = zoom
                            appearance.elapsed.size = elapsed
                            appearance.remaining.size = remaining
                            appearance.safeZones = safe
                            let key = "\(position.rawValue)/\(zoom)/\(elapsed.rawValue)/\(remaining.rawValue)/\(zone)"
                            rows[key] = Geometry(appearance.layout)
                        }
                    }
                }
            }
        }
        return rows
    }

    func testGeometryMatchesBuild17() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "build17-layouts", withExtension: "json"))
        let expected = try JSONDecoder().decode([String: Geometry].self, from: Data(contentsOf: url))
        let actual = measurements()
        XCTAssertEqual(expected.count, 320)
        XCTAssertEqual(Set(actual.keys), Set(expected.keys))
        for (key, row) in expected {
            XCTAssertEqual(actual[key], row, key)
        }
    }
}
