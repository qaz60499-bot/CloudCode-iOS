# DEVICE_VALIDATION_REQUIRED

These checks must be run on the target TrollStore iPhone. CI must never convert them to PASS merely because the app compiles.

## 1. Installation and entitlement reality

- Install the test IPA through the user's actual TrollStore flow.
- Confirm Cloud Code launches without entitlement-related crash.
- Inspect the process entitlement set from a trusted on-device tool and compare with the intended TrollStore entitlement candidate.
- Confirm `CapabilityProfile` reports observed access rather than inferring it from installation method.

## 2. Filesystem

- Verify own-container read/write.
- Probe `/var/mobile/Media` read access.
- Probe a harmless metadata-only path under `/var/mobile/Library`.
- Confirm paths outside real capability remain `unavailable` rather than causing repeated failing actions.
- Confirm a symlink that leaves an allowed root is rejected.

## 3. Apps and containers

- Run `apps.list` and compare a sample of bundle IDs against installed apps.
- Resolve at least three apps, including a file manager/document app and Telegram if installed.
- Restart/reinstall one target app if safe, then resolve its container again to prove Cloud Code does not persist a container UUID as identity.
- Confirm sandbox-only fallback does not falsely claim complete app enumeration.

## 4. App Knowledge Registry

- Verify installed apps named Files, Documents, Slides and other document/file tools are discovered when present.
- Confirm registry entries store bundle ID, version, preferred route, capability notes, cost/success fields.
- Do not mark GUI routes reliable until successfully verified for the current app version.

## 5. Root / privileged helper

- Do not expose arbitrary root command execution to the model.
- Add/enable the helper only behind a typed privilege-broker adapter.
- Validate helper handshake, caller identity, requested operation schema and target path.
- Confirm helper unavailable/crashed/stale produces a capability downgrade instead of an execution loop.
- Verify the main app cannot turn on Full permission mode programmatically.

## 6. `ios_system`

- If linked into a TrollStore build, confirm the `ios_system` symbol is detected.
- Run a harmless semantic command through a typed wrapper first.
- Verify `advanced.shell` requires detailed confirmation in Safe/Balanced.
- Verify stdout/stderr/result capture before exposing it for troubleshooting use.

## 7. Trash

Create a disposable test file and verify:

- Safe mode shows detailed deletion approval.
- Approval moves the target into Cloud Code Trash rather than unlinking it.
- Journal contains originalPath, logicalResourceId, trashPath, filename, size, hash, timestamp, sessionId, toolCallId, reason and source App when known.
- Restore returns the exact bytes to the original path.
- Permanent delete has a separate permission decision.

## 8. Important modification transaction

On a disposable plist/config/database copy:

- Show target, original summary, diff, reason and plan.
- Deny and verify bytes remain unchanged.
- Approve and verify backup is created before replacement.
- Force postcondition failure and verify rollback restores the original.
- Change the target while approval is open and verify the TOCTOU re-check aborts.

Never perform the first transaction test on a live important database.

## 9. IPA service

Use a known disposable IPA and verify:

- locate
- Info.plist
- architectures
- frameworks
- extensions
- signature metadata
- embedded XML entitlements when present
- safe extraction

Then separately validate any future decrypt/repack/install adapter. `ipa.install`, `ipa.decrypt`, privileged resigning and uninstall remain system-changing/destructive capabilities.

## 10. GUI fallback

Only after a WDA/XCTest-compatible backend is actually available:

- open app
- read UI tree
- screenshot
- tap
- type
- scroll/swipe
- postcondition verify

Confirm Tool Router still chooses a structured filesystem/container tool for a task that both GUI and structured routes could satisfy.

## 11. Lifecycle

- Start a multi-round task.
- Background/terminate the app during a safe step.
- Relaunch and verify interrupted checkpoint is visible with exact last durable step.
- Resume only an idempotent/recoverable step; otherwise offer rollback/cancel.

## 12. Provider / streaming

- Add one provider/key/model through Settings.
- Confirm the key is not persisted in UserDefaults or logs.
- Stream a normal chat response.
- Exercise a typed tool call and result continuation.
- Simulate a connection reset before first output and confirm at most one replay.
- Simulate a disconnect after partial streamed output and confirm the turn is surfaced as interrupted rather than replayed automatically.
