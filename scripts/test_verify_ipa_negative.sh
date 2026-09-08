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

make_archive_case() {
  local name="$1"
  local mutation="$2"
  local tmp
  tmp="$(mktemp -d)"
  local bad_ipa="$tmp/$name.ipa"
  python3 - "$IPA_PATH" "$bad_ipa" "$mutation" <<'PY'
import shutil
import stat
import sys
import warnings
import zipfile

source, destination, mutation = sys.argv[1:4]
shutil.copyfile(source, destination)
with zipfile.ZipFile(destination, "a") as archive:
    if mutation == "traversal":
        archive.writestr("../cloudcode-verifier-escape", b"x")
    elif mutation == "symlink":
        info = zipfile.ZipInfo("Payload/CloudCodeVerifierSymlink")
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        archive.writestr(info, b"/tmp")
        archive.writestr("Payload/CloudCodeVerifierSymlink/child", b"must-not-extract-through-link")
    elif mutation == "duplicate":
        target = next(name for name in archive.namelist() if name.endswith("/Info.plist"))
        data = archive.read(target)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            archive.writestr(target, data)
    elif mutation == "case-collision":
        target = next(name for name in archive.namelist() if name.endswith("/Info.plist"))
        archive.writestr(target[:-len("Info.plist")] + "info.plist", archive.read(target))
    else:
        raise SystemExit(f"unknown archive mutation: {mutation}")
PY
  if bash scripts/verify_ipa.sh "$bad_ipa" >/dev/null 2>&1; then
    echo "FAIL: verifier accepted unsafe archive case: $name" >&2
    rm -rf "$tmp"
    exit 11
  fi
  rm -rf "$tmp"
  echo "PASS: verifier rejected unsafe archive case: $name"
}

make_case missing-short-version remove-short-version
make_case missing-build-version remove-build-version
make_case wrong-package-type wrong-package-type
make_case missing-main-executable remove-main-executable
make_archive_case traversal-entry traversal
make_archive_case symlink-entry symlink
make_archive_case duplicate-entry duplicate
make_archive_case case-collision-entry case-collision

echo "PASS: installability verifier negative regression suite"
