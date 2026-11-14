# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Shared helpers for the settlement Z3 models.

check(pid, title, solver_or_constraints, expect) asserts the NEGATION of a
property (or the shape of a counterexample being searched for) and reports:
  PROVED          the negation is unsat
  COUNTEREXAMPLE  the negation is sat (the model is printed)
  TIMEOUT         Z3 returned unknown within the time limit
  COMPUTED        a worked example whose stated figures equal the exact evaluation
  MISMATCH        a stated figure differs from the exact evaluation
`expect` is the result the README documents. Scripts exit 1 if any result
differs from what is documented, so run_all.sh flags drift.
"""
import sys
from z3 import Solver, Optimize, sat, unsat, IntNumRef, RatNumRef, BitVecNumRef, is_true, is_false

TIMEOUT_MS = 120_000
RAY = 10**27
WAD = 10**18
BPS = 10_000

_results = []


def _fmt(v):
    if isinstance(v, (IntNumRef, BitVecNumRef)):
        n = v.as_long()
        return f"{n}" if abs(n) < 10**6 else f"{n} (~{n:.4e})"
    if isinstance(v, RatNumRef):
        return f"{float(v.numerator_as_long()) / float(v.denominator_as_long()):.10g}"
    if is_true(v):
        return "true"
    if is_false(v):
        return "false"
    s = str(v)
    return s if len(s) < 80 else s[:77] + "..."


def check(pid, title, constraints, expect, show=None, timeout_ms=TIMEOUT_MS):
    s = Solver()
    s.set("timeout", timeout_ms)
    s.add(*constraints)
    r = s.check()
    if r == unsat:
        res = "PROVED"
    elif r == sat:
        res = "COUNTEREXAMPLE"
    else:
        res = "TIMEOUT"
    print(f"[{res}] {pid}: {title}")
    if res == "COUNTEREXAMPLE":
        m = s.model()
        names = show if show is not None else sorted(m.decls(), key=lambda d: d.name())
        for d in names:
            try:
                val = m.eval(d, model_completion=True) if not hasattr(d, "arity") else m[d]
            except Exception:
                val = m[d]
            label = d if isinstance(d, str) else (d.name() if hasattr(d, "name") else str(d))
            print(f"      {label} = {_fmt(val)}")
    if res != expect:
        print(f"      !! documented result is {expect}")
    _results.append((pid, res, expect))
    return res


def maximize(pid, title, constraints, objective, expect_max=None, timeout_ms=TIMEOUT_MS):
    """Finds the maximum of `objective` (an Int) under constraints; informational."""
    o = Optimize()
    o.set("timeout", timeout_ms)
    o.add(*constraints)
    h = o.maximize(objective)
    r = o.check()
    if r == sat:
        val = o.upper(h)
        print(f"[MAX] {pid}: {title} = {val}")
        if expect_max is not None and str(val) != str(expect_max):
            print(f"      !! documented maximum is {expect_max}")
            _results.append((pid, "MAX-DRIFT", "MAX"))
        return val
    print(f"[TIMEOUT] {pid}: {title}")
    _results.append((pid, "TIMEOUT", "MAX"))
    return None


def floor_div(q, n, d):
    """q = floor(n / d) for d > 0, as linear constraints when d is a constant."""
    return [q * d <= n, n < (q + 1) * d]


def ceil_div(q, n, d):
    """q = ceil(n / d) for d > 0."""
    return [q * d >= n, n > (q - 1) * d]


def half_up(q, n, d):
    """Aave V3 percentMul: q = floor((n + d/2) / d)."""
    return floor_div(q, n + d // 2, d)


def computed(pid, title, rows, expect="COMPUTED"):
    """Exact integer evaluation of stated figures (worked examples).
    rows: (label, stated, exact). All equal -> COMPUTED; any difference -> MISMATCH."""
    bad = [r for r in rows if r[1] != r[2]]
    res = "MISMATCH" if bad else "COMPUTED"
    print(f"[{res}] {pid}: {title}")
    for lab, st, ex in rows:
        print(f"      {'ok ' if st == ex else 'BAD'} {lab}: stated {st}, exact {ex}")
    if res != expect:
        print(f"      !! documented result is {expect}")
    _results.append((pid, res, expect))
    return res


def mul_div_ceil(a, b, d):
    """Python-int ceil(a * b / d) for worked examples."""
    return -(-(a * b) // d)


def done():
    bad = [r for r in _results if r[1] != r[2]]
    print(f"-- {len(_results)} checks, {len(bad)} differ from documented result")
    sys.exit(1 if bad else 0)
