# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 Avana Labs
# Contains a port of the Uniswap v3-core TickMath algorithm and constants (commit 5ea68a7), (c) 2021 Uniswap Labs,
# under GPL-2.0-or-later; see THIRD_PARTY_LICENSES.md.
"""Shared helpers for the units-oracle Z3 models (vault-token units, LPOracle and
DebtOracle math, backing ledger and exposure counters).

Run any sibling script directly (`../../.venv/bin/python <file>.py`) or all of them
with `../../run_all.sh`. This module only defines helpers and reference data;
running it checks the TickMath port and exits 0.

prove(pid, desc, hyps, goal)   asserts hyps and Not(goal): unsat -> PROVED, sat -> COUNTEREXAMPLE
witness(pid, desc, cons)       searches for a state: sat -> COUNTEREXAMPLE, unsat -> PROVED
note(pid, desc, text)          exact-integer computation, reported as COMPUTED
A script exits 1 when a result differs from its `expect` value.

Upstream arithmetic modelled here:
  Uniswap v3-core TickMath (MIN/MAX_TICK, MIN/MAX_SQRT_RATIO, getSqrtRatioAtTick),
  Tick.tickSpacingToMaxLiquidityPerTick, SqrtPriceMath.getAmount0Delta/getAmount1Delta
  (roundUp = false on burn), v3-periphery LiquidityAmounts (rounds down).
  Aave V4 @ a3ef63ea6415d25237a9775bf66e76e9993561c2: Hub addCap is uint40 whole
  tokens (MAX_ALLOWED_SPOKE_CAP = 2^40-1 means "no cap"), Hub shares are uint120,
  underlying decimals in [6, 18], SpokeUtils.toValue = amount * price * 10^(18-dec),
  KeyValueList VALUE_BITS = 224, AaveOracle requires price > 0.
"""
import sys
from z3 import Solver, Not, sat, unsat, Int, Real

TIMEOUT_MS = 120_000
Q96 = 2 ** 96
U128 = 2 ** 128 - 1
U120 = 2 ** 120 - 1
U256 = 2 ** 256 - 1
HUB_CAP_MAX = 2 ** 40 - 1          # Aave V4 MAX_ALLOWED_SPOKE_CAP = "unlimited"
PRICE_ONE = 10 ** 8                # $1.00000000 in Chainlink / Aave 8-decimal format

MIN_TICK = -887272
MAX_TICK = 887272
MIN_SQRT_RATIO = 4295128739
MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342

# Launch stablecoins. token0/token1 follow Uniswap's address order (token0 < token1):
# GHO 0x40D1.. < DAI 0x6B17.. < USDC 0xA0b8.. < USDT 0xdAC1.. < USDS 0xdC03..
TOKENS = {'USDC': 6, 'USDT': 6, 'DAI': 18, 'USDS': 18, 'GHO': 18}
ADDR = {
    'GHO': 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f,
    'DAI': 0x6B175474E89094C44Da98b954EedeAC495271d0F,
    'USDC': 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
    'USDT': 0xdAC17F958D2ee523a2206206994597C13D831ec7,
    'USDS': 0xdC035D45d973E3EC169d2276DDab16f1e407384F,
}
LAUNCH_PAIRS = [('USDC', 'USDT'), ('DAI', 'USDC'), ('GHO', 'USDC'),
                ('DAI', 'USDS'), ('GHO', 'DAI'), ('USDC', 'GHO')]
TICK_SPACINGS = [1, 10, 60, 200]   # fee tiers 0.01%, 0.05%, 0.3%, 1%
MAX_ROUTE_ANSWER = 10 ** 12        # $10,000 per whole token, 8 decimals (Q-191, Q-210)
STABLE_CEILING = PRICE_ONE         # stableCeilingUsd = $1.00000000 (SPEC-ORC-004)
MAX_FULL_RANGE_EPSILON_INV = 10 ** 12   # listing requires eps < 1e-12 (REQ-ORACLE-050)


def pool_order(a, b):
    """Return (token0, token1) as Uniswap orders them (by address)."""
    return (a, b) if ADDR[a] < ADDR[b] else (b, a)


