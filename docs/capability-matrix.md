# Phase 1 capability matrix

This is the implementation/default matrix. Runtime `CapabilityProbe` is authoritative on a device.

| Domain | Capability | Normal sandbox | TrollStore target | GitHub Runner proof |
|---|---|---:|---:|---:|
| Filesystem | own container | available | available | core logic only |
| Filesystem | shared user files | runtime probe | runtime probe | no |
| Filesystem | unrestricted filesystem | unavailable by default | device validation required | no |
| Apps | installed-app enumeration | own-app fallback only | device validation required until LaunchServices proves it | no |
| Apps | resolve own bundle/container | available | available | core logic only |
| Apps | resolve other bundle/container | device validation required | device validation required until observed | no |
| Execution | ios_system | only if dynamic symbol exists | only if embedded/runtime symbol exists | no runtime proof |
| Execution | posix_spawn symbol | runtime symbol probe | runtime symbol probe | not privilege proof |
| Execution | spawn helper | device validation required | device validation required | no |
| Execution | root helper | device validation required | device validation required | no |
| Data | own Keychain scope | available | available | source/build only |
| Data | Photos/Contacts/Calendar | authorization/device dependent | authorization/device dependent | no |
| IPA | locate/inspect/extract | available within accessible roots | available within accessible roots | unit/build/archive verification |
| IPA | decrypt | unavailable/unproven | device validation required | no |
| IPA | install | unavailable/unproven | device validation required | no |
| Apps | uninstall/terminate | unavailable/unproven | device validation required | no |
| Automation | URL scheme adapter | available subject to iOS policy | available subject to iOS policy | source/build only |
| Automation | XCTest/WDA GUI | unavailable until backend proves readiness | device validation required | no device proof |

## Authorization rule

Only status `available` satisfies a tool's required capability. `device_validation_required`, `unknown`, and `unavailable` all block execution.
