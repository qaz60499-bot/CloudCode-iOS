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

    // Physical iOS 16.6 evidence shows that merely opening an AccessibilityAudit/AX diagnostic
    // session can leave axauditd holding the green status indicator after the read has finished.
    // Keep explicit AX probes quarantined too; OCR/selection diagnostics must stay screenshot +
    // Vision-only until a device regression proves AX can enter and exit without visible state.
    static let explicitAccessibilityDiagnosticsAllowed = false
    static let backgroundProcessAssertionAllowed = false

    static let accessibilityDisabledReason =
        "AX/AXAudit is quarantined on this iOS 16.6 device because even read-only diagnostic sessions can leave a visible green Accessibility status indicator. Use screenshot/local OCR/native/HID paths only."

    static let backgroundProcessAssertionDisabledReason =
        "Production BKSProcessAssertion is quarantined because a detached background-assert worker can keep the visible green status indicator active while OCR itself is already overlay-free. Use the ordinary bounded UIKit background window plus checkpoint recovery; detached PC-control/OCR helpers must not acquire this assertion."
}
