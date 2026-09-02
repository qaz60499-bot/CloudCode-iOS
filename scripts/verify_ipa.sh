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
APP_PATH="$(find "$TMP_DIR/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  echo "FAIL: Payload/*.app missing" >&2
  exit 3
fi

INFO="$APP_PATH/Info.plist"
if [[ ! -f "$INFO" ]]; then
  echo "FAIL: Info.plist missing" >&2
  exit 4
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO")"
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$INFO" 2>/dev/null || true)"

if [[ "$BUNDLE_ID" != "com.cloudcode.ios" ]]; then
  echo "FAIL: unexpected bundle id: $BUNDLE_ID" >&2
  exit 5
fi
if [[ ! -x "$APP_PATH/$EXECUTABLE" && ! -f "$APP_PATH/$EXECUTABLE" ]]; then
  echo "FAIL: executable missing: $EXECUTABLE" >&2
  exit 6
fi

file "$APP_PATH/$EXECUTABLE"
lipo -info "$APP_PATH/$EXECUTABLE" || true
plutil -lint "$INFO"
unzip -t "$IPA_PATH"

echo "PASS: IPA archive is structurally valid"
echo "bundle_id=$BUNDLE_ID"
echo "minimum_os=$MIN_OS"
echo "app_path=$APP_PATH"
echo "NOTE: TrollStore private entitlements/root-helper behavior is DEVICE_VALIDATION_REQUIRED and is not proven by this unsigned Runner artifact."
