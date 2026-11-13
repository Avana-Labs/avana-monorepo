# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 Avana Labs
# Contains a port of the Uniswap v3-core TickMath algorithm and constants (commit 5ea68a7) and the v3-periphery
# LiquidityAmounts formula (commit 24ccf01), (c) 2021 Uniswap Labs, under GPL-2.0-or-later; see
# THIRD_PARTY_LICENSES.md.
"""Exact reference for Avana's differential tests (TEST-037 and the math libraries).

Called by Foundry through FFI from contracts/test/differential/, as
    contracts/.venv/bin/python -I avana_reference.py <function> <arg> [<arg> ...]
with every argument a decimal or 0x-hex unsigned integer. It prints the ABI encoding of the result (each value a
uint256 word) as 0x-hex on one line, which `vm.ffi` returns as bytes.

Arithmetic is exact: Python integers and fractions.Fraction, so every floor and ceiling is the true one and a
difference from the Solidity result is a bug in the contract, never in the reference.

Two groups of formulas are below. The settlement formulas of 2.11 (`SPEC-LIQ-001`…`022`) and 2.13 (`SPEC-SET-001`)
back SettlementMath. Each is written from the spec text, not from the Solidity: maxima and minima are taken over
Python integers, so no saturating step of the contract is copied. A function whose Solidity counterpart reverts
returns a status word first (0 = success, 1 and 2 = the reverts listed in its docstring) followed by its values. The
LPPriceMath formulas of 2.10 (SPEC-ORC-001 to SPEC-ORC-023 except the concentrated-liquidity and state-machine ones)
follow; the formulas of MATH-UO-06, MATH-UO-07 and MATH-UO-17 (concentrated-liquidity composition) join this file with
the CL pricing library.

The file imports nothing from spec/, so the contracts workspace stays self-contained.
"""
from __future__ import annotations

import sys
from fractions import Fraction
from math import isqrt

UINT256_MAX = (1 << 256) - 1


def _word(x: int) -> str:
    if not 0 <= x <= UINT256_MAX:
        raise ValueError(f"result out of uint256 range: {x}")
    return f"{x:064x}"


def _floor(q: Fraction) -> int:
    return q.numerator // q.denominator


