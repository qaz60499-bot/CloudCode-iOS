#!/usr/bin/env bash
set -euo pipefail

IPA_PATH="${1:-}"
if [[ -z "$IPA_PATH" || ! -f "$IPA_PATH" ]]; then
  echo "usage: $0 <ipa>" >&2
  exit 2
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

unzip -q "$IPA_PATH" -d "$TMP_DIR"
APP_COUNT="$(find "$TMP_DIR/Payload" -maxdepth 1 -type d -name '*.app' -print | wc -l | tr -d ' ')"
if [[ "$APP_COUNT" != "1" ]]; then
  echo "FAIL: expected exactly one Payload/*.app, found $APP_COUNT" >&2
  exit 3
fi
APP_PATH="$(find "$TMP_DIR/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"

INFO="$APP_PATH/Info.plist"
if [[ ! -f "$INFO" ]]; then
  echo "FAIL: Info.plist missing" >&2
  exit 4
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO" 2>/dev/null || true)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO" 2>/dev/null || true)"
PACKAGE_TYPE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundlePackageType' "$INFO" 2>/dev/null || true)"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$INFO" 2>/dev/null || true)"
SUPPORTED_PLATFORM="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$INFO" 2>/dev/null || true)"

if [[ "$BUNDLE_ID" != "com.cloudcode.ios" ]]; then
  echo "FAIL: unexpected bundle id: $BUNDLE_ID" >&2
  exit 5
fi
if [[ -z "$VERSION" || "$VERSION" == "(null)" ]]; then
  echo "FAIL: CFBundleShortVersionString is missing; TrollStore/install services require stable version metadata" >&2
  exit 6
fi
if [[ -z "$BUILD" || "$BUILD" == "(null)" ]]; then
  echo "FAIL: CFBundleVersion is missing; TrollStore/install services require stable build metadata" >&2
  exit 7
fi
if [[ "$PACKAGE_TYPE" != "APPL" ]]; then
  echo "FAIL: unexpected CFBundlePackageType: $PACKAGE_TYPE" >&2
  exit 8
fi
if [[ "$SUPPORTED_PLATFORM" != "iPhoneOS" ]]; then
  echo "FAIL: unexpected supported platform: $SUPPORTED_PLATFORM" >&2
  exit 9
fi
if [[ ! -f "$APP_PATH/$EXECUTABLE" ]]; then
  echo "FAIL: executable missing: $EXECUTABLE" >&2
  exit 10
fi

file "$APP_PATH/$EXECUTABLE"
if ! lipo -info "$APP_PATH/$EXECUTABLE" | grep -q 'arm64'; then
  echo "FAIL: main executable does not contain arm64" >&2
  exit 11
fi

while IFS= read -r dependency; do
  case "$dependency" in
    @rpath/*.framework/*)
      relative="${dependency#@rpath/}"
      if [[ ! -f "$APP_PATH/Frameworks/$relative" ]]; then
        echo "FAIL: required embedded framework dependency missing: $dependency" >&2
        exit 12
      fi
      ;;
  esac
done < <(otool -L "$APP_PATH/$EXECUTABLE" | tail -n +2 | awk '{print $1}')

python3 - "$IPA_PATH" "$APP_PATH" <<'PY'
import os
import plistlib
import sys
import zipfile
from pathlib import PurePosixPath

ipa_path = sys.argv[1]
app_path = sys.argv[2]

with zipfile.ZipFile(ipa_path) as archive:
    names = archive.namelist()
    if len(names) != len(set(names)):
        raise SystemExit("FAIL: IPA contains duplicate ZIP entries")
    lowered = {}
    for name in names:
        path = PurePosixPath(name)
        if name.startswith("/") or ".." in path.parts:
            raise SystemExit(f"FAIL: unsafe IPA path: {name}")
        key = name.lower()
        if key in lowered and lowered[key] != name:
            raise SystemExit(f"FAIL: case-colliding IPA entries: {lowered[key]} vs {name}")
        lowered[key] = name

for root, dirs, files in os.walk(app_path):
    if root.endswith(".framework") or root.endswith(".app"):
        info_path = os.path.join(root, "Info.plist")
        if not os.path.isfile(info_path):
            continue
        with open(info_path, "rb") as handle:
            info = plistlib.load(handle)
        executable = info.get("CFBundleExecutable")
        if executable:
            binary = os.path.join(root, executable)
            if not os.path.isfile(binary):
                raise SystemExit(f"FAIL: bundle executable missing: {binary}")
print("PASS: archive paths and nested bundle executables validated")
PY

plutil -lint "$INFO"
unzip -t "$IPA_PATH"

echo "PASS: IPA archive is structurally valid and install metadata is complete"
echo "bundle_id=$BUNDLE_ID"
echo "version=$VERSION"
echo "build=$BUILD"
echo "minimum_os=$MIN_OS"
echo "app_path=$APP_PATH"
echo "NOTE: device-only privileged behavior still requires target-device runtime proof."
