#!/usr/bin/env python3
"""V077: real Swift staging failure rollback on a disposable macOS test root.

Never uses /var/containers or any device. The iOS guard and hardcoded production
root are replaced only in a compiler input copy under a temporary directory.
"""
import argparse
import os
import pathlib
import subprocess
import tempfile

MAIN = r'''
import Darwin
import Foundation

enum UnfairError: Error { case io(String) }
struct MachORecord { let url: URL; let name: String }
struct UnfairLogger {
    func log(_ s: String) {}
    func verbose(_ s: String) {}
}
enum FileSystem {
    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    static func chmod(_ url: URL, mode: mode_t) throws {
        guard Darwin.chmod(url.path, mode) == 0 else {
            throw UnfairError.io("chmod failed")
        }
    }
    static func removeTree(_ url: URL) {
        // Failure injection applies only to the disposable macOS test double.
        if ProcessInfo.processInfo.environment["UNFAIR_V078_FAIL_CLEANUP"] == "1" { return }
        try? FileManager.default.removeItem(at: url)
    }
}

let fm = FileManager.default
let staging = URL(fileURLWithPath: ProcessInfo.processInfo.environment["UNFAIR_V077_STAGING_ROOT"]!, isDirectory: true)
let sourceRoot = URL(fileURLWithPath: ProcessInfo.processInfo.environment["UNFAIR_V077_INPUT_ROOT"]!, isDirectory: true)
let missing = sourceRoot.appendingPathComponent("missing-binary")
let logger = UnfairLogger()
var checks = 0
func assertEmpty(_ tag: String) {
    let items = try! fm.contentsOfDirectory(atPath: staging.path)
    guard items.isEmpty else { fatalError("ORPHAN_UUID_CONTAINER " + tag + ": " + String(describing: items)) }
    checks += 1
}
func mustThrow(_ tag: String, _ f: () throws -> Void) {
    do { try f(); fatalError("EXPECTED_THROW " + tag) }
    catch {
        assertEmpty(tag)
        print("PASS rollback " + tag)
    }
}

mustThrow("binary-missing-input") {
    _ = try AppBundleStager.stageBinary(missing, rootSinf: missing, logger: logger)
}
let plain = sourceRoot.appendingPathComponent("FixtureMachO")
try! Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: plain)
mustThrow("binary-missing-sinf") {
    _ = try AppBundleStager.stageBinary(plain, rootSinf: sourceRoot.appendingPathComponent("missing.sinf"), logger: logger)
}
let app = sourceRoot.appendingPathComponent("Fixture.app", isDirectory: true)
try! fm.createDirectory(at: app, withIntermediateDirectories: true)
mustThrow("app-missing-record") {
    _ = try AppBundleStager.stageAppBundle(
        sourceApp: app,
        encryptedRecords: [MachORecord(url: app.appendingPathComponent("DoesNotExist"), name: "DoesNotExist")],
        logger: logger
    )
}
mustThrow("app-outside-record") {
    _ = try AppBundleStager.stageAppBundle(
        sourceApp: app,
        encryptedRecords: [MachORecord(url: plain, name: "FixtureMachO")],
        logger: logger
    )
}
guard checks == 4 else { fatalError("FAIL expected 4 rollback checks") }
print("PASS 4/4 synthetic rollback checks; real iOS staging and FairPlay not exercised")

// In production this guard must reject an in-root symlink that resolves to
// another app or out-of-root folder, even though the lexical path is in-root.
let rootEscape = staging.appendingPathComponent("outside-link")
try! fm.createSymbolicLink(at: rootEscape, withDestinationURL: sourceRoot)
guard !AppBundleStager.isInsideApplicationBundleRoot(rootEscape.appendingPathComponent("FixtureMachO")) else {
    fatalError("SYMLINK_ESCAPE_ACCEPTED_ROOT_GUARD")
}
try! fm.removeItem(at: rootEscape)
let escapedRecord = app.appendingPathComponent("LinkToOutside")
try! fm.createSymbolicLink(at: escapedRecord, withDestinationURL: plain)
mustThrow("app-symlink-escape") {
    _ = try AppBundleStager.stageAppBundle(
        sourceApp: app,
        encryptedRecords: [MachORecord(url: escapedRecord, name: "LinkToOutside")],
        logger: logger
    )
}
print("PASS 2/2 symlink escape safeguards")

// Simulate FileSystem.removeTree silently failing. Source must report an orphan
// rather than making the test believe cleanup completed. Only test TMP is used.
func mustReportOrphan(_ tag: String, _ f: () throws -> Void) {
    let before = Set(try! fm.contentsOfDirectory(atPath: staging.path))
    do { try f(); fatalError("EXPECTED_THROW " + tag) }
    catch {
        guard String(describing: error).contains("cleanup is incomplete") else {
            fatalError("SILENT_ORPHAN_MISREPORTED " + tag + " " + String(describing: error))
        }
        let after = Set(try! fm.contentsOfDirectory(atPath: staging.path))
        let added = after.subtracting(before)
        guard added.count == 1 else { fatalError("MISSING_INJECTED_ORPHAN " + tag) }
        for folder in added { try! fm.removeItem(at: staging.appendingPathComponent(folder)) }
        print("PASS orphan cleanup failure detected " + tag)
    }
}
setenv("UNFAIR_V078_FAIL_CLEANUP", "1", 1)
mustReportOrphan("binary") {
    _ = try AppBundleStager.stageBinary(missing, rootSinf: missing, logger: logger)
}
mustReportOrphan("app") {
    _ = try AppBundleStager.stageAppBundle(
        sourceApp: app,
        encryptedRecords: [MachORecord(url: app.appendingPathComponent("DoesNotExist"), name: "DoesNotExist")],
        logger: logger
    )
}
unsetenv("UNFAIR_V078_FAIL_CLEANUP")
assertEmpty("after-fault-injection")
print("PASS 2/2 injected cleanup-failure detection cases")
'''

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    args = ap.parse_args()
    source = pathlib.Path(args.source).read_text(encoding="utf-8")
    guard = "#if os(iOS)\n"
    assert source.count(guard) == 1, "missing iOS gate"
    assert source.rstrip().endswith("#endif"), "unexpected source tail"
    target = 'fileURLWithPath: "/var/containers/Bundle/Application"'
    assert source.count(target) == 1, "unexpected production staging root"
    source = source.replace(guard, "", 1)
    source = source[:source.rfind("#endif")]
    source = source.replace(
        target,
        'fileURLWithPath: ProcessInfo.processInfo.environment["UNFAIR_V077_STAGING_ROOT"]!'
    )
    with tempfile.TemporaryDirectory(prefix="ipa-total-v077-") as tmp:
        base = pathlib.Path(tmp)
        (base / "staged").mkdir()
        (base / "inputs").mkdir()
        (base / "Stager.swift").write_text(source, encoding="utf-8")
        (base / "main.swift").write_text(MAIN, encoding="utf-8")
        exe = base / "rollback"
        subprocess.run(["swiftc", str(base / "Stager.swift"), str(base / "main.swift"), "-o", str(exe)], check=True)
        env = dict(os.environ, UNFAIR_V077_STAGING_ROOT=str(base / "staged"), UNFAIR_V077_INPUT_ROOT=str(base / "inputs"))
        subprocess.run([str(exe)], env=env, check=True)

if __name__ == "__main__":
    main()
