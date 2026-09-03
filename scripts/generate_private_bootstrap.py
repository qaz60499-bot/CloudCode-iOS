#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path

DEFAULT_RUNTIME = Path(r"D:\wendangcodex\CloudRuntime")
DEFAULT_OUTPUT = Path("Secrets") / "CloudCode-Provider-Bootstrap.json"


def read_keys(paths: list[Path]) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for path in paths:
        if not path.is_file():
            continue
        for raw in path.read_text(encoding="utf-8").splitlines():
            value = raw.strip()
            if not value or value.startswith("#"):
                continue
            for part in value.split(","):
                key = part.strip()
                if key and key not in seen:
                    seen.add(key)
                    result.append(key)
    return result


def fingerprint(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def enabled_provider_ids(runtime: Path) -> list[str]:
    registry_path = runtime / "custom_providers.json"
    payload = json.loads(registry_path.read_text(encoding="utf-8"))
    result: list[str] = []
    for row in payload.get("providers") or []:
        if not isinstance(row, dict) or row.get("enabled") is not True:
            continue
        provider_id = str(row.get("id") or "").strip()
        if not provider_id or provider_id.lower() == "seekai":
            continue
        result.append(provider_id)
    return result


def provider_key_paths(runtime: Path, provider_id: str) -> list[Path]:
    if provider_id == "tabitoken":
        return [runtime / ".secrets" / "tabitoken.key", runtime / ".secrets" / "tabitoken-extra.keys"]
    return [
        runtime / ".secrets" / f"custom-{provider_id}.key",
        runtime / ".secrets" / f"custom-{provider_id}-extra.keys",
    ]


def make_provider(provider_id: str, keys: list[str]) -> dict:
    return {
        "providerID": provider_id,
        "keys": [
            {
                "slotID": f"slot-{index}",
                "label": f"Key {index}",
                "secret": key,
                "fingerprint": fingerprint(key),
            }
            for index, key in enumerate(keys, 1)
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a local-only Cloud Code iOS Key bootstrap. Raw Keys are never printed.")
    parser.add_argument("--runtime", type=Path, default=DEFAULT_RUNTIME)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--dry-run", action="store_true", help="Validate sources and print only counts/fingerprint prefixes; do not write plaintext bootstrap data.")
    args = parser.parse_args()

    runtime = args.runtime.resolve()
    output = args.output.resolve()
    provider_ids = ["tabitoken"] + enabled_provider_ids(runtime)
    providers: list[dict] = []
    summary: list[tuple[str, int, list[str]]] = []

    for provider_id in provider_ids:
        keys = read_keys(provider_key_paths(runtime, provider_id))
        if not keys:
            continue
        providers.append(make_provider(provider_id, keys))
        summary.append((provider_id, len(keys), [fingerprint(key)[:8] for key in keys]))

    if not providers:
        raise SystemExit("No Provider Keys were found. Bootstrap was not created.")

    if not args.dry_run:
        output.parent.mkdir(parents=True, exist_ok=True)
        payload = {
            "schemaVersion": 1,
            "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            "providers": providers,
        }
        output.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        print(f"PRIVATE_KEY_BOOTSTRAP_REQUIRED: wrote {len(providers)} provider entries to {output}")
    else:
        print(f"PRIVATE_KEY_BOOTSTRAP_REQUIRED: dry-run validated {len(providers)} provider entries; no plaintext bootstrap file was written")
    for provider_id, count, prefixes in summary:
        print(f"{provider_id}: {count} keys; fingerprints={','.join(prefixes)}")
    print("Raw API Keys were not printed. Keep this file private and import it once into the iOS app.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
