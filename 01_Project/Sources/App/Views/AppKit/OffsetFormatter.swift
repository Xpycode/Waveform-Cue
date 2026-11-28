import CueCore
import Foundation

/// An invalid entry still lets the field resign focus. Its sentinel displays the current
/// offset and lets the action distinguish a rejected entry from a valid, unchanged offset.
final class OffsetFormatter: Formatter {
    var valueInUse = 0

    override func string(for obj: Any?) -> String? {
        if obj is NSNull { return OffsetText.format(valueInUse) }
        return (obj as? NSNumber).map { OffsetText.format($0.intValue) }
    }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?,
                                 for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        if let value = OffsetText.parse(string) {
            obj?.pointee = NSNumber(value: value)
        } else {
            obj?.pointee = NSNull()
        }
        return true
    }
}
