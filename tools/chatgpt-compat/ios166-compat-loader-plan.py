"""Read-only compatibility-layer deployment planner for ChatGPT 1.2026.286.
Inspect Mach-O load commands and refuse deployment if any required binary remains
FairPlay-encrypted. Never patch, decrypt, sign, or install any input.
"""
from __future__ import annotations
import argparse
import json
import plistlib
import struct
import zipfile
from pathlib import Path

DEFAULT_IPA = Path(r"E:\google\ipatool-rs-compat\pinned-artifacts\go270-webgui-270k\apps\ChatGPT_1.2026.286_iOS18.0_ygao7331.ipa")
REQUIRED = (
    "Payload/ChatGPT.app/ChatGPT",
    "Payload/ChatGPT.app/Frameworks/ChatGPT.framework/ChatGPT",
    "Payload/ChatGPT.app/Frameworks/OpenAIXPlat.framework/OpenAIXPlat",
    "Payload/ChatGPT.app/Frameworks/LinkKit.framework/LinkKit",
    "Payload/ChatGPT.app/Frameworks/Lottie.framework/Lottie",
    "Payload/ChatGPT.app/Frameworks/LiveKitWebRTC.framework/LiveKitWebRTC",
    "Payload/ChatGPT.app/Frameworks/libswiftCompatibilitySpan.dylib",
)
REBIND = {
    "/usr/lib/swift/libswiftObservation.dylib": "@rpath/libswiftObservation.dylib",
    "/usr/lib/swift/libswiftSynchronization.dylib": "@rpath/libswiftSynchronization.dylib",
}
FRAMEWORKS = ("FinanceKit.framework", "MarketplaceKit.framework", "Symbols.framework")

def cstring(buf: bytes, start: int, limit: int) -> str:
    if start < 0 or start >= limit:
        raise ValueError("invalid dylib name offset")
    end = buf.find(b"\0", start, limit)
    if end < 0:
        raise ValueError("unterminated dylib name")
    return buf[start:end].decode("utf-8", "replace")

def inspect_macho(buf: bytes) -> dict:
    if len(buf) < 32 or struct.unpack_from("<I", buf, 0)[0] != 0xFEEDFACF:
        raise ValueError("expected thin MH_MAGIC_64 arm64 Mach-O")
    _, cpu, subtype, kind, commands, total, flags, reserved = struct.unpack_from("<IiiIIIII", buf, 0)
    if cpu != 0x100000C or commands > 256 or total > len(buf) - 32:
        raise ValueError("unexpected Mach-O header or load commands")
    result = {"cpu": cpu, "subtype": subtype, "minimum_os": None, "encrypted": False,
              "encryption_ranges": [], "absolute_swift_imports": [], "frameworks": [],
              "other_dylib_import_count": 0, "rebinding_plan": []}
    ptr = 32
    for i in range(commands):
        cmd, size = struct.unpack_from("<II", buf, ptr)
        if size < 8 or ptr + size > 32 + total:
            raise ValueError("invalid LC command size")
        if cmd == 0x2C:
            start, length, cryptid = struct.unpack_from("<III", buf, ptr + 8)
            if cryptid:
                result["encrypted"] = True
                result["encryption_ranges"].append({"start": start, "length": length, "cryptid": cryptid})
        if cmd == 0x32:
            platform, minos, sdk, tools = struct.unpack_from("<IIII", buf, ptr + 8)
            result["minimum_os"] = f"{(minos >> 16) & 0xffff}.{(minos >> 8) & 0xff}.{minos & 0xff}"
            result["platform"] = platform
        if cmd in (0xC, 0x80000018, 0x8000001F, 0x80000023):
            off = struct.unpack_from("<I", buf, ptr + 8)[0]
            dep = cstring(buf, ptr + off, ptr + size)
            if dep in REBIND:
                result["absolute_swift_imports"].append({"name": dep, "link_command": hex(cmd)})
                result["rebinding_plan"].append({"old": dep, "new": REBIND[dep], "operation": "requires authorized isolated decrypted Mach-O"})
            elif any(f in dep for f in FRAMEWORKS):
                result["frameworks"].append({"name": dep, "link_command": hex(cmd)})
            else:
                result["other_dylib_import_count"] += 1
        ptr += size
    return result

def analyze(ipa: Path) -> dict:
    if not ipa.is_file():
        raise FileNotFoundError(str(ipa))
    result = {"source": str(ipa), "mode": "READ_ONLY", "required_bins": {}, "missing": [],
              "possible_rebindings": [], "framework_blockers": [], "candidate_gate": "BLOCKED"}
    with zipfile.ZipFile(ipa, "r") as archive:
        items = set(archive.namelist())
        plist_path = "Payload/ChatGPT.app/Info.plist"
        if plist_path in items:
            p = plistlib.loads(archive.read(plist_path))
            result["original_bundle_id"] = p.get("CFBundleIdentifier")
            result["original_version"] = p.get("CFBundleShortVersionString")
            result["original_min_os"] = p.get("MinimumOSVersion")
        for name in REQUIRED:
            if name not in items:
                result["missing"].append(name)
                continue
            with archive.open(name) as f:
                first = f.read(0x40000)
            record = inspect_macho(first)
            result["required_bins"][name] = record
            result["possible_rebindings"].extend([{"owner": name, **item} for item in record["rebinding_plan"]])
            result["framework_blockers"].extend([{"owner": name, **item} for item in record["frameworks"]])
    still_encrypted = [k for k,v in result["required_bins"].items() if v["encrypted"]]
    not_targeted = [k for k,v in result["required_bins"].items()
                    if v["minimum_os"] is not None and tuple(int(x) for x in v["minimum_os"].split(".")) > (16,6,0)]
    result["encrypted_required_bins"] = still_encrypted
    result["higher_minimum_os_required_bins"] = not_targeted
    result["checks"] = {
        "all_seven_required_present": not bool(result["missing"]),
        "all_seven_unencrypted": not bool(still_encrypted) and not result["missing"],
        "all_required_minos_compatible": not bool(not_targeted) and not result["missing"],
        "no_unimplemented_frameworks": not bool(result["framework_blockers"]),
        "needs_rebinding": bool(result["possible_rebindings"]),
    }
    # This is only a necessary, never sufficient, precondition to installability.
    if all(result["checks"][k] for k in ("all_seven_required_present", "all_seven_unencrypted",
                                           "all_required_minos_compatible", "no_unimplemented_frameworks")):
        result["candidate_gate"] = "STATIC_PREREQUISITES_ONLY; still requires actual dyld and device behavior tests"
    else:
        result["candidate_gate"] = "BLOCKED; do not treat a loader plan as a runnable application"
    result["safety_note"] = ("TrollStore may handle signing on supported devices, but does not decrypt FairPlay. "
        "Never install over com.openai.chat or reuse its protected data container. This script does not patch inputs.")
    return result

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--ipa", type=Path, default=DEFAULT_IPA)
    opts = parser.parse_args()
    print(json.dumps(analyze(opts.ipa), ensure_ascii=False, indent=2))
