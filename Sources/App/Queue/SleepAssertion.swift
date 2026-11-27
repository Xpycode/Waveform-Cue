import CueCore
import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac from idle-sleeping while the queue exports (spec B): one IOKit power assertion
/// from Start Queue until the run ends, however many jobs it exports. The display may still
/// sleep. `begin` while held and `end` while not held do nothing.
final class SleepAssertion: SleepPreventing {
    private var assertion: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
    private var isHeld = false

    func begin(reason: String) {
        guard !isHeld else { return }
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason as CFString, &id)
        guard result == kIOReturnSuccess else { return }
        assertion = id
        isHeld = true
    }

    func end() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertion)
        assertion = IOPMAssertionID(kIOPMNullAssertionID)
        isHeld = false
    }

    deinit { end() }
}
