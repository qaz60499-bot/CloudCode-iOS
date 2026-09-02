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

If XCTest/WDA is configured:

1. Probe backend readiness.
2. Open a harmless test app.
3. Read UI tree.
4. Capture screenshot.
5. Tap a deterministic element.
6. Enter harmless text.
7. Scroll/swipe.
8. Verify a postcondition.

If WDA is not configured, `automation.gui` must remain unavailable/unproven and the Agent must continue using structured tools.

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
