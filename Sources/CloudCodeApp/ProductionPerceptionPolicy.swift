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

    // A real Agent run may temporarily hold a process assertion while Cloud Code is actually
    // backgrounded. PC-control/OCR helpers and standalone Provider self-tests are deliberately
    // excluded by CloudCodeViewModel, and the assertion is released as soon as the App returns to
    // the foreground. This keeps long Agent work alive without restoring the old always-on
    // background guardian that could leave a visible system indicator behind.
    static let backgroundProcessAssertionAllowed = true

    static let accessibilityDisabledReason =
        "AX/AXAudit is quarantined on this iOS 16.6 device because even read-only diagnostic sessions can leave a visible green Accessibility status indicator. Use screenshot/local OCR/native/HID paths only."

    static let backgroundProcessAssertionDisabledReason =
        "Long-lived process assertion is unavailable for this run. Use the bounded UIKit background window plus checkpoint recovery; PC-control/OCR helpers and standalone Provider self-tests must not acquire a privileged assertion."
}
