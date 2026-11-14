# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (c) 2026 Avana Labs
# Contains a port of Uniswap v3-core TickMath, SqrtPriceMath and Tick (commit 5ea68a7; SqrtPriceMath and Tick were
# BUSL-1.1 until their 2023-04-01 change date), (c) 2021 Uniswap Labs, under GPL-2.0-or-later; see
# THIRD_PARTY_LICENSES.md.
"""Uniswap v3 full-range position math and a minimal pool + position manager.

Ports (exact integer arithmetic, same rounding):
  v3-core TickMath.getSqrtRatioAtTick, SqrtPriceMath.getAmount0Delta/getAmount1Delta
  (roundUp = true when liquidity is added, false when it is removed),
  Tick.tickSpacingToMaxLiquidityPerTick; v3-periphery LiquidityAmounts (not needed: liquidity is chosen directly).

The pool is modelled as a token holder. Every position is full range, so the
tokens a position can withdraw depend only on its liquidity and the pool price.
Price moves are an arbitrage swap with an external `arb` account that moves the
pool's reserves to what all positions need at the new price (rounded up), so
token conservation is exact and the pool is always solvent for withdrawals.
Fees are credited directly to positions' tokensOwed (the effect of fee growth).
"""
from .mathlib import U128, U160, U256, chk, mul_div, cdiv, isqrt

Q96 = 2 ** 96
MIN_TICK = -887272
MAX_TICK = 887272
MIN_SQRT_RATIO = 4295128739
MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342

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
    """TickMath.getSqrtRatioAtTick."""
    a = -tick if tick < 0 else tick
    assert a <= MAX_TICK
    ratio = 0xfffcb933bd6fad37aa2d162d1a594001 if a & 1 else 1 << 128
    for i, c in enumerate(_TM):
        if a & (2 << i):
            ratio = (ratio * c) >> 128
    if tick > 0:
        ratio = U256 // ratio
    return (ratio >> 32) + (0 if ratio % (1 << 32) == 0 else 1)


