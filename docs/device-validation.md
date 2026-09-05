# TrollStore device validation plan

GitHub macOS Runner validation is necessary but not sufficient. The unsigned Runner IPA proves source compilation, unit tests and archive structure only.

The following capabilities remain `DEVICE_VALIDATION_REQUIRED` until the target TrollStore iPhone proves them at runtime.

## Filesystem

- Read outside Cloud Code's own sandbox/container.
- Enumerate `/var/mobile` areas required by the product.
- Resolve and read other application data containers.
- Verify symlink/path guards still behave correctly when no-sandbox access expands the reachable filesystem.

Expected probe behavior: no capability becomes `available` just because a private entitlement is present in the plist. The probe must successfully observe the required resource.

## Apps / LaunchServices

- Enumerate installed apps beyond Cloud Code itself.
- Resolve non-own bundle paths.
- Resolve non-own data containers.
- Launch an app through the chosen private/URL adapter.
- Terminate an app only after explicit policy approval when required.

Tests should include Files/Documents plus at least two third-party apps installed on the phone. Container UUIDs must be resolved again after reinstall/update rather than persisted as identity.

## Privileged helper

- Verify a bundled helper can be spawned.
- Separately verify whether it can assume root persona.
- Confirm stdout/stderr/exit status are captured without exposing arbitrary `root_exec(string)` to the Agent.
- Confirm helper input is a typed operation/schema.

Failure must downgrade the capability and leave structured read-only tools usable.

## IPA

Read-only first:

1. Locate several IPA files.
2. Inspect Info.plist.
3. Read architecture list.
4. Enumerate frameworks/extensions.
5. Report signature/provision metadata.
6. Verify malicious archive traversal paths are rejected.

Privileged/device-only:

- Decrypt an installed app only if the runtime actually supports the required task/process access.
- Repack a copied test IPA.
- Install a disposable test IPA.
- Re-resolve its bundle/container.
- Uninstall the disposable app only after the destructive-operation policy path is exercised.

No decryption/install/uninstall result is considered PASS from the GitHub Runner.

## GUI fallback

Build 37 has two distinct GUI backend classes and they must never be conflated:

1. The preferred self-contained TrollStore path runs private GUI work only in the bounded embedded root helper. Runtime readiness is reported independently for `automation.gui.open_app`, `.tree`, `.screenshot`, `.touch`, `.text_input`, `.gestures`, and `.verify`.
2. XCTest/WDA may be added as a replaceable external adapter. A missing WDA service must not affect Cloud Code startup/chat and must never be treated as proof that the TrollStore-native backend is ready.

The TrollStore-native device test sequence is:

1. Explicit device refresh performs only a lightweight bounded helper handshake; it must not touch global screenshot, AX tree, coordinate-space, or synthetic-touch paths that can destabilize a private runtime.
2. Open a harmless deterministic test app. An exact `gui.openApp` request may self-validate its LaunchServices backend when the cached status is `device_validation_required`.
3. Require a real frontmost-app AX tree from the exact bounded `gui.tree` helper call before treating that observation as successful.
4. Require a real global screenshot from the exact bounded `gui.screenshot` helper call before treating that observation as successful.
5. Touch, gesture, and text-input requests self-validate their exact IOHID/coordinate runtime in the action helper; helper failure never upgrades the capability.
6. Tap a deterministic element, then observe the UI again.
7. Enter harmless text and verify the plaintext never appears in approval, diagnostic, or audit logs.
8. Scroll/swipe, observe again, and verify a postcondition from a fresh tree.

The aggregate `automation.gui` becomes `available` only when open-app, tree, screenshot, touch, text input, gestures, and verification are all actually available on that device. Partial success stays partial; for example, a working IOHID tap backend does not prove AX observation or full autonomous GUI automation. Simulator/mock tests and GitHub Runner compilation are not TrollStore on-device proof.

Protected confirmation surfaces (Face ID, Touch ID, Apple Pay/payment approval, passcode/password confirmation, system permission prompts, and equivalent OS security confirmation UI) are manual boundaries. The Agent must stop and request user confirmation instead of trying to automate them.

## Safety tests on device

### Safe mode

- Read ordinary file without prompt.
- Create a new ordinary file.
- Attempt to modify `.plist` or SQLite data and confirm full approval preview includes target, summary, diff, reason and plan.
- Deny and verify bytes are unchanged.
- Approve and verify backup + transaction journal + postcondition.

### Balanced mode

- Ordinary safe write proceeds.
- Delete moves to Cloud Code Trash.
- Important modification still asks for approval.
- Permanent Trash purge still asks for approval.

### Full mode

- Enable explicitly from Settings.
- Confirm reduced prompts.
- Confirm audit/transaction records still exist.
- Confirm backups are still created where feasible.

### Delete/restore

- Trash a disposable file.
- Verify original path is gone and Trash payload exists.
- Restore it.
- Verify original content/hash.
- Purge a separate disposable Trash item and verify the permanent-delete policy path.

### Failure recovery

- Interrupt a long storage scan/task.
- Reopen Cloud Code and verify interrupted checkpoint is visible.
- Simulate transaction verification failure and confirm rollback.
- Confirm a malformed/corrupted journal cannot cause an unsafe automatic mutation.

## First real-device smoke task set

1. “List the apps you can actually see on this phone.”
2. “Inspect the Files app and show its logical ID and current resolved paths, without modifying anything.”
3. “Find IPA files I can access and inspect one.”
4. “Analyze the size of a disposable test directory.”
5. “Create a disposable text file.”
6. “Modify that file and show the diff/transaction.”
7. “Move it to Cloud Code Trash, then restore it.”
8. “Inspect a known third-party app container if capability permits.”
9. “Explain which requested operations are blocked because their capability is not proven.”
10. Only after the above passes, test a disposable IPA install/uninstall path if the privileged adapter has been proven.
