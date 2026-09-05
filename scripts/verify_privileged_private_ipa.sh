#!/usr/bin/env bash
set -euo pipefail

IPA_PATH="${1:-}"
if [[ -z "$IPA_PATH" || ! -f "$IPA_PATH" ]]; then
  echo "usage: $0 <privileged-private-trollstore-ipa>" >&2
  exit 2
fi

bash scripts/verify_ipa.sh "$IPA_PATH"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
unzip -q "$IPA_PATH" -d "$TMP_DIR"
APP_PATH="$(find "$TMP_DIR/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
BOOTSTRAP="$APP_PATH/CloudCode-Provider-Bootstrap.json"

if [[ ! -f "$BOOTSTRAP" ]]; then
  echo "FAIL: private Provider bootstrap missing from privileged IPA" >&2
  exit 10
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
datetime.fromisoformat(generated_at.replace("Z", "+00:00"))
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

MAIN_EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_PATH/Info.plist")"
ENTITLEMENTS="$TMP_DIR/privileged-entitlements.plist"
ldid -e "$APP_PATH/$MAIN_EXECUTABLE" > "$ENTITLEMENTS"
plutil -lint "$ENTITLEMENTS" >/dev/null

for key in \
  'com.apple.private.security.no-sandbox' \
  'platform-application' \
  'com.apple.private.security.storage.AppDataContainers' \
  'com.apple.private.persona-mgmt'; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$ENTITLEMENTS" 2>/dev/null || true)"
  if [[ "$value" != "true" ]]; then
    echo "FAIL: privileged entitlement missing or false: $key" >&2
    exit 11
  fi
done
for helper_only in \
  'com.apple.multitasking.unlimitedassertions' \
  'com.apple.hid.system.server-access' \
  'com.apple.private.hid.client.event-dispatch' \
  'com.apple.private.hid.client.event-filter' \
  'com.apple.private.hid.client.event-monitor' \
  'com.apple.private.hid.client.service-protected' \
  'com.apple.private.hid.manager.client' \
  'com.apple.accessibility.api' \
  'com.apple.QuartzCore.displayable-context' \
  'com.apple.QuartzCore.global-capture' \
  'com.apple.QuartzCore.secure-capture' \
  'com.apple.QuartzCore.secure-mode' \
  'com.apple.QuartzCore.system-layers' \
  'com.apple.private.IOSurface.protected-access' \
  'com.apple.backboard.client'; do
  if /usr/libexec/PlistBuddy -c "Print :$helper_only" "$ENTITLEMENTS" >/dev/null 2>&1; then
    echo "FAIL: GUI-only entitlement leaked onto SwiftUI host: $helper_only" >&2
    exit 11
  fi
done
for banned in \
  'com.apple.private.cs.debugger' \
  'dynamic-codesigning' \
  'com.apple.private.skip-library-validation'; do
  if /usr/libexec/PlistBuddy -c "Print :$banned" "$ENTITLEMENTS" >/dev/null 2>&1; then
    echo "FAIL: TrollStore launch-crashing entitlement present on main executable: $banned" >&2
    exit 11
  fi
done

test "$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$ENTITLEMENTS")" = 'TROLLTROLL.*'
test "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$ENTITLEMENTS")" = 'TROLLTROLL'
/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$ENTITLEMENTS" | grep -F 'TROLLTROLL.*' >/dev/null

