# Phase 1 capability matrix

This is the implementation/default matrix. Runtime `CapabilityProbe` is authoritative on a device.

| Domain | Capability | Normal sandbox | TrollStore target | GitHub Runner proof |
|---|---|---:|---:|---:|
| Filesystem | own container | available | available | core logic only |
| Filesystem | shared user files | runtime probe | runtime probe | no |
| Filesystem | unrestricted filesystem | unavailable by default | device validation required | no |
| Apps | installed-app enumeration | bounded isolated helper may fail closed | bounded isolated LaunchServices helper | source/build only |
| Apps | resolve own bundle/container | available | available | core logic only |
| Apps | resolve other bundle/container | bounded isolated resolver | bounded isolated resolver after observed app inventory | source/build only |
| Apps | launch | bounded isolated runtime validation | bounded isolated LaunchServices validation; root not required | source/build only |
| Apps | terminate | unavailable/unproven | device validation required until root/persona and process backend prove readiness | no |
| Apps | uninstall | unavailable/unproven | device validation required until root/persona and uninstall backend prove readiness | no |
| Execution | ios_system | only if dynamic symbol exists | only if embedded/runtime symbol exists | no runtime proof |
| Execution | posix_spawn symbol | runtime symbol probe | runtime symbol probe | not privilege proof |
| Execution | spawn helper | device validation required | device validation required | no |
| Execution | root helper | device validation required | device validation required | no |
| Data | own Keychain scope | runtime/entitlement dependent | runtime/entitlement dependent | source/build only |
| Data | Photos/Contacts/Calendar | authorization/device dependent | authorization/device dependent | no |
| IPA | locate/inspect/extract/repack | available within accessible roots | available within accessible roots | unit/build/archive verification |
| IPA | decrypt | unavailable in current build | unavailable in current build | no |
| IPA | install | unavailable in current build | unavailable in current build | no |
| Automation | URL scheme adapter | unavailable in current build | unavailable in current build | source/build only |
| Automation | XCTest/WDA GUI | unavailable until backend proves readiness | unavailable until backend proves readiness | no device proof |

## Authorization and validation rule

Status `available` directly satisfies a tool's declared capability. `unknown` and `unavailable` always block execution. A `device_validation_required` capability may proceed only through an executor that explicitly supports exact-operation self-validation for that same capability; route selection itself remains side-effect free and the concrete helper operation must fail closed.

`apps.list`, `apps.inspect`, `container.resolve`, and `apps.launch` are bounded self-validating adapters. `apps.terminate`, `apps.uninstall`, and granular `gui.*` operations may also self-validate only when the user explicitly requested that exact operation. Destructive/root actions still pass normal policy and confirmation checks before the state-changing helper call executes.
