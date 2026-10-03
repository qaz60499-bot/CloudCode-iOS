from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import zipfile
import plistlib

from cryptography.hazmat.primitives import hashes, padding, serialization
from cryptography.hazmat.primitives.asymmetric import padding as asym_padding, rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

if len(sys.argv) != 3 or not sys.argv[1].isdigit() or not sys.argv[2].isdigit():
    raise SystemExit("usage: local_bundle_fetch.py <successful-privileged-run-id> <expected-build>")

SOURCE_RUN_ID = sys.argv[1]
EXPECTED_BUILD = sys.argv[2]
ROOT = Path.cwd()
WORK = ROOT / ".delivery" / f"local-fetch-{SOURCE_RUN_ID}-build{EXPECTED_BUILD}-{time.time_ns()}"
WORK.mkdir(parents=True, exist_ok=True)


def run(args: list[str]) -> str:
    completed = subprocess.run(args, check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if completed.returncode != 0:
        raise RuntimeError(f"command failed ({completed.returncode}): {args[0]}: {(completed.stderr or '').strip()}")
    return completed.stdout.strip()


def run_retry(args: list[str], *, attempts: int = 6, base_delay_seconds: float = 2.0) -> str:
    """Retry read/download commands that can fail transiently without repeating workflow dispatch."""
    last_error: RuntimeError | None = None
    for attempt in range(attempts):
        try:
            return run(args)
        except RuntimeError as error:
            last_error = error
            if attempt + 1 >= attempts:
                raise
            time.sleep(min(base_delay_seconds * (attempt + 1), 10.0))
    assert last_error is not None
    raise last_error

source = json.loads(run_retry(["gh", "run", "view", SOURCE_RUN_ID, "--json", "status,conclusion,headSha,name"]))
if source.get("status") != "completed" or source.get("conclusion") != "success":
    raise RuntimeError("source privileged validation run is not successful")
if source.get("name") != "Private TrollStore Privileged Validation IPA":
    raise RuntimeError("unexpected source workflow")

private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
public_pem = private_key.public_key().public_bytes(
    encoding=serialization.Encoding.PEM,
    format=serialization.PublicFormat.SubjectPublicKeyInfo,
)
public_b64 = base64.b64encode(public_pem).decode("ascii")

trigger = run([
    "gh", "workflow", "run", "Private Privileged IPA Secure Delivery",
    "--ref", "main",
    "-f", f"source_run_id={SOURCE_RUN_ID}",
    "-f", f"delivery_public_key_b64={public_b64}",
])
match = re.search(r"/runs/(\d+)", trigger)
if not match:
    raise RuntimeError("secure delivery dispatch did not return a run URL")
delivery_run_id = match.group(1)
print(json.dumps({"deliveryRunId": delivery_run_id, "work": str(WORK)}), flush=True)

for _ in range(160):
    state = json.loads(run_retry(["gh", "run", "view", delivery_run_id, "--json", "status,conclusion"]))
    if state.get("status") == "completed":
        if state.get("conclusion") != "success":
            raise RuntimeError(f"secure delivery failed: {state.get('conclusion')}")
        break
    time.sleep(3)
else:
    raise TimeoutError("secure delivery did not complete")

artifact_dir = WORK / "artifact"
artifact_dir.mkdir(parents=True, exist_ok=True)
run_retry([
    "gh", "run", "download", delivery_run_id,
    "--name", "CloudCode-iOS-TrollStore-PRIVILEGED-secure-delivery",
    "--dir", str(artifact_dir),
], attempts=6, base_delay_seconds=3.0)

key_enc = next(artifact_dir.glob("*.key.enc"))
ipa_enc = next(artifact_dir.glob("*.ipa.delivery.enc"))
metadata_path = next(artifact_dir.glob("*.metadata.txt"))
wrapped = key_enc.read_bytes()
key_material = private_key.decrypt(
    wrapped,
    asym_padding.OAEP(mgf=asym_padding.MGF1(algorithm=hashes.SHA1()), algorithm=hashes.SHA1(), label=None),
).decode("ascii")
key_hex, iv_hex = key_material.split(":", 1)
key = bytes.fromhex(key_hex)
iv = bytes.fromhex(iv_hex)
if len(key) != 32 or len(iv) != 16:
    raise RuntimeError("invalid one-time delivery key material")

decryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
padded = decryptor.update(ipa_enc.read_bytes()) + decryptor.finalize()
unpadder = padding.PKCS7(128).unpadder()
plain = unpadder.update(padded) + unpadder.finalize()

metadata: dict[str, str] = {}
for line in metadata_path.read_text(encoding="utf-8").splitlines():
    if "=" in line:
        k, v = line.split("=", 1)
        metadata[k] = v
ipa_name = metadata.get("ipa_name") or ipa_enc.name.removesuffix(".delivery.enc")
plain_ipa = WORK / ipa_name
plain_ipa.write_bytes(plain)

with zipfile.ZipFile(plain_ipa, "r") as archive:
    if archive.testzip() is not None:
        raise RuntimeError("IPA ZIP integrity failed")
    info = plistlib.loads(archive.read("Payload/CloudCode.app/Info.plist"))
    required = {
        "Payload/CloudCode.app/CloudCode",
        "Payload/CloudCode.app/CloudCodeRootHelper",
        "Payload/CloudCode.app/CloudCodeVisionHelper",
        "Payload/CloudCode.app/CloudCode-Provider-Bootstrap.json",
    }
    missing = sorted(required - set(archive.namelist()))
    if missing:
        raise RuntimeError(f"missing required IPA entries: {missing}")
    if int(EXPECTED_BUILD) >= 133:
        share_info_path = "Payload/CloudCode.app/PlugIns/CloudCodeShareExtension.appex/Info.plist"
        if share_info_path not in archive.namelist():
            raise RuntimeError("Build 133+ IPA is missing CloudCodeShareExtension.appex")
        share_info = plistlib.loads(archive.read(share_info_path))
        if share_info.get("CFBundleIdentifier") != "com.cloudcode.ios.share":
            raise RuntimeError("unexpected Share Extension bundle identifier")
        extension = share_info.get("NSExtension") or {}
        if extension.get("NSExtensionPointIdentifier") != "com.apple.share-services":
            raise RuntimeError("unexpected Share Extension point identifier")

digest = hashlib.sha256(plain).hexdigest()
if metadata.get("sha256") and digest.lower() != metadata["sha256"].lower():
    raise RuntimeError("IPA SHA-256 mismatch")
if metadata.get("size_bytes") and len(plain) != int(metadata["size_bytes"]):
    raise RuntimeError("IPA size mismatch")
if metadata.get("source_run_id") != SOURCE_RUN_ID:
    raise RuntimeError("source run mismatch")
if metadata.get("source_head") != source.get("headSha"):
    raise RuntimeError("source HEAD mismatch")
if str(info.get("CFBundleVersion")) != EXPECTED_BUILD or metadata.get("build") != EXPECTED_BUILD:
    raise RuntimeError(f"expected Build {EXPECTED_BUILD}")
if info.get("CFBundleIdentifier") != "com.cloudcode.ios":
    raise RuntimeError("unexpected bundle identifier")

shutil.rmtree(artifact_dir)

print(json.dumps({
    "ok": True,
    "deliveryRunId": delivery_run_id,
    "sourceRunId": SOURCE_RUN_ID,
    "sourceHead": source.get("headSha"),
    "ipa": str(plain_ipa),
    "sha256": digest,
    "sizeBytes": len(plain),
    "version": metadata.get("version"),
    "build": metadata.get("build"),
}, ensure_ascii=False), flush=True)
