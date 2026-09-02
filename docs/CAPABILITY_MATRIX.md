# Capability Matrix

The matrix is intentionally conservative. `DEVICE_VALIDATION_REQUIRED` means the implementation/adapter slot exists or a candidate entitlement/helper path is identified, but a GitHub macOS Runner cannot prove that capability on the target iPhone.

| Capability | Normal sandbox | TrollStore / no-sandbox candidate | Root helper proven | GitHub macOS Runner |
|---|---|---|---|---|
| Own container read/write | Available | Available | Available | Core tests only |
| User/shared files | Permission/device dependent | Expected broader access; probe required | Expected broader access; probe required | Not device-verifiable |
| Unrestricted filesystem | Unavailable | Probe required | Probe required | Not device-verifiable |
| Enumerate installed apps | Usually unavailable as a general inventory | Private LaunchServices probe | Private LaunchServices probe | Compile only |
| Resolve app bundle path | Own app / limited | Probe required | Probe required | Compile only |
| Resolve other app data container | Unavailable | AppDataContainers/private API probe | Probe required | Compile only |
| `ios_system` | Only if linked | Only if linked | Only if linked | Core can compile without it |
| Spawn privileged helper | Unavailable | Device-specific candidate | Available only after real helper validation | Not device-verifiable |
| Root helper | Unavailable | `DEVICE_VALIDATION_REQUIRED` | Available only after helper handshake verifies identity/capability | Not device-verifiable |
| JIT/WASM | Runtime/signing dependent | Runtime/signing dependent | Runtime/signing dependent | Not device-verifiable |
| PhotoKit | User authorization dependent | User authorization dependent | User authorization still required by policy | Not device-verifiable |
| Keychain | Own scope available | Own scope available | Own scope available | API/compiler tests only |
| URL scheme | Available subject to iOS policy | Available subject to iOS policy | Available subject to iOS policy | Compile only |
| XCTest/WDA GUI | Separate backend required | Separate backend required | Separate backend required | No physical-device proof |
| IPA locate/inspect | Available inside accessible roots | Available in broader accessible roots | Available | Unit/build testable |
| IPA extract | Available inside writable roots | Available in broader writable roots | Available | Unit/build testable |
| IPA decrypt | Unavailable | `DEVICE_VALIDATION_REQUIRED` | `DEVICE_VALIDATION_REQUIRED` | Not device-verifiable |
| IPA install/uninstall | Unavailable through core | `DEVICE_VALIDATION_REQUIRED` | `DEVICE_VALIDATION_REQUIRED` | Not device-verifiable |

## Runtime rule

The app never converts the left-hand column into an assumption from the packaging method. It probes the current process/device and generates a `CapabilityProfile`. Planning uses that profile before selecting a route.
