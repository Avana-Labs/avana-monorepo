#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Report the SMTChecker results of one target from a forge build's build-info files.

forge prints only errors and warnings; the model checker's results also come as info messages (a target proved safe),
which only the solc output in the build-info files keeps. Reads every <build>/build-info/*.json, takes each solc job
whose input holds <source>, and prints one line per model-checker message about that source (severity, error code,
line, message), then the counts.

It also counts the source's verification targets on its own, from the solc AST of that job: in every non-abstract
contract of the source (not interfaces, libraries or free functions), each checked integer +, -, *, ** (outside an
`unchecked` block), each / and %, each compound assignment and ++/-- of those, each assert, each index into an array or
bytes, each .pop() of an array and each .transfer of an address. solc reports each such target as a CHC result at the
target's exact source range (proved safe with show_proved_safe, "might happen" when unproved, "happens" with a
counterexample), so every counted target must have a CHC result at its range.

Exit status:
  1  no solc job compiled <source>, more than one did (the source would be analysed twice), the model checker reported
     that no solver ran (7649 CHC, 8158 BMC), found a counterexample, or a counted target has no CHC result (the model
     checker skipped it); with --require-results also when there is no target or no CHC result at all (the CI job's
     probe, a contract with known targets)
  0  otherwise; unproved targets ("might happen here") are listed and counted, not failed. A contract with no counted
     target (Lock: address comparisons and transient-storage assembly only) has nothing to prove; that is reported.

Usage, from contracts/:  script/smt-report.py [--require-results] <build dir> <source> [<summary file>]
"""
import glob
import json
import os
import sys

NO_SOLVER = {"7649", "8158"}
ARITH = {"+": "overflow", "-": "underflow", "*": "overflow", "**": "overflow", "/": "divByZero", "%": "divByZero"}


def int_type(desc):
    t = (desc or {}).get("typeString") or ""
    return t.startswith(("uint", "int")) and not t.startswith("int_const")


def type_of(node):
    return ((node or {}).get("typeDescriptions") or {}).get("typeString") or ""


def ast_targets(ast):
    """[(start, end, kind)] of the verification targets in the source's non-abstract contracts."""
    found = []

    def add(node, kind):
        start, length = (int(x) for x in node["src"].split(":")[:2])
        found.append((start, start + length, kind))

    def walk(node, in_contract, unchecked):
        if isinstance(node, list):
            for n in node:
                walk(n, in_contract, unchecked)
            return
        if not isinstance(node, dict):
            return
        t = node.get("nodeType")
        if t == "ContractDefinition":
            in_contract = node.get("contractKind") == "contract" and not node.get("abstract")
        if t == "VariableDeclaration" and node.get("constant"):
            return
        if t == "UncheckedBlock":
            unchecked = True
        if in_contract:
            op = node.get("operator") or ""
            if t == "BinaryOperation" and op in ARITH and int_type(node.get("commonType")):
                if ARITH[op] == "divByZero" or not unchecked:
                    add(node, ARITH[op])
            elif t == "Assignment" and op[:-1] in ARITH and int_type(node.get("typeDescriptions")):
                if ARITH[op[:-1]] == "divByZero" or not unchecked:
                    add(node, ARITH[op[:-1]])
            elif t == "UnaryOperation" and op in ("++", "--") and not unchecked:
                if int_type(node.get("typeDescriptions")):
                    add(node, "overflow" if op == "++" else "underflow")
            elif t == "FunctionCall":
                callee = node.get("expression") or {}
                if callee.get("nodeType") == "Identifier" and callee.get("name") == "assert":
                    add(node, "assert")
                elif callee.get("nodeType") == "MemberAccess":
                    base = type_of(callee.get("expression"))
                    if callee.get("memberName") == "pop" and "[]" in base:
                        add(node, "popEmptyArray")
                    elif callee.get("memberName") == "transfer" and base.startswith("address"):
                        add(node, "balance")
            elif t == "IndexAccess":
                base = type_of(node.get("baseExpression"))
                if not base.startswith("mapping") and ("[" in base or base.startswith("bytes")):
                    add(node, "outOfBounds")
        for value in node.values():
            if isinstance(value, (dict, list)):
                walk(value, in_contract, unchecked)

    walk(ast, False, False)
    return sorted(set(found))


def line_of(text, offset):
    return text.count("\n", 0, max(offset, 0)) + 1


def main(argv):
    require = bool(argv) and argv[0] == "--require-results"
    if require:
        argv = argv[1:]
    if len(argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    build, source = argv[0], argv[1]
    summary = argv[2] if len(argv) == 3 else None
    with open(source, encoding="utf8") as fh:
        text = fh.read()
    jobs = 0
    rows = []
    targets = []
    for path in sorted(glob.glob(os.path.join(build, "build-info", "*.json"))):
        with open(path, encoding="utf8") as fh:
            info = json.load(fh)
        if source not in info.get("input", {}).get("sources", {}):
            continue
        jobs += 1
        # Only the kinds the build asked for (model_checker.targets; solc's default is every kind).
        asked = (info.get("input", {}).get("settings", {}).get("modelChecker") or {}).get("targets")
        targets = [
            t for t in ast_targets(info.get("output", {}).get("sources", {}).get(source, {}).get("ast"))
            if not asked or t[2] in asked
        ]
        for e in info.get("output", {}).get("errors", []):
            msg, code = e.get("message", ""), str(e.get("errorCode", ""))
            loc = e.get("sourceLocation") or {}
            ours = loc.get("file") == source
            # Results about the source, and summary lines with no location (solc's per-job counts).
            if code in NO_SOLVER or ((ours or not loc.get("file")) and ("CHC" in msg or "BMC" in msg)):
                line = line_of(text, loc.get("start", -1)) if ours else 0
                span = (loc.get("start"), loc.get("end")) if ours else None
                rows.append((e.get("severity", "?"), code, line, msg.replace("\n", " "), span))
    no_solver = [r for r in rows if r[1] in NO_SOLVER]
    cex = [r for r in rows if "happens here" in r[3] and "might happen" not in r[3]]
    unproved = [r for r in rows if "might happen here" in r[3]]
    safe = [r for r in rows if "is safe" in r[3] or "proved safe" in r[3]]
    chc = [r for r in rows if "CHC" in r[3] and r[1] not in NO_SOLVER]
    chc_spans = {r[4] for r in chc if r[4]}
    missed = [(s, e, k) for s, e, k in targets if (s, e) not in chc_spans]
    kinds = {}
    for _s, _e, k in targets:
        kinds[k] = kinds.get(k, 0) + 1
    out = [f"{sev} {code} {source}:{line}: {msg}" for sev, code, line, msg, _span in rows]
    out += [f"target {source}:{line_of(text, s)}: {k} {text[s:e]!r}: no CHC result" for s, e, k in missed]
    counts = (
        f"{source}: solc jobs {jobs}; targets {len(targets)} "
        f"({', '.join(f'{k} {n}' for k, n in sorted(kinds.items())) or 'none'}); with a CHC result "
        f"{len(targets) - len(missed)}; CHC results {len(chc)}; proved safe {len(safe)}; unproved {len(unproved)}; "
        f"counterexamples {len(cex)}; solver missing {len(no_solver)}"
    )
    print("\n".join(out))
    print(counts)
    if summary:
        with open(summary, "a", encoding="utf8") as fh:
            fh.write(f"{counts}\n\n")
            if unproved or cex or missed:
                fh.write("```\n" + "\n".join(o for o in out if "happen" in o or "no CHC result" in o) + "\n```\n")
    errors = []
    if jobs != 1:
        errors.append(f"{jobs} solc jobs compiled {source} (expected 1)")
    if no_solver:
        errors.append("solc found no solver (warning 7649 or 8158): nothing was checked")
    if missed:
        errors.append(f"{len(missed)} of {len(targets)} targets in {source} have no CHC result: the model checker skipped them")
    if require and not (targets and chc):
        errors.append(f"no target or no CHC result for {source}: the model checker did not run on it")
    elif not targets:
        note = f"{source}: no verification target (no checked arithmetic, division, assert, array index, pop or transfer)"
        print(note)
        if summary:
            with open(summary, "a", encoding="utf8") as fh:
                fh.write(note + "\n\n")
    if cex:
        errors.append(f"{len(cex)} counterexample(s)")
    for e in errors:
        print(f"::error::{e}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
