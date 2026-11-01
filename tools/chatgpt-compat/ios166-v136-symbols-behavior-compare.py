"""Compare observed native calls; layout observations remain platform specific."""
import argparse
import json
from pathlib import Path


def compare(apple, candidate):
    for report in (apple, candidate):
        if report.get("schema") != "ipa-total-v136-symbols-behavior/1":
            raise ValueError("unsupported native behavior report")
        for key in ("semantic_equalities", "witness_calls"):
            values = report.get(key)
            if not isinstance(values, dict) or not values or len(values) > 2048:
                raise ValueError("missing bounded native observations")
            if any(not isinstance(k, str) or type(v) is not bool for k, v in values.items()):
                raise ValueError("native observations must be named booleans")
        if report.get("rendering_tested") is not False or report.get("official_app_tested") is not False:
            raise ValueError("unsupported proof boundary")
    if apple["semantic_equalities"].keys() != candidate["semantic_equalities"].keys():
        raise ValueError("different native case coverage")
    if apple["witness_calls"].keys() != candidate["witness_calls"].keys():
        raise ValueError("different witness case coverage")
    mismatch = [key for key in sorted(apple["semantic_equalities"])
                if apple["semantic_equalities"][key] != candidate["semantic_equalities"][key]]
    failed_witnesses = {provider: sorted(k for k, v in report["witness_calls"].items() if not v)
                        for provider, report in (("apple", apple), ("candidate", candidate))}
    return {
        "status": "FAIL_NATIVE_BEHAVIOR_DIFFERENCE" if mismatch or any(failed_witnesses.values())
                  else "PASS_SELECTED_NATIVE_CALLS_ONLY",
        "semantic_comparisons": len(apple["semantic_equalities"]),
        "behavior_mismatches": mismatch, "failed_witness_calls": failed_witnesses,
        "layout_observations": {"apple_host": apple.get("value_layouts"),
                                "candidate_host": candidate.get("value_layouts")},
        "ios16_binary_layout_equivalence_proven": False,
        "ios16_device_execution_proven": False, "rendering_proven": False,
        "official_boot_plaintext": "0/6", "official_features": "0/5",
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apple", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = compare(json.loads(args.apple.read_text()), json.loads(args.candidate.read_text()))
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result["status"] == "PASS_SELECTED_NATIVE_CALLS_ONLY" else 1)
