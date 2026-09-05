# Reference research and adopted design points

This document records design ideas actually absorbed into Cloud Code iOS. It is deliberately not a star-count comparison and does not claim that desktop/device-host protocols can be transplanted unchanged into an on-device iOS process.

## TrollStore

Reference: https://github.com/opa334/TrollStore

Adopted:

- Treat no-sandbox entitlements and root helpers as separate capabilities.
- Keep private entitlements in a separate TrollStore profile rather than in the normal build.
- Model helper spawning through a brokered/typed layer instead of exposing a generic root shell.

Important limitation retained in architecture:

- TrollStore can support unsandboxed applications and, with specific entitlements, root-helper spawning, but it does not provide unrestricted platformization and does not make every private/system capability automatically available.
- `platform-application` can tighten IOKit access. GUI-only IOKit/accessibility/capture entitlements therefore belong on the crash-isolated root helper, and exact GUI operations must still prove runtime support on-device.
- App/container cleanup must not equate a LaunchServices registration change with a completed uninstall. Bundle and known data-container state remain independent postconditions.
- Cloud Code's root helper mirrors only the TrollStore RootHelper lifecycle entitlements needed by its typed app-management surface: container-free/root access, LaunchServices database access, MobileInstallation helper access, uninstall deletion, and the `UninstallForLaunchServices`/`Uninstall` SPI entries. It deliberately does not copy TrollStore's unrelated AMFI/shutdown capabilities.
- TrollStore's own uninstall implementation uses `LSApplicationWorkspace` first and falls back to bounded bundle-container removal. Cloud Code retains stricter postcondition verification around that pattern so an accepted registration change is never reported as a completed uninstall while the bundle is still present.

## Apple OSS / Accessibility APIs

References:

- https://github.com/apple-oss-distributions/IOHIDFamily
- https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition
- https://developer.apple.com/documentation/applicationservices/1462095-axuielementcreatesystemwide

Adopted:

- Apple IOHID sources distinguish server access from EventSystem user access; the GUI helper carries both relevant HID entitlements while the SwiftUI host carries neither.
- Creating an IOHID EventSystem client is treated as a runtime capability check, not proof that a later synthetic gesture was accepted by the foreground UI.
- Private IOKit access stays narrowly scoped to the helper and is paired with explicit user-client entitlement lists because the TrollStore `platform-application` profile can otherwise tighten those accesses.
- `AXUIElementCreateSystemWide` and `AXUIElementCopyElementAtPosition` provide a separate z-order-aware read-only hit-test path. Cloud Code uses a bounded multi-point snapshot only after full application-root discovery fails, and labels it as a sampled snapshot rather than pretending it is a complete accessibility hierarchy.

## ios-mcp accessibility/GUI implementation

Reference: https://github.com/witchan/ios-mcp

Adopted as compatibility guidance only:

- Accessibility symbols can move between AXRuntime, Accessibility, HIServices and ApplicationServices across iOS generations. Cloud Code resolves the small AX symbol set it needs across multiple runtime candidates instead of assuming one framework owns every symbol.
- Foreground discovery is layered rather than tied to one SpringBoardServices call: focused/frontmost AX attributes are tried first, then bounded `AXUIElementCopyApplicationAtPosition` / `AXUIElementCopyApplicationAndContextAtPosition` probes at visible screen points recover the application/PID when a detached helper cannot read the SBS frontmost identifier.
- Screen observations should use the same logical point coordinate space as touch actions; Retina scale and Display Zoom must not silently introduce coordinate drift.
- Continuous GUI work remains observation -> one bounded action -> observation/verification. The jailbreak/SpringBoard execution model of ios-mcp is not transplanted into Cloud Code's detached TrollStore root helper.

## Santander

Reference: https://github.com/NSAntoine/Santander

Adopted:

- Unsandboxed filesystem manager as evidence that high-privilege file access should live behind a dedicated adapter.
- Separate RootHelper and TrollStore entitlement assets.
- File-system capability must be probed and should not be conflated with Agent permission.

Cloud Code does not copy Santander's UI; the reusable idea is the capability boundary and helper separation.

## Geranium / Geranium-RH

References:

- https://github.com/c22dev/Geranium
- https://github.com/c22dev/Geranium-RH

