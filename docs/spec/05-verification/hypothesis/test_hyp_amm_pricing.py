# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""HYP-AMM: fair-composition LP pricing under manipulation, for three AMM types.

Uses the integer AMM ports of ../z3/amm-pricing/_common.py (concentrated-liquidity LiquidityAmounts,
a constant-product pair with reserves, balances, sync, skim and kLast, an NG-style StableSwap pool)
and a 50-digit weighted-pool model. The Z3 proofs and the attack numbers are in
../z3/amm-pricing/README.md; these tests search random states and transaction sequences for a
violation of the same properties. Tests named `..._deliberate_...` assert that a known-unsafe
quote IS manipulable.

Each test keeps its spec citation ID HYP-AMM-01 … 11 and carries the listing-method IDs
HYP-AMM-<P>-PRICE-NN or HYP-AMM-<P>-MANIP-NN of the AMM protocols it covers; the concentrated-liquidity
tests carry a V3 and a SLIP tag (same tick and amount math).
"""
import copy
import importlib.util
import math
import os
from fractions import Fraction as F

import mpmath
from hypothesis import assume, given, strategies as st

from model.hsettings import cfg

_P = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'z3', 'amm-pricing', '_common.py')
_spec = importlib.util.spec_from_file_location('amm_common', _P)
amm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(amm)

SPACINGS = amm.SPACINGS
Q96 = amm.Q96


def max_liq(spacing):
    lo, hi = -((-amm.MIN_TICK) // spacing) * spacing, (amm.MAX_TICK // spacing) * spacing
    return amm.U128 // ((hi - lo) // spacing + 1)


@st.composite
def cl_case(draw):
    s = draw(st.sampled_from(SPACINGS))
    lo, hi = -((-amm.MIN_TICK) // s), amm.MAX_TICK // s
    kl = draw(st.integers(lo, hi - 1))
    ku = draw(st.integers(kl + 1, min(hi, kl + max(1, 400_000 // s))))
    d0, d1 = draw(st.sampled_from([6, 8, 18])), draw(st.sampled_from([6, 8, 18]))
    p0, p1 = draw(st.integers(10 ** 6, 10 ** 12)), draw(st.integers(10 ** 6, 10 ** 12))   # 8-decimal USD
    L = draw(st.integers(1, max_liq(s)))
    spot_tick = draw(st.integers(amm.MIN_TICK, amm.MAX_TICK))
    return s, kl * s, ku * s, d0, d1, p0, p1, L, spot_tick


def oracle_sqrt(p0, p1, d0, d1):
    """sqrtPriceX96 of the raw price (p0 / 10^d0) / (p1 / 10^d1), floored."""
    return amm.sqrt_price_x96(p0 * 10 ** d1, p1 * 10 ** d0)


def cl_quote(L, tl, tu, p0, p1, d0, d1):
    so = oracle_sqrt(p0, p1, d0, d1)
    so = min(max(so, amm.MIN_SQRT_RATIO), amm.MAX_SQRT_RATIO - 1)
    sa, sb = amm.sqrt_ratio_at_tick(tl), amm.sqrt_ratio_at_tick(tu)
    a0, a1 = amm.amounts_for_liquidity(so, sa, sb, L)
    return amm.value8(a0, a1, p0, p1, d0, d1), so, sa, sb, a0, a1


# --------------------------------------------------------------------------- A: concentrated liquidity
# HYP-AMM-01 verifies: REQ-AMM-CORE-008, SPEC-AMM-CORE-001, REQ-AMM-V3-005, SPEC-AMM-V3-001, REQ-AMM-SLIP-012, SPEC-AMM-V4-001, REQ-VAULT-149, SPEC-ORC-007
# HYP-AMM-V3-MANIP-01 verifies: SPEC-AMM-CORE-001, SPEC-AMM-V3-001, REQ-AMM-V3-005, INV-078
# HYP-AMM-SLIP-MANIP-01 verifies: SPEC-AMM-CORE-001, REQ-AMM-SLIP-012, INV-078
# The fair quote lower-bounds a spot-composition quote at every spot price (moving slot0 cannot
# lower it, and a quote that read slot0 could only be pushed up).
@cfg(400)
@given(c=cl_case())
def test_hyp_amm01_cl_spot_composition_never_below_fair(c):
    s, tl, tu, d0, d1, p0, p1, L, spot_tick = c
    v, so, sa, sb, _, _ = cl_quote(L, tl, tu, p0, p1, d0, d1)
    s0, s1 = amm.amounts_for_liquidity(amm.sqrt_ratio_at_tick(spot_tick), sa, sb, L)
    v_spot = amm.value8(s0, s1, p0, p1, d0, d1)
    # integer floors on two legs: allow 2 units of 8-decimal USD plus one raw unit of each token's value
    slack = 2 + p0 // 10 ** d0 + p1 // 10 ** d1 + 1
    assert v_spot + slack >= v


# HYP-AMM-02 verifies: SPEC-AMM-V3-001, REQ-AMM-SLIP-012
# HYP-AMM-V3-PRICE-01 verifies: SPEC-AMM-V3-001
# HYP-AMM-SLIP-PRICE-01 verifies: REQ-AMM-SLIP-012
# Monotone non-decreasing in L (integer port).
@cfg(300)
@given(c=cl_case(), extra=st.integers(0, 2 ** 100))
def test_hyp_amm02_cl_monotone_in_liquidity(c, extra):
    s, tl, tu, d0, d1, p0, p1, L, _ = c
    L2 = min(L + extra, max_liq(s))
    assert cl_quote(L, tl, tu, p0, p1, d0, d1)[0] <= cl_quote(L2, tl, tu, p0, p1, d0, d1)[0]


# HYP-AMM-03 verifies: SPEC-AMM-CORE-001, SPEC-AMM-V3-001, REQ-AMM-SLIP-012, SPEC-ORC-006, SPEC-ORC-008
# HYP-AMM-V3-PRICE-02 verifies: SPEC-AMM-CORE-001, SPEC-AMM-V3-001, INV-078
# HYP-AMM-SLIP-PRICE-02 verifies: REQ-AMM-SLIP-012, INV-078
# Floored amounts and value never exceed exact rational math at the same sqrt price.
@cfg(300)
@given(c=cl_case())
def test_hyp_amm03_cl_rounding_never_overvalues(c):
    s, tl, tu, d0, d1, p0, p1, L, _ = c
    v, so, sa, sb, a0, a1 = cl_quote(L, tl, tu, p0, p1, d0, d1)
    if so <= sa:
        e0, e1 = F(L * Q96 * (sb - sa), sa * sb), F(0)
    elif so < sb:
        e0, e1 = F(L * Q96 * (sb - so), so * sb), F(L * (so - sa), Q96)
    else:
        e0, e1 = F(0), F(L * (sb - sa), Q96)
    assert a0 <= e0 and a1 <= e1
    assert v <= e0 * p0 / 10 ** d0 + e1 * p1 / 10 ** d1


# HYP-AMM-04 verifies: SPEC-AMM-CORE-001, REQ-AMM-V3-005, SPEC-AMM-V3-001, REQ-AMM-SLIP-012, SPEC-ORC-006
# HYP-AMM-V3-PRICE-03 verifies: SPEC-AMM-V3-001, REQ-AMM-V3-005, INV-078, AMMN-RT-02
# HYP-AMM-SLIP-PRICE-03 verifies: REQ-AMM-SLIP-012, INV-078, AMMN-RT-02
# Oracle price outside the range -> all token0 (below) or all token1 (above).
@cfg(200)
@given(c=cl_case())
def test_hyp_amm04_cl_out_of_range_single_token(c):
    s, tl, tu, d0, d1, p0, p1, L, _ = c
    v, so, sa, sb, a0, a1 = cl_quote(L, tl, tu, p0, p1, d0, d1)
    if so <= sa:
        assert a1 == 0
    if so >= sb:
        assert a0 == 0


# HYP-AMM-05 verifies: REQ-AMM-CORE-006, REQ-AMM-SLIP-008, SPEC-AMM-V4-001, SPEC-BACK-001, REQ-ORACLE-105
# HYP-AMM-V3-PRICE-04 verifies: REQ-AMM-V3-008, REQ-AMM-CORE-006, INV-005, AMMN-RT-01
# HYP-AMM-SLIP-PRICE-04 verifies: REQ-AMM-SLIP-008, REQ-AMM-SLIP-017, INV-005, AMMN-RT-01
# The int24 test `tick % spacing == 0` is the alignment test for every spacing; uint24 casting is not.
@cfg(500)
@given(s=st.sampled_from(SPACINGS), t=st.integers(amm.MIN_TICK, amm.MAX_TICK))
def test_hyp_amm05_tick_spacing_alignment(s, t):
    assert amm.aligned_solidity(t, s) == (t % s == 0)            # Python % is floor-mod: == 0 iff s | t
    if s in (10, 50, 100, 200, 2000):
        bad = -(2 ** 24 % s)           # misaligned negative tick whose uint24 cast is a multiple of s
        assert ((bad + 2 ** 24) % s == 0) and not amm.aligned_solidity(bad, s)


# --------------------------------------------------------------------------- B: constant product
P0, P1 = 10 ** 12, 2000                 # USD (x1e18) per raw unit: USDC $1 (6 dec), WETH $2,000 (18 dec)


def v2_pool(fee_on):
    pr = amm.V2Pair(fee_on)
    pr.transfer_in(10 ** 12, 500 * 10 ** 18)
    pr.mint()
    return pr


def fair_total(pr):
    return amm.v2_fair_value(pr.r0, pr.r1, P0, P1)


op = st.one_of(
    st.tuples(st.just('swap0'), st.integers(10 ** 6, 10 ** 14)),
    st.tuples(st.just('swap1'), st.integers(10 ** 15, 10 ** 22)),
    st.tuples(st.just('donate_sync'), st.integers(0, 10 ** 11), st.integers(0, 10 ** 20)),
    st.tuples(st.just('donate_skim'), st.integers(1, 10 ** 13), st.integers(1, 10 ** 21)),
    st.tuples(st.just('mint'), st.integers(10 ** 6, 10 ** 12)),
    st.tuples(st.just('burn'), st.integers(1, 10 ** 4)),
)


# HYP-AMM-06 verifies: REQ-AMM-CORE-008, SPEC-AMM-V2-001
# HYP-AMM-V2-MANIP-01 verifies: SPEC-AMM-V2-001, INV-078, AMMN-RT-07
# In one block, any sequence of swaps, donations (sync or skim), mints and burns raises the
# fair pool value by at most the attacker's net token inflow at oracle prices, and the per-LP quote
# (supply + pending protocol-fee liquidity) never exceeds the per-LP redeemable value.
@cfg(300)
@given(fee_on=st.booleans(), ops=st.lists(op, min_size=1, max_size=12))
def test_hyp_amm06_v2_block_sequence_bounded(fee_on, ops):
    pr = v2_pool(fee_on)
    if fee_on:                      # make kLast meaningful
        pr.transfer_in(10 ** 6, 5 * 10 ** 14)
        pr.mint()
    v_start = fair_total(pr)
    inflow = 0                      # value of tokens the attacker sent in minus received, at oracle prices
    for o in ops:
        snap = copy.deepcopy(pr.__dict__)
        try:
            if o[0] == 'swap0':
                out = pr.amount_out(o[1], pr.r0, pr.r1)
                pr.swap(True, o[1])
                inflow += o[1] * P0 - out * P1
            elif o[0] == 'swap1':
                out = pr.amount_out(o[1], pr.r1, pr.r0)
                pr.swap(False, o[1])
                inflow += o[1] * P1 - out * P0
            elif o[0] == 'donate_sync':
                pr.transfer_in(o[1], o[2])
                pr.sync()
                inflow += o[1] * P0 + o[2] * P1
            elif o[0] == 'donate_skim':
                pr.transfer_in(o[1], o[2])
                assert pr.skim() == (o[1], o[2])
            elif o[0] == 'mint':
                a0 = o[1]
                a1 = -(-a0 * pr.r1 // pr.r0)
                pr.transfer_in(a0, a1)
                pr.mint()
                inflow += a0 * P0 + a1 * P1
            elif o[0] == 'burn':
                liq = min(o[1] * 10 ** 12, pr.supply - amm.MINIMUM_LIQUIDITY - 1)
                if liq > 0:
                    a0, a1 = pr.burn(liq)
                    inflow -= a0 * P0 + a1 * P1
        except AssertionError:
            pr.__dict__ = snap      # a reverted call changes nothing
            continue
        supply = pr.supply + pr.pending_fee_liquidity()
        assert F(fair_total(pr), supply) <= F(pr.r0 * P0 + pr.r1 * P1, supply)
    assert fair_total(pr) - v_start <= inflow + 2


# HYP-AMM-07 verifies: REQ-AMM-CORE-014, REQ-AMM-V2-005
# HYP-AMM-V2-MANIP-02 verifies: REQ-AMM-V2-005, REQ-AMM-CORE-014, AMMN-RT-07
# A single swap of any size raises the fair per-LP quote by < 1/sqrt(0.997) - 1 = 0.1503%.
@cfg(300)
@given(z=st.booleans(), size=st.integers(10 ** 3, 10 ** 24))
def test_hyp_amm07_v2_one_swap_bound(z, size):
    pr = v2_pool(False)
    q0 = F(fair_total(pr), pr.supply)
    try:
        pr.swap(z, size)
    except AssertionError:
        return
    # (q1/q0)^2 = k1/k0 <= 1000/997 in exact math (AMM-B2b); the floored output leaves < 1 raw unit more
    # of the output token, worth at most r_in_after / k0 of extra k ratio
    k0 = 10 ** 12 * 500 * 10 ** 18
    k_ratio = F(pr.r0 * pr.r1, k0)
    assert k_ratio <= F(1000, 997) + F(max(pr.r0, pr.r1), k0)
    assert F(fair_total(pr), pr.supply) / q0 <= F(10015035, 10 ** 7)


# HYP-AMM-08 verifies: REQ-AMM-V2-002
# HYP-AMM-V2-PRICE-01 verifies: REQ-AMM-V2-002, AMMN-RT-07
# The fee-on-mint overstatement of a totalSupply-based quote is <= (sqrt(k / kLast) - 1) / 6.
@cfg(200)
@given(swaps=st.lists(st.integers(10 ** 9, 10 ** 13), min_size=1, max_size=15))
def test_hyp_amm08_v2_fee_on_mint_bound(swaps):
    pr = v2_pool(True)
    pr.transfer_in(10 ** 6, 5 * 10 ** 14)
    pr.mint()
    for x in swaps:
        out = pr.swap(True, x)
        pr.swap(False, out)
    pend = pr.pending_fee_liquidity()
    over = F(pr.supply + pend, pr.supply) - 1
    assert over <= (F(math.isqrt(pr.r0 * pr.r1)) / math.isqrt(pr.k_last) - 1) / 6 + F(1, pr.supply)


# HYP-AMM-09 verifies: REQ-AMM-V2-001
# HYP-AMM-V2-MANIP-03 verifies: REQ-AMM-V2-001, AMMN-RT-07
# Deliberate: naive spot reserves x price, or reserves read from balanceOf, are manipulable.
@cfg(150)
@given(frac=st.integers(50, 2000))
def test_hyp_amm09_deliberate_naive_quotes_are_inflatable(frac):
    pr = v2_pool(False)
    naive0, fair0 = pr.r0 * P0 + pr.r1 * P1, fair_total(pr)
    size = pr.r0 * frac // 100                                # swap 0.5x .. 20x the token0 reserve
    pr.swap(True, size)
    naive1, fair1 = pr.r0 * P0 + pr.r1 * P1, fair_total(pr)
    assert F(naive1, naive0) > F(108, 100)                    # +8.3% at 0.5x, about +1,000% at 20x
    assert F(fair1, fair0) < F(10016, 10000)                  # fair moves < 0.16%
    pr2 = v2_pool(False)
    pr2.transfer_in(pr2.r0, pr2.r1)                           # donate 100% without sync
    assert F(amm.v2_fair_value(pr2.b0, pr2.b1, P0, P1), fair_total(pr2)) >= 2   # balanceOf quote doubles
    pr2.skim()                                                # ...and the attacker takes it all back
    assert (pr2.b0, pr2.b1) == (pr2.r0, pr2.r1)


# --------------------------------------------------------------------------- C: StableSwap and weighted
E18 = 10 ** 18


@st.composite
def ss_case(draw):
    n = draw(st.sampled_from([2, 3]))
    bal = [draw(st.integers(10 ** 4, 10 ** 8)) * E18 for _ in range(n)]
    amp = draw(st.sampled_from([10, 100, 200, 2000])) * amm.A_PREC
    prices = [F(draw(st.integers(90, 100)), 100) for _ in range(n)]
    ops = draw(st.lists(st.tuples(st.sampled_from(['swap', 'donate']), st.integers(0, n - 1),
                                  st.integers(0, n - 1), st.integers(1, 10 ** 9)), min_size=1, max_size=6))
    return bal, amp, prices, ops


# HYP-AMM-10 verifies: REQ-AMM-CORE-008, SPEC-AMM-CORE-001, REQ-AMM-CURVE-001, SPEC-AMM-CURVE-001
# HYP-AMM-CURVE-MANIP-01 verifies: REQ-AMM-CURVE-001, SPEC-AMM-CURVE-001, INV-078, AMMN-RT-07
# Min(p) * D never exceeds the redeemable value after any swaps or donations, and a swap
# never lowers D (fees stay in the pool; the virtual price only moves up).
@cfg(200)
@given(c=ss_case())
def test_hyp_amm10_stableswap_lower_bound_quote(c):
    bal, amp, prices, ops = c
    try:
        pool = amm.StableSwap(bal, amp=amp)
    except AssertionError:
        assume(False)               # get_D does not converge for this deposit: the pool reverts it
    pmin = min(prices)
    for kind, i, j, amt in ops:
        dx = amt * E18 // 100
        if kind == 'donate':
            d = [0] * len(bal)
            d[i] = dx
            pool.donate(d)
        else:
            if i == j:
                continue
            try:
                D_before = pool.D()
            except AssertionError:
                return
            try:
                out = pool.exchange(i, j, dx)
            except (AssertionError, ZeroDivisionError):
                continue
            try:
                D_after = pool.D()
            except AssertionError:
                return              # get_D does not converge at this imbalance: the pool and the quote revert
            assert D_after + 2 >= D_before
        try:
            D = pool.D()
        except AssertionError:
            return
        assert pmin * D <= sum(x * p for x, p in zip(pool.x, prices)) + 1


W_SETS = [(F(1, 2), F(1, 2)), (F(4, 5), F(1, 5)), (F(1, 5), F(4, 5)), (F(1, 3), F(1, 3), F(1, 3))]


# HYP-AMM-11 verifies: REQ-AMM-CORE-008, SPEC-AMM-CORE-001, REQ-AMM-BAL-005, SPEC-AMM-BAL-001
# HYP-AMM-BAL-MANIP-01 verifies: REQ-AMM-BAL-005, SPEC-AMM-BAL-001, INV-078, AMMN-RT-07
# Weighted pool. Fair V = k prod (p_i / w_i)^w_i stays <= sum b_i p_i after any swaps
# (fee kept in the pool) and donations, and one swap into token i grows k by <= (1 - fee)^-w_i.
@cfg(200)
@given(ws=st.sampled_from(W_SETS), seed=st.lists(st.integers(1, 10 ** 6), min_size=3, max_size=3),
       px=st.lists(st.integers(1, 10 ** 4), min_size=3, max_size=3),
       ops=st.lists(st.tuples(st.sampled_from(['swap', 'donate']), st.integers(0, 2), st.integers(0, 2),
                              st.integers(1, 10 ** 9)), min_size=1, max_size=6))
def test_hyp_amm11_weighted_fair_value(ws, seed, px, ops):
    mpmath.mp.dps = 50
    n = len(ws)
    w = [mpmath.mpf(x.numerator) / x.denominator for x in ws]
    bal = [mpmath.mpf(seed[k]) * 1000 for k in range(n)]
    p = [mpmath.mpf(px[k]) / 100 for k in range(n)]
    fee = mpmath.mpf(3) / 1000

    def k_of(b):
        r = mpmath.mpf(1)
        for bi, wi in zip(b, w):
            r *= bi ** wi
        return r

    def fair(b):
        r = k_of(b)
        for pi, wi in zip(p, w):
            r *= (pi / wi) ** wi
        return r

    for kind, i, j, amt in ops:
        i, j = i % n, j % n
        dx = mpmath.mpf(amt) / 100
        if kind == 'donate':
            bal[i] += dx
        elif i != j:
            k0 = k_of(bal)
            out = bal[j] * (1 - (bal[i] / (bal[i] + dx * (1 - fee))) ** (w[i] / w[j]))
            bal[i] += dx
            bal[j] -= out
            assert k_of(bal) <= k0 * (1 - fee) ** (-w[i]) * (1 + mpmath.mpf(10) ** -40)
        assert fair(bal) <= sum(b * q for b, q in zip(bal, p)) * (1 + mpmath.mpf(10) ** -40)
