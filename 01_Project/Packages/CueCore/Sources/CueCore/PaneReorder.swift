import Foundation

public enum PaneReorder {
    /// Identifies the job (or the editable defaults) and every pane that defined the drop gaps.
    public struct Context: Equatable {
        public let jobID: UUID?
        public let order: [PicturePane]
        public let isEditable: Bool

        public init(jobID: UUID?, order: [PicturePane], isEditable: Bool) {
            self.jobID = jobID
            self.order = order
            self.isEditable = isEditable
        }

        public func permitsMove(in current: Self?) -> Bool {
            isEditable && self == current
        }
    }

    /// Midpoints are ordered from top to bottom in the flipped document's coordinates.
    public static func dropGap(pointerY: CGFloat, paneMidYs: [CGFloat]) -> Int {
        paneMidYs.prefix { $0 <= pointerY }.count
    }

    /// A gap is measured before removing the source. The two gaps touching it are no-ops.
    public static func move(_ order: [PicturePane], from: Int, toGap: Int) -> [PicturePane] {
        guard order.indices.contains(from), (0...order.count).contains(toGap),
              toGap != from, toGap != from + 1 else { return order }
        var result = order
        let pane = result.remove(at: from)
        result.insert(pane, at: toGap > from ? toGap - 1 : toGap)
        return result
    }

    public static func canMoveUp(from: Int, count: Int) -> Bool { from > 0 && from < count }
    public static func canMoveDown(from: Int, count: Int) -> Bool { from >= 0 && from + 1 < count }
}
