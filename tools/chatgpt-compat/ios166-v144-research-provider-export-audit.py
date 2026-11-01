"""V144 strict actual iPhoneOS native provider export audit (research only).

Use genuine nm exports from Swift binaries, not source-name searches.
These providers deliberately deny or throw; matching public exported symbols
does not establish runtime semantic equivalence or system framework routing.
"""
from __future__ import annotations
import argparse
import json
import re
from pathlib import Path

MANGLED = re.compile(r"_\$s(?:10FinanceKit|14MarketplaceKit)[A-Za-z0-9_]+")


def required(path: Path) -> tuple[set[str], set[str]]:
    all_names = [line.strip() for line in path.read_text(encoding="utf-8").splitlines()
                 if line.strip() and not line.startswith("#")]
    if len(all_names) != 22 or len(set(all_names)) != 22:
        raise ValueError("INVALID_EXPECTED_22_STRONG_SYMBOLS")
    finance = {x for x in all_names if x.startswith("_$s10FinanceKit")}
    market = {x for x in all_names if x.startswith("_$s14MarketplaceKit")}
    if len(finance) != 14 or len(market) != 8:
        raise ValueError("INVALID_FINANCE_MARKET_SPLIT")
    return finance, market


def exports(text: str) -> set[str]:
    found = set()
    for line in text.splitlines():
        # nm -gU export rows include a non-undefined address, symbol type,
        # and the global Swift symbol. Reject bare source text and undefined U.
        pieces = line.strip().split()
        if (len(pieces) == 3 and re.fullmatch(r"[0-9a-fA-F]{8,16}", pieces[0])
                and pieces[1] not in {"U", "u"} and MANGLED.fullmatch(pieces[2])):
            found.add(pieces[2])
    return found


def evaluate(expected_finance: set[str], expected_market: set[str],
             finance_export: set[str], market_export: set[str],
             negative_export: set[str]) -> dict:
    missing_finance = sorted(expected_finance - finance_export)
    missing_market = sorted(expected_market - market_export)
    target = {x for x in expected_finance if "requestAuthorization" in x}
    if len(target) != 2 or not any(x.endswith("Tu") for x in target):
        raise ValueError("NO_EXPECTED_FINANCE_ASYNC_PAIR")
    missing_negative = sorted(target - negative_export)
    unexpected_negative = sorted((expected_finance - target) - negative_export)
    positive = not missing_finance and not missing_market
    negative = not (target & negative_export) and not unexpected_negative
    return {
        "schema": "ipa-total-ios166-v144-native-research-provider-exports/1",
        "expected": {"finance":14, "marketplace":8},
        "matching": {
            "finance":len(expected_finance & finance_export),
            "marketplace":len(expected_market & market_export),
        },
        "missingPositiveFinance":missing_finance,
        "missingPositiveMarketplace":missing_market,
        "missingDeliberatelyNegative":missing_negative,
        "negativeUnexpectedlyMissing":unexpected_negative,
        "positiveSymbolShapeStatus":"PASS" if positive else "FAIL",
        "negativeSymbolOmissionStatus":"PASS" if negative else "FAIL",
        "providerBehavior":"FAIL_CLOSED_RESEARCH_ONLY_NOT_APPLE_EQUIVALENT",
        "dyldInstallNameRebinding":"NOT_TESTED",
        "ios166Runtime":"NOT_TESTED",
        "officialChatGPT":"BLOCKED_P0_0_OF_6",
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", type=Path, required=True)
    ap.add_argument("--finance-nm", type=Path, required=True)
    ap.add_argument("--market-nm", type=Path, required=True)
    ap.add_argument("--finance-negative-nm", type=Path, required=True)
    args = ap.parse_args()
    f,m = required(args.manifest)
    result = evaluate(f,m,exports(args.finance_nm.read_text()),
                      exports(args.market_nm.read_text()),
                      exports(args.finance_negative_nm.read_text()))
    print(json.dumps(result,indent=2))
    return 0 if (result["positiveSymbolShapeStatus"] == "PASS"
                 and result["negativeSymbolOmissionStatus"] == "PASS") else 1


if __name__=="__main__":
    raise SystemExit(main())
