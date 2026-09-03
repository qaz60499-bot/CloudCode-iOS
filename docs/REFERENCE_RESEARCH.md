# Reference Research

This project does not copy a reference project's architecture wholesale. It extracts mechanisms that fit an on-device Tool-first agent and rejects assumptions that do not transfer to iOS.

## Privilege / TrollStore ecosystem

### opa334/TrollStore

Absorbed:

- arbitrary/private entitlement packaging is possible on supported TrollStore devices
- no-sandbox/AppDataContainers/persona-style root-helper patterns are real mechanisms worth probing
- root-helper binaries and app entitlements are separate concerns
- TrollStore documents persona-based root helpers for unsandboxed apps, but also explicitly documents that proper platformization and launch-daemon behavior are not implied

License/integration decision:

- TrollStore is primarily MIT; some RootHelper/uicache-derived code is BSD-4-Clause. Cloud Code keeps its helper implementation independent and only follows the published entitlement/persona pattern.

Rejected assumption:

- TrollStore does **not** mean unrestricted root/platformization. The project therefore probes filesystem/helper behavior and never marks it available solely because installation came from TrollStore.

### NSAntoine/Santander and Santander variants

Absorbed:

- unsandboxed file-manager organization
- separate RootHelper area rather than placing every privileged operation in the UI process
- file browsing should remain a structured resource/service model

License/integration decision:

- Santander is MIT licensed. Cloud Code currently reuses the architectural boundary only; any future copied component must keep attribution and remain behind ToolRouter/PolicyEngine.

Rejected assumption:

- a file-manager UI is not the Agent architecture; Cloud Code keeps file operations as typed tools and logical resources.

### Geranium / c22dev/Geranium-RH

Absorbed:

- explicit root-helper component boundary
- small helper surface is preferable to a model-owned root shell

Rejected assumption:

- helper existence is not capability proof. A handshake/probe and Policy Engine remain required.

### donato-fiore/TrollDecrypt / TrollDecryptor

Absorbed:

- IPA decryption is a distinct service/capability
- outputs belong to an explicit app-accessible location and should be surfaced as resources

Rejected assumption:

- decrypt is not a universal IPA read operation. It remains `DEVICE_VALIDATION_REQUIRED` and separately risk-classified.

## On-device CLI/runtime

### holzschu/ios_system

Absorbed:

- CLI semantics can map commands to in-process functions
- stdout/stdin and command context are runtime concerns
- Unix-like command UX does not require normal desktop `fork/exec`

Applied:

- `SemanticCommand` / `CLISemanticParser`
- typed native tools remain preferred
- `advanced.shell` is optional/high risk

### a-Shell

Absorbed:

- embedded native commands and WASM can expand a mobile shell incrementally
- command history/context/current-directory should be scoped per workspace rather than treated as process-global state
- `ios_system` is the command runtime underneath a-Shell, so Cloud Code should reuse that boundary instead of inventing a second shell abstraction

License/integration decision:

- a-Shell is BSD-3-Clause and `ios_system` is BSD-3-Clause; their architecture is compatible with selective reuse, but this phase only absorbs patterns and does not vendor their large command catalogs.

Rejected assumption:

- Cloud Code phase 1 does not require a large bundled command catalog.

### iSH

Absorbed:

- user-mode emulation is an optional way to obtain Linux semantics when truly needed

Rejected for core:

- emulating a Linux userspace is heavier than the structured operations needed for app/container/file/IPA intelligence.

### utmapp/UTM

Absorbed:

- a QEMU/VM backend can be an optional future heavy runtime
- JIT availability is device/signing dependent and must be probed

Rejected for core:

- full QEMU/VM architecture is intentionally excluded from phase 1.

## GUI/mobile agents

### PhoneAgent

Absorbed:

- separate observation/action execution from model planning
- XCTest can be one device action backend

### WebDriverAgent / Appium XCUITest Driver

Absorbed:

- open/terminate/tap/scroll/tree/screenshot operations fit a backend interface
- XCTest/WDA is a runtime/service dependency, not a capability to assume

Applied:

- `GUIAutomationBackend` provides open app, tree, screenshot, tap, type, scroll, swipe and verify.
- phase 1 ships an explicit unavailable backend until a real device proves one.

### AppAgent

Absorbed:

- reusable app knowledge should accumulate instead of visually rediscovering the app every time

Applied:

- `AppKnowledgeRegistry` stores app identity, routes, cost/success, known pages/failure notes/version.

### Mobile-Agent / UI-TARS

Absorbed:

- observation → plan → action → verify is useful when GUI is unavoidable
- GUI grounding belongs behind the same verification discipline as other tools

### ToolCUA

Absorbed strongly:

- tool-vs-GUI path selection is a first-class problem

Applied:

- deterministic default route priority favors structured/native and CLI/container paths before GUI.
- a GUI route is not selected merely because screenshots are available.

## iOS service abstraction

### libimobiledevice / pymobiledevice3

Absorbed:

- Apps, Files, Containers, Installation, SpringBoard, Diagnostics and Automation are better treated as service domains than one generic shell

Rejected assumption:

- host-to-device lockdown/services cannot be copied as an on-device protocol. Cloud Code copies the module boundaries, not the transport model.

## Git and terminal UI

### libgit2 / iOS wrappers

Absorbed:

- Git should be a linkable library/service capability, not a stringly-typed shell-only feature.
- repository identity, status, diff, commit and remote operations should become typed tools with explicit workspace roots.

License/integration decision:

- upstream libgit2 uses GPLv2 with a linking exception, which permits linking from this app while modifications to libgit2 itself retain source-distribution obligations.
- current iOS community build wrappers have maintenance/dependency caveats, so `homeos.git` remains explicitly unavailable until a pinned, reproducible XCFramework/SwiftPM path is validated on the macOS runner and device.

### SwiftTerm

Absorbed:

- terminal rendering can remain a separate UI adapter over a command/session backend.
- it is optional for HomeOS: command execution does not depend on a terminal widget.

License/integration decision:

- SwiftTerm is MIT licensed and can be considered later for a terminal view, but no dependency is added in this phase because the structured Agent/Tool surface is higher priority.

## HomeOS capability facade

The current HomeOS layer is intentionally an aggregate facade rather than a second router. `homeos.file`, `homeos.app`, `homeos.process`, `homeos.shell`, `homeos.archive`, `homeos.network`, `homeos.script`, `homeos.device`, `homeos.workspace`, and `homeos.root_helper` are derived from existing `CapabilityProbe` facts. `homeos.git` remains unavailable until a real Git backend is linked and verified.

No HomeOS record may turn an unavailable primitive capability into an available one, and all state-changing operations still flow through `ToolRouter`, `PolicyEngine`, execution ledger/transactions, confirmations where required, audit logging, and final-state verification.

## Local Native Cloud Runtime

The local `D:\wendangcodex\CloudRuntime` was inspected without reading secret values.

Absorbed:

- provider readiness should be computed centrally rather than guessed by each caller
- an unverified/auto protocol is not the same as a verified usable inference path
- short transport retries should be conservative
- already-started generations should not be blindly replayed

Phase-1 iOS application:

- provider key is held in Keychain
- streaming transport permits a single replay only before any model/tool output for transient transport/5xx failure
- tool calls remain session/history events

Not found in the local CloudRuntime reference:

- a reusable iOS Agent Session/Tool Loop/transaction/trash architecture. Those layers are implemented independently in this repository.
