# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Shared helpers for the SymPy algebra checks (prefix SYM).

Each check compares a formula from the decisions with the intended rule, exactly and
before any rounding, and prints

  [CONSISTENT]   residual simplifies to 0 (or a certificate proves the inequality)
  [INCONSISTENT] residual is not 0; the residual expression (and a numeric witness) is printed

`expect` is the result recorded in README.md. A script exits 1 only if a result
differs from what README documents, so run_all.sh flags drift, not known findings.
Rounding is out of scope here; README lists the Z3 (MATH-...) checks that cover it.
"""
import sys
import sympy as sp

_results = []


def _simp(e):
    e = sp.sympify(e)
    for f in (lambda x: x, sp.expand, sp.simplify, sp.factor,
              lambda x: sp.simplify(sp.powsimp(sp.expand_power_base(x, force=True), force=True)),
              lambda x: sp.nsimplify(sp.simplify(x))):
        try:
            r = f(e)
        except Exception:
            continue
        if r == 0:
            return sp.Integer(0)
    return sp.simplify(e)


def _report(pid, title, ok, residual, expect, witness=None, note=None):
    res = "CONSISTENT" if ok else "INCONSISTENT"
    print(f"[{res}] {pid}: {title}")
    print(f"      residual: {residual}")
    if witness is not None:
        print(f"      witness: {witness}")
    if note:
        print(f"      {note}")
    if res != expect:
        print(f"      !! README documents {expect}")
    _results.append((pid, res, expect))
    return res


def eq(pid, title, lhs, rhs, expect="CONSISTENT", witness_subs=None, note=None):
    """Checks lhs == rhs identically. Residual = lhs - rhs."""
    r = _simp(sp.sympify(lhs) - sp.sympify(rhs))
    w = None
    if r != 0 and witness_subs is not None:
        w = f"{witness_subs} -> residual = {sp.N(r.subs(witness_subs), 8)}"
    return _report(pid, title, r == 0, r, expect, w, note)


def nonneg(pid, title, expr, certificate, expect="CONSISTENT", note=None):
    """Proves expr >= 0 by checking expr == certificate, where certificate is
    manifestly non-negative under the symbols' declared assumptions
    (sympy must confirm certificate.is_nonnegative)."""
    r = _simp(sp.sympify(expr) - sp.sympify(certificate))
    cert_ok = sp.sympify(certificate).is_nonnegative is True
    ok = (r == 0) and cert_ok
    resid = r if r != 0 else (sp.Integer(0) if cert_ok else f"certificate sign unknown: {certificate}")
    return _report(pid, title, ok, resid, expect, None, note)


def fails(pid, title, residual_expr, witness_subs, expect="INCONSISTENT", note=None):
    """Reports a rule that does NOT hold: residual_expr is the (signed) gap that should be
    >= 0 (or == 0) for the rule to hold; witness_subs is a concrete assignment where it fails."""
    r = _simp(residual_expr)
    val = sp.N(r.subs(witness_subs), 10)
    ok = bool(val >= 0)
    return _report(pid, title, ok, sp.factor(r), expect,
                   f"{witness_subs} -> {val}", note)


def numeric(pid, title, stated, exact, tol, expect="CONSISTENT", note=None):
    """Illustrative figure check: |stated - exact| <= tol (stated figures are rounded)."""
    exact = sp.nsimplify(exact)
    diff = sp.nsimplify(stated) - exact
    ok = abs(diff) <= sp.nsimplify(tol)
    return _report(pid, title, ok, f"stated {stated} - exact {exact} (= {sp.N(exact, 10)}) = {sp.N(diff, 6)}; tolerance {tol}",
                   expect, None, note)


def info(pid, title, text):
    print(f"[DERIVED] {pid}: {title}")
    for line in str(text).splitlines():
        print(f"      {line}")


def done():
    drift = [(p, r, e) for (p, r, e) in _results if r != e]
    n_c = sum(1 for _, r, _ in _results if r == "CONSISTENT")
    n_i = sum(1 for _, r, _ in _results if r == "INCONSISTENT")
    print(f"-- {len(_results)} checks: {n_c} CONSISTENT, {n_i} INCONSISTENT; {len(drift)} differ from README")
    sys.exit(1 if drift else 0)