HELPER="$APP_PATH/CloudCodeRootHelper"
test -f "$HELPER"
HELPER_ENTITLEMENTS="$TMP_DIR/root-helper-entitlements.plist"
ldid -e "$HELPER" > "$HELPER_ENTITLEMENTS"
plutil -lint "$HELPER_ENTITLEMENTS" >/dev/null
# The helper has a dedicated privilege profile: keep GUI-only accessibility/capture
# entitlements off the SwiftUI host and verify them only on the crash-isolated root helper.
for key in \
  'com.apple.private.security.no-sandbox' \
  'platform-application' \
  'com.apple.private.security.storage.AppDataContainers' \
  'com.apple.private.security.storage.AppBundles' \
  'com.apple.private.security.container-manager' \
  'com.apple.private.MobileContainerManager.allowed' \
  'com.apple.private.coreservices.canmaplsdatabase' \
  'com.apple.lsapplicationworkspace.rebuildappdatabases' \
  'com.apple.private.security.storage-exempt.heritable' \
  'com.apple.private.MobileInstallationHelperService.InstallDaemonOpsEnabled' \
  'com.apple.private.MobileInstallationHelperService.allowed' \
  'com.apple.private.uninstall.deletion' \
  'com.apple.private.persona-mgmt' \
  'com.apple.multitasking.unlimitedassertions' \
  'com.apple.hid.system.server-access' \
  'com.apple.hid.system.user-access-service' \
  'com.apple.private.hid.client.event-dispatch' \
  'com.apple.private.hid.client.event-filter' \
  'com.apple.private.hid.client.event-monitor' \
  'com.apple.private.hid.client.service-protected' \
  'com.apple.private.hid.manager.client' \
  'com.apple.accessibility.api' \
  'com.apple.QuartzCore.displayable-context' \
  'com.apple.QuartzCore.global-capture' \
  'com.apple.QuartzCore.secure-capture' \
  'com.apple.QuartzCore.secure-mode' \
  'com.apple.QuartzCore.system-layers' \
  'com.apple.private.IOSurface.protected-access' \
  'com.apple.backboard.client'; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$HELPER_ENTITLEMENTS" 2>/dev/null || true)"
  if [[ "$value" != "true" ]]; then
    echo "FAIL: root helper entitlement missing or false: $key" >&2
    exit 12
  fi
done
container_required="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.private.security.container-required' "$HELPER_ENTITLEMENTS" 2>/dev/null || true)"
if [[ "$container_required" != "false" ]]; then
  echo "FAIL: root helper entitlement missing or not false: com.apple.private.security.container-required" >&2
  exit 12
fi
for uninstall_spi in 'UninstallForLaunchServices' 'Uninstall'; do
  if ! /usr/libexec/PlistBuddy -c 'Print :com.apple.private.mobileinstall.allowedSPI' "$HELPER_ENTITLEMENTS" 2>/dev/null | grep -F "$uninstall_spi" >/dev/null; then
    echo "FAIL: root helper MobileInstallation SPI entitlement missing: $uninstall_spi" >&2
    exit 12
  fi
done
for iokit_key in \
  'com.apple.security.iokit-user-client-class' \
  'com.apple.security.exception.iokit-user-client-class'; do
  for iokit_class in \
    'IOSurfaceRootUserClient' \
    'IOHIDEventServiceFastPathUserClient' \
    'IOHIDLibUserClient' \
    'IOAccelDevice' \
    'IOAccelDevice2' \
    'IOAccelSharedUserClient' \
    'IOAccelSharedUserClient2' \
    'AGXDeviceUserClient'; do
    if ! /usr/libexec/PlistBuddy -c "Print :$iokit_key" "$HELPER_ENTITLEMENTS" 2>/dev/null | grep -F "$iokit_class" >/dev/null; then
      echo "FAIL: root helper IOKit entitlement missing: $iokit_key -> $iokit_class" >&2
      exit 12
    fi
  done
done
for banned in \
  'com.apple.private.cs.debugger' \
  'dynamic-codesigning' \
  'com.apple.private.skip-library-validation'; do
  if /usr/libexec/PlistBuddy -c "Print :$banned" "$HELPER_ENTITLEMENTS" >/dev/null 2>&1; then
    echo "FAIL: TrollStore launch-crashing entitlement present on root helper: $banned" >&2
    exit 12
  fi
done

echo "PASS: privileged TrollStore host entitlement set matches the device-compatible no-sandbox/platform/container profile"
echo "SECURITY: this IPA contains private Provider credentials and privileged entitlements; use only on the user's own TrollStore test device"
echo "NOTE: entitlement presence does not prove device runtime support; capability probes must still verify each operation on-device."
