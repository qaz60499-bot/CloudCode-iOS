# IOSSystemMinimal upstream record

Cloud Code intentionally vendors no source or opaque third-party binaries here. This local Swift
package re-declares four checksum-verified XCFramework artifacts published by `holzschu/ios_system`.

- Upstream repository: `holzschu/ios_system`
- Upstream master observed during integration: `7658fcf551935b42d6bb5bedc9315d8f53f760c4`
- Published binary release used by this package: `v3.0.4`
- License for `ios_system`: BSD-3-Clause (upstream `LICENSE`)
- Included targets: `ios_system`, `files`, `shell`, `text`
- Excluded from this integration: `awk`, `curl_ios`, `ssh_cmd`, `tar`, `mandoc`, `perl`, `perlA`, `perlB`

The authoritative artifact SHA-256 checksums are declared in `Package.swift`. CI must fail if SwiftPM
cannot verify them. The app additionally validates that only the intended command dictionaries and
framework command symbols are present before exposing the CLI runtime to the Agent.

`jq` is intentionally not included in this record: the current upstream ios_system Swift package does
not publish a jq binary target. Cloud Code must continue using its native `json.*` tools until a pinned,
auditable iOS jq build is added and independently verified.
