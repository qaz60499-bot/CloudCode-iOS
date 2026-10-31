// V087 isolated, nonprivileged read-only runtime identity probe.
// Never reads the official ChatGPT bundle, licenses, app data or keychain.
// Intended for separate TrollStore installation after an isolated iOS build.
import Darwin
import Foundation

var diagnostic: [String: Any] = [
    "schema": "ipa-total-v087-runtime-identity/1",
    "uid": Int(getuid()),
    "euid": Int(geteuid()),
    "gid": Int(getgid()),
    "egid": Int(getegid()),
    "pid": Int(getpid()),
    "bundle_id": Bundle.main.bundleIdentifier ?? "UNKNOWN",
    "sandbox_state": "UNKNOWN_NOT_CHECKED",
    "operation": "READ_ONLY_NO_PRIVILEGE_TRANSITION"
]

// csops(CS_OPS_STATUS) requests only this process's code-signing flags.
// Absence, denial, or unrecognized flags must remain UNKNOWN, not PASS.
typealias CSOps = @convention(c) (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "csops") {
    let query = unsafeBitCast(symbol, to: CSOps.self)
    var flags: UInt32 = 0
    errno = 0
    let result = withUnsafeMutablePointer(to: &flags) { pointer in
        query(getpid(), 0, UnsafeMutableRawPointer(pointer), MemoryLayout<UInt32>.size)
    }
    diagnostic["csops_status_result"] = Int(result)
    if result == 0 {
        diagnostic["csops_flags_hex"] = String(format: "0x%08x", flags)
    } else {
        diagnostic["csops_errno"] = Int(errno)
    }
} else {
    diagnostic["csops_status_result"] = "UNAVAILABLE"
}

do {
    let data = try JSONSerialization.data(withJSONObject: diagnostic, options: [.sortedKeys])
    print("IPA_V087_RUNTIME_IDENTITY " + String(decoding: data, as: UTF8.self))
} catch {
    fputs("IPA_V087_RUNTIME_IDENTITY_SERIALIZATION_FAILED\n", stderr)
}
