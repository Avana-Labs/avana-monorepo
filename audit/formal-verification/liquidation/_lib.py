"""Shared helpers for the liquidation-area checks (FV-LIQ-*).

Exact integer arithmetic (the reference semantics of every formula) and a small
Z3 harness. A check is a named obligation; `prove` asks Z3 for a model of the
negated claim: `unsat` means the claim holds for every input satisfying the
assumptions, `sat` returns the counterexample. `expect_violation` is used for
properties the spec states but that do not hold: the check passes only when Z3
finds the counterexample, so a later spec fix turns it into a failing check that
must be flipped to `prove`.
"""
from __future__ import annotations

import sys
import time

import z3

RAY = 10**27
WAD = 10**18
BPS = 10**4
VIRTUAL = 10**6

RESULTS: list[tuple[str, str, str]] = []


# ---------------------------------------------------------------- exact integer semantics
def mul_div_down(x: int, y: int, d: int) -> int:
    assert d > 0 and x >= 0 and y >= 0
    return (x * y) // d


def mul_div_up(x: int, y: int, d: int) -> int:
    assert d > 0 and x >= 0 and y >= 0
    return -((-(x * y)) // d)


def ceil_div(a: int, b: int) -> int:
    assert b > 0 and a >= 0
    return -((-a) // b)


def ray_mul_up(a: int, b: int) -> int:  # WadRayMath.rayMulUp
    return ceil_div(a * b, RAY)


def from_ray_up(a: int) -> int:  # WadRayMath.fromRayUp
    return ceil_div(a, RAY)


def round_ray_up(a: int) -> int:  # WadRayMath.roundRayUp: next multiple of RAY
    return ceil_div(a, RAY) * RAY


def percent_mul_half_up(value: int, bps: int) -> int:  # Aave v3 PercentageMath.percentMul (GHO FlashMinter fee)
    return (value * bps + BPS // 2) // BPS


def sat_sub(a: int, b: int) -> int:
    return a - b if a > b else 0


# ---------------------------------------------------------------- Z3 helpers
def z_floor_div(s: z3.Solver, num, den, name: str):
    """Fresh integer q with q = floor(num/den); den must be constrained > 0 by the caller."""
    q = z3.Int(name)
    s.add(q * den <= num, num < (q + 1) * den)
    return q


def z_ceil_div(s: z3.Solver, num, den, name: str):
    q = z3.Int(name)
    s.add(q * den >= num, num > (q - 1) * den)
    return q


def z_min(a, b):
    return z3.If(a <= b, a, b)


def z_max(a, b):
    return z3.If(a >= b, a, b)


def _solve(s: z3.Solver, timeout_ms: int):
    s.set("timeout", timeout_ms)
    return s.check()


def _mk(real: bool) -> z3.Solver:
    return z3.SolverFor("QF_NRA") if real else z3.Solver()


def prove(check_id: str, title: str, assumptions, claim, timeout_ms: int = 120_000, solver=None,
          real: bool = False) -> bool:
    """Proves `assumptions -> claim` for all values. Records Verified / Violated / Timeout.
    real=True decides the claim over the reals with nlsat (complete for nonlinear real
    arithmetic); every rounding is then kept as its two defining inequalities, which is a
    sound over-approximation of the integer semantics."""
    s = solver or _mk(real)
    s.add(*assumptions)
    # Witness (rule_sanity): the premise must be reachable, otherwise the proof is vacuous.
    w = _mk(real)
    w.add(*assumptions)
    w.add(claim)
    if _solve(w, timeout_ms) != z3.sat:
        RESULTS.append((check_id, "Violated", f"{title}: vacuous premise (no witness)"))
        print(f"[FAIL] {check_id} {title}: vacuous premise, no witness satisfies the assumptions")
        return False
    s.add(z3.Not(claim))
    t0 = time.time()
    r = _solve(s, timeout_ms)
    dt = time.time() - t0
    if r == z3.unsat:
        RESULTS.append((check_id, "Verified", f"{title} ({dt:.1f}s)"))
        print(f"[PASS] {check_id} {title} ({dt:.1f}s)")
        return True
    if r == z3.sat:
        m = s.model()
        RESULTS.append((check_id, "Violated", f"{title}: {m}"))
        print(f"[FAIL] {check_id} {title}\n       counterexample: {m}")
        return False
    RESULTS.append((check_id, "Timeout", title))
    print(f"[FAIL] {check_id} {title}: solver returned {r} (timeouts never count as verified)")
    return False


def expect_violation(check_id: str, title: str, assumptions, claim, timeout_ms: int = 120_000, show=None,
                     label: str = "finding", real: bool = False) -> bool:
    """The spec states `claim`; the check passes when Z3 exhibits a counterexample."""
    s = _mk(real)
    s.add(*assumptions)
    s.add(z3.Not(claim))
    r = _solve(s, timeout_ms)
    if r == z3.sat:
        m = s.model()
        shown = {str(v): m.eval(v, model_completion=True) for v in (show or [])}
        status = {"finding": "Violated (finding)", "accepted": "Accepted violation"}.get(label, "Mutant caught")
        RESULTS.append((check_id, status, f"{title}: {shown or m}"))
        print(f"[PASS] {check_id} {title}: counterexample found ({label})\n       {shown or m}")
        return True
    RESULTS.append((check_id, "Unexpectedly holds", title))
    print(f"[FAIL] {check_id} {title}: expected a counterexample, solver returned {r}")
    return False


def replay(check_id: str, title: str, violated: bool, detail: str = "") -> bool:
    """Exact-integer replay of a finding's counterexample: passes when the violation reproduces."""
    RESULTS.append((check_id, "Violated (finding)" if violated else "Unexpectedly holds", f"{title} {detail}".strip()))
    print(f"[{'PASS' if violated else 'FAIL'}] {check_id} {title}: {'reproduced' if violated else 'NOT reproduced'} {detail}".rstrip())
    return violated


def check(check_id: str, title: str, ok: bool, detail: str = "") -> bool:
    """Concrete (exact-integer) check, used for worked examples and counterexample replay."""
    RESULTS.append((check_id, "Verified" if ok else "Violated", f"{title} {detail}".strip()))
    print(f"[{'PASS' if ok else 'FAIL'}] {check_id} {title} {detail}".rstrip())
    return ok


def finish() -> None:
    failed = [r for r in RESULTS if r[1] in ("Violated", "Timeout", "Unexpectedly holds")]
    print(f"--- {len(RESULTS)} obligations, {len(failed)} failed")
    sys.exit(1 if failed else 0)
