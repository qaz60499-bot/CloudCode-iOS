# Capability Matrix

The matrix is intentionally conservative. `DEVICE_VALIDATION_REQUIRED` means the implementation/adapter slot exists or a candidate entitlement/helper path is identified, but a GitHub macOS Runner cannot prove that capability on the target iPhone.

| Capability | Normal sandbox | TrollStore / no-sandbox candidate | Root helper proven | GitHub macOS Runner |
|---|---|---|---|---|
| Own container read/write | Available | Available | Available | Core tests only |
| User/shared files | Permission/device dependent | Expected broader access; probe required | Expected broader access; probe required | Not device-verifiable |
| Unrestricted filesystem | Unavailable | Probe required | Probe required | Not device-verifiable |
| Enumerate installed apps | Usually unavailable as a general inventory | Bounded isolated LaunchServices helper; lazy or explicit validation | Same isolated helper; root is not required for enumeration | Compile/static validation only |
| Resolve app bundle path | Own app / limited | Uses bounded isolated app inventory and current runtime path | Same | Compile/static validation only |
| Resolve other app data container | Unavailable | Uses bounded isolated app inventory when LaunchServices exposes a container path | Same | Compile/static validation only |
| Launch installed app | URL scheme/private API dependent | Bounded isolated LaunchServices helper validates backend and target installation state at execution time | Root is not required for launch | Compile/static validation only |
| Terminate app/process | Unavailable | `DEVICE_VALIDATION_REQUIRED` | Available only after root/persona and process-inspection validation | Not device-verifiable |
| Uninstall app | Unavailable | `DEVICE_VALIDATION_REQUIRED` | Available only after root/persona, install-state and uninstall-backend validation | Not device-verifiable |
| `ios_system` | Only if linked | Only if linked | Only if linked | Core can compile without it |
| Spawn privileged helper | Unavailable | Device-specific candidate | Available only after real helper validation | Not device-verifiable |
| Root helper | Unavailable | `DEVICE_VALIDATION_REQUIRED` | Available only after helper handshake verifies UID 0/persona capability | Not device-verifiable |
| JIT/WASM | Runtime/signing dependent | Runtime/signing dependent | Runtime/signing dependent | Not device-verifiable |
| PhotoKit | User authorization dependent | User authorization dependent | User authorization still required by policy | Not device-verifiable |
| Keychain | Own scope, authorization/runtime dependent | Own scope, entitlement/runtime dependent | Own scope, entitlement/runtime dependent | API/compiler tests only |
| URL scheme executor | Not connected in current build | Not connected in current build | Not connected in current build | Compile only |
| XCTest/WDA GUI | Separate backend required | Separate backend required | Separate backend required | No physical-device proof |
| IPA locate/inspect | Available inside accessible roots | Available in broader accessible roots | Available | Unit/build testable |
| IPA extract/repack | Available inside writable roots | Available in broader writable roots | Available | Unit/build testable |
| IPA decrypt | Unavailable in current build | Unavailable in current build | Unavailable in current build | Not device-verifiable |
| IPA install | Unavailable in current build | Unavailable in current build | Unavailable in current build | Not device-verifiable |

## Runtime rules

1. Automatic startup uses only `probeStartupSafe()` and never invokes root/persona or private LaunchServices code.
2. `apps.list`, `apps.inspect`, `container.resolve`, and `apps.launch` are bounded self-validating operations. They may perform an isolated child-process validation when the user explicitly requests the operation, and they fail closed if the helper crashes, times out, or cannot prove the target.
3. `apps.terminate`, `apps.uninstall`, root helper use, and other root-required mutations remain capability-gated. Ordinary model execution never promotes `device_validation_required` to `available` for these operations.
4. Helper subprocess output is bounded and helper execution has a hard timeout; a stuck or signaled helper must degrade that primitive instead of hanging the SwiftUI host.
5. Capability and permission remain separate. A capability being technically available does not authorize a state-changing action that policy or confirmation rules reject.
