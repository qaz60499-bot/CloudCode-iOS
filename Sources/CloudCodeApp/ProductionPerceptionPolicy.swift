import Foundation

/// Production perception must never opt the foreground device into a visible Accessibility/
/// Automation client state. Build 131-133 physical-device evidence showed that merely entering
/// private AX/AXAudit client paths can surface the green system frame even after all explicit
/// `_AXSSetAutomationEnabled` and requesting-client writes were removed.
///
/// Keep AX code available only to the explicit Perception Probe diagnostics surface while normal
/// Agent execution uses screenshot + bounded local OCR + HID/native routes. Re-enable production AX
/// only after a device regression proves that the exact read/focus/type path cannot surface the
/// system accessibility frame across launch, foreground/background, timeout, crash and recovery.
enum ProductionPerceptionPolicy {
    static let accessibilityRuntimeAllowed = false
    static let backgroundProcessAssertionAllowed = false

    static let accessibilityDisabledReason =
        "Production AX/AXAudit is quarantined because iOS 16.6 can surface the visible green Accessibility frame without an explicit Automation-state write. Use screenshot/local OCR/native/HID paths; AX remains available only in explicit diagnostics."

    static let backgroundProcessAssertionDisabledReason =
        "Production BKSProcessAssertion is quarantined because a detached background-assert worker can keep the visible green status indicator active while OCR itself is already overlay-free. Use the ordinary bounded UIKit background window plus checkpoint recovery; detached PC-control/OCR helpers must not acquire this assertion."
}
