import XCTest
@testable import CueCore

final class PaneReorderTests: XCTestCase {
    func testGapUsesMidpointsOfDifferentHeightPanesInFlippedCoordinates() {
        let midYs: [CGFloat] = [24, 100, 305, 461]
        for (pointer, gap) in [(-20, 0), (23, 0), (24, 1), (99, 1), (180, 2), (460, 3), (800, 4)] {
            XCTAssertEqual(PaneReorder.dropGap(pointerY: CGFloat(pointer), paneMidYs: midYs), gap)
        }
        XCTAssertEqual(PaneReorder.dropGap(pointerY: 0, paneMidYs: []), 0)
    }

    func testDropRequiresTheOriginalEditableJobAndCompleteOrder() {
        let job = UUID()
        let order = PicturePane.defaultOrder
        let drag = PaneReorder.Context(jobID: job, order: order, isEditable: true)
        XCTAssertTrue(drag.permitsMove(in: drag))
        XCTAssertFalse(drag.permitsMove(in: nil))
        XCTAssertFalse(drag.permitsMove(in: .init(jobID: UUID(), order: order, isEditable: true)))
        XCTAssertFalse(drag.permitsMove(in: .init(jobID: nil, order: order, isEditable: true)))
        XCTAssertFalse(drag.permitsMove(in: .init(jobID: job, order: order, isEditable: false)))
        // The dragged title is still at index zero, but its destination now means something different.
        XCTAssertFalse(drag.permitsMove(in: .init(jobID: job, order: [.title, .clocks, .fullTrack, .closeUp], isEditable: true)))
        let defaults = PaneReorder.Context(jobID: nil, order: order, isEditable: true)
        XCTAssertTrue(defaults.permitsMove(in: defaults))
        XCTAssertFalse(defaults.permitsMove(in: drag))
    }

    func testEveryInsertionGapAndEndMenuState() {
        let panes = PicturePane.defaultOrder
        for (from, pane) in panes.enumerated() {
            XCTAssertEqual(PaneReorder.canMoveUp(from: from, count: panes.count), from > 0)
            XCTAssertEqual(PaneReorder.canMoveDown(from: from, count: panes.count), from < 3)
            for gap in 0...panes.count {
                let result = PaneReorder.move(panes, from: from, toGap: gap)
                XCTAssertEqual(result.firstIndex(of: pane), gap > from ? gap - 1 : gap)
                XCTAssertEqual(result.filter { $0 != pane }, panes.filter { $0 != pane })
            }
        }
        for (from, gap) in [(-1, 1), (4, 1), (0, 5), (0, -1)] {
            XCTAssertEqual(PaneReorder.move(panes, from: from, toGap: gap), panes)
        }
    }
}
