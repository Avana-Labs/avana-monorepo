"""Shared harness for the control-area formal verification models (FV-C).

Every check is one of:
  prove(...)    - the negation of the claim is unsatisfiable under the stated assumptions
                  (Verified) or satisfiable (Violated, with a concrete counterexample);
  witness(...)  - a premise is satisfiable (the success path of a rule is reachable);
  exhaustive(.) - a property checked over every element of a finite domain (a complete proof
                  for that domain, reported as Verified);
  bounded(...)  - a property checked over a bounded domain or depth (Verified under bounded model).

Each model file calls finish() at the end; finish() prints a table, writes results/<model>.json
and returns exit code 1 when any check is Violated or Unknown, except a violation registered with
open_finding(), which is printed as [OPN] with its counterexample and its finding ID.
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import z3

HERE = Path(__file__).resolve().parent
RESULTS_DIR = HERE / "results"
_RESULTS: list[dict] = []
# Checks whose violation is an open finding recorded in report.md section "Open findings": the counterexample is
# printed and stored as usual, the status reads "Violated (open finding <ID>)", and the check does not fail the
# run. A check listed here that passes is reported as Verified and the entry is stale.
OPEN_FINDINGS: dict[str, str] = {}


def open_finding(cid: str, finding: str) -> None:
    OPEN_FINDINGS[cid] = finding
_MODEL = Path(sys.argv[0]).stem


def _fmt_model(m: z3.ModelRef, names=None) -> dict:
    out = {}
    for d in sorted(m.decls(), key=lambda d: d.name()):
        if names and d.name() not in names:
            continue
        v = m[d]
        try:
            if z3.is_int_value(v):
                out[d.name()] = v.as_long()
            elif z3.is_bv_value(v):
                out[d.name()] = v.as_long()
            elif z3.is_true(v) or z3.is_false(v):
                out[d.name()] = z3.is_true(v)
            else:
                out[d.name()] = str(v)
        except Exception:  # pragma: no cover - printing only
            out[d.name()] = str(v)
    return out


def _record(cid, title, status, method, verifies, targets, detail="", cex=None, seconds=0.0):
    if status == "Violated" and cid in OPEN_FINDINGS:
        status = f"Violated (open finding {OPEN_FINDINGS[cid]})"
    r = {"id": cid, "title": title, "status": status, "method": method,
         "verifies": list(verifies), "targets": list(targets), "detail": detail,
         "counterexample": cex, "seconds": round(seconds, 2), "model": _MODEL}
    _RESULTS.append(r)
    mark = "OPN" if "open finding" in status else \
        {"Verified": "ok ", "Violated": "VIO", "Unknown": "UNK"}.get(status.split(" ")[0], "ok ")
    print(f"[{mark}] {cid:<18} {status:<34} {title}")
    if cex is not None:
        print(f"       counterexample: {json.dumps(cex, default=str)[:900]}")
    if detail and status != "Verified":
        print(f"       {detail}")
    return r


def prove(cid, title, claim, assumptions=(), verifies=(), targets=(), show=None, timeout_ms=120_000,
          detail=""):
    """Prove `claim` holds for every assignment satisfying `assumptions`."""
    t0 = time.time()
    s = z3.Solver()
    s.set("timeout", timeout_ms)
    for a in assumptions:
        s.add(a)
    s.add(z3.Not(claim))
    r = s.check()
    dt = time.time() - t0
    if r == z3.unsat:
        return _record(cid, title, "Verified", "Z3 (unsat of negation)", verifies, targets, detail, None, dt)
    if r == z3.sat:
        return _record(cid, title, "Violated", "Z3 (sat of negation)", verifies, targets, detail,
                       _fmt_model(s.model(), show), dt)
    return _record(cid, title, "Unknown", f"Z3 {r}", verifies, targets, detail, None, dt)


def witness(cid, title, premise, verifies=(), targets=(), show=None, timeout_ms=60_000, detail=""):
    """Show `premise` is satisfiable (non-vacuity of a rule's success path)."""
    t0 = time.time()
    s = z3.Solver()
    s.set("timeout", timeout_ms)
    s.add(premise)
    r = s.check()
    dt = time.time() - t0
    if r == z3.sat:
        return _record(cid, title, "Verified", "Z3 witness (sat)", verifies, targets, detail,
                       None, dt)
    return _record(cid, title, "Violated" if r == z3.unsat else "Unknown", f"Z3 witness {r}",
                   verifies, targets, detail or "premise unsatisfiable: rule would be vacuous", None, dt)


def exhaustive(cid, title, domain, pred, verifies=(), targets=(), detail="", bounded_note=None):
    """Check pred(x) for every x in a finite domain; a failing x is the counterexample."""
    t0 = time.time()
    n = 0
    for x in domain:
        n += 1
        ok = pred(x)
        if ok is not True:
            return _record(cid, title, "Violated", f"exhaustive enumeration ({n} cases)", verifies,
                           targets, detail, {"case": x, "why": ok} if ok not in (False, None) else {"case": x},
                           time.time() - t0)
    status = "Verified" if bounded_note is None else "Verified under bounded model"
    d = detail if bounded_note is None else (detail + " " + bounded_note).strip()
    return _record(cid, title, status, f"exhaustive enumeration ({n} cases)", verifies, targets, d, None,
                   time.time() - t0)


def bounded_prove(cid, title, claim, assumptions=(), verifies=(), targets=(), show=None, bound="",
                  timeout_ms=120_000):
    r = prove(cid, title, claim, assumptions, verifies, targets, show, timeout_ms, detail=bound)
    if r["status"] == "Verified":
        r["status"] = "Verified under bounded model"
        print(f"       (bounded: {bound})")
    return r


def expect(cid, title, ok, verifies=(), targets=(), detail="", cex=None):
    """Record a property established by direct computation (e.g. an arithmetic identity on constants)."""
    return _record(cid, title, "Verified" if ok else "Violated", "direct computation", verifies, targets,
                   detail, None if ok else cex)


def finish() -> int:
    RESULTS_DIR.mkdir(exist_ok=True)
    (RESULTS_DIR / f"{_MODEL}.json").write_text(json.dumps(_RESULTS, indent=1, default=str))
    bad = [r for r in _RESULTS if r["status"] in ("Violated", "Unknown") or r["status"].startswith("Unknown")]
    opn = [r for r in _RESULTS if "open finding" in r["status"]]
    print(f"--- {_MODEL}: {len(_RESULTS)} checks, {len(bad)} violated or unknown"
          + (f", {len(opn)} violated as open findings ({', '.join(r['id'] for r in opn)})" if opn else ""))
    return 1 if bad else 0


# ---------------------------------------------------------------- helpers
def zmax(*xs):
    m = xs[0]
    for x in xs[1:]:
        m = z3.If(x > m, x, m)
    return m


def zmin(*xs):
    m = xs[0]
    for x in xs[1:]:
        m = z3.If(x < m, x, m)
    return m


def floor_div(a, b):
    """Integer floor division for non-negative Ints (Z3 `/` on Int is floor for b > 0)."""
    return a / b


def ceil_div(a, b):
    return (a + b - 1) / b
