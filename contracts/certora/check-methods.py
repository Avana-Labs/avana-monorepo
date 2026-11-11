#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Check every CVL methods block in certora/specs against the compiled interface ABIs in out/.

Each entry of a `methods { ... }` block must name a function that exists, with the same parameter types (and the
same return types where the entry states them), in the ABI it binds to:

  function f(...)           the verified contract: its interface (`I<Contract>`, or the override below) plus the
                            OpenZeppelin interfaces the contract inherits (IAccessControl for every AccessControl
                            contract)
  function c.f(...)         contract C of a multi-contract conf, bound by `using C as c;`: the interface of C
  function _.f(...)         any external contract: some ABI in out/ that declares f with these parameter types

Internal entries and `unresolved external` entries are refused: no implementation exists to name internal functions,
and every external call of a verified contract is bound to an interface function by name.

Types are compared on the ABI `internalType`: structs and enums by their declared name (with or without the
declaring interface as qualifier), contract types as `address`, arrays element-wise.

Specs are matched to their verified contract through the confs in certora/conf (`"verify": "<Contract>:<spec>"`);
a spec with no conf is mapped in SPEC_WITHOUT_CONF.

Usage, from contracts/:  python3 certora/check-methods.py [--out out] [-v]
Exit status: 0 when every entry matches, 1 otherwise.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONTRACTS = HERE.parent

# Verified contract -> interface ABIs, where the interface is not simply I<Contract>.
INTERFACE_OF = {
    "HubInstance": ["IAaveV4Hub"],
    "PegModuleRoute": ["ISettlementRoute"],
    "DexPathRoute": ["ISettlementRoute"],
    "WrapperThenDexRoute": ["ISettlementRoute"],
    "CoverageSpoke": ["ICoverageSpoke"],
    "AaveV3FlashSource": ["IFlashSource", "IAaveV3FlashLoanReceiver"],
    "LPOracleHarness": ["ILPOracle"],
}

# Contracts that inherit OpenZeppelin AccessControl (v5.1.0) and so expose IAccessControl (PROP-034, PROP-070).
ACCESS_CONTROL = {
    "AaveAdapter", "ProxyManager", "MarketRegistry", "ParameterStore", "RiskModule", "LPOracle", "DebtOracle",
    "LPVaultSwap", "AvanaTimelock", "LPOracleHarness",
}

# Specs verified by no conf: the contract whose interface their unqualified entries bind to.
SPEC_WITHOUT_CONF = {
    "CoverageSpoke.spec": "CoverageSpoke",
}

ELEMENTARY = re.compile(r"^(u?int\d*|address|bool|bytes\d*|string)$")


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def load_json5(path: Path) -> dict:
    text = re.sub(r"(?m)^\s*//.*$", "", path.read_text())
    text = re.sub(r",(\s*[}\]])", r"\1", text)
    return json.loads(text)


def canon_abi_type(p: dict) -> str:
    """Canonical comparable type of an ABI parameter."""
    it = p.get("internalType", p["type"])
    suffix = ""
    m = re.match(r"^(.*?)((\[\d*\])*)$", it)
    base, suffix = m.group(1), m.group(2)
    if base.startswith("contract ") or base.startswith("interface "):
        base = "address"
    elif base.startswith("struct ") or base.startswith("enum "):
        base = base.split(" ", 1)[1].split(".")[-1]
    elif base == "uint":
        base = "uint256"
    elif base == "int":
        base = "int256"
    return base + suffix


def canon_cvl_type(t: str) -> str:
    t = re.sub(r"\b(memory|calldata|storage|payable)\b", "", t).strip()
    t = t.split()[0] if t else t  # drop a parameter name
    m = re.match(r"^(.*?)((\[\d*\])*)$", t)
    base, suffix = m.group(1), m.group(2)
    if base == "uint":
        base = "uint256"
    elif base == "int":
        base = "int256"
    elif not ELEMENTARY.match(base):
        base = base.split(".")[-1]
    return base + suffix


def split_top(s: str) -> list[str]:
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [x.strip() for x in out if x.strip()]


