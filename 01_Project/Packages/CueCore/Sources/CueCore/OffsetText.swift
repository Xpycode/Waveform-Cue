import Foundation

public enum OffsetText {
    public static func format(_ value: Int) -> String {
        let sign = value < 0 ? "−" : (value > 0 ? "+" : "")
        return "\(sign)\(value.magnitude) px"
    }

    public static func parse(_ text: String) -> Int? {
        var number = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if number.hasSuffix("px") {
            number.removeLast(2)
            number = number.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Int(number.replacingOccurrences(of: "−", with: "-"))
    }
}
