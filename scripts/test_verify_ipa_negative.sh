#!/usr/bin/env bash
set -euo pipefail

IPA_PATH="${1:-}"
if [[ -z "$IPA_PATH" || ! -f "$IPA_PATH" ]]; then
  echo "usage: $0 <ipa>" >&2
  exit 2
fi

make_case() {
  local name="$1"
  local mutation="$2"
  local tmp
  tmp="$(mktemp -d)"
  unzip -q "$IPA_PATH" -d "$tmp/unpacked"
  local app
  app="$(find "$tmp/unpacked/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
  test -n "$app"
  local info="$app/Info.plist"
  local executable
  executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info")"

  case "$mutation" in
    remove-short-version)
      /usr/libexec/PlistBuddy -c 'Delete :CFBundleShortVersionString' "$info"
      ;;
    remove-build-version)
      /usr/libexec/PlistBuddy -c 'Delete :CFBundleVersion' "$info"
      ;;
    wrong-package-type)
      /usr/libexec/PlistBuddy -c 'Set :CFBundlePackageType BNDL' "$info"
      ;;
    remove-main-executable)
      rm -f "$app/$executable"
      ;;
    *)
      echo "unknown mutation: $mutation" >&2
      exit 3
      ;;
  esac

  local bad_ipa="$tmp/$name.ipa"
  (cd "$tmp/unpacked" && zip -qry "$bad_ipa" Payload)
  if bash scripts/verify_ipa.sh "$bad_ipa" >/dev/null 2>&1; then
    echo "FAIL: verifier accepted negative case: $name" >&2
    rm -rf "$tmp"
    exit 10
  fi
  rm -rf "$tmp"
  echo "PASS: verifier rejected negative case: $name"
}

make_case missing-short-version remove-short-version
make_case missing-build-version remove-build-version
make_case wrong-package-type wrong-package-type
make_case missing-main-executable remove-main-executable

echo "PASS: installability verifier negative regression suite"
