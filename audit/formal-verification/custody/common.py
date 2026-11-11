"""Shared harness for the custody-area checks (FV-CUS-*).

Every check is a rule of Avana's internal formal verification:
  hypotheses (pre-state invariant + guard of the call) and a claim on the post-state.
`prove` asks Z3 for a model of `hyps and not claim`:
  unsat  -> VERIFIED (the claim holds for every input in the stated ranges)
  sat    -> VIOLATED (the model is a concrete counterexample)
  unknown-> UNKNOWN  (never counted as verified)
A second query checks that `hyps` alone is satisfiable (the `satisfy` witness), so a
rule whose hypotheses are contradictory is reported as VACUOUS, never as verified.
"""
import sys
import time
from z3 import (Solver, Not, sat, unsat, And, Or, If, Int, Ints, Bool, Sum,
                IntVal, BoolVal, Implies, simplify, is_true)

RESULTS = []
# Checks whose counterexample is a recorded finding still open against the spec text.
# Such a check still runs; when VIOLATED it is reported as OPEN with its counterexample
# and finding ID and does not fail run.sh. When it later passes it reports VERIFIED and
# its entry here is removed.
OPEN_FINDINGS = {}


def open_finding(cid, finding):
    OPEN_FINDINGS[cid] = finding


def _open(cid, status):
    if status == "VIOLATED" and cid in OPEN_FINDINGS:
        return f"OPEN {OPEN_FINDINGS[cid]}"
    return status

U128 = 2 ** 128
U120 = 2 ** 120
U256 = 2 ** 256
MAX_CREDITED = 2 ** 120 - 1


def ceil_div(a, b):
    """Integer ceiling for a >= 0, b > 0 (z3 Int division is floor for these signs)."""
    return (a + b - 1) / b


def floor_div(a, b):
    return a / b


def _model_values(m, show):
    out = {}
    for v in show:
        try:
            out[str(v)] = m.eval(v, model_completion=True)
        except Exception:  # noqa: BLE001
            out[str(v)] = "?"
    return out


def prove(cid, title, claim, hyps=(), show=(), timeout_ms=120000, kind="rule"):
    """Prove `claim` under `hyps`. Returns the status string."""
    t0 = time.time()
    hyps = list(hyps)
    # Witness: the hypotheses are satisfiable.
    w = Solver()
    w.set("timeout", timeout_ms)
    w.add(*hyps)
    wr = w.check()
    s = Solver()
    s.set("timeout", timeout_ms)
    s.add(*hyps)
    s.add(Not(claim))
    r = s.check()
    cex = None
    if wr == unsat:
        status = "VACUOUS"
    elif r == unsat:
        status = "VERIFIED"
    elif r == sat:
        status = "VIOLATED"
        cex = _model_values(s.model(), show)
    else:
        status = "UNKNOWN"
    status = _open(cid, status)
    dt = time.time() - t0
    RESULTS.append(dict(id=cid, title=title, status=status, cex=cex, secs=dt, kind=kind))
    line = f"[{status:9s}] {cid:16s} {title} ({dt:.1f}s)"
    print(line)
    if cex:
        for k, v in cex.items():
            print(f"      {k} = {v}")
    sys.stdout.flush()
    return status


def satisfiable(cid, title, cond, show=(), timeout_ms=120000):
    """A reachability check: report VERIFIED when `cond` has a model (used for
    witnesses that a scenario exists), printing the model."""
    t0 = time.time()
    s = Solver()
    s.set("timeout", timeout_ms)
    s.add(cond)
    r = s.check()
    cex = None
    if r == sat:
        status = "VERIFIED"
        cex = _model_values(s.model(), show)
    elif r == unsat:
        status = "VIOLATED"
    else:
        status = "UNKNOWN"
    dt = time.time() - t0
    RESULTS.append(dict(id=cid, title=title, status=status, cex=cex, secs=dt, kind="witness"))
    print(f"[{status:9s}] {cid:16s} {title} ({dt:.1f}s)")
    if cex:
        for k, v in cex.items():
            print(f"      {k} = {v}")
    return status


def concrete(cid, title, ok, detail=""):
    """A check over concrete numbers (examples, enumerations)."""
    status = _open(cid, "VERIFIED" if ok else "VIOLATED")
    RESULTS.append(dict(id=cid, title=title, status=status, cex=None if ok else detail,
                        secs=0.0, kind="concrete"))
    print(f"[{status:9s}] {cid:16s} {title}")
    if not ok and detail:
        print(f"      {detail}")
    return status


def summary(module):
    counts = {}
    for r in RESULTS:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print(f"-- {module}: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    bad = [r for r in RESULTS if r["status"] != "VERIFIED" and not r["status"].startswith("OPEN")]
    return 1 if bad else 0
