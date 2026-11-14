#!/usr/bin/env python3
"""Fails if any spec ID cited by an FV-CUS check (tag line) is not defined in the spec.
Uses the definition rules of docs/spec/05-verification/trace.py."""
import importlib.util
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("trace", HERE.parents[3] / "docs/spec/05-verification/trace.py")
trace = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trace)
defined = trace.collect_requirements([])
cited = {}
for f in list(HERE.glob("*.py")) + list(HERE.glob("*.qnt")):
    for n, line in enumerate(f.read_text().splitlines(), 1):
        m = trace.TAG.search(line)
        if m:
            for rid in trace.SPLIT.findall(m.group(2)):
                cited.setdefault(rid, f"{f.name}:{n}")
for r in (HERE / "results").glob("*.json"):
    for rec in json.loads(r.read_text()):
        for rid in rec["verifies"]:
            cited.setdefault(rid, f"results/{r.name}:{rec['id']}")
missing = {k: v for k, v in cited.items() if k not in defined}
print(f"check_ids: {len(cited)} cited spec IDs, {len(missing)} undefined")
for k, v in sorted(missing.items()):
    print(f"  undefined {k} (cited at {v})")
sys.exit(1 if missing else 0)
