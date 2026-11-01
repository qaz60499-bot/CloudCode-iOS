"""Summarize only selected public API facts from swift-api-digester output."""
import argparse
import json
from pathlib import Path

TARGET = {"SymbolEffect", "ContentTransitionSymbolEffect", "SymbolEffectOptions",
          "SymbolEffectConfiguration", "ReplaceSymbolEffect", "AutomaticSymbolEffect"}

def describe(decl, depth=0):
    if depth > 4:
        raise ValueError("public declaration nesting outside bound")
    result = {k: decl[k] for k in ("name", "kind", "printedName", "declKind", "mangledName")
              if k in decl}
    result["static"] = decl.get("static", False)
    result["types"] = [c.get("printedName") for c in decl.get("children", [])
                       if c.get("kind", "").startswith("Type") and c.get("kind") != "TypeDecl"]
    result["conformances"] = sorted(c["name"] for c in decl.get("conformances", []) if c.get("name"))
    if decl.get("kind") == "TypeDecl":
        result["members"] = [describe(c, depth + 1) for c in decl.get("children", [])]
    return result

def summarize(raw):
    declarations = raw["ABIRoot"]["children"]
    result = {d["name"]: describe(d) for d in declarations if d.get("name") in TARGET}
    if set(result) != TARGET:
        raise ValueError("missing selected public SDK/candidate type")
    return {"schema": "ios166-v123-symbols-public-shape/1", "types": result,
            "private_layout_read": False, "runtime_compatibility_proven": False}

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    args.output.write_text(json.dumps(summarize(json.loads(args.input.read_text())), indent=2))