def full_range_ticks(spacing):
    lo = -((-MIN_TICK) // spacing) * spacing
    hi = (MAX_TICK // spacing) * spacing
    return lo, hi


def max_liquidity_per_tick(spacing):
    """Tick.tickSpacingToMaxLiquidityPerTick."""
    lo, hi = full_range_ticks(spacing)
    num_ticks = (hi - lo) // spacing + 1
    return U128 // num_ticks


def amount0_delta(sa, sb, liq, round_up):
    if sa > sb:
        sa, sb = sb, sa
    chk(liq, U128, "uint128 liquidity")
    n1 = liq << 96
    n2 = sb - sa
    assert sa > 0
    if round_up:
        return cdiv(mul_div(n1, n2, sb, up=True), sa)
    return mul_div(n1, n2, sb) // sa


def amount1_delta(sa, sb, liq, round_up):
    if sa > sb:
        sa, sb = sb, sa
    chk(liq, U128, "uint128 liquidity")
    return mul_div(liq, sb - sa, Q96, up=round_up)


def position_amounts(sqrt_p, liq, spacing, round_up):
    """Token amounts of a full-range position of `liq` at pool price sqrt_p (Q64.96)."""
    lo, hi = full_range_ticks(spacing)
    sa, sb = sqrt_ratio_at_tick(lo), sqrt_ratio_at_tick(hi)
    sp = min(max(sqrt_p, sa), sb)
    if sp <= sa:
        return amount0_delta(sa, sb, liq, round_up), 0
    if sp >= sb:
        return 0, amount1_delta(sa, sb, liq, round_up)
    return amount0_delta(sp, sb, liq, round_up), amount1_delta(sa, sp, liq, round_up)


def sqrt_price_from_usd(p0_8, p1_8, d0, d1):
    """sqrtPriceX96 of a pool whose raw price token1/token0 equals the USD prices given.

    raw price = (p0 / 10^d0) / (p1 / 10^d1) token1 base units per token0 base unit.
    """
    num = p0_8 * 10 ** d1 * Q96 * Q96
    den = p1_8 * 10 ** d0
    return chk(isqrt(num // den), U160, "uint160 sqrtPrice")


class Pool:
    """A full-range-only Uniswap v3 pool viewed as a reserve holder."""

    def __init__(self, name, token0, token1, d0, d1, spacing, sqrt_p, ledger):
        self.name, self.token0, self.token1 = name, token0, token1
        self.d0, self.d1, self.spacing = d0, d1, spacing
        self.sqrt_p = sqrt_p
        self.twap_sqrt_p = sqrt_p     # guard input for LPOracle (time-averaged price)
        self.liquidity = 0            # in-range liquidity (all positions are full range)
        self.owed0 = 0                # sum of positions' tokensOwed0 (held in the pool until collected)
        self.owed1 = 0
        self.ledger = ledger
        self.addr = f"pool:{name}"
        self.unlocked = True

    def required_reserves(self):
        a0, a1 = position_amounts(self.sqrt_p, self.liquidity, self.spacing, True)
        return a0 + self.owed0, a1 + self.owed1

    def move_price(self, new_sqrt_p, arb, follow_twap=True):
        """Arbitrage swap: arb settles the reserve difference so reserves == required (rounded up)."""
        self.sqrt_p = new_sqrt_p
        if follow_twap:
            self.twap_sqrt_p = new_sqrt_p
        r0, r1 = self.required_reserves()
        for tok, need in ((self.token0, r0), (self.token1, r1)):
            have = self.ledger.balance(tok, self.addr)
            if need > have:
                self.ledger.transfer(tok, arb, self.addr, need - have)
            elif have > need:
                # keep the rounding headroom already held; only release the clear excess
                self.ledger.transfer(tok, self.addr, arb, have - need)


class Position:
    def __init__(self, token_id, pool, owner):
        self.token_id, self.pool, self.owner = token_id, pool, owner
        self.liquidity = 0
        self.owed0 = 0            # tokensOwed0 (fees + principal from decreases)
        self.owed1 = 0
        self.fees0 = 0            # model-side tag: part of owed that is trading fees
        self.fees1 = 0
        self.approved = None      # NFPM getApproved


class NFPM:
    """NonfungiblePositionManager subset: mint, increaseLiquidity (anyone), decreaseLiquidity,
    collect, approve, transferFrom. Full range only."""

    def __init__(self, ledger):
        self.ledger = ledger
        self.positions = {}
        self.next_id = 1

    def mint(self, pool, owner, liq):
        chk(liq, U128, "uint128 liquidity")
        if liq == 0:
            raise ValueError("zero liquidity")
        p = Position(self.next_id, pool, owner)
        self.next_id += 1
        self.positions[p.token_id] = p
        self._add(p, owner, liq)
        return p.token_id

    def _add(self, p, payer, liq):
        pool = p.pool
        if pool.liquidity + liq > max_liquidity_per_tick(pool.spacing):
            raise ValueError("LO")  # liquidityGrossAfter <= maxLiquidity
        a0, a1 = position_amounts(pool.sqrt_p, liq, pool.spacing, True)
        for tok, a in ((pool.token0, a0), (pool.token1, a1)):
            if a:
                self.ledger.transfer(tok, payer, pool.addr, a)
        p.liquidity = chk(p.liquidity + liq, U128, "uint128 liquidity")
        pool.liquidity += liq
        return a0, a1

    def increase_liquidity(self, token_id, payer, liq):
        """NFPM.increaseLiquidity has no owner check: anyone can donate liquidity to any tokenId."""
        return self._add(self.positions[token_id], payer, liq)

    def decrease_liquidity(self, caller, token_id, liq, amount0_min=0, amount1_min=0):
        p = self.positions[token_id]
        self._auth(caller, p)
        if liq > p.liquidity:
            raise ValueError("liquidity")
        pool = p.pool
        a0, a1 = position_amounts(pool.sqrt_p, liq, pool.spacing, False)
        if a0 < amount0_min or a1 < amount1_min:
            raise ValueError("Price slippage check")
        p.liquidity -= liq
        pool.liquidity -= liq
        p.owed0 += a0
        p.owed1 += a1
        pool.owed0 += a0
        pool.owed1 += a1
        return a0, a1

    def collect(self, caller, token_id, recipient, max0, max1):
        p = self.positions[token_id]
        self._auth(caller, p)
        if max0 == 0 and max1 == 0:
            raise ValueError("NFPM collect: both caps zero")      # require(amount0Max > 0 || amount1Max > 0)
        c0, c1 = min(max0, p.owed0), min(max1, p.owed1)
        p.owed0 -= c0
        p.owed1 -= c1
        p.pool.owed0 -= c0
        p.pool.owed1 -= c1
        # fees are whatever is owed beyond un-collected principal; keep the tag consistent
        p.fees0 = min(p.fees0, p.owed0)
        p.fees1 = min(p.fees1, p.owed1)
        for tok, c in ((p.pool.token0, c0), (p.pool.token1, c1)):
            if c:                                  # UniswapV3Pool.collect pays only non-zero amounts
                self.ledger.transfer(tok, p.pool.addr, recipient, c)
        return c0, c1

    def credit_fees(self, pool, payer, f0, f1):
        """Swap fees: payer pays f0/f1 into the pool, split pro rata (rounded down) over positions."""
        if pool.liquidity == 0:
            return
        for tok, f in ((pool.token0, f0), (pool.token1, f1)):
            if f:
                self.ledger.transfer(tok, payer, pool.addr, f)
        for p in self.positions.values():
            if p.pool is pool and p.liquidity > 0:
                g0 = f0 * p.liquidity // pool.liquidity
                g1 = f1 * p.liquidity // pool.liquidity
                p.owed0 += g0
                p.owed1 += g1
                p.fees0 += g0
                p.fees1 += g1
                pool.owed0 += g0
                pool.owed1 += g1

    def approve(self, caller, token_id, spender):
        p = self.positions[token_id]
        if caller != p.owner:
            raise PermissionError("not owner")
        p.approved = spender

    def transfer_from(self, caller, frm, to, token_id):
        p = self.positions[token_id]
        if p.owner != frm:
            raise PermissionError("not owner")
        if caller != frm and p.approved != caller:
            raise PermissionError("not approved")
        p.owner = to
        p.approved = None          # per-token approval cleared on transfer (VAULT-058)

    def _auth(self, caller, p):
        if caller != p.owner and p.approved != caller:
            raise PermissionError("Not approved")