Adopted:

- Separate app and RootHelper components.
- Private CoreServices/LaunchServices wrappers as an adapter pattern for app/container operations.
- System-changing tools should be typed operations, not arbitrary shell strings.

## TrollDecrypt

Reference: https://github.com/donato-fiore/TrollDecrypt

Adopted:

- IPA decryption is a distinct privileged capability, not a normal IPA-inspection feature.
- Entitlements such as no-sandbox, AppBundles access, task-for-pid and application launching demonstrate why `ipa.decrypt` must remain device-gated.
- Cloud Code's normal IPA inspector therefore remains useful even when decryption is unavailable.

## ios_system / a-Shell

References:

- https://github.com/holzschu/ios_system
- https://github.com/holzschu/a-shell

Adopted:

- CLI is a semantic surface, not a requirement that all tools be implemented as Bash.
- `ios_system` is useful for embedded Unix-style commands without requiring the core Agent to assume traditional process semantics.
- Command availability can be probed dynamically.

Not adopted:

- The core is not a terminal emulator and does not make shell the default execution path.

## iSH

Reference: https://github.com/ish-app/ish

Adopted:

- User-mode emulation is evidence that a Linux-like environment can be implemented on iOS, but it has substantial runtime/complexity cost.

Decision:

- iSH-style emulation is not part of Phase 1 core. It remains a possible optional heavy runtime in the future.

## UTM

Reference: https://github.com/utmapp/UTM

Adopted:

- Explicitly separate heavy emulation/JIT capabilities from normal iOS tool execution.
- Treat JIT/hypervisor support as device/signing-specific capability data.

Decision:

- QEMU/UTM is intentionally excluded from the Phase 1 core.

## PhoneAgent / WebDriverAgent / Appium XCUITest driver

References:

- https://github.com/rounak/PhoneAgent
- https://github.com/appium/WebDriverAgent
- https://github.com/appium/appium-xcuitest-driver

Adopted:

- Common GUI action vocabulary: tree, screenshot, open app, tap, text entry, scroll/swipe and verify.
- Observation → action → postcondition loop.
- GUI automation is a replaceable backend and can be unavailable.

Decision:

- XCTest/WDA is not a prerequisite for the core. It is a fallback adapter and remains `DEVICE_VALIDATION_REQUIRED` until the device has a proven backend.

## AppAgent

Reference: https://github.com/TencentQQGYLab/AppAgent

Adopted:

- Persist successful app-specific operating knowledge rather than rediscovering every UI path.
- Store route preference, version, success/failure experience and known pages in `AppKnowledgeRegistry`.

Difference:

- Cloud Code prefers native/structured tools before learned GUI paths.

## Mobile-Agent / UI-TARS / ToolCUA

References:

- https://github.com/X-PLUG/MobileAgent
- https://github.com/bytedance/UI-TARS
- https://github.com/X-PLUG/ToolCUA

Adopted:

- A unified action model is useful for GUI fallback.
- GUI grounding should include verification rather than blind action replay.
- Tool/GUI path selection is itself an important agent decision.

Cloud Code hard-codes the initial route preference as structured → CLI → private/privileged → intent/scheme → GUI. The model cannot silently promote a GUI route above a proven structured route.

## libimobiledevice / pymobiledevice3

References:

- https://github.com/libimobiledevice/libimobiledevice
- https://github.com/doronz88/pymobiledevice3

Adopted:

- Service-oriented decomposition: apps, installation, containers/files, SpringBoard/system, diagnostics and automation should be distinct service domains.
- App/container identity should be semantic (`bundleId`) rather than tied to a transient container UUID.

Decision:

- Their host-to-device protocols are architectural references only. Cloud Code does not assume that lockdownd/AFC/House Arrest can be used unchanged from an on-device process.

## Resulting rule set

1. Capability is measured separately from permission.
2. `device_validation_required` never authorizes a tool.
3. Structured tools dominate the route order.
4. Generic shell is not a privileged API.
5. GUI automation is optional and replaceable.
6. Resource identity is logical and dynamically resolved.
7. Heavy Linux/VM runtimes are optional future adapters, not Phase 1 dependencies.
8. Data returned by files/web/apps/IPA metadata is untrusted Agent data, not system instruction.