def load_abis(out: Path) -> dict[str, list[dict]]:
    abis: dict[str, list[dict]] = {}
    # Interfaces that share a name in different folders (the Uniswap v3 and the Slipstream
    # INonfungiblePositionManager) compile to out/<folder>/<File>.sol/; every declaration is kept.
    for f in sorted(p for p in out.rglob("*.json") if p.parent.name.endswith(".sol") and "build-info" not in p.parts):
        # A source compiled under a second compiler profile (foundry.toml `compilation_restrictions`, used for
        # Collateralization) gets `<Name>.<profile>.json`; every profile's ABI of a declaration is the same.
        name = f.stem.split(".", 1)[0]
        abi = json.loads(f.read_text()).get("abi", [])
        fns = [x for x in abi if x.get("type") == "function"]
        if fns:
            abis.setdefault(name, []).extend(fns)
    return abis


def methods_blocks(text: str) -> list[tuple[int, str]]:
    """(line number, body) of each `methods { ... }` block of a comment-free spec text."""
    blocks = []
    for m in re.finditer(r"\bmethods\s*\{", text):
        depth, i = 1, m.end()
        while depth and i < len(text):
            depth += {"{": 1, "}": -1}.get(text[i], 0)
            i += 1
        blocks.append((text.count("\n", 0, m.start()) + 1, text[m.end(): i - 1]))
    return blocks


ENTRY = re.compile(
    r"^function\s+(?P<target>(?:[A-Za-z_]\w*|_)\.)?(?P<name>[A-Za-z_]\w*)\s*\((?P<params>[^)]*)\)\s*(?P<rest>.*)$", re.S)


def parse_entry(stmt: str):
    m = ENTRY.match(stmt)
    if not m:
        return None
    rest = m.group("rest")
    vis = re.match(r"\s*(external|internal|public)\b", rest)
    returns = re.search(r"\breturns\s*\(([^)]*)\)", rest.split("=>")[0])
    if not returns:
        r1 = re.search(r"\breturns\s+([A-Za-z_][\w.\[\]]*)", rest.split("=>")[0])
        returns_list = [r1.group(1)] if r1 else None
    else:
        returns_list = split_top(returns.group(1))
    expect = None
    em = re.search(r"\bexpect\s+(\(([^)]*)\)|[A-Za-z_][\w.\[\]]*)", rest)
    if em:
        expect = [] if em.group(1) == "void" else (split_top(em.group(2)) if em.group(2) is not None else [em.group(1)])
    return {
        "target": (m.group("target") or "")[:-1],
        "name": m.group("name"),
        "params": [canon_cvl_type(p) for p in split_top(m.group("params"))],
        "visibility": vis.group(1) if vis else None,
        "returns": [canon_cvl_type(r) for r in returns_list] if returns_list is not None else None,
        "expect": [canon_cvl_type(r) for r in expect] if expect is not None else None,
    }


def candidates(abis, names, fname):
    for n in names:
        for fn in abis.get(n, []):
            if fn["name"] == fname:
                yield n, fn


