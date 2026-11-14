# SPDX-License-Identifier: LicenseRef-BUSL
# Copyright (c) 2026 Avana Labs
# Contains a port of Aave V4 code (aave/aave-v4 commit a3ef63e, (c) Aave Labs), used only in test environments under
# the Aave V4 license in LICENSES/LicenseRef-BUSL-AaveV4.md; see THIRD_PARTY_LICENSES.md.
"""Exact-integer Python reimplementation of the Aave V4 arithmetic used by the
aave-risk models (pinned commit a3ef63ea6415d25237a9775bf66e76e9993561c2).

Sources mirrored line-for-line:
  src/spoke/libraries/LiquidationLogic.sol  (calculateLiquidationBonus,
      _calculateLiquidationAmounts, _calculateDebtToLiquidate,
      _calculateDebtToTargetHealthFactor, _calculateCollateralToLiquidate)
  src/spoke/Spoke.sol  (_processUserAccountData health factor)
  src/hub/libraries/SharesMath.sol, AssetLogic.sol (share conversions)
  src/libraries/math/{WadRayMath,PercentageMath,MathUtils}.sol

Running this module prints a note and exits 0.
"""
WAD = 10**18
RAY = 10**27
BPS = 10**4
VIRT = 10**6
HF_LIQ = 10**18
DUST = 1000 * 10**26


def cdiv(a, b):
    return -(-a // b)


def percent_mul_down(v, p):
    return v * p // BPS


def percent_mul_up(v, p):
    return cdiv(v * p, BPS)


def ray_mul_up(a, b):
    return cdiv(a * b, RAY)


def ray_div_down(a, b):
    return a * RAY // b


def ray_div_up(a, b):
    return cdiv(a * RAY, b)


def from_ray_up(a):
    return cdiv(a, RAY)


def round_ray_up(a):
    return cdiv(a, RAY) * RAY


def to_value(amount, decimals, price):
    return amount * price * 10 ** (18 - decimals)


class Hub:
    """Added-share conversions for one Hub asset (A = totalAddedAssets, S = addedShares)."""

    def __init__(self, A, S):
        self.A, self.S = A, S

    def to_shares_down(self, a):
        return a * (self.S + VIRT) // (self.A + VIRT)

    def to_shares_up(self, a):
        return cdiv(a * (self.S + VIRT), self.A + VIRT)

    def to_assets_down(self, s):
        return s * (self.A + VIRT) // (self.S + VIRT)

    def to_assets_up(self, s):
        return cdiv(s * (self.A + VIRT), self.S + VIRT)

    # IHubBase preview functions
    def previewAddByAssets(self, a):
        return self.to_shares_down(a)

    def previewAddByShares(self, s):
        return self.to_assets_up(s)

    def previewRemoveByShares(self, s):
        return self.to_assets_down(s)


def health_factor(collaterals, debts):
    """collaterals: list of (amount, decimals, price8, cf_bps); debts: list of (debtRay, decimals, price8)."""
    avg = sum(cf * to_value(a, d, p) for a, d, p, cf in collaterals)
    tdv = sum(to_value(dr, d, p) for dr, d, p in debts)
    if tdv == 0:
        return 2**256 - 1, tdv
    return (avg * (WAD // BPS)) * RAY // tdv, tdv


def liquidation_bonus(hf_for_max, lbf, hf, max_lb):
    if hf <= hf_for_max:
        return max_lb
    min_lb = percent_mul_down(max_lb - BPS, lbf) + BPS
    return min_lb + (max_lb - min_lb) * (HF_LIQ - hf) // (HF_LIQ - hf_for_max)


def debt_to_target(tdv_ray, debt_unit, debt_price, cf, lb, hf, thf):
    penalty = percent_mul_up(lb * (WAD // BPS), cf)
    return cdiv(tdv_ray * (debt_unit * (thf - hf)), (thf - penalty) * (debt_price * WAD))


def collateral_to_liquidate(hub, cunit, cprice, ds, prem_ray, idx, dunit, dprice, lb):
    debt_ray = ds * idx + prem_ray
    coll = debt_ray * (dprice * cunit * lb) // (dunit * cprice * BPS * RAY)
    return hub.previewAddByAssets(coll)


def debt_to_liquidate(ds, prem_ray, idx, tdv_ray, ddec, dunit, dprice, cover, cf, lb, hf, thf):
    to_target = debt_to_target(tdv_ray, dunit, dprice, cf, lb, hf, thf)
    prem = min(round_ray_up(to_target), prem_ray)
    if cover < from_ray_up(prem):
        prem = cover * RAY
    drawn = 0
    if prem == prem_ray and prem < to_target:
        s_target = cdiv(to_target - prem, idx)
        s_cover = (cover - from_ray_up(prem)) * RAY // idx
        drawn = min(s_target, s_cover, ds)
    remaining = (ds - drawn) * idx + prem_ray - prem
    dust = drawn < ds and to_value(remaining, ddec, dprice) < DUST * RAY
    if dust:
        drawn, prem = ds, prem_ray
    return drawn, prem, to_target, dust


class MustNotLeaveDust(Exception):
    pass


def liquidation_amounts(*, hub, supplied_shares, cdec, cprice, ds, prem_ray, idx, tdv_ray,
                        ddec, dprice, cover, cf, hf_for_max, lbf, max_lb, thf, hf, fee=0):
    cunit, dunit = 10 ** cdec, 10 ** ddec
    lb = liquidation_bonus(hf_for_max, lbf, hf, max_lb)
    drawn, prem, to_target, debt_dust = debt_to_liquidate(ds, prem_ray, idx, tdv_ray, ddec, dunit, dprice,
                                               cover, cf, lb, hf, thf)
    cshares = collateral_to_liquidate(hub, cunit, cprice, drawn, prem, idx, dunit, dprice, lb)
    branch = 'normal'
    coll_dust = False
    if cshares < supplied_shares:
        rem = hub.previewRemoveByShares(supplied_shares - cshares)
        coll_dust = to_value(rem, cdec, cprice) < DUST
    if cshares > supplied_shares or (coll_dust and drawn < ds):
        branch = 'collateral-cap' if cshares > supplied_shares else 'collateral-dust'
        cshares = supplied_shares
        debt_ray = cdiv(hub.previewAddByShares(cshares) * (cprice * dunit * BPS * RAY),
                        dprice * cunit * lb)
        if debt_ray <= prem_ray:
            prem = min(round_ray_up(debt_ray), prem_ray)
            drawn = 0
        else:
            prem = prem_ray
            drawn = cdiv(debt_ray - prem, idx)
            if drawn > ds:
                drawn = ds
                cshares = min(collateral_to_liquidate(hub, cunit, cprice, drawn, prem, idx,
                                                      dunit, dprice, lb), supplied_shares)
    elif debt_dust:
        branch = 'debt-dust'
    paid = ray_mul_up(drawn, idx) + from_ray_up(prem)
    if cover < paid:
        raise MustNotLeaveDust(paid)
    to_liq = cshares - cdiv(cshares * (fee * (lb - BPS)), lb * BPS)
    return dict(bonus=lb, drawn_shares=drawn, prem_ray=prem, paid=paid, coll_shares=cshares,
                coll_to_liquidator=to_liq, coll_removed=hub.previewRemoveByShares(cshares),
                branch=branch, debt_to_target_ray=to_target)


if __name__ == '__main__':
    print('aave-risk/_v4ref.py: reference implementation, no properties.')