_TM = [0xfff97272373d413259a46990580e213a, 0xfff2e50f5f656932ef12357cf3c7fdcc,
       0xffe5caca7e10e4e61c3624eaa0941cd0, 0xffcb9843d60f6159c9db58835c926644,
       0xff973b41fa98c081472e6896dfb254c0, 0xff2ea16466c96a3843ec78b326b52861,
       0xfe5dee046a99a2a811c461f1969c3053, 0xfcbe86c7900a88aedcffc83b479aa3a4,
       0xf987a7253ac413176f2b074cf7815e54, 0xf3392b0822b70005940c7a398e4b70f3,
       0xe7159475a2c29b7443b29c7fa6e889d9, 0xd097f3bdfd2022b8845ad8f792aa5825,
       0xa9f746462d870fdf8a65dc1f90e061e5, 0x70d869a156d2a1b890bb3df62baf32f7,
       0x31be135f97d08fd981231505542fcfa6, 0x9aa508b5b7a84e1c677de54f3e99bc9,
       0x5d6af8dedb81196699c329225ee604, 0x2216e584f5fa1ea926041bedfe98,
       0x48a170391f7dc42444e8fa2]


def sqrt_ratio_at_tick(tick):
    """Exact port of TickMath.getSqrtRatioAtTick (v3-core)."""
    a = -tick if tick < 0 else tick
    assert a <= MAX_TICK
    ratio = 0xfffcb933bd6fad37aa2d162d1a594001 if a & 1 else 1 << 128
    for i, c in enumerate(_TM):
        if a & (2 << i):
            ratio = (ratio * c) >> 128
    if tick > 0:
        ratio = U256 // ratio
    return (ratio >> 32) + (0 if ratio % (1 << 32) == 0 else 1)


def usable_ticks(spacing):
    """Full-range ticks as NFPM/Tick.sol compute them (Solidity truncating division)."""
    lo = -((-MIN_TICK) // spacing) * spacing
    hi = (MAX_TICK // spacing) * spacing
    return lo, hi


def max_liquidity_per_tick(spacing):
    lo, hi = usable_ticks(spacing)
    return U128 // ((hi - lo) // spacing + 1)


def isqrt(n):
    import math
    return math.isqrt(n)


def price8(v0, v1):
    """SPEC-ORC-008: Math.sqrt(4 * v0 * v1) - 1 (round down, then one unit down)."""
    return isqrt(4 * v0 * v1) - 1


def mul_div(a, b, c, ceil=False):
    """OpenZeppelin Math.mulDiv with Floor (default) or Ceil rounding, exact integers."""
    q, r = divmod(a * b, c)
    return q + (1 if ceil and r else 0)


def tick_at_sqrt_ratio(s):
    """TickMath.getTickAtSqrtRatio: the greatest tick t with getSqrtRatioAtTick(t) <= s."""
    lo, hi = MIN_TICK, MAX_TICK
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if sqrt_ratio_at_tick(mid) <= s:
            lo = mid
        else:
            hi = mid - 1
    return lo


_results = []


def _fmt_model(m, limit=16):
    items = []
    for dcl in m.decls():
        if dcl.name().startswith('_') or dcl.arity() > 0:
            continue
        v = m[dcl]
        try:
            if hasattr(v, 'is_real') and v.is_real() and not v.is_int():
                v = v.as_decimal(12)
        except Exception:
            pass
        items.append(f"{dcl.name()}={v}")
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
    """Search for a bad state. sat => COUNTEREXAMPLE, unsat => PROVED (none exists)."""
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
    """Deterministic computation with exact integers (not a solver query)."""
    print(f"[{pid}] COMPUTED  {desc}")
    for line in text.rstrip().splitlines():
        print(f"      {line}")
    _results.append((pid, 'COMPUTED', 'COMPUTED'))


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
    # self-check of the TickMath port against the published constants
    assert sqrt_ratio_at_tick(MIN_TICK) == MIN_SQRT_RATIO
    assert sqrt_ratio_at_tick(MAX_TICK) == MAX_SQRT_RATIO
    print('units-oracle/_common.py: helper module, no properties (TickMath port self-check passed).')
