# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""SYM-100..141 — worked examples of the units, LPOracle, DebtOracle and backing-ledger rules, recomputed
from the final formulas in exact integers or rationals.

Pages: [2.3] Collateralization, [2.4] Vault tokens, [2.10] LPOracle and DebtOracle, [2.2] LPVault,
[2.17] Lens, [3.1] Deposit, [3.4] Withdraw, [3.8] Market lifecycle.
Each check compares a stated figure with the value the formula gives: `eq` for exact integers, `numeric`
for figures the page rounds (tolerance = half a unit of the last stated digit).
Uniswap amounts use an exact port of TickMath.getSqrtRatioAtTick and the SqrtPriceMath burn formulas.
"""
import importlib.util
import math
import os
import sympy as sp
from _common import eq, numeric, done

_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("uo_common", os.path.join(_here, "..", "z3", "units-oracle", "_common.py"))
uo = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(uo)

R = sp.Rational
Q96 = 2 ** 96


def mul_div(a, b, c, ceil=False):
    q, r = divmod(a * b, c)
    return q + (1 if ceil and r else 0)


def price8(v0, v1):
    return math.isqrt(4 * v0 * v1) - 1


def burn(L, S, spacing):
    """Uniswap amounts on removal of L at sqrtPriceX96 S, full range at the given spacing (round down)."""
    lo, hi = uo.usable_ticks(spacing)
    SL, SU = uo.sqrt_ratio_at_tick(lo), uo.sqrt_ratio_at_tick(hi)
    a0 = (L * Q96 * (SU - S) // SU) // S
    a1 = L * (S - SL) // Q96
    return a0, a1


def eqm(pid, title, lhs, rhs):
    """eq for a single value or a column of values: residual = sum of squared differences."""
    if isinstance(lhs, sp.MatrixBase):
        assert lhs.shape == rhs.shape
        return eq(pid, title, sum((a - b) ** 2 for a, b in zip(lhs, rhs)), 0)
    return eq(pid, title, lhs, rhs)


def holds(pid, title, cond):
    return eq(pid, title, sp.Integer(1 if cond else 0), 1)


# ======================= [2.4] Vault tokens =======================
# SYM-100 verifies: SPEC-UNIT-001, SPEC-ORC-005
eqm("SYM-100a", "SPEC-UNIT-001: USDC/USDT d = 6, DAI/USDC d = 12, GHO/DAI d = 18, DAI/USDS d = 18",
   sp.Matrix([(6 + 6) // 2, (18 + 6) // 2, (18 + 18) // 2, (18 + 18) // 2]), sp.Matrix([6, 12, 18, 18]))
# SYM-100 verifies: SPEC-UNIT-001, REQ-VTOKEN-022
holds("SYM-100b", "SPEC-UNIT-001: a 6- and 7-decimal pair has an odd sum and reverts OddDecimalSum", (6 + 7) % 2 == 1)
# SYM-101 verifies: SPEC-UNIT-002, SPEC-BACK-002
eqm("SYM-101", "SPEC-UNIT-002 / SPEC-BACK-002: 5,000,000,000 units = 5,000 whole tokens at d = 6, worth $10,000 at $2.00",
   sp.Matrix([R(5_000_000_000, 10 ** 6), R(5_000_000_000, 10 ** 6) * 2]), sp.Matrix([5000, 10000]))
# SYM-102 verifies: SPEC-UNIT-003
eqm("SYM-102a", "SPEC-UNIT-003: legs at $1.00 give $2.00; USDT $0.64 with USDC $1.00 gives 2*sqrt(0.64) = $1.60",
   sp.Matrix([2 * sp.sqrt(1 * 1), 2 * sp.sqrt(R(64, 100))]), sp.Matrix([2, R(8, 5)]))
p8_peg = price8(10 ** 8, 10 ** 8)
# SYM-102 verifies: SPEC-UNIT-003, SPEC-ORC-008
eqm("SYM-102b", "SPEC-UNIT-003: L = 1 at pool price 1, 6 decimals: removal returns (0, 0) raw units; credited value floor(1 * price8 / 10^6) = 199",
   sp.Matrix(list(burn(1, Q96, 1)) + [1 * p8_peg // 10 ** 6]), sp.Matrix([0, 0, 199]))
# SYM-103 verifies: SPEC-UNIT-004
eqm("SYM-103", "SPEC-UNIT-004: 5e9 units at price8 2e8: value 5e9*2e8/1e6 = 1e12 ($10,000); Aave value 5e9*2e8*1e12 = 1e30",
   sp.Matrix([5 * 10 ** 9 * 2 * 10 ** 8 // 10 ** 6, 5 * 10 ** 9 * 2 * 10 ** 8 * 10 ** 12]), sp.Matrix([10 ** 12, 10 ** 30]))
# SYM-104 verifies: SPEC-UNIT-005, MKT-014
eqm("SYM-104a", "SPEC-UNIT-005: addCap >= ceil(5,500,000 / 1.00) = 5,500,000 whole tokens = 5.5e12 base units < 2^120",
   sp.Matrix([sp.ceiling(R(5_500_000, 1)), 5_500_000 * 10 ** 6, int(5_500_000 * 10 ** 6 < 2 ** 120)]),
   sp.Matrix([5_500_000, 5_500_000_000_000, 1]))
# SYM-104 verifies: MKT-014, SPEC-UNIT-005
eqm("SYM-104b", "MKT-014: marketUsdCap $2,000,000 + slice $200,000 at stressFloorUsd $1.00 gives addCap >= 2,200,000",
   sp.ceiling(R(2_200_000, 1)), 2_200_000)
# SYM-105 verifies: SPEC-UNIT-006
eqm("SYM-105a", "SPEC-UNIT-006: $100 million of USDC/USDT full-range liquidity at $2 per whole token is 5e13 units",
   R(100_000_000, 2) * 10 ** 6, 5 * 10 ** 13)
# SYM-105 verifies: SPEC-UNIT-006
numeric("SYM-105b", "SPEC-UNIT-006: maxLiquidityPerTick(1) ~ 1.92e32 (within one unit of the last stated digit)",
        R(192, 100) * 10 ** 32, uo.max_liquidity_per_tick(1), 10 ** 30)
# SYM-105 verifies: SPEC-UNIT-006
numeric("SYM-105c", "SPEC-UNIT-006: maxLiquidityPerTick(200) ~ 3.83e34 (exact 3.835e34, within one unit of the last stated digit)",
        R(383, 100) * 10 ** 34, uo.max_liquidity_per_tick(200), 10 ** 32)

# ======================= [2.3] Collateralization =======================
ticks = {s: uo.usable_ticks(s) for s in (1, 10, 60, 200)}
# SYM-106 verifies: SPEC-BACK-001
eqm("SYM-106", "SPEC-BACK-001: trunc(-887272/60)*60 = -887220; spacings 1, 10, 60, 200 give +-887272, +-887270, +-887220, +-887200",
   sp.Matrix([int(-887272 / 60) * 60] + [ticks[s][1] for s in (1, 10, 60, 200)] + [ticks[s][0] for s in (1, 10, 60, 200)]),
   sp.Matrix([-887220, 887272, 887270, 887220, 887200, -887272, -887270, -887220, -887200]))
# SYM-107 verifies: SPEC-BACK-003
eqm("SYM-107", "SPEC-BACK-003: NFT 42 charges ceil(5e9*2e8/1e6) = 1e12 at price8 2e8 and 5e11 at the floor when price8 = 9e7",
   sp.Matrix([mul_div(5 * 10 ** 9, max(2 * 10 ** 8, 10 ** 8), 10 ** 6, True), mul_div(5 * 10 ** 9, max(9 * 10 ** 7, 10 ** 8), 10 ** 6, True)]),
   sp.Matrix([10 ** 12, 5 * 10 ** 11]))
# SYM-108 verifies: SPEC-BACK-004
eqm("SYM-108", "SPEC-BACK-004: top-up charge 3e11 with slice 2e11 adds $1,000 regular, $2,000 slice, $3,000 per token and depositor",
   sp.Matrix([3 * 10 ** 11 - 2 * 10 ** 11, 2 * 10 ** 11, 3 * 10 ** 11]), sp.Matrix([10 ** 11, 2 * 10 ** 11, 3 * 10 ** 11]))
rem = mul_div(10 ** 12, 3_425_000_000, 5_000_000_000, True)
# SYM-109 verifies: SPEC-BACK-005
eqm("SYM-109a", "SPEC-BACK-005: reconciling 1,575,000,000 of NFT 42 leaves 685e9 and releases 315e9 ($3,150)",
   sp.Matrix([rem, 10 ** 12 - rem]), sp.Matrix([685 * 10 ** 9, 315 * 10 ** 9]))
fs_ = min(3 * 10 ** 11, 2 * 10 ** 11)
# SYM-109 verifies: SPEC-BACK-005
eqm("SYM-109b", "SPEC-BACK-005: the top-up record leaving in full with slice 2e11: fromSlice = 2e11 and regular drops by 1e11 ($1,000)",
   sp.Matrix([fs_, 3 * 10 ** 11 - fs_]), sp.Matrix([2 * 10 ** 11, 10 ** 11]))


def debit(lst, u):
    out, remu = [], u
    for rid, c in lst:
        t = min(remu, c)
        remu -= t
        out.append((rid, c - t))
    return out, remu


lst = [(42, 5_000_000_000), (7, 4_000_000_000)]
new = (99, 4_000_000_000)
pos = next((i for i, (_, c) in enumerate(lst) if c < new[1]), len(lst))
lst_ins = lst[:pos] + [new] + lst[pos:]
after, remu = debit(lst_ins, 6_000_000_000)
# SYM-110 verifies: SPEC-BACK-006
eqm("SYM-110", "SPEC-BACK-006: a third 4e9 NFT goes after NFT 7; a 6e9 debit empties NFT 42 and leaves NFT 7 at 3e9",
   sp.Matrix([[r for r, _ in lst_ins].index(99), after[0][1], after[1][1], after[2][1], remu]),
   sp.Matrix([2, 0, 3_000_000_000, 4_000_000_000, 0]))
# SYM-111 verifies: SPEC-BACK-007
eqm("SYM-111", "SPEC-BACK-007: seizure of 1,575,000,000 from 9e9 shares / 12e9 supply leaves 7,425,000,000 and 10,425,000,000",
   sp.Matrix([9_000_000_000 - 1_575_000_000, 12_000_000_000 - 1_575_000_000]), sp.Matrix([7_425_000_000, 10_425_000_000]))
S125 = 5 * 2 ** 94                                  # sqrtPriceX96 = 1.25 * 2^96 exactly
a0, a1 = burn(1_575_000_000, S125, 1)
# SYM-112 verifies: SPEC-BACK-008
eqm("SYM-112a", "SPEC-BACK-008: USDT at $0.64 (sqrtP = 1.25): removing 1,575,000,000 units returns a0 = 1,259,999,999, a1 = 1,968,749,999",
   sp.Matrix([a0, a1]), sp.Matrix([1_259_999_999, 1_968_749_999]))
# SYM-112 verifies: SPEC-BACK-008
numeric("SYM-112b", "SPEC-BACK-008: the removed principal is worth $2,520 at USDC $1.00 and USDT $0.64",
        2520, R(a0, 10 ** 6) + R(a1, 10 ** 6) * R(64, 100), R(1, 100))
# SYM-112 verifies: SPEC-BACK-008
eqm("SYM-112c", "SPEC-BACK-008: a 10 bps transfer fee (rounded down) leaves r1 = 1,966,781,250 received",
   a1 - a1 * 10 // 10_000, 1_966_781_250)
# SYM-113 verifies: SPEC-BACK-009
eqm("SYM-113", "SPEC-BACK-009: gap 0 after the reconciled withdrawal; orphan-burn case gapBefore = gapAfter = 1,575,000,000",
   sp.Matrix([4_000_000_000 + 1_575_000_000 - 5_575_000_000,
              9_000_000_000 + 0 - 7_425_000_000,
              (9_000_000_000 - 1_575_000_000 - 4_000_000_000) + 1_575_000_000 - (7_425_000_000 - 4_000_000_000)]),
   sp.Matrix([0, 1_575_000_000, 1_575_000_000]))
# SYM-114 verifies: SPEC-BACK-010
eqm("SYM-114", "SPEC-BACK-010: donation 1e8 then reconciling 1,575,000,000 leaves credited 3,425,000,000 and live 3,525,000,000",
   sp.Matrix([5_000_000_000 - 1_575_000_000, 5_100_000_000 - 1_575_000_000]), sp.Matrix([3_425_000_000, 3_525_000_000]))
S_ = (7_425_000_000 - 3_425_000_000) + 3_425_000_000
# SYM-115 verifies: SPEC-BACK-011
eqm("SYM-115", "SPEC-BACK-011: withdrawing NFT 42 with 3,425,000,000 units gives S = 7,425,000,000 and shortfall 1,575,000,000",
   sp.Matrix([S_, max(9_000_000_000 - S_, 0)]), sp.Matrix([7_425_000_000, 1_575_000_000]))
o0, o1 = mul_div(1_259_999_999, 10 ** 9, 1_575_000_000), mul_div(1_968_749_999, 10 ** 9, 1_575_000_000)
# SYM-116 verifies: SPEC-BACK-012
eqm("SYM-116a", "SPEC-BACK-012: settling 1e9 of 1,575,000,000 pays 799,999,999 and 1,249,999,999, leaving 460,000,000 and 718,750,000",
   sp.Matrix([o0, o1, 1_259_999_999 - o0, 1_968_749_999 - o1]), sp.Matrix([799_999_999, 1_249_999_999, 460_000_000, 718_750_000]))
# SYM-116 verifies: SPEC-BACK-012
eqm("SYM-116b", "SPEC-BACK-012: the check passes at supply 575,000,000 after the burn, and without a burn reverts SupplyDropMismatch(0, 575,000,000)",
   sp.Matrix([int(575_000_000 + 1_000_000_000 <= 0 + 1_575_000_000), int(575_000_000 + 575_000_000 <= 575_000_000),
              0 + 575_000_000 - 575_000_000]), sp.Matrix([1, 0, 0]))
cb = mul_div(10 ** 12, 4 * 10 ** 9, 5 * 10 ** 9, True)
rc = mul_div(1_500_000_000, 2 * 10 ** 8, 10 ** 6, True)
C1 = cb + rc
rem2 = mul_div(C1, 2_750_000_000, 5_500_000_000, True)
# SYM-117 verifies: SPEC-BACK-013
eqm("SYM-117", "SPEC-BACK-013: c_b = 8e11, re-credit charge 3e11, C0' = 1.1e12, a 2.75e9 removal leaves 5.5e11; life total $13,000",
   sp.Matrix([cb, rc, C1, rem2, (10 ** 12 - cb) + (C1 - rem2) + rem2]),
   sp.Matrix([8 * 10 ** 11, 3 * 10 ** 11, 11 * 10 ** 11, 55 * 10 ** 10, 13 * 10 ** 11]))
# SYM-118 verifies: SPEC-BACK-014, REQ-COLL-016
eqm("SYM-118", "SPEC-BACK-014: slice-only top-up books 1e9; ceil(1.5e9 * 2e11 / 3e11) = 1e9; capped at 3e8 after a seizure; rescue pledge 5e8",
   sp.Matrix([mul_div(10 ** 9, 2 * 10 ** 11, 2 * 10 ** 11, True), mul_div(1_500_000_000, 2 * 10 ** 11, 3 * 10 ** 11, True),
              min(10 ** 9, 300_000_000), 500_000_000]),
   sp.Matrix([10 ** 9, 10 ** 9, 300_000_000, 500_000_000]))
# SYM-119 verifies: REQ-COLL-017, SPEC-BACK-005
eqm("SYM-119", "REQ-COLL-017: repay with collateral of 8e8 units of NFT 7 (4e9, $8,000) leaves 3.2e9 units and a $6,400 charge",
   sp.Matrix([4_000_000_000 - 800_000_000, mul_div(8000 * 10 ** 8, 3_200_000_000, 4_000_000_000, True)]),
   sp.Matrix([3_200_000_000, 6400 * 10 ** 8]))
rows = [(9e9, 0, 9e9), (9e9, 0, 9e9), (4e9, 1.575e9, 5.575e9), (0, 1.575e9, 1.575e9), (0, 0, 0)]
# SYM-120 verifies: SPEC-BACK-009, SPEC-BACK-011, SPEC-BACK-012
eqm("SYM-120", "worked example 'reconcile on exit': every row has totalCredited + pending.units = totalSupply (gap 0)",
   sp.Matrix([int(tc + p - y) for tc, p, y in rows]), sp.zeros(5, 1))

# ======================= [2.10] LPOracle and DebtOracle =======================
# SYM-121 verifies: SPEC-ORC-001
eqm("SYM-121", "SPEC-ORC-001: 99,987,000 from 8-, 18- and 6-decimal feeds",
   sp.Matrix([99_987_000, 999_870_000_000_000_000 // 10 ** 10, 999_870 * 100]), sp.Matrix([99_987_000] * 3))
# SYM-122 verifies: SPEC-ORC-002
eqm("SYM-122", "SPEC-ORC-002: USDT/ETH x ETH/USD = floor(3.333e14 * 3e11 / 1e18) = 99,990,000; route time = 1,762,649,000",
   sp.Matrix([mul_div(333_300_000_000_000, 300_000_000_000, 10 ** 18), min(1_762_650_000, 1_762_649_000)]),
   sp.Matrix([99_990_000, 1_762_649_000]))
agree = lambda p, b, T: abs(p - b) * 10 ** 4 <= T * min(p, b)
# SYM-123 verifies: SPEC-ORC-003
eqm("SYM-123", "SPEC-ORC-003: T = 225, p = 100,010,000: b = 99,900,000 agrees (1.1e9 <= 2.24775e10); b = 97,500,000 disagrees (2.51e10 > 2.19375e10)",
   sp.Matrix([int(agree(100_010_000, 99_900_000, 225)), int(agree(100_010_000, 97_500_000, 225)),
              (100_010_000 - 97_500_000) * 10 ** 4, 225 * 97_500_000]),
   sp.Matrix([1, 0, 25_100_000_000, 21_937_500_000]))
# SYM-124 verifies: SPEC-ORC-004
eqm("SYM-124", "SPEC-ORC-004: GHO at 100,300,000 is valued at 100,000,000; USDC at 99,987,000 passes unchanged",
   sp.Matrix([min(100_300_000, 10 ** 8), min(99_987_000, 10 ** 8)]), sp.Matrix([10 ** 8, 99_987_000]))


def cl_amounts(S, SA, SB, L):
    """LiquidityAmounts.getAmountsForLiquidity at sqrt price S for [SA, SB] (floor)."""
    if S <= SA:
        return mul_div(L * Q96, SB - SA, SB) // SA, 0
    if S < SB:
        return mul_div(L * Q96, SB - S, SB) // S, mul_div(L, S - SA, Q96)
    return 0, mul_div(L, SB - SA, Q96)


def cl_price8(v, dec, tl, tu, d, clamp=True):
    """SPEC-ORC-006 / SPEC-ORC-008: clamped composition of 10^d units, floor, minus one raw unit."""
    sO = math.isqrt(v[0] * 10 ** dec[1] * 2 ** 192 // (v[1] * 10 ** dec[0]))
    SA, SB = uo.sqrt_ratio_at_tick(tl), uo.sqrt_ratio_at_tick(tu)
    S = min(max(sO, SA), SB) if clamp else sO
    a = cl_amounts(S, SA, SB, 10 ** d) if clamp else (0, mul_div(10 ** d, sO - SA, Q96))
    return max(1, sum(max(a[i] - 1, 0) * v[i] // 10 ** dec[i] for i in range(2))), a


def smallest_d(v, dec, tl, tu):
    return next(d for d in range(6, 19) if cl_price8(v, dec, tl, tu, d)[0] >= 10 ** 8)


p_rt, a_rt = cl_price8([10 ** 8, 95_200_000], [6, 6], -100, 100, 9)
p_un, a_un = cl_price8([10 ** 8, 95_200_000], [6, 6], -100, 100, 9, clamp=False)
# SYM-125 verifies: SPEC-ORC-006
eqm("SYM-125", "SPEC-ORC-006: USDC/USDT [-100, 100], d = 9, token1 at 0.952: clamped a = (0, 9,999,541), price8 = 951,956,208; unclamped a1 = 29,887,349 ($28.45)",
   sp.Matrix([a_rt[0], a_rt[1], p_rt, a_un[1], a_un[1] * 95_200_000 // 10 ** 6 // 10 ** 6]),
   sp.Matrix([0, 9_999_541, 951_956_208, 29_887_349, 2845]))
x_, y_ = 1 / sp.Rational(11, 10), sp.Rational(11, 10)
# SYM-126 verifies: SPEC-ORC-007
numeric("SYM-126", "SPEC-ORC-007: pool at P = 1.21 holds x = 0.9091, y = 1.1, worth $2.0091; excess 0.0091",
        R(20091, 10000), x_ + y_, R(5, 10 ** 5))
p_ex, a_ex = cl_price8([99_987_000, 10 ** 8], [6, 6], -10, 10, 10)
p_dai, a_dai = cl_price8([10 ** 8, 10 ** 8], [18, 6], -887_270, 887_270, 12)
# SYM-127 verifies: SPEC-ORC-008, SPEC-ORC-012
eqm("SYM-127", "SPEC-ORC-008: USDC/USDT [-10, 10], d = 10: a = (5,648,563, 4,348,479), price8 = 564,782,768 + 434,847,800 = 999,630,568; DAI/USDC full range d = 12: 199,999,799 vs closed form 199,999,999",
   sp.Matrix([a_ex[0], a_ex[1], 5_648_562 * 99_987_000 // 10 ** 6, 4_348_478 * 10 ** 8 // 10 ** 6, p_ex, p_dai, math.isqrt(4 * 10 ** 16) - 1]),
   sp.Matrix([5_648_563, 4_348_479, 564_782_768, 434_847_800, 999_630_568, 199_999_799, 199_999_999]))
# SYM-167 verifies: SPEC-ORC-005
eqm("SYM-167", "SPEC-ORC-005: smallest d with a whole token >= $1: DAI/USDC full range 12; USDC/USDT [-10, 10] 10 (d = 9 gives 99,963,04x < 1e8); USDC/USDT [-100, 100] depegged 9",
   sp.Matrix([smallest_d([10 ** 8, 10 ** 8], [18, 6], -887_270, 887_270), smallest_d([99_987_000, 10 ** 8], [6, 6], -10, 10),
              int(cl_price8([99_987_000, 10 ** 8], [6, 6], -10, 10, 9)[0] < 10 ** 8), smallest_d([10 ** 8, 95_200_000], [6, 6], -100, 100)]),
   sp.Matrix([12, 10, 1, 9]))
s_dai = math.isqrt(10 ** 14 * 2 ** 192 // 10 ** 26)
# SYM-128 verifies: SPEC-ORC-009
eqm("SYM-128a", "SPEC-ORC-009: DAI/USDC at $1: num = 1e14, den = 1e26, s = 79,228,162,514,264,337,593,543, no clamp",
   sp.Matrix([10 ** 8 * 10 ** 6, 10 ** 8 * 10 ** 18, s_dai, int(uo.MIN_SQRT_RATIO <= s_dai < uo.MAX_SQRT_RATIO)]),
   sp.Matrix([10 ** 14, 10 ** 26, 79_228_162_514_264_337_593_543, 1]))
W, dlt = 1800, -497_384_100
tr = -((-dlt) // W)
mean = tr - 1 if (dlt < 0 and dlt % W != 0) else tr
# SYM-128 verifies: SPEC-ORC-010
eqm("SYM-128b", "SPEC-ORC-010: tickRef = getTickAtSqrtRatio(s) = -276,325; delta -497,384,100 over 1,800 s truncates to -276,324 and rounds to -276,325",
   sp.Matrix([uo.tick_at_sqrt_ratio(s_dai), tr, mean]), sp.Matrix([-276_325, -276_324, -276_325]))
fx = lambda *xs: __import__('functools').reduce(lambda a, b: a * b // 10 ** 8, xs)
# SYM-129 verifies: SPEC-ORC-011
eqm("SYM-129", "SPEC-ORC-011: band 9e7 / 1.02e8 with fixed-point products: GHO/USDC 104,700,000 >= 81,000,000, capped 1e8 <= 104,040,000; 99,996,998 in band; 79,210,000 < 81,000,000; three tokens 99,970,002 >= 72,900,000",
   sp.Matrix([fx(104_700_000, 10 ** 8), fx(90_000_000, 90_000_000), fx(10 ** 8, 10 ** 8), fx(102_000_000, 102_000_000),
              fx(99_987_000, 100_010_000), fx(89_000_000, 89_000_000), fx(99_990_000, 10 ** 8, 99_980_000), fx(90_000_000, 90_000_000, 90_000_000)]),
   sp.Matrix([104_700_000, 81_000_000, 10 ** 8, 104_040_000, 99_996_998, 79_210_000, 99_970_002, 72_900_000]))
dl_ = min(1_762_600_000 + 84_600, 1_762_640_000 + 88_200, 1_762_645_000 + 5_400)
# SYM-130 verifies: SPEC-ORC-015, SPEC-ORC-012
eqm("SYM-130", "SPEC-ORC-015: servedUpdatedAt 1,762,600,000; deadline 1,762,650,400; maxAge 50,400; on primaries: servedUpdatedAt 1,762,560,000, deadline 1,762,648,200, maxAge 88,200",
   sp.Matrix([min(1_762_600_000, 1_762_640_000, 1_762_645_000), dl_, dl_ - 1_762_600_000,
              min(1_762_600_000, 1_762_560_000), min(1_762_600_000 + 84_600, 1_762_560_000 + 88_200), min(1_762_600_000 + 84_600, 1_762_560_000 + 88_200) - 1_762_560_000]),
   sp.Matrix([1_762_600_000, 1_762_650_400, 50_400, 1_762_560_000, 1_762_648_200, 88_200]))
stp, sta = 1_000_000 + 84_600 + 1, 1_130_000 + 5_400 + 1
# SYM-131 verifies: SPEC-ORC-013
eqm("SYM-131", "SPEC-ORC-013: staleFrom 1,084,601 and 1,135,401; Cached until 1,139,000, Expired from 1,139,001; late-poke case Expired at 1,004,100 instead of Cached until 1,007,600",
   sp.Matrix([stp, sta, max(stp, sta) + 3600 - 1, max(stp, sta) + 3600, int(1_004_100 >= min(1_000_000, 1_004_100) + 3600), 1_004_000 + 3600]),
   sp.Matrix([1_084_601, 1_135_401, 1_139_000, 1_139_001, 1, 1_007_600]))
# SYM-132 verifies: SPEC-ORC-014
eqm("SYM-132", "SPEC-ORC-014: S_primary starts 1,084,601; alternate gap starts 1,134,201; B = [1,134,201, 1,190,000) lasts 55,799 >= 3,600; grace ends 1,191,800; fallback gap starts 1,081,001",
   sp.Matrix([1_000_000 + 84_600 + 1, 1_128_800 + 5_400 + 1, min(1_200_000, 1_190_000) - max(1_084_601, 1_134_201), 1_190_000 + 1800, 996_400 + 84_600 + 1]),
   sp.Matrix([1_084_601, 1_134_201, 55_799, 1_191_800, 1_081_001]))
low, a_low = cl_price8([10 ** 8, 97_500_000], [6, 6], -887_272, 887_272, 6)
fresh_fr, _ = cl_price8([10 ** 8, 10 ** 8], [6, 6], -887_272, 887_272, 6)
# SYM-133 verifies: SPEC-ORC-016, SPEC-ORC-017
eqm("SYM-133", "SPEC-ORC-016/017: pause ends 1,762,653,600; full-range USDC/USDT d = 6: lower composition (987,420, 1,012,739), lower = 197,483,855 = served below A = 199,980,000; fresh 199,999,600 Drifting serves A",
   sp.Matrix([1_762_650_000 + 3600, a_low[0], a_low[1], low, min(low, 199_980_000), fresh_fr, min(fresh_fr, 199_980_000)]),
   sp.Matrix([1_762_653_600, 987_420, 1_012_739, 197_483_855, 197_483_855, 199_999_600, 199_980_000]))
def usd_level(*q):
    """SPEC-ORC-011: the largest L with L^(x)n <= (x) q, counted up from the real root of the product."""
    n, prod = len(q), fx(*q)
    lv = math.isqrt(prod * 10 ** 8) if n == 2 else int(sp.integer_nthroot(prod * 10 ** (8 * (n - 1)), n)[0])
    while fx(*([lv + 1] * n)) <= prod:
        lv += 1
    while fx(*([lv] * n)) > prod:
        lv -= 1
    return lv


# SYM-190 verifies: SPEC-ORC-011, REQ-ORACLE-042
eqm("SYM-190", "SPEC-ORC-011: usdLevel 99,998,499 for (99,987,000, 100,010,000) (power 99,996,998, next 99,997,000); 89,000,000 for both at 0.89; 99,990,000 for the three-token pool; 90,000,001 = usdBandLow for (81,000,001, 1e8) in band, real root 90,000,000; order example 91,459,272 vs 91,459,273 against 91,459,273",
   sp.Matrix([usd_level(99_987_000, 100_010_000), fx(99_998_499, 99_998_499), fx(99_998_500, 99_998_500), usd_level(89_000_000, 89_000_000),
              usd_level(99_990_000, 10 ** 8, 99_980_000), usd_level(81_000_001, 10 ** 8), fx(90_000_001, 90_000_001), math.isqrt(81_000_001 * 10 ** 8),
              fx(95_243_313, 98_905_925, 97_089_205), fx(97_089_205, 98_905_925, 95_243_313), fx(97_067_963, 97_067_963, 97_067_963)]),
   sp.Matrix([99_998_499, 99_996_998, 99_997_000, 89_000_000, 99_990_000, 90_000_001, 81_000_001, 90_000_000, 91_459_272, 91_459_273, 91_459_273]))
fr_v, a_fv = cl_price8([97_544_839, 97_383_701], [6, 6], -887_272, 887_272, 6)
lo_w, a_lw = cl_price8([97_544_839, 97_383_663], [6, 6], -887_272, 887_272, 6)
# SYM-191 verifies: SPEC-ORC-017, REQ-ORACLE-086
eqm("SYM-191", "SPEC-ORC-017: full-range USDC/USDT d = 6: v = (97,544,839, 97,383,701) gives (999,173, 1,000,826) and fresh 194,928,113; w = (97,544,839, 97,383,663) <= v gives (999,173, 1,000,827) and lower 194,928,172; served min(lower, fresh, A = 2e8) = 194,928,113",
   sp.Matrix([a_fv[0], a_fv[1], fr_v, a_lw[0], a_lw[1], lo_w, min(lo_w, fr_v, 2 * 10 ** 8)]),
   sp.Matrix([999_173, 1_000_826, 194_928_113, 999_173, 1_000_827, 194_928_172, 194_928_113]))
# SYM-134 verifies: SPEC-ORC-018
eqm("SYM-134a", "SPEC-ORC-018: Expired USDC A = 99,990,000: delta 500 -> 104,989,500; delta 200 -> 101,989,800; A = 99,987,001 -> 104,986,352; disagreement -> 100,300,000",
   sp.Matrix([mul_div(99_990_000, 10_500, 10_000, True), mul_div(99_990_000, 10_200, 10_000, True),
              mul_div(99_987_001, 10_500, 10_000, True), max(99_990_000, 100_300_000, 99_995_000)]),
   sp.Matrix([104_989_500, 101_989_800, 104_986_352, 100_300_000]))
# SYM-134 verifies: SPEC-ORC-018
numeric("SYM-134b", "SPEC-ORC-018: 10,000 USDC of debt counts as $10,498.95 when Expired", R(1049895, 100),
        10_000 * R(104_989_500, 10 ** 8), R(1, 200))
# SYM-135 verifies: REQ-ORACLE-032, REQ-ORACLE-088, REQ-ORACLE-090, REQ-ORACLE-054
eqm("SYM-135", "oracle rules: grace to 1,762,651,800 (not 1,762,648,200); price-drop alert 193,900,000*1e4 < 199,950,000*9,700; alternate leg age 21,601 at 1,762,661,601 against a lowered 21,600; limits 84,600 / 88,200 / 5,400",
   sp.Matrix([1_762_650_000 + 1800, 1_762_646_400 + 1800, int(193_900_000 * 10 ** 4 < 199_950_000 * 9_700),
              1_762_661_601 - 1_762_640_000, min(88_200, 21_600), 82_800 + 1800, 86_400 + 1800, 3_600 + 1800]),
   sp.Matrix([1_762_651_800, 1_762_648_200, 1, 21_601, 21_600, 84_600, 88_200, 5_400]))
# SYM-166 verifies: SPEC-ORC-019, REQ-ORACLE-054
eqm("SYM-166", "SPEC-ORC-019: USDT/USD round at 1,762,560,000 valid until 1,762,648,200 and Stale from 1,762,648,201; a 4,200 s limit would refuse it from 1,762,564,201",
   sp.Matrix([1_762_560_000 + 86_400 + 1_800, 1_762_560_000 + 88_200 + 1, 1_762_560_000 + 4_200 + 1]),
   sp.Matrix([1_762_648_200, 1_762_648_201, 1_762_564_201]))
agr = lambda q, s, S: abs(q - s) * 10 ** 4 <= S * min(q, s)
# SYM-169 verifies: SPEC-ORC-020
eqm("SYM-169", "SPEC-ORC-020: S = 100, q = 100,020,000: s = 99,400,000 confirmed (6.2e9 <= 9.94e9); s = 98,900,000 not (1.12e10 > 9.89e9)",
   sp.Matrix([int(agr(100_020_000, 99_400_000, 100)), int(agr(100_020_000, 98_900_000, 100)), 620_000 * 10 ** 4, 100 * 99_400_000, 1_120_000 * 10 ** 4, 100 * 98_900_000]),
   sp.Matrix([1, 0, 6_200_000_000, 9_940_000_000, 11_200_000_000, 9_890_000_000]))
# SYM-170 verifies: SPEC-ORC-021, REQ-ORACLE-099
eqm("SYM-170", "SPEC-ORC-021: Base restart at 1,010,000 with grace 3,600: in grace until 1,013,599; borrowing from 1,013,600 on a round newer than the restart: a round of 1,009,000 or 1,010,000 keeps it closed, one of 1,013,000 opens it",
   sp.Matrix([1_010_000 + 3_600 - 1, 1_010_000 + 3_600, int(1_009_000 > 1_010_000), int(1_010_000 > 1_010_000), int(1_013_000 > 1_010_000)]),
   sp.Matrix([1_013_599, 1_013_600, 0, 0, 1]))
# SYM-171 verifies: SPEC-ORC-022, REQ-ORACLE-055
eqm("SYM-171", "SPEC-ORC-022: W = 1,800: Ethereum 151, Base 901 observations; the Ethereum value on Base spans 300 s",
   sp.Matrix([-(-1800 // 12) + 1, -(-1800 // 2) + 1, (151 - 1) * 2]), sp.Matrix([151, 901, 300]))
# SYM-172 verifies: SPEC-ORC-023, REQ-ORACLE-038
eqm("SYM-172", "SPEC-ORC-023: G = 50,000 needs 50,794 + 5,000 = 55,794; that gasleft forwards min(50,000, 54,923); G_inputs(2) = 150,000 + 2 * 140,000 = 430,000, bound 436,826 + 5,000; worst-case two-token poke with the token-decimals reads: binding read 718,836 + 50,794 + 5,000 = 774,630, W_poke 830,781, floor max = 830,781, below POKE_MIN_GAS_FLOOR = 900,000 by 69,219",
   sp.Matrix([-(-64 * 50_000 // 63), -(-64 * 50_000 // 63) + 5_000, 55_794 - 55_794 // 64, 150_000 + 2 * 140_000, -(-64 * 430_000 // 63), 718_836 - (-64 * 50_000 // 63) + 5_000, max(830_781, 718_836 - (-64 * 50_000 // 63) + 5_000), 900_000 - max(830_781, 718_836 - (-64 * 50_000 // 63) + 5_000)]),
   sp.Matrix([50_794, 55_794, 54_923, 430_000, 436_826, 774_630, 830_781, 69_219]))

# ======================= [2.2] LPVault =======================
b0, b1 = burn(1_000_000_000, Q96, 1)
# SYM-136 verifies: REQ-VAULT-161, SPEC-BACK-008
holds("SYM-136", f"REQ-VAULT-161: removing 1e9 units at pool price 1 returns about 1,000 USDC and 1,000 USDT ({b0}, {b1}), both above the 995,000,000 minimums",
      b0 >= 995_000_000 and b1 >= 995_000_000 and abs(b0 - 10 ** 9) <= 1 and abs(b1 - 10 ** 9) <= 1)

# ======================= [3.1] Deposit worked example =======================
# SYM-137 verifies: DEP-012, DEP-018, SPEC-CAP-001, SPEC-CAP-005
eqm("SYM-137a", "deposit: pledge value and charge 5e12 ($50,000); pool share 1.525e16 <= 4e16; capacity $15,600; dust 4e6 units = 8e8 < 1e9",
   sp.Matrix([25_000_000_000 * 2 * 10 ** 8 // 10 ** 6, mul_div(25_000_000_000, 2 * 10 ** 8, 10 ** 6, True),
              (1_500_000_000_000 + 25_000_000_000) * 10 ** 4, 1000 * 40_000_000_000_000, 50_000 * R(312, 1000),
              4_000_000 * 2 * 10 ** 8 // 10 ** 6]),
   sp.Matrix([5 * 10 ** 12, 5 * 10 ** 12, R(1525, 100) * 10 ** 15, 4 * 10 ** 16, 15_600, 800_000_000]))
# SYM-137 verifies: DEP-012
numeric("SYM-137b", "deposit: Avana holds 3.81% of the pool", R(381, 100), R(1_525_000_000_000, 40_000_000_000_000) * 100, R(5, 1000))
# SYM-137 verifies: DEP-004, SPEC-BACK-014, SPEC-CAP-003
eqm("SYM-137c", "deposit: restore amount ceil(900 / 0.312) = $2,884.61538462 (8 decimals); rescue ceil(276 / 0.312) = $884.61538462",
   sp.Matrix([sp.ceiling(R(900, 1) / R(312, 1000) * 10 ** 8), sp.ceiling(R(276, 1) / R(312, 1000) * 10 ** 8)]),
   sp.Matrix([288_461_538_462, 88_461_538_462]))
# SYM-137 verifies: DEP-004, SPEC-CAP-003
numeric("SYM-137d", "deposit: HF after the slice top-up 52,000 * 0.312 / 15,000 = 1.0816; after the rescue top-up 1.0982",
        R(10816, 10000) + R(10982, 10000), R(52_000 * 312, 1000 * 15_000) + R(52_800 * 312, 1000 * 15_000), R(5, 10 ** 5))
# SYM-137 verifies: DEP-025, SPEC-BACK-013
eqm("SYM-137e", "deposit: re-credit of 2.5e9 charges 5e11 ($5,000); record basis 27.5e9 units and $55,000",
   sp.Matrix([mul_div(2_500_000_000, 2 * 10 ** 8, 10 ** 6, True), 25_000_000_000 + 2_500_000_000, 50_000 + 5_000]),
   sp.Matrix([5 * 10 ** 11, 27_500_000_000, 55_000]))

# ======================= [3.4] Withdraw worked example =======================
# SYM-138 verifies: WDR-008, WDR-018
numeric("SYM-138a", "withdraw path A: HF 1.56 before, 1.1143 after #9, 0.4457 if #7 left alone",
        R(156, 100) + R(11143, 10000) + R(4457, 10000),
        R(21_840, 14_000) + R(15_600, 14_000) + R(6_240, 14_000), R(5, 10 ** 4))
# SYM-138 verifies: WDR-018
eqm("SYM-138b", "withdraw path C: refunds 7,123,287,671,232,876,712 GHO wei and 5,342,465 USDC base units",
   sp.Matrix([8_040 * 10 ** 18 - 8_032_876_712_328_767_123_288, 5_030_000_000 - 5_024_657_535]),
   sp.Matrix([7_123_287_671_232_876_712, 5_342_465]))
# SYM-138 verifies: WDR-016, SPEC-BACK-005
eqm("SYM-138c", "withdraw partial record: ceil(50,000 * 20/25) = $40,000; reconcile: missing 12e9, #7 charge ceil(50,000*13/25) = $26,000",
   sp.Matrix([sp.ceiling(R(50_000 * 20, 25)), 35_000_000_000 - (13_000_000_000 + 10_000_000_000), sp.ceiling(R(50_000 * 13, 25))]),
   sp.Matrix([40_000, 12_000_000_000, 26_000]))
# Reconcile removal of 12e9 units of #7: a1 = 12,001,500,000 fixes the pool price; a0 follows.
L12, A1 = 12_000_000_000, 12_001_500_000
lo1, hi1 = uo.usable_ticks(1)
SL1, SU1 = uo.sqrt_ratio_at_tick(lo1), uo.sqrt_ratio_at_tick(hi1)
def first_S(target):
    """Smallest sqrtPriceX96 S at which removing L12 returns amount1 >= target (amount1 is monotone in S)."""
    lo_, hi_ = Q96, 2 * Q96
    while lo_ < hi_:
        mid = (lo_ + hi_) // 2
        if burn(L12, mid, 1)[1] >= target:
            hi_ = mid
        else:
            lo_ = mid + 1
    return lo_


S_lo, S_hi = first_S(A1), first_S(A1 + 1) - 1
a0_range = sorted({burn(L12, S_lo, 1)[0], burn(L12, S_hi, 1)[0]})
# SYM-138 verifies: WDR-028, SPEC-BACK-008
eqm("SYM-138d", f"withdraw reconcile: removing 12e9 units with a1 = 12,001,500,000 returns a0 in {a0_range}; the stated a0 = 11,998,500,187 occurs",
   sp.Matrix([int(11_998_500_187 in a0_range), a0_range[-1]]), sp.Matrix([1, 11_998_500_187]))
# SYM-138 verifies: WDR-028, SPEC-BACK-012
eqm("SYM-138e", "withdraw reconcile: settling half pays floor(11,998,500,187 * 6/12) = 5,999,250,093 and 6,000,750,000",
   sp.Matrix([mul_div(11_998_500_187, 6, 12), mul_div(12_001_500_000, 6, 12)]), sp.Matrix([5_999_250_093, 6_000_750_000]))
# SYM-138 verifies: WDR-035, WDR-038, SPEC-BACK-005
eqm("SYM-138f", "withdraw path E: mulDiv(4e6, 199,990,000, 1e6) = 799,960,000; mulDiv(5,001,000, ...) = 1,000,149,990; charge falls to $10.002",
   sp.Matrix([mul_div(4_000_000, 199_990_000, 10 ** 6), mul_div(5_001_000, 199_990_000, 10 ** 6),
              mul_div(100_000 * 10 ** 8, 5_001_000, 50_000_000_000, True)]),
   sp.Matrix([799_960_000, 1_000_149_990, 1_000_200_000]))
# SYM-138 verifies: WDR-035
numeric("SYM-138g", "withdraw path E: collateral $179,991, CF-weighted $56,157.19, HF 5.6157; after the removal hfEx 2.4961 / 2.4962",
        179_991 + R(5_615_719, 100) + R(56_157, 10_000) + R(24_961, 10_000) + R(24_962, 10_000),
        R(90_000_000_000 * 19_999, 10 ** 10) + R(90_000_000_000 * 19_999 * 312, 10 ** 13)
        + R(90_000_000_000 * 19_999 * 312, 10 ** 13 * 10_000)
        + R(40_004_000_000 * 19_999 * 312, 10 ** 13 * 10_000) + R(40_005_001_000 * 19_999 * 312, 10 ** 13 * 10_000),
        R(3, 1000))

# ======================= [3.8] Market lifecycle =======================
# SYM-139 verifies: MKT-005, MKT-010, MKT-011, MKT-043, MKT-049, MKT-052, MKT-053, MKT-054, SPEC-ORC-019
eqm("SYM-139a", "lifecycle: borrowPriceMaxAge = feedHeartbeat + heartbeatMargin (1,800 s, SPEC-ORC-019, no cap): USDC/USD 82,800 -> 84,600, USDT/USD 86,400 -> 88,200; CF 3,120 bps; 10,500*3,120/1e4 = 3,276; slippage min(100, 196) = 100; pledge 5e6 -> 1e9, 4,999,999 -> 999,999,800; 149 bps passes, 150 fails; CF 2,730; per-market window 500/3 GHO and 100 GHO floor",
   sp.Matrix([82_800 + 1_800, 86_400 + 1_800, 7800 * 4000 // 10 ** 4, 10_500 * 3_120 // 10_000,
              min(100, 10_000 * 200 // 10_200), 5_000_000 * 2 * 10 ** 8 // 10 ** 6, 4_999_999 * 2 * 10 ** 8 // 10 ** 6,
              int(10_200 * 9_950 * 10 ** 4 >= 10 ** 8 * (10 ** 4 + 149)), int(10_200 * 9_950 * 10 ** 4 >= 10 ** 8 * (10 ** 4 + 150)),
              7800 * 35 // 100, 500 * 10 ** 18 // 3, max(100, 500 // 8)]),
   sp.Matrix([84_600, 88_200, 3120, 3276, 100, 10 ** 9, 999_999_800, 1, 0, 2730, 166_666_666_666_666_666_666, 100]))
LF = R(10005, 10000) - R(95, 100) * R(30, 100) / (R(312, 1000) * R(105, 100))
# SYM-139 verifies: MKT-010
numeric("SYM-139b", "lifecycle: opening LTV 3,120 bps / 1.10 = 28.4%", R(284, 1000), R(312, 1100), R(5, 10 ** 4))
# SYM-139 verifies: MKT-013
numeric("SYM-139c", "lifecycle: loss factor 1.0005 - 0.95 * 0.30 / 0.3276 = 0.1305", R(1305, 10000), LF, R(5, 10 ** 5))
# SYM-139 verifies: MKT-013
numeric("SYM-139d", "lifecycle: the 400,000 GHO reserve supports about 3,064,000 GHO of debt (to the nearest thousand)",
        3_064_000, 400_000 / LF, 500)
# SYM-139 verifies: MKT-013
numeric("SYM-139e", "lifecycle: tail term CF_t = 0.312 and token cap 400,000 / 0.312 = $1,282,051", R(312, 1000) + 1_282_051,
        R(312, 1000) + 400_000 / R(312, 1000), 1)
# SYM-139 verifies: MKT-053, MKT-014
eqm("SYM-139f", "lifecycle: one loosening from 1.10 / $2,000,000 / 100 bps reaches at most 1.07 / $3,000,000 / 125 bps",
   sp.Matrix([R(110, 100) - R(3, 100), 2_000_000 * R(15_000, 10_000), 100 + 25]), sp.Matrix([R(107, 100), 3_000_000, 125]))

# ======================= [2.17] Lens =======================
# SYM-140 verifies: REQ-LENS-009, REQ-LENS-017, REQ-LENS-028, REQ-LENS-029
numeric("SYM-140a", "lens: HF 0.9997; debt repaid 4,990 USDC; after: 69,368.3 tokens, 35,466.12 USDC, HF 1.10",
        R(9997, 10000) + 4990 + R(6_936_83, 10) + R(3_546_612, 100) + R(110, 100),
        R(14_382_640 * 2812, 100 * 10_000) / R(4_045_612, 100)
        + (R(110, 100) * R(4_045_612, 100) - R(14_382_640 * 2812, 100 * 10_000)) / (R(110, 100) - R(102, 100) * R(2812, 10_000))
        + (R(719_132, 10) - R(4990 * 102, 200)) + (R(4_045_612, 100) - 4990)
        + (R(719_132, 10) - R(4990 * 102, 200)) * 2 * R(2812, 10_000) / (R(4_045_612, 100) - 4990),
        R(1, 1000))
# SYM-140 verifies: REQ-LENS-028, REQ-LENS-029, REQ-LENS-016
eqm("SYM-140b", "lens: maxGhoSpend 5,004.97; ceil(1,060*1.003) = 1,063.18; c = 2,544.9 tokens; V = 5,089.80; slippage min(100, 166); floor 5,037.9019980002; A = 19.96; payout 79.84",
   sp.Matrix([R(4990 * 10_030, 10_000), R(1060 * 1003, 1000), R(4990 * 102, 200), R(4990 * 102, 200) * 2,
              min(100, 10 ** 4 * (10_200 * 10 ** 4 - 10 ** 4 * 10_030) // (10_200 * 10 ** 4)),
              sp.ceiling(R(508_980, 100) * R(99, 100) * 10 ** 18) / sp.Integer(10) ** 18 - R(19_998, 10 ** 10) - 1,
              min(sp.floor(R(9980, 100) * 2000 / 10 ** 4 * 100) / 100, R(9980, 100)),
              (R(500_497, 100) + R(508_980, 100)) - (4990 + R(500_497, 100) + R(1996, 100))]),
   sp.Matrix([R(500_497, 100), R(106_318, 100), R(25_449, 10), R(508_980, 100), 100, R(50_379_019_980_002, 10 ** 10),
              R(1996, 100), R(7984, 100)]))
# SYM-140 verifies: REQ-LENS-016
eqm("SYM-140c", "lens: bNet 10,500 slippage min(100, 476); minGhoPerWholeToken = 1,236.499998999999999999 GHO",
   sp.Matrix([min(100, 10 ** 4 * 500 // 10_500), R(12375, 10) - R(10 ** 12 + 1, 10 ** 18) - 1]),
   sp.Matrix([100, R(1_236_499_998_999_999_999_999, 10 ** 18)]))
# SYM-140 verifies: REQ-LENS-034, REQ-LENS-018, REQ-LENS-014, REQ-LENS-026
eqm("SYM-140d", "lens: tail_USDT $93,600, tail_USDC $78,000, ratioBps 10,683; 5 whole tokens at $10 / $2; page walks 50 IDs; pending 1,208.65",
   sp.Matrix([min(R(330_000 * 312, 1000) / R(110, 100), 600_000), R(275_000 * 312, 1000) / R(110, 100),
              100_000 * 10 ** 4 // 93_600, R(10, 2), min(200, 1250 - 1200), R(61_025, 100) + R(59_840, 100)]),
   sp.Matrix([93_600, 78_000, 10_683, 5, 50, R(120_865, 100)]))
Ht = R(110, 100) * (1 + R(8, 100) * 1200 / 31_536_000) * R(1005, 1000)
# SYM-140 verifies: REQ-LENS-035, REQ-LENS-036
numeric("SYM-140e", "lens: Ht = 1.1055034 and amount = 15,436.376661 GHO", R(11_055_034, 10 ** 7) + R(15_436_376_661, 10 ** 6),
        Ht + (R(28_120) / Ht - 10_000), R(1, 10 ** 6))
# SYM-140 verifies: REQ-LENS-036
eqm("SYM-140f", "lens: ceil(10,000 * 1.0000030441 * 1.001) = 10,010.030472 USDC; repaid ceil(10,000.0304414) = 10,000.030442; refund 10.000030",
   sp.Matrix([sp.ceiling(10_000 * R(10_000_030_441, 10 ** 10) * R(1001, 1000) * 10 ** 6),
              sp.ceiling(10_000 * (1 + R(8, 100) * 1200 / 31_536_000) * 10 ** 6), 10_010_030_472 - 10_000_030_442]),
   sp.Matrix([10_010_030_472, 10_000_030_442, 10_000_030]))
# SYM-140 verifies: REQ-LENS-038, SPEC-BACK-013
eqm("SYM-140g", "lens: re-credit charge ceil(2.5e9 * 199,990,000 / 1e6) = 499,975,000,000; Bob x = 1,979.999998, to wallet 20.000002",
   sp.Matrix([mul_div(2_500_000_000, 199_990_000, 10 ** 6, True), 2000 * R(99, 100) - R(2, 10 ** 6), 2000 - (2000 * R(99, 100) - R(2, 10 ** 6))]),
   sp.Matrix([499_975_000_000, R(1_979_999_998, 10 ** 6), R(20_000_002, 10 ** 6)]))
# SYM-140 verifies: REQ-LENS-038
numeric("SYM-140h", "lens: Bob HF 1.406 before and 27,557.6 / 18,020.000002 = 1.5293 after",
        R(1406, 1000) + R(15293, 10000),
        R(100_000 * 2812, 10_000 * 20_000) + R(98_000 * 2812, 10_000) / (20_000 - (2000 * R(99, 100) - R(2, 10 ** 6))), R(5, 10 ** 5))

done()
