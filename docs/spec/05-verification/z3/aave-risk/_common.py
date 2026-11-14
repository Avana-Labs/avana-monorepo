# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Shared helpers for the aave-risk Z3 models.

Run any sibling script directly (../../.venv/bin/python <file>.py). This module only
defines helpers; running it prints a note and exits 0.

Result kinds: PROVED / COUNTEREXAMPLE / TIMEOUT (solver queries), COMPUTED (a deterministic
table or a worked example whose stated figures all equal the exact integer evaluation) and
MISMATCH (a stated figure differs). A script exits 1 when any result differs from `expect`.

Conventions copied from Aave V4 @ a3ef63ea6415d25237a9775bf66e76e9993561c2:
  WAD = 1e18, RAY = 1e27, BPS (PERCENTAGE_FACTOR) = 1e4,
  oracle prices have 8 decimals, "Value" units have 26 decimals (1e26 = $1),
  DUST_LIQUIDATION_THRESHOLD = 1000e26 (= $1,000),
  Hub share math uses VIRTUAL_ASSETS = VIRTUAL_SHARES = 1e6.
"""
import sys
from z3 import (Solver, Not, And, sat, unsat, Int, Real, ToReal)

WAD = 10**18
RAY = 10**27
BPS = 10**4
VIRT = 10**6
DUST_VALUE = 1000 * 10**26          # Value units (26 decimals)
TIMEOUT_MS = 120_000

_results = []


def floor_div(n, d, name):
    """Fresh Int q with q = floor(n / d) for d > 0 (n, d Int expressions)."""
    q = Int(name)
    return q, [d > 0, q * d <= n, n < q * d + d]


def ceil_div(n, d, name):
    """Fresh Int q with q = ceil(n / d) for d > 0, n >= 0."""
    q = Int(name)
    return q, [d > 0, q * d >= n, n > q * d - d]


def _fmt_model(m, limit=14):
    items = []
    for dcl in m.decls():
        if dcl.name().startswith('_'):
            continue
        items.append(f"{dcl.name()}={m[dcl]}")
    items.sort()
    if len(items) > limit:
        items = items[:limit] + ['...']
    return ', '.join(items)


def prove(pid, desc, hyps, goal, expect='PROVED', timeout=TIMEOUT_MS):
    """Assert hyps and Not(goal); unsat => PROVED, sat => COUNTEREXAMPLE."""
    s = Solver()
    s.set('timeout', timeout)
    s.add(*hyps)
    s.add(Not(goal))
    r = s.check()
    if r == unsat:
        res, extra = 'PROVED', ''
    elif r == sat:
        res, extra = 'COUNTEREXAMPLE', _fmt_model(s.model())
    else:
        res, extra = 'TIMEOUT', s.reason_unknown()
    _report(pid, desc, res, extra, expect)
    return res


def witness(pid, desc, constraints, expect='COUNTEREXAMPLE', timeout=TIMEOUT_MS):
    """Search for a state satisfying `constraints` (a vulnerability / bad state).
    sat => COUNTEREXAMPLE (state found), unsat => PROVED (no such state)."""
    s = Solver()
    s.set('timeout', timeout)
    s.add(*constraints)
    r = s.check()
    if r == sat:
        res, extra = 'COUNTEREXAMPLE', _fmt_model(s.model())
    elif r == unsat:
        res, extra = 'PROVED', 'no such state exists'
    else:
        res, extra = 'TIMEOUT', s.reason_unknown()
    _report(pid, desc, res, extra, expect)
    return res


def note(pid, desc, text):
    """Deterministic computation (not a solver query) — e.g. worked examples."""
    print(f"[{pid}] COMPUTED  {desc}")
    for line in text.rstrip().splitlines():
        print(f"      {line}")
    _results.append((pid, 'COMPUTED', 'COMPUTED'))


def computed(pid, desc, rows, expect='COMPUTED'):
    """Exact integer / rational evaluation of stated figures (worked examples).
    rows: list of (label, stated, actual). All equal => COMPUTED; any difference => MISMATCH."""
    bad = [(lab, st, ac) for lab, st, ac in rows if st != ac]
    res = 'MISMATCH' if bad else 'COMPUTED'
    flag = '' if res == expect else f'   (expected {expect})'
    print(f"[{pid}] {res}  {desc}{flag}")
    for lab, st, ac in rows:
        mark = 'ok ' if st == ac else 'BAD'
        print(f"      {mark} {lab}: stated {st}, computed {ac}")
    _results.append((pid, res, expect))
    return res


def _report(pid, desc, res, extra, expect):
    flag = '' if res == expect else f'   (expected {expect})'
    print(f"[{pid}] {res}  {desc}{flag}")
    if extra:
        print(f"      model: {extra}")
    _results.append((pid, res, expect))


def finish():
    bad = [r for r in _results if r[1] != r[2]]
    counts = {}
    for _, res, _ in _results:
        counts[res] = counts.get(res, 0) + 1
    print('-- summary: ' + ', '.join(f'{k} {v}' for k, v in sorted(counts.items())))
    if bad:
        print('-- UNEXPECTED: ' + ', '.join(f'{p}={r}' for p, r, _ in bad))
        sys.exit(1)


if __name__ == '__main__':
    print('aave-risk/_common.py: helper module, no properties.')
