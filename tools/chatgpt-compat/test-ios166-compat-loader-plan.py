"""Offline unit tests for read-only Mach-O deployment planner. Never touch original IPA."""
import importlib.util
import io
import plistlib
import struct
import unittest
import zipfile

spec = importlib.util.spec_from_file_location("loader_plan", "ios166-compat-loader-plan.py")
loader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(loader)

def fixture(*, cryptid=0, minos=0x00100600, libs=()):
    commands = bytearray()
    for lib in libs:
        name = lib.encode("utf-8") + b"\0"
        sz = (24 + len(name) + 7) & ~7
        cmd = bytearray(sz)
        struct.pack_into("<IIIIII", cmd, 0, 0xc, sz, 24, 0, 0, 0)
        cmd[24:24+len(name)] = name
        commands.extend(cmd)
    commands.extend(struct.pack("<IIIIII",0x2c,24,0,4096,cryptid,0))
    commands.extend(struct.pack("<IIIIII",0x32,24,2,minos,0x00120500,0))
    header = struct.pack("<IiiIIIII",0xFEEDFACF,0x0100000C,0,6,len(libs)+2,len(commands),0,0)
    return header+commands

class PlanTests(unittest.TestCase):
    def test_encrypted_blocked(self):
        record=loader.inspect_macho(fixture(cryptid=1,libs=(
            "/usr/lib/swift/libswiftObservation.dylib",
            "/usr/lib/swift/libswiftSynchronization.dylib",
            "/System/Library/Frameworks/FinanceKit.framework/FinanceKit")))
        self.assertTrue(record["encrypted"])
        self.assertEqual(len(record["rebinding_plan"]),2)
        self.assertEqual(len(record["frameworks"]),1)
    def test_unencrypted_header_only(self):
        record=loader.inspect_macho(fixture())
        self.assertFalse(record["encrypted"])
        self.assertEqual(record["minimum_os"],"16.6.0")
    def test_future_deployment(self):
        record=loader.inspect_macho(fixture(minos=0x00120000))
        self.assertEqual(record["minimum_os"],"18.0.0")
    def test_malformed_rejected(self):
        with self.assertRaises(ValueError):
            loader.inspect_macho(b"junk")
        with self.assertRaises(ValueError):
            loader.inspect_macho(fixture()[:-3])
    def test_complete_zip_with_seven_images(self):
        # No real app code, no device or signing operations, no persistent files.
        mem=io.BytesIO()
        with zipfile.ZipFile(mem,"w") as z:
            z.writestr("Payload/ChatGPT.app/Info.plist",plistlib.dumps({
                "CFBundleIdentifier":"research.test.only","MinimumOSVersion":"16.6",
                "CFBundleShortVersionString":"0.0.0"}))
            for path in loader.REQUIRED:
                z.writestr(path,fixture())
        class FakePath:
            def is_file(self): return True
            def __str__(self): return "<memory>"
        orig=loader.zipfile.ZipFile
        try:
            loader.zipfile.ZipFile=lambda path,mode:orig(io.BytesIO(mem.getvalue()),mode)
            report=loader.analyze(FakePath())
            self.assertEqual(len(report["required_bins"]),7)
            self.assertIn("STATIC_PREREQUISITES_ONLY",report["candidate_gate"])
            self.assertFalse(report["framework_blockers"])
        finally:
            loader.zipfile.ZipFile=orig

if __name__=="__main__":
    unittest.main(verbosity=2)