def matches(fn, params, outs):
    if [canon_abi_type(p) for p in fn["inputs"]] != params:
        return False
    if outs is not None and [canon_abi_type(p) for p in fn["outputs"]] != outs:
        return False
    return True


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(CONTRACTS / "out"), help="forge artifact directory (default contracts/out)")
    ap.add_argument("-v", "--verbose", action="store_true", help="list every checked entry")
    args = ap.parse_args()

    out = Path(args.out)
    abis = load_abis(out)
    if not abis:
        print(f"check-methods: no ABIs under {out}; run forge build first", file=sys.stderr)
        return 1

    spec_contracts: dict[str, set[str]] = defaultdict(set)   # spec file -> verified contract names
    conf_contracts: dict[str, set[str]] = defaultdict(set)   # spec file -> every contract of its confs
    for conf in sorted((HERE / "conf").glob("*.conf")):
        c = load_json5(conf)
        contract, spec = c["verify"].split(":", 1)
        spec_name = Path(spec).name
        spec_contracts[spec_name].add(contract)
        for f in c.get("files", []):
            conf_contracts[spec_name].add(f.split(":")[-1] if ":" in f else Path(f).stem)
        if not (CONTRACTS / spec).is_file():
            print(f"ERROR {conf.relative_to(CONTRACTS)}: verify names {spec}, which does not exist")
            spec_contracts["__missing__"].add(spec)
    for spec_name, contract in SPEC_WITHOUT_CONF.items():
        spec_contracts[spec_name].add(contract)

    def iface(contract: str) -> list[str]:
        names = list(INTERFACE_OF.get(contract, [f"I{contract}"]))
        if contract in ACCESS_CONTROL:
            names.append("IAccessControl")
        return names

    errors = len(spec_contracts.pop("__missing__", []))
    checked = 0
    all_names = sorted(abis)
    for spec in sorted((HERE / "specs").rglob("*.spec")):
        rel = spec.relative_to(CONTRACTS)
        text = strip_comments(spec.read_text())
        blocks = methods_blocks(text)
        verified = spec_contracts.get(spec.name, set())
        if blocks and not verified and spec.parent.name != "setup":
            print(f"ERROR {rel}: no conf verifies this spec and it is not in SPEC_WITHOUT_CONF")
            errors += 1
            continue
        if spec.parent.name == "setup" and blocks:
            print(f"ERROR {rel}: setup models hold only ghosts and CVL functions; bind them in the contract spec")
            errors += 1
            continue
        own = sorted({n for c in verified for n in iface(c)})
        alias = {a: c for c, a in re.findall(r"\busing\s+(\w+)\s+as\s+(\w+)\s*;", text)}
        alias["currentContract"] = next(iter(verified), "")
        for c in verified:
            if not any(n in abis for n in iface(c)):
                print(f"ERROR {rel}: no ABI in {out.name}/ for {c} (looked for {', '.join(iface(c))})")
                errors += 1
        for line0, body in blocks:
            for stmt in body.split(";"):
                stmt = " ".join(stmt.split())
                if not stmt:
                    continue
                line = line0  # block line; entries are reported by text
                if stmt.startswith("unresolved") or re.match(r"^function\s+_\._\b", stmt):
                    print(f"ERROR {rel}:{line}: catch-all entry `{stmt}`; bind every call to a named function")
                    errors += 1
                    continue
                e = parse_entry(stmt)
                if e is None:
                    print(f"ERROR {rel}:{line}: cannot parse methods entry `{stmt}`")
                    errors += 1
                    continue
                checked += 1
                if e["visibility"] != "external":
                    print(f"ERROR {rel}: `{e['name']}` is not an external entry; only interface functions may be named")
                    errors += 1
                    continue
                outs = e["returns"] if e["returns"] is not None else e["expect"]
                if e["target"] == "_":
                    pool, where = all_names, "any ABI"
                elif e["target"]:
                    target = alias.get(e["target"], e["target"])
                    pool = iface(target)
                    where = ", ".join(pool)
                    if target not in conf_contracts.get(spec.name, set()) and target not in verified:
                        print(f"ERROR {rel}: `{e['target']}.{e['name']}` names a contract that no conf of this spec links")
                        errors += 1
                        continue
                else:
                    pool, where = own, ", ".join(own) or "(no interface)"
                found = list(candidates(abis, pool, e["name"]))
                sig = f"{(e['target'] + '.') if e['target'] else ''}{e['name']}({','.join(e['params'])})"
                if not found:
                    print(f"ERROR {rel}: {sig} does not exist in {where}")
                    errors += 1
                    continue
                ok = [n for n, fn in found if matches(fn, e["params"], outs)]
                if not ok:
                    have = sorted({f"{n}.{fn['name']}({','.join(canon_abi_type(p) for p in fn['inputs'])})"
                                   f" returns ({','.join(canon_abi_type(p) for p in fn['outputs'])})" for n, fn in found})
                    want = f" returns ({','.join(outs)})" if outs is not None else ""
                    print(f"ERROR {rel}: {sig}{want} matches no declaration; candidates: {'; '.join(have)}")
                    errors += 1
                elif args.verbose:
                    print(f"ok    {rel}: {sig} -> {ok[0]}")

    print(f"check-methods: {checked} methods entries in {len(list((HERE / 'specs').rglob('*.spec')))} spec files, "
          f"{errors} error(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
