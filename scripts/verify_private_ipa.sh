#!/usr/bin/env bash
set -euo pipefail

IPA_PATH="${1:-}"
if [[ -z "$IPA_PATH" || ! -f "$IPA_PATH" ]]; then
  echo "usage: $0 <private-trollstore-ipa>" >&2
  exit 2
fi

bash scripts/verify_ipa.sh "$IPA_PATH"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
unzip -q "$IPA_PATH" -d "$TMP_DIR"
APP_PATH="$(find "$TMP_DIR/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
BOOTSTRAP="$APP_PATH/CloudCode-Provider-Bootstrap.json"

if [[ ! -f "$BOOTSTRAP" ]]; then
  echo "FAIL: private Provider bootstrap missing from private IPA" >&2
  exit 10
fi

BOOTSTRAP_COUNT="$(find "$APP_PATH" -type f -name '*Provider-Bootstrap*.json' | wc -l | tr -d ' ')"
if [[ "$BOOTSTRAP_COUNT" != "1" ]]; then
  echo "FAIL: expected exactly one Provider bootstrap in app bundle, found $BOOTSTRAP_COUNT" >&2
  exit 11
fi

python3 - "$BOOTSTRAP" <<'PY'
import hashlib
import json
import re
import sys
from datetime import datetime
from pathlib import Path

path = Path(sys.argv[1])
payload = json.loads(path.read_text(encoding="utf-8"))
if payload.get("schemaVersion") != 1:
    raise SystemExit("FAIL: private bootstrap schemaVersion must be 1")

generated_at = payload.get("generatedAt")
if not isinstance(generated_at, str) or not generated_at:
    raise SystemExit("FAIL: private bootstrap generatedAt missing")
try:
    datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
except ValueError as exc:
    raise SystemExit(f"FAIL: private bootstrap generatedAt is not ISO8601: {exc}")

providers = payload.get("providers")
if not isinstance(providers, list) or not providers:
    raise SystemExit("FAIL: private bootstrap has no providers")

provider_ids = set()
key_count = 0
for provider in providers:
    provider_id = provider.get("providerID")
    if not isinstance(provider_id, str) or not provider_id or provider_id in provider_ids:
        raise SystemExit("FAIL: duplicate/invalid providerID in private bootstrap")
    provider_ids.add(provider_id)
    slot_ids = set()
    keys = provider.get("keys")
    if not isinstance(keys, list) or not keys:
        raise SystemExit(f"FAIL: provider {provider_id} has no keys")
    for key in keys:
        slot_id = key.get("slotID")
        secret = key.get("secret")
        fingerprint = key.get("fingerprint")
        if not isinstance(slot_id, str) or not slot_id or slot_id in slot_ids:
            raise SystemExit(f"FAIL: duplicate/invalid slotID for {provider_id}")
        slot_ids.add(slot_id)
        if not isinstance(secret, str) or not secret:
            raise SystemExit(f"FAIL: empty secret for {provider_id}/{slot_id}")
        expected = hashlib.sha256(secret.encode("utf-8")).hexdigest()
        if fingerprint != expected or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise SystemExit(f"FAIL: fingerprint mismatch for {provider_id}/{slot_id}")
        key_count += 1

print(f"PASS: private bootstrap validated without printing secrets ({len(provider_ids)} providers, {key_count} keys)")
PY

codesign --verify --deep --strict "$APP_PATH"
ENTITLEMENTS="$TMP_DIR/entitlements.plist"
codesign -d --entitlements :- "$APP_PATH" > "$ENTITLEMENTS" 2>/dev/null
plutil -lint "$ENTITLEMENTS" >/dev/null

NO_SANDBOX="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.private.security.no-sandbox' "$ENTITLEMENTS" 2>/dev/null || true)"
PLATFORM_APP="$(/usr/libexec/PlistBuddy -c 'Print :platform-application' "$ENTITLEMENTS" 2>/dev/null || true)"
APP_DATA="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.private.security.storage.AppDataContainers' "$ENTITLEMENTS" 2>/dev/null || true)"
PERSONA="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.private.persona-mgmt' "$ENTITLEMENTS" 2>/dev/null || true)"
if [[ "$NO_SANDBOX" != "true" || "$PLATFORM_APP" != "true" || "$APP_DATA" != "true" || "$PERSONA" != "true" ]]; then
  echo "FAIL: TrollStore private entitlement set is incomplete" >&2
  exit 12
fi

for banned in com.apple.private.cs.debugger dynamic-codesigning com.apple.private.skip-library-validation; do
  if /usr/libexec/PlistBuddy -c "Print :$banned" "$ENTITLEMENTS" >/dev/null 2>&1; then
    echo "FAIL: banned TrollStore entitlement present: $banned" >&2
    exit 13
  fi
done

echo "PASS: private TrollStore IPA signature and required private entitlements verified"
echo "SECURITY: this IPA contains private Provider credentials; distribute only through an encrypted/private channel"
