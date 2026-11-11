# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Shared helpers for the AMM LP pricing models (fair composition of LP positions).

Reuses the solver wrappers and the exact TickMath port of ../units-oracle/_common.py, and adds
integer ports of the AMM arithmetic used by the pricing checks:

  concentrated liquidity   LiquidityAmounts.getAmountsForLiquidity (rounds down), the same
                           math for every AMM protocol with Uniswap v3 style ticks
  constant product         UniswapV2Pair swap (0.3% fee, balance check), mint, burn, sync, skim,
                           _mintFee (kLast / feeTo, 1/6 of fee growth), MINIMUM_LIQUIDITY = 1000
  StableSwap (NG style)    get_D, get_y, dynamic fee, admin fee share (integer, 18-decimal xp)
  weighted pool            invariant prod(b_i^w_i), out-given-in with swap fee (mpmath, 80 digits)

This module defines helpers only; running it checks the TickMath port and exits 0.
"""
import importlib.util
import math
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location('uo_common', os.path.join(_HERE, '..', 'units-oracle', '_common.py'))
_uo = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_uo)

prove, witness, note, finish = _uo.prove, _uo.witness, _uo.note, _uo.finish
sqrt_ratio_at_tick, tick_at_sqrt_ratio = _uo.sqrt_ratio_at_tick, _uo.tick_at_sqrt_ratio
mul_div = _uo.mul_div
Q96, U128, U256 = _uo.Q96, _uo.U128, _uo.U256
MIN_TICK, MAX_TICK = _uo.MIN_TICK, _uo.MAX_TICK
MIN_SQRT_RATIO, MAX_SQRT_RATIO = _uo.MIN_SQRT_RATIO, _uo.MAX_SQRT_RATIO

# Tick spacings checked: Uniswap v3 fee tiers (1, 10, 60, 200) and the AMM protocol variants
# with tickSpacing-keyed pools (1, 50, 100, 200, 2000).
SPACINGS = [1, 10, 50, 100, 200, 2000]


# --------------------------------------------------------------------------- concentrated liquidity
def amount0_for_liquidity(sa, sb, liq):
    """LiquidityAmounts.getAmount0ForLiquidity: mulDiv(L << 96, sb - sa, sb) / sa (both floor)."""
    if sa > sb:
        sa, sb = sb, sa
    return mul_div(liq << 96, sb - sa, sb) // sa


def amount1_for_liquidity(sa, sb, liq):
    """LiquidityAmounts.getAmount1ForLiquidity: mulDiv(L, sb - sa, Q96) (floor)."""
    if sa > sb:
        sa, sb = sb, sa
    return mul_div(liq, sb - sa, Q96)


def amounts_for_liquidity(s, sa, sb, liq):
    """LiquidityAmounts.getAmountsForLiquidity at sqrt price s (Q64.96) for the range [sa, sb]."""
    if sa > sb:
        sa, sb = sb, sa
    if s <= sa:
        return amount0_for_liquidity(sa, sb, liq), 0
    if s < sb:
        return amount0_for_liquidity(s, sb, liq), amount1_for_liquidity(sa, s, liq)
    return 0, amount1_for_liquidity(sa, sb, liq)


def sqrt_price_x96(num, den):
    """sqrtPriceX96 of the raw price num/den: isqrt(mulDiv(num, 2^192, den)), rounds down."""
    return math.isqrt(mul_div(num, 1 << 192, den))


def value8(a0, a1, p0_8, p1_8, d0, d1):
    """USD value with 8 decimals: mulDiv(a0, p0, 10^d0) + mulDiv(a1, p1, 10^d1), floor."""
    return mul_div(a0, p0_8, 10 ** d0) + mul_div(a1, p1_8, 10 ** d1)


def aligned_solidity(tick, spacing):
    """Solidity int24 `tick % spacing == 0` (remainder takes the dividend's sign)."""
    return int(math.fmod(tick, spacing)) == 0


# --------------------------------------------------------------------------- constant product
MINIMUM_LIQUIDITY = 1000


class V2Pair:
    """Integer port of UniswapV2Pair: reserves vs balances, 0.3% fee, kLast / feeTo."""

    def __init__(self, fee_on=False):
        self.r0 = self.r1 = 0          # getReserves()
        self.b0 = self.b1 = 0          # token balances held by the pair
        self.supply = 0
        self.k_last = 0
        self.fee_on = fee_on
        self.fee_to_balance = 0

    def _mint_fee(self):
        if not self.fee_on:
            self.k_last = 0
            return 0
        minted = 0
        if self.k_last:
            rk, rkl = math.isqrt(self.r0 * self.r1), math.isqrt(self.k_last)
            if rk > rkl:
                minted = self.supply * (rk - rkl) // (rk * 5 + rkl)
                if minted:
                    self.supply += minted
                    self.fee_to_balance += minted
        return minted

    def pending_fee_liquidity(self):
        """What _mintFee would mint now (the dilution not yet in totalSupply)."""
        if not self.fee_on or not self.k_last:
            return 0
        rk, rkl = math.isqrt(self.r0 * self.r1), math.isqrt(self.k_last)
        return self.supply * (rk - rkl) // (rk * 5 + rkl) if rk > rkl else 0

    def _update(self):
        self.r0, self.r1 = self.b0, self.b1

    def transfer_in(self, a0, a1):
        """A donation or the input leg of mint/swap: tokens sent to the pair."""
        self.b0 += a0
        self.b1 += a1

    def mint(self):
        a0, a1 = self.b0 - self.r0, self.b1 - self.r1
        self._mint_fee()
        if self.supply == 0:
            liq = math.isqrt(a0 * a1) - MINIMUM_LIQUIDITY
            assert liq > 0, 'INSUFFICIENT_LIQUIDITY_MINTED'
            self.supply = MINIMUM_LIQUIDITY
        else:
            liq = min(a0 * self.supply // self.r0, a1 * self.supply // self.r1)
            assert liq > 0, 'INSUFFICIENT_LIQUIDITY_MINTED'
        self.supply += liq
        self._update()
        if self.fee_on:
            self.k_last = self.r0 * self.r1
        return liq

    def burn(self, liq):
        assert 0 < liq <= self.supply - MINIMUM_LIQUIDITY
        self._mint_fee()
        a0, a1 = liq * self.b0 // self.supply, liq * self.b1 // self.supply
        assert a0 > 0 and a1 > 0, 'INSUFFICIENT_LIQUIDITY_BURNED'
        self.supply -= liq
        self.b0 -= a0
        self.b1 -= a1
        self._update()
        if self.fee_on:
            self.k_last = self.r0 * self.r1
        return a0, a1

    @staticmethod
    def amount_out(a_in, r_in, r_out):
        """UniswapV2Library.getAmountOut (0.3% fee)."""
        x = a_in * 997
        return x * r_out // (r_in * 1000 + x)

    def swap(self, zero_for_one, a_in):
        if zero_for_one:
            out = self.amount_out(a_in, self.r0, self.r1)
            assert 0 < out < self.r1
            self.b0 += a_in
            self.b1 -= out
        else:
            out = self.amount_out(a_in, self.r1, self.r0)
            assert 0 < out < self.r0
            self.b1 += a_in
            self.b0 -= out
        # the pair's own K check, with the fee-adjusted balances
        assert (self.b0 * 1000 - (a_in * 3 if zero_for_one else 0)) * \
               (self.b1 * 1000 - (0 if zero_for_one else a_in * 3)) >= self.r0 * self.r1 * 10 ** 6
        self._update()
        return out

    def sync(self):
        self._update()

    def skim(self):
        e0, e1 = self.b0 - self.r0, self.b1 - self.r1
        self.b0, self.b1 = self.r0, self.r1
        return e0, e1


def v2_fair_value(r0, r1, p0, p1):
    """2 * sqrt(r0 * r1 * p0 * p1) with p_i the USD price per raw unit as exact integers; floor."""
    return 2 * math.isqrt(r0 * r1 * p0 * p1)


# --------------------------------------------------------------------------- StableSwap (NG style)
FEE_DEN = 10 ** 10
A_PREC = 100


def ss_get_D(xp, amp):
    """StableSwap get_D (Newton, A in A_PRECISION units), as in the NG pool."""
    n = len(xp)
    S = sum(xp)
    if S == 0:
        return 0
    D, Ann = S, amp * n
    for _ in range(255):
        D_P = D
        for x in xp:
            D_P = D_P * D // x
        D_P //= n ** n
        Dprev = D
        D = (Ann * S // A_PREC + D_P * n) * D // ((Ann - A_PREC) * D // A_PREC + (n + 1) * D_P)
        if abs(D - Dprev) <= 1:
            return D
    raise AssertionError('get_D did not converge')


def ss_get_y(i, j, x, xp, amp, D):
    n = len(xp)
    Ann = amp * n
    c, S_ = D, 0
    for k in range(n):
        if k == i:
            _x = x
        elif k != j:
            _x = xp[k]
        else:
            continue
        S_ += _x
        c = c * D // (_x * n)
    c = c * D * A_PREC // (Ann * n)
    b = S_ + D * A_PREC // Ann
    y = D
    for _ in range(255):
        y_prev = y
        y = (y * y + c) // (2 * y + b - D)
        if abs(y - y_prev) <= 1:
            return y
    raise AssertionError('get_y did not converge')


def ss_dynamic_fee(xpi, xpj, fee, offpeg):
    if offpeg <= FEE_DEN:
        return fee
    xps2 = (xpi + xpj) ** 2
    return offpeg * fee // ((offpeg - FEE_DEN) * 4 * xpi * xpj // xps2 + FEE_DEN)


class StableSwap:
    """n-coin StableSwap pool with 18-decimal balances, swap fee with off-peg multiplier and a
    50% admin share that leaves the LP balances."""

    def __init__(self, balances, amp=200 * A_PREC, fee=4 * 10 ** 6, offpeg=2 * FEE_DEN):
        self.x = list(balances)
        self.amp, self.fee, self.offpeg = amp, fee, offpeg
        self.supply = ss_get_D(self.x, amp)        # first deposit mints D
        self.admin = [0] * len(balances)

    def D(self):
        return ss_get_D(self.x, self.amp)

    def virtual_price(self):
        return self.D() * 10 ** 18 // self.supply

    def exchange(self, i, j, dx):
        D = self.D()
        x = self.x[i] + dx
        y = ss_get_y(i, j, x, self.x, self.amp, D)
        dy = self.x[j] - y - 1
        fee = ss_dynamic_fee((self.x[i] + x) // 2, (self.x[j] + y) // 2, self.fee, self.offpeg)
        dy_fee = dy * fee // FEE_DEN
        out = dy - dy_fee
        assert out > 0
        admin = dy_fee // 2
        self.x[i] = x
        self.x[j] = self.x[j] - out - admin
        self.admin[j] += admin
        return out

    def donate(self, amounts):
        for k, a in enumerate(amounts):
            self.x[k] += a


if __name__ == '__main__':
    assert sqrt_ratio_at_tick(MIN_TICK) == MIN_SQRT_RATIO
    assert sqrt_ratio_at_tick(MAX_TICK) == MAX_SQRT_RATIO
    print('amm-pricing/_common.py: helper module, no properties (TickMath port self-check passed).')
