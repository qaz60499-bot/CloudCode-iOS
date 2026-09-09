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
if [[ ! -f "$APP_PATH/Assets.car" ]]; then
  echo "FAIL: compiled asset catalog missing; app icon would be absent after installation" >&2
  exit 13
fi
if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon' "$INFO" >/dev/null 2>&1; then
  echo "FAIL: CFBundleIcons/CFBundlePrimaryIcon metadata missing" >&2
  exit 14
fi
HELPER="$APP_PATH/CloudCodeRootHelper"
if [[ ! -f "$HELPER" ]]; then
  echo "FAIL: embedded CloudCodeRootHelper missing; privileged uninstall fallback would be unavailable" >&2
  exit 15
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :TSRootBinaries:0' "$INFO" 2>/dev/null || true)" != "CloudCodeRootHelper" ]]; then
  echo "FAIL: TSRootBinaries does not declare CloudCodeRootHelper" >&2
  exit 16
fi
if [[ -n "$(/usr/libexec/PlistBuddy -c 'Print :TSRootBinaries:1' "$INFO" 2>/dev/null || true)" ]]; then
  echo "FAIL: TSRootBinaries contains an unexpected additional root binary; CloudCodeVisionHelper must remain non-privileged" >&2
  exit 16
fi
if ! lipo -info "$HELPER" | grep -q 'arm64'; then
  echo "FAIL: CloudCodeRootHelper does not contain arm64" >&2
  exit 17
fi
if ! LC_ALL=C grep -aFq 'cloudcode-root-helper-protocol=1' "$HELPER"; then
  echo "FAIL: embedded CloudCodeRootHelper protocol marker is missing or incompatible" >&2
  exit 18
fi
VISION_HELPER="$APP_PATH/CloudCodeVisionHelper"
if [[ ! -f "$VISION_HELPER" ]]; then
  echo "FAIL: embedded CloudCodeVisionHelper missing; local OCR fallback would be unavailable" >&2
  exit 19
fi
if ! lipo -info "$VISION_HELPER" | grep -q 'arm64'; then
  echo "FAIL: CloudCodeVisionHelper does not contain arm64" >&2
  exit 20
fi
if ! LC_ALL=C grep -aFq 'cloudcode-vision-helper-protocol=1' "$VISION_HELPER"; then
  echo "FAIL: embedded CloudCodeVisionHelper protocol marker is missing or incompatible" >&2
  exit 21
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

# The bounded CLI runtime is part of the install artifact, not a source-only capability claim.
# Verify exactly the minimal upstream framework set and both runtime dictionaries. Generic CLI
# frameworks remain ordinary app frameworks and must never appear in TSRootBinaries.
for cli_framework in ios_system files shell text; do
  cli_binary="$APP_PATH/Frameworks/$cli_framework.framework/$cli_framework"
  if [[ ! -f "$cli_binary" ]]; then
    echo "FAIL: bounded CLI framework missing from IPA: $cli_framework" >&2
    exit 22
  fi
  if ! lipo -info "$cli_binary" | grep -q 'arm64'; then
    echo "FAIL: bounded CLI framework is missing arm64: $cli_framework" >&2
    exit 22
  fi
done
if ! otool -L "$APP_PATH/$EXECUTABLE" | grep -Fq '@rpath/ios_system.framework/ios_system'; then
  echo "FAIL: main executable is not linked against ios_system.framework" >&2
  exit 22
fi
for lazy_cli_framework in files shell text; do
  if otool -L "$APP_PATH/$EXECUTABLE" | grep -Fq "@rpath/$lazy_cli_framework.framework/$lazy_cli_framework"; then
    echo "FAIL: lazy CLI framework is linked at app launch instead of remaining dlopen-only: $lazy_cli_framework" >&2
    exit 22
  fi
done
for dictionary in commandDictionary.plist extraCommandsDictionary.plist; do
  if [[ ! -f "$APP_PATH/$dictionary" ]]; then
    echo "FAIL: ios_system command dictionary missing from IPA: $dictionary" >&2
    exit 22
  fi
  plutil -lint "$APP_PATH/$dictionary" >/dev/null
done
for forbidden_cli_framework in awk curl_ios ssh_cmd tar mandoc perl perlA perlB Python lua_ios network_ios; do
  if [[ -e "$APP_PATH/Frameworks/$forbidden_cli_framework.framework" ]]; then
    echo "FAIL: non-minimal CLI framework unexpectedly packaged: $forbidden_cli_framework" >&2
    exit 22
  fi
done

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

expected_cli = {
    "pwd", "echo", "ls", "cat", "cp", "mv", "mkdir", "rm", "stat", "find",
    "grep", "head", "tail", "wc", "sort", "uniq",
}
with open(os.path.join(app_path, "commandDictionary.plist"), "rb") as handle:
    command_dictionary = plistlib.load(handle)
with open(os.path.join(app_path, "extraCommandsDictionary.plist"), "rb") as handle:
    extra_dictionary = plistlib.load(handle)
if set(command_dictionary) != expected_cli:
    raise SystemExit(
        f"FAIL: packaged CLI command catalog mismatch: expected={sorted(expected_cli)} actual={sorted(command_dictionary)}"
    )
if extra_dictionary != {}:
    raise SystemExit("FAIL: extraCommandsDictionary must remain empty in the minimal CLI build")
allowed_frameworks = {"files.framework/files", "shell.framework/shell", "text.framework/text"}
for command, entry in command_dictionary.items():
    if not isinstance(entry, list) or len(entry) != 4:
        raise SystemExit(f"FAIL: invalid CLI dictionary entry for {command}")
    if entry[0] not in allowed_frameworks:
        raise SystemExit(f"FAIL: CLI command {command} references non-minimal framework {entry[0]}")
print(f"PASS: minimal CLI catalog validated ({len(expected_cli)} commands; extra catalog empty)")

for root, dirs, files in os.walk(app_path):
    if root.endswith(".framework") or root.endswith(".app"):
        info_path = os.path.join(root, "Info.plist")
        if not os.path.isfile(info_path):
            continue
        with open(info_path, "rb") as handle:
            info = plistlib.load(handle)
        executable = info.get("CFBundleExecutable")
        package_type = info.get("CFBundlePackageType")
        if package_type == "FMWK":
            version = info.get("CFBundleShortVersionString")
            build = info.get("CFBundleVersion")
            if not version or not build:
                raise SystemExit(f"FAIL: embedded framework version metadata missing: {root}")
        if executable:
            binary = os.path.join(root, executable)
            if not os.path.isfile(binary):
                raise SystemExit(f"FAIL: bundle executable missing: {binary}")
print("PASS: archive paths, nested bundle executables and framework metadata validated")
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
