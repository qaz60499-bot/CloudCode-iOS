# Cloud Code iOS

Cloud Code iOS is an independent, on-device, Tool-first agent for iPhone. It is not a RemoteAI module and does not require the Windows RemoteAI Agent.

Phase 1 focuses on a native Agent Core, capability-aware phone intelligence, structured filesystem/app/IPA tools, transactional safety, resumable tasks, and a native SwiftUI activity console. TrollStore/high-privilege support is treated as a capability layer rather than an assumption.

## Core execution order

1. Structured native tool
2. CLI / filesystem / container semantic tool
3. Private-framework or privileged adapter
4. URL Scheme / App Intent adapter
5. GUI automation fallback

`advanced.shell` exists only as an explicitly high-risk escape hatch. The LLM is never given an unrestricted root-shell primitive.

## Phase 1 implemented surface

- Provider / Key / Model configuration with Keychain-backed provider key storage.
- OpenAI-compatible streaming chat + tool-call loop + retry.
- Session history, task checkpoints and interrupted-task discovery.
- Capability Probe with `available`, `unavailable`, `unknown`, and `device_validation_required` states.
- Resource Graph + progressive indexing.
- Logical `app://`, `container://`, `file://`, and `ipa://` resource resolution.
- Installed-app discovery through a runtime LaunchServices adapter when available; own-app-only fallback otherwise.
- Structured file list/search/read/create/modify/delete and storage analysis.
- App Knowledge Registry for learned app/tool routes.
- IPA locate/inspect/extract with archive traversal checks, Info.plist parsing, Mach-O architecture inspection, framework/extension/signature metadata.
- Safe/Balanced/Full policy modes.
- Cloud Code Trash with restore and separately controlled permanent deletion.
- Important-file transactions with diff, approval, backup, TOCTOU revalidation, atomic replacement, postcondition verification, audit and rollback.
- Untrusted tool-output envelope to keep file/web/IPA/app text as data rather than agent instructions.
- GUI automation protocol (`openApp`, tree, screenshot, tap, type, scroll, swipe, verify) with an unavailable backend by default until a real backend proves readiness.
- ios_system dynamic adapter for `advanced.shell` only when the symbol is actually present.
- Swift Package unit tests and XcodeGen iOS project.
- GitHub Actions macOS workflow for package tests, simulator build, unsigned device build, IPA verification and artifact upload.

## Capability rule

`device_validation_required` is **not** permission to execute. A tool that requires such a capability remains blocked until a real device probe upgrades it to `available`.

This is intentional: the project does not use “try the privileged operation and infer permission from failure” as its capability model.

## High-privilege target

The repository contains a separate **experimental** TrollStore privileged entitlement profile for future device builds. It is not applied to the stable private-Provider IPA. The stable private-Provider IPA is intentionally left unsigned so TrollStore can apply its own standard fallback application identity and Keychain access-group entitlements at install time; pre-signing it with only private entitlements previously caused `errSecMissingEntitlement (-34018)` and broke Provider Key import. The standard GitHub Runner artifact still does not prove root-helper behavior, cross-app container access, app install/uninstall, app termination, decryption, or XCTest/WDA control. Those remain `DEVICE_VALIDATION_REQUIRED` until tested on the target iPhone.

See:

- `docs/reference-research.md`
- `docs/device-validation.md`
- `Entitlements/TrollStore.entitlements` (experimental privileged profile; not used by stable release)
- `Entitlements/TrollStoreFallback.entitlements` (CI-only simulation of TrollStore's standard fallback identity/Keychain entitlements)

## Build

Core package on macOS:

```sh
swift test
```

iOS project:

```sh
xcodegen generate
xcodebuild -project CloudCodeIOS.xcodeproj -scheme CloudCodeIOS -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

The GitHub workflow also creates `build/CloudCode-iOS-unsigned.ipa` and verifies its archive structure before uploading it.