def _ceil(q: Fraction) -> int:
    return -((-q.numerator) // q.denominator)


def mul_div(a: int, b: int, d: int, rounding: int) -> list[int]:
    """floor(a·b/d) for rounding 0, ceil(a·b/d) for rounding 1 (OpenZeppelin Math.Rounding Floor / Ceil)."""
    q = Fraction(a * b, d)
    return [_floor(q) if rounding == 0 else _ceil(q)]


BPS = 10_000
MAX_LEG_SLIPPAGE_BPS = 9_999
PENDING_SLIPPAGE_CAP_BPS = 30


MAX_DECIMALS = 36


def _value(amount: int, price: int, from_dec: int, to_dec: int, quote: int, up: bool) -> int:
    """SPEC-LIQ-004: valid only for decimals <= 36 and positive prices (the contract reverts otherwise; the differential
    suite checks those reverts directly, so the reference refuses such inputs)."""
    if from_dec > MAX_DECIMALS or to_dec > MAX_DECIMALS or price == 0 or quote == 0:
        raise ValueError("invalid valuation input: decimals above 36 or a zero price")
    q = Fraction(amount * price * 10**to_dec, 10**from_dec * quote)
    return _ceil(q) if up else _floor(q)


def _sub_floor(a: int, b: int, c: int) -> int:
    return max(0, a - b - c)


def net_bonus(b: int, lf: int) -> list[int]:
    """SPEC-LIQ-001: bNet = 1e4 + floor((b - 1e4)(1e4 - lf)/1e4); 1e4 when b <= 1e4 or lf >= 1e4."""
    if b <= BPS or lf >= BPS:
        return [BPS]
    return [BPS + _floor(Fraction((b - BPS) * (BPS - lf), BPS))]


def effective_slippage(bnet: int, allowance: int) -> list[int]:
    """SPEC-LIQ-003: min(allowance, floor(1e4 (bNet - 1e4) / bNet)) if bNet > 1e4, else 0 (no cost term, SPEC-LIQ-002)."""
    if bnet <= BPS:
        return [0]
    return [min(allowance, _floor(Fraction(BPS * (bnet - BPS), bnet)))]


def leg_slippage(s: int, max_shortfall: int, v: int, max_shortfall_bps: int) -> list[int]:
    """SPEC-LIQ-019: min(9,999, s + min(maxShortfallBps, floor(maxShortfall * 1e4 / V))), 0 term if either is 0."""
    relax = 0 if max_shortfall == 0 or v == 0 else min(max_shortfall_bps, _floor(Fraction(max_shortfall * BPS, v)))
    return [min(MAX_LEG_SLIPPAGE_BPS, s + relax)]


def pending_slippage(allowance: int) -> list[int]:
    """SPEC-LIQ-014: s_P = min(slippageAllowanceBps, 30)."""
    return [min(allowance, PENDING_SLIPPAGE_CAP_BPS)]


def seized_value(c: int, pc: int, dv: int, dd: int, pdebt: int) -> list[int]:
    """SPEC-LIQ-004: floor(c * Pc * 10^dd / (10^dv * Pdebt))."""
    return [_value(c, pc, dv, dd, pdebt, False)]


def leg_value(a: int, p: int, d: int, dd: int, pdebt: int) -> list[int]:
    """SPEC-LIQ-018: Vleg = floor(a * p * 10^dd / (10^d * Pdebt))."""
    return [_value(a, p, d, dd, pdebt, False)]


def pending_leg_value(a: int, p: int, d: int, dp: int, pp: int) -> list[int]:
    """SPEC-LIQ-014: one term of V_P, ceil(a * p * 10^dp / (10^d * Pp))."""
    return [_value(a, p, d, dp, pp, True)]


def unit_value(p: int, d: int, dd: int, pdebt: int) -> list[int]:
    """SPEC-LIQ-005: ceil(p * 10^dd / (10^d * Pdebt)), at least 1 for a positive price."""
    return [_value(1, p, d, dd, pdebt, True)]


def recovery_floor(v: int, s: int, u: int, eps: int) -> list[int]:
    """SPEC-LIQ-005 / SPEC-LIQ-014: max(0, ceil(V (1e4 - s) / 1e4) - U - eps)."""
    return [_sub_floor(_ceil(Fraction(v * (BPS - s), BPS)), u, eps)]


def leg_min_out(vleg: int, sleg: int, uleg: int, eps: int, n: int) -> list[int]:
    """SPEC-LIQ-018: max(1, ceil(Vleg (1e4 - sLeg) / 1e4) - Uleg - floor(eps / n'))."""
    return [max(1, _ceil(Fraction(vleg * (BPS - sleg), BPS)) - uleg - eps // n)]


def recovery_with_floor(min_rec: int, r: int) -> list[int]:
    """SPEC-LIQ-008 / SPEC-LIQ-019: R_f = R + max(0, minRec - R), the recovery plus the floor part of the top-up."""
    return [r + max(0, min_rec - r)]


def rounding_gap(d: int, a: int, b: int, kf: int, r: int) -> list[int]:
    """SPEC-SET-001: g = max(0, D + A + B - Kf - R)."""
    return [max(0, d + a + b - kf - r)]


def shortfall_top_up(min_rec: int, r: int, gap: int, max_shortfall: int) -> list[int]:
    """SPEC-LIQ-019: [status, shortfall]; status 1 = RecoveryBelowFloor (minRec - R > maxShortfall), 2 =
    InsufficientProceeds (gap > maxShortfall), checked in that order."""
    if min_rec - r > max_shortfall:
        return [1, 0]
    if gap > max_shortfall:
        return [2, 0]
    return [0, max(0, min_rec - r, gap)]


def payouts(v: int, d: int, rf: int, share: int) -> list[int]:
    """SPEC-LIQ-008, -009, -022: [status, S, G, A, kr, B]; status 1 = InvalidFeeShare (share above 1e4).
    kr = min(S, G) - A and B = max(0, S - G) are taken as the spec states them, unclamped."""
    if share > BPS:
        return [1, 0, 0, 0, 0, 0]
    s = max(0, rf - d)
    g = max(0, v - d)
    a = min(_floor(Fraction(g * share, BPS)), s)
    return [0, s, g, a, min(s, g) - a, max(0, s - g)]


def keeper_payout(kf: int, rp: int, d: int, a: int, b: int) -> list[int]:
    """SPEC-LIQ-010: [status, keeperOut = (Kf + R') - (D + A + B)]; status 1 = InsufficientProceeds."""
    out = (kf + rp) - (d + a + b)
    return [1, 0] if out < 0 else [0, out]


def liquidation_settlement(v: int, d: int, kf: int, min_rec: int, r: int, share: int, max_shortfall: int) -> list[int]:
    """One routed liquidation after its last route call, with no flash term (SPEC-LIQ-002, SPEC-LIQ-007):
    R_f = max(R, minRec) (SPEC-LIQ-008), S, G, A, kr, B (SPEC-LIQ-009, SPEC-LIQ-022), the gap
    g = max(0, D + A + B - Kf - R) and shortfall = max(0, minRec - R, g) (SPEC-LIQ-019),
    keeperOut = Kf + R + shortfall - D - A - B (SPEC-LIQ-010, SPEC-LIQ-017).
    [status, shortfall, A, kr, B, keeperOut]; status 1 = RecoveryBelowFloor, 2 = InsufficientProceeds (gap),
    3 = InvalidFeeShare, 4 = InsufficientProceeds (keeperOut < 0)."""
    if share > BPS:
        return [3, 0, 0, 0, 0, 0]
    rf = max(r, min_rec)
    s = max(0, rf - d)
    g = max(0, v - d)
    a = min(_floor(Fraction(g * share, BPS)), s)
    kr = min(s, g) - a
    b = s - a - kr
    gap = max(0, d + a + b - kf - r)
    if min_rec - r > max_shortfall:
        return [1, 0, 0, 0, 0, 0]
    if gap > max_shortfall:
        return [2, 0, 0, 0, 0, 0]
    shortfall = max(0, min_rec - r, gap)
    out = kf + r + shortfall - d - a - b
    return [4, 0, 0, 0, 0, 0] if out < 0 else [0, shortfall, a, kr, b, out]


def flash_premium_within_cap(phi: int, amount: int, max_fee: int) -> list[int]:
    """SPEC-LIQ-015: 1 if phi * 1e4 <= maxFlashFeeBps * amount, else 0."""
    return [1 if phi * BPS <= max_fee * amount else 0]


def deleverage_cap(v: int, s: int, u: int, eps: int, max_fee: int) -> list[int]:
    """SPEC-LIQ-020: floor(max(0, floor(V (1e4 - s) / 1e4) - U - eps) * 1e4 / (1e4 + maxFlashFeeBps))."""
    vnet = max(0, _floor(Fraction(v * (BPS - s), BPS)) - u - eps)
    return [_floor(Fraction(vnet * BPS, BPS + max_fee))]


def deleverage_repayment(debt: int, cap: int, min_debt: int) -> list[int]:
    """SPEC-LIQ-020: [status, x]; status 1 = DeleverageTooSmall (x = 0 or x < minDebtRepaid)."""
    x = min(debt, cap)
    return [1, x] if x == 0 or x < min_debt else [0, x]


def deleverage_asset_out(r: int, x: int, phi: int) -> list[int]:
    """SPEC-LIQ-020: [status, R - x - phi]; status 1 = DeleverageShortfall."""
    return [1, 0] if r < x + phi else [0, r - x - phi]
# ---------------------------------------------------------------------------------------------------------------------
# LPPriceMath (2.10): every formula written from the spec text with exact integers and fractions. Signed answers arrive
# as their 256-bit two's complement words and are read back as signed integers. Validity bounds are the spec's
# (SPEC-ORC-001, SPEC-ORC-008, SPEC-ORC-011, REQ-ORACLE-103); saturation is written as "the exact value if it fits in
# 256 bits, else 2^256 - 1", never as a copy of the contract's steps.
# ---------------------------------------------------------------------------------------------------------------------

PRICE_UNIT = 10**8
BPS = 10**4
MAX_ROUTE_ANSWER = 10**18
ANSWER_BOUND = 2**128
MIN_TOKENS, MAX_TOKENS = 2, 8
POST_CALL_GAS = 5_000


def _signed(word: int) -> int:
    return word - (1 << 256) if word >= 1 << 255 else word


def _sat(x: int) -> int:
    return x if x <= UINT256_MAX else UINT256_MAX


def _route_value_ok(x: int) -> bool:
    return 1 <= x <= MAX_ROUTE_ANSWER


def normalize_answer(word: int, f: int) -> list[int]:
    """SPEC-ORC-001: 0 unless 0 < a < 2^128; a * 10^(8 - f) if f <= 8, else floor(a / 10^(f - 8))."""
    a = _signed(word)
    if not 0 < a < ANSWER_BOUND:
        return [0]
    return [a * 10 ** (8 - f) if f <= 8 else _floor(Fraction(a, 10 ** (f - 8)))]


def route_value2(word_a: int, f_a: int, word_b: int, f_b: int) -> list[int]:
    """SPEC-ORC-002: floor(aA * aB / 10^(fA + fB - 8)) for 0 < aA, aB < 2^128 and fA + fB >= 8; otherwise 0 (invalid)."""
    a_a, a_b = _signed(word_a), _signed(word_b)
    if not (0 < a_a < ANSWER_BOUND and 0 < a_b < ANSWER_BOUND) or f_a + f_b < 8:
        return [0]
    return [_floor(Fraction(a_a * a_b, 10 ** (f_a + f_b - 8)))]


def routes_agree(p: int, b: int, t: int) -> list[int]:
    """SPEC-ORC-003 and SPEC-ORC-020: both in [1, MAX_ROUTE_ANSWER] and |p - b| * 10^4 <= T * min(p, b)."""
    return [int(_route_value_ok(p) and _route_value_ok(b) and abs(p - b) * BPS <= t * min(p, b))]


def deviation_bps(x: int, y: int) -> list[int]:
    """REQ-ORACLE-042: floor(|x - y| * 10^4 / min(x, y)); 2^256 - 1 when min is 0 or |x - y| * 10^4 needs 257 bits."""
    lo = min(x, y)
    if lo == 0 or abs(x - y) * BPS > UINT256_MAX:
        return [UINT256_MAX]
    return [_floor(Fraction(abs(x - y) * BPS, lo))]


def valuation_price(q: int, stable: int) -> list[int]:
    """SPEC-ORC-004: min(q, stableCeilingUsd) for a USD-pegged stable."""
    return [min(q, PRICE_UNIT) if stable else q]


def lp_price(n_a: int, n_v: int, n_d: int, *rest: int) -> list[int]:
    """SPEC-ORC-008: [valid, price8] with price8 = max(1, sum_i floor((a_i - 1)^+ * v_i / 10^(d_i))); valid only for one
    length n in [2, 8], a_i < 2^128, d_i <= 77 and v_i in [1, MAX_ROUTE_ANSWER]. Arguments: the three lengths, then
    a[n_a], v[n_v], d[n_d]."""
    a, v, d = rest[:n_a], rest[n_a : n_a + n_v], rest[n_a + n_v : n_a + n_v + n_d]
    if not (n_a == n_v == n_d and MIN_TOKENS <= n_a <= MAX_TOKENS):
        return [0, 0]
    if any(x >= ANSWER_BOUND for x in a) or any(x > 77 for x in d) or not all(_route_value_ok(x) for x in v):
        return [0, 0]
    total = sum(_floor(Fraction(max(a[i] - 1, 0) * v[i], 10 ** d[i])) for i in range(n_a))
    return [1, max(1, total)]


def _fx(xs) -> int:
    """x0 (x) x1 (x) ... left to right, x (x) y = floor(x y / 10^8); 2^256 - 1 once any step would not fit 256 bits."""
    if not xs:
        return PRICE_UNIT
    acc = xs[0]
    for x in xs[1:]:
        if acc == UINT256_MAX or x == UINT256_MAX or acc * x > UINT256_MAX:
            acc = UINT256_MAX
        else:
            acc = acc * x // PRICE_UNIT
    return acc


def in_usd_band(n_q: int, n_v: int, low: int, high: int, *rest: int) -> list[int]:
    """SPEC-ORC-011: [valid, inBand, (x) q, (x) v, low^(x)n, high^(x)n]; valid only for one length n in [2, 8] and every
    entry in [1, MAX_ROUTE_ANSWER]. Arguments: n_q, n_v, low, high, q[n_q], v[n_v]."""
    q, v = list(rest[:n_q]), list(rest[n_q : n_q + n_v])
    if not (n_q == n_v and MIN_TOKENS <= n_q <= MAX_TOKENS) or not all(_route_value_ok(x) for x in q + v):
        return [0, 0, 0, 0, 0, 0]
    n = n_q
    pq, pv, pl, ph = _fx(q), _fx(v), _fx([low] * n), _fx([high] * n)
    return [1, int(pl <= pq and pv <= ph), pq, pv, pl, ph]


def usd_level(n: int, *q: int) -> list[int]:
    """SPEC-ORC-011: max{L : L^(x)n <= (x) q}; 0 for malformed quotes. Found from the real root of the product (an
    independent start point) and corrected one unit at a time, not by the contract's binary search."""
    q = list(q[:n])
    if not MIN_TOKENS <= n <= MAX_TOKENS or not all(_route_value_ok(x) for x in q):
        return [0]
    prod = _fx(q)
    level = _iroot(prod * PRICE_UNIT ** (n - 1), n)
    while _fx([level + 1] * n) <= prod:
        level += 1
    while level > 0 and _fx([level] * n) > prod:
        level -= 1
    return [level]


def _iroot(x: int, n: int) -> int:
    lo, hi = 0, 1
    while hi**n <= x:
        hi *= 2
    while hi - lo > 1:
        mid = (lo + hi) // 2
        lo, hi = (mid, hi) if mid**n <= x else (lo, mid)
    return lo


LIVE, DRIFTING, CACHED, EXPIRED = 0, 1, 2, 3


def served_price(state: int, disagreeing: int, fresh: int, lower: int, accepted: int) -> list[int]:
    """SPEC-ORC-017: Expired 1; Cached A; a disagreement min(lower, fresh); Live and Drifting fresh; never below 1
    (REQ-ORACLE-060). The accepted price bounds borrowing only, so it is served only while Cached."""
    if state == EXPIRED:
        return [1]
    if state == CACHED:
        served = accepted
    elif disagreeing:
        served = min(lower, fresh)
    else:
        served = fresh
    return [max(1, served)]


def debt_served_price(state: int, q: int, p: int, b: int, accepted: int, rise: int) -> list[int]:
    """SPEC-ORC-018: Live q; Drifting max(p, b, A); Cached A; Expired ceil(A (10^4 + max(delta, 100)) / 10^4), 2^256 - 1
    when A (10^4 + delta) needs 257 bits; never below 1."""
    if state == EXPIRED:
        factor = BPS + max(rise, 100)
        served = UINT256_MAX if accepted * factor > UINT256_MAX or factor > UINT256_MAX else _ceil(Fraction(accepted * factor, BPS))
    elif state == CACHED:
        served = accepted
    elif state == DRIFTING:
        served = max(p, b, accepted)
    else:
        served = q
    return [max(1, served)]


def served_timestamp(failed: int, accepted_at: int, *t: int) -> list[int]:
    """SPEC-ORC-012: failed -> the accepted timestamp; else the oldest t_i, and 0 with no timestamp."""
    if failed:
        return [accepted_at]
    return [min(t) if t else 0]


def age_limits(n: int, failed: int, *legs: int) -> list[int]:
    """SPEC-ORC-015: deadline - servedUpdatedAt per limit; alternate legs use min(liquidation, borrow) for liquidation.
    servedUpdatedAt is the oldest route timestamp (SPEC-ORC-012), here the oldest leg, since a route's timestamp is
    its oldest leg. Arguments: n, failed, then (updatedAt, borrowPriceMaxAge, liquidationPriceMaxAge, onAlternate)."""
    if failed or n == 0:
        return [0, 0]
    rows = [legs[4 * i : 4 * i + 4] for i in range(n)]
    served = min(u for u, _, _, _ in rows)
    borrow = min(u + b for u, b, _, _ in rows)
    liq = min(u + (min(l, b) if alt else l) for u, b, l, alt in rows)
    return [borrow - served, liq - served]


def sequencer_status(has_feed: int, read_ok: int, answer_word: int, started: int, now: int, grace: int) -> list[int]:
    """SPEC-ORC-021: [up, down, unknown, inGrace, ready]; no feed -> ready only."""
    if not has_feed:
        return [0, 0, 0, 0, 1]
    answer = _signed(answer_word)
    up = bool(read_ok) and answer == 0 and started != 0 and started <= now
    down = bool(read_ok) and answer == 1
    in_grace = up and now < started + grace
    ready = up and now >= started + grace
    return [int(up), int(down), int(not up and not down), int(in_grace), int(ready)]


def min_observations(window: int, block_time: int) -> list[int]:
    """SPEC-ORC-022: ceil(W / CHAIN_BLOCK_TIME) + 1; 2^256 - 1 for a zero block time or when the count needs 257 bits."""
    if block_time == 0:
        return [UINT256_MAX]
    return [_sat(_ceil(Fraction(window, block_time)) + 1)]


def gas_for_call(g: int) -> list[int]:
    """SPEC-ORC-023: ceil(64 G / 63) + POST_CALL_GAS; 2^256 - 1 when 64 G needs 257 bits."""
    if 64 * g > UINT256_MAX:
        return [UINT256_MAX]
    return [_ceil(Fraction(64 * g, 63)) + POST_CALL_GAS]


def poke_min_gas_floor(w: int, g: int) -> list[int]:
    """SPEC-ORC-023: W_poke + ceil(64 G_max / 63) + POST_CALL_GAS, 2^256 - 1 when it needs 257 bits."""
    bound = gas_for_call(g)[0]
    return [UINT256_MAX if bound == UINT256_MAX else _sat(w + bound)]


# ---------------------------------------------------------------------------------------------------------------------
# RouteMath (2.12): the LitePSM gem amount of a PegModule swap route (REQ-ROUTE-012).
# ---------------------------------------------------------------------------------------------------------------------

WAD = 10**18
LITEPSM_MAX_TOUT = 10**36


def lite_psm_cost(g: int, tout: int, c: int) -> list[int]:
    """REQ-ROUTE-012: DssLitePsm.buyGem cost g*c + floor(g*c*tout / 1e18)."""
    return [g * c + (g * c * tout) // WAD]


def lite_psm_gem_amt(dai: int, tout: int, c: int) -> list[int]:
    """REQ-ROUTE-012: the largest g with cost(g) <= dai, found by binary search (independent of the closed form the
    contract uses); 0 when tout >= 1e36."""
    if tout >= LITEPSM_MAX_TOUT:
        return [0]
    lo, hi = 0, dai // c + 1  # cost(g) >= g*c, so g <= dai // c
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if lite_psm_cost(mid, tout, c)[0] <= dai:
            lo = mid
        else:
            hi = mid - 1
    return [lo]


# --- Concentrated liquidity (ClPriceMath, SPEC-ORC-006, SPEC-ORC-009, SPEC-ORC-010, SPEC-AMM-V3-001, SPEC-BACK-001) ---
# Ticks cross the FFI boundary offset by TICK_OFFSET (= MAX_TICK) so every argument stays unsigned.

MIN_TICK = -887272
MAX_TICK = 887272
TICK_OFFSET = MAX_TICK
MIN_SQRT_RATIO = 4295128739
MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342
Q96 = 1 << 96
_TICK_FACTORS = [
    0xFFF97272373D413259A46990580E213A, 0xFFF2E50F5F656932EF12357CF3C7FDCC, 0xFFE5CACA7E10E4E61C3624EAA0941CD0,
    0xFFCB9843D60F6159C9DB58835C926644, 0xFF973B41FA98C081472E6896DFB254C0, 0xFF2EA16466C96A3843EC78B326B52861,
    0xFE5DEE046A99A2A811C461F1969C3053, 0xFCBE86C7900A88AEDCFFC83B479AA3A4, 0xF987A7253AC413176F2B074CF7815E54,
    0xF3392B0822B70005940C7A398E4B70F3, 0xE7159475A2C29B7443B29C7FA6E889D9, 0xD097F3BDFD2022B8845AD8F792AA5825,
    0xA9F746462D870FDF8A65DC1F90E061E5, 0x70D869A156D2A1B890BB3DF62BAF32F7, 0x31BE135F97D08FD981231505542FCFA6,
    0x9AA508B5B7A84E1C677DE54F3E99BC9, 0x5D6AF8DEDB81196699C329225EE604, 0x2216E584F5FA1EA926041BEDFE98,
    0x48A170391F7DC42444E8FA2,
]


def _sqrt_ratio(tick: int) -> int:
    """Uniswap v3-core TickMath.getSqrtRatioAtTick, the same integer algorithm (its rounding is part of the spec)."""
    if not MIN_TICK <= tick <= MAX_TICK:
        raise ValueError("tick out of range")
    a = abs(tick)
    ratio = 0xFFFCB933BD6FAD37AA2D162D1A594001 if a & 1 else 1 << 128
    for i, f in enumerate(_TICK_FACTORS):
        if a & (2 << i):
            ratio = (ratio * f) >> 128
    if tick > 0:
        ratio = UINT256_MAX // ratio
    return (ratio >> 32) + (0 if ratio % (1 << 32) == 0 else 1)


def sqrt_ratio_at_tick(tick_off: int) -> list[int]:
    return [_sqrt_ratio(tick_off - TICK_OFFSET)]


def tick_at_sqrt_ratio(s: int) -> list[int]:
    """Greatest tick t with sqrtRatioAtTick(t) <= s, by bisection over the exact tick map; returned offset."""
    lo, hi = MIN_TICK, MAX_TICK
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if _sqrt_ratio(mid) <= s:
            lo = mid
        else:
            hi = mid - 1
    return [lo + TICK_OFFSET]


def _oracle_sqrt(p0: int, p1: int, d0: int, d1: int) -> tuple[int, int]:
    num, den = p0 * 10**d1, p1 * 10**d0
    if num >= den << 128:
        return MAX_SQRT_RATIO - 1, 1
    if num >= den << 64:
        s = isqrt((num << 128) // den) << 32
        if s >= MAX_SQRT_RATIO:
            return MAX_SQRT_RATIO - 1, 1
        return s, 0
    s = isqrt((num << 192) // den)
    if s < MIN_SQRT_RATIO:
        return MIN_SQRT_RATIO, 1
    return s, 0


def cl_oracle_sqrt(p0: int, p1: int, d0: int, d1: int) -> list[int]:
    """SPEC-ORC-009: [sqrtPriceX96, clamped]."""
    return list(_oracle_sqrt(p0, p1, d0, d1))


def _cl_amounts(s: int, sa: int, sb: int, u: int) -> tuple[int, int]:
    if s <= sa:
        return (u * Q96 * (sb - sa) // sb) // sa, 0
    if s < sb:
        return (u * Q96 * (sb - s) // sb) // s, u * (s - sa) // Q96
    return 0, u * (sb - sa) // Q96


def cl_amounts(s: int, sa: int, sb: int, u: int) -> list[int]:
    """SPEC-ORC-006 / LiquidityAmounts.getAmountsForLiquidity, each amount floored."""
    return list(_cl_amounts(s, sa, sb, u))


def _cl_raw(p0, p1, d0, d1, tl_off, tu_off, u):
    sa, sb = _sqrt_ratio(tl_off - TICK_OFFSET), _sqrt_ratio(tu_off - TICK_OFFSET)
    s, _ = _oracle_sqrt(p0, p1, d0, d1)
    return _cl_amounts(min(max(s, sa), sb), sa, sb, u)


def cl_composition(p0: int, p1: int, d0: int, d1: int, tl_off: int, tu_off: int, u: int) -> list[int]:
    """SPEC-AMM-V3-001: the clamped amounts, each positive one reduced by 1 raw unit."""
    a0, a1 = _cl_raw(p0, p1, d0, d1, tl_off, tu_off, u)
    return [max(a0 - 1, 0), max(a1 - 1, 0)]


def cl_unit_decimals(p0: int, p1: int, d0: int, d1: int, tl_off: int, tu_off: int) -> list[int]:
    """SPEC-ORC-005 over the CL composition: [found, d], the smallest d in [6, 18] with price8(10^d) >= 10^8."""
    for d in range(6, 19):
        a0, a1 = _cl_raw(p0, p1, d0, d1, tl_off, tu_off, 10**d)
        price8 = max(a0 - 1, 0) * p0 // 10**d0 + max(a1 - 1, 0) * p1 // 10**d1
        if max(1, price8) >= PRICE_UNIT:
            return [1, d]
    return [0, 0]


def cl_price8(p0: int, p1: int, d0: int, d1: int, tl_off: int, tu_off: int, s0: int, s1: int) -> list[int]:
    """The concentrated-liquidity LPOracle's fresh price: [d, price8] with d of SPEC-ORC-005 and price8 of SPEC-ORC-008
    over the module's raw composition (SPEC-ORC-006) at the valuation prices (SPEC-ORC-004; s0, s1 the stable flags);
    [0, 0] when no d in [6, 18] qualifies."""
    v0 = valuation_price(p0, s0)[0]
    v1 = valuation_price(p1, s1)[0]
    for d in range(6, 19):
        a0, a1 = _cl_raw(v0, v1, d0, d1, tl_off, tu_off, 10**d)
        price8 = max(1, max(a0 - 1, 0) * v0 // 10**d0 + max(a1 - 1, 0) * v1 // 10**d1)
        if price8 >= PRICE_UNIT:
            return [d, price8]
    return [0, 0]


def cl_price8_at(p0: int, p1: int, d0: int, d1: int, tl_off: int, tu_off: int, s0: int, s1: int, d: int) -> list[int]:
    """The concentrated-liquidity LPOracle's fresh price8 of 10^d units at the valuation prices of (p0, p1)."""
    v0 = valuation_price(p0, s0)[0]
    v1 = valuation_price(p1, s1)[0]
    a0, a1 = _cl_raw(v0, v1, d0, d1, tl_off, tu_off, 10**d)
    return [max(1, max(a0 - 1, 0) * v0 // 10**d0 + max(a1 - 1, 0) * v1 // 10**d1)]


def bounded_health_factor(hf: int, served: int, accepted: int) -> list[int]:
    """REQ-RISK-059: hf * min(served, accepted) / served, floored; hf when accepted >= served or served = 0."""
    if served == 0 or accepted >= served:
        return [hf]
    return [hf * accepted // served]


FUNCTIONS = {
    "mulDiv": (mul_div, 4),
    "netBonus": (net_bonus, 2),
    "effectiveSlippage": (effective_slippage, 2),
    "legSlippage": (leg_slippage, 4),
    "pendingSlippage": (pending_slippage, 1),
    "seizedValue": (seized_value, 5),
    "legValue": (leg_value, 5),
    "pendingLegValue": (pending_leg_value, 5),
    "unitValue": (unit_value, 4),
    "recoveryFloor": (recovery_floor, 4),
    "legMinOut": (leg_min_out, 5),
    "recoveryWithFloor": (recovery_with_floor, 2),
    "roundingGap": (rounding_gap, 5),
    "shortfallTopUp": (shortfall_top_up, 4),
    "payouts": (payouts, 4),
    "keeperPayout": (keeper_payout, 5),
    "liquidationSettlement": (liquidation_settlement, 7),
    "flashPremiumWithinCap": (flash_premium_within_cap, 3),
    "deleverageCap": (deleverage_cap, 5),
    "deleverageRepayment": (deleverage_repayment, 3),
    "deleverageAssetOut": (deleverage_asset_out, 3),
    "normalizeAnswer": (normalize_answer, 2),
    "routeValue2": (route_value2, 4),
    "routesAgree": (routes_agree, 3),
    "deviationBps": (deviation_bps, 2),
    "valuationPrice": (valuation_price, 2),
    "lpPrice": (lp_price, None),
    "inUsdBand": (in_usd_band, None),
    "servedPrice": (served_price, 5),
    "debtServedPrice": (debt_served_price, 6),
    "usdLevel": (usd_level, None),
    "servedTimestamp": (served_timestamp, None),
    "ageLimits": (age_limits, None),
    "sequencerStatus": (sequencer_status, 6),
    "minObservations": (min_observations, 2),
    "gasForCall": (gas_for_call, 1),
    "litePsmCost": (lite_psm_cost, 3),
    "litePsmGemAmt": (lite_psm_gem_amt, 3),
    "pokeMinGasFloor": (poke_min_gas_floor, 2),
    "sqrtRatioAtTick": (sqrt_ratio_at_tick, 1),
    "tickAtSqrtRatio": (tick_at_sqrt_ratio, 1),
    "clOracleSqrt": (cl_oracle_sqrt, 4),
    "clAmounts": (cl_amounts, 4),
    "clComposition": (cl_composition, 7),
    "clUnitDecimals": (cl_unit_decimals, 6),
    "clPrice8": (cl_price8, 8),
    "clPrice8At": (cl_price8_at, 9),
    "boundedHealthFactor": (bounded_health_factor, 3),
}


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] not in FUNCTIONS:
        print(f"usage: {argv[0]} <{'|'.join(FUNCTIONS)}> <args>", file=sys.stderr)
        return 2
    fn, arity = FUNCTIONS[argv[1]]
    args = [int(a, 0) for a in argv[2:]]
    if arity is not None and len(args) != arity:
        print(f"{argv[1]} takes {arity} arguments, got {len(args)}", file=sys.stderr)
        return 2
    sys.stdout.write("0x" + "".join(_word(v) for v in fn(*args)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
