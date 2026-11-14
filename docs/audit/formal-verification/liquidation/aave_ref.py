"""Exact-integer port of Aave V4 liquidation sizing at the pinned commit
a3ef63ea6415d25237a9775bf66e76e9993561c2 (src/spoke/libraries/LiquidationLogic.sol,
src/hub/libraries/SharesMath.sol, src/spoke/libraries/SpokeUtils.sol, WadRayMath,
PercentageMath). Function and variable names follow the Solidity source line for line;
only the storage reads are replaced by arguments. Used as the reference semantics for
the Z3 lemmas of fv_liq_02 (each lemma is cross-checked on this port with Hypothesis)
and to replay counterexamples with real numbers.
"""
from __future__ import annotations

from dataclasses import dataclass

from _lib import BPS, RAY, VIRTUAL, WAD, ceil_div, from_ray_up, mul_div_down, mul_div_up, ray_mul_up, round_ray_up

HEALTH_FACTOR_LIQUIDATION_THRESHOLD = WAD
DUST_LIQUIDATION_THRESHOLD = 1000 * 10**26


class AaveRevert(Exception):
    pass


# ---------------------------------------------------------------- Hub share math (SharesMath, virtual 1e6)
def to_shares_down(assets, A, S):
    return mul_div_down(assets, S + VIRTUAL, A + VIRTUAL)


def to_shares_up(assets, A, S):
    return mul_div_up(assets, S + VIRTUAL, A + VIRTUAL)


def to_assets_down(shares, A, S):
    return mul_div_down(shares, A + VIRTUAL, S + VIRTUAL)


def to_assets_up(shares, A, S):
    return mul_div_up(shares, A + VIRTUAL, S + VIRTUAL)


def to_value(amount, decimals, price):  # SpokeUtils.toValue (WAD_DECIMALS = 18)
    return amount * price * 10 ** (18 - decimals)


def percent_mul_down(v, p):
    return v * p // BPS


def percent_mul_up(v, p):
    return ceil_div(v * p, BPS)


def calculate_liquidation_bonus(hf_for_max_bonus, bonus_factor, hf, max_lb):
    if hf <= hf_for_max_bonus:
        return max_lb
    min_lb = percent_mul_down(max_lb - BPS, bonus_factor) + BPS
    return min_lb + mul_div_down(max_lb - min_lb, HEALTH_FACTOR_LIQUIDATION_THRESHOLD - hf,
                                 HEALTH_FACTOR_LIQUIDATION_THRESHOLD - hf_for_max_bonus)


@dataclass
class Params:
    supplied_shares: int          # user collateral shares on the vault-token Hub asset
    coll_A: int                   # collateral Hub asset total added assets
    coll_S: int                   # collateral Hub asset added shares
    coll_decimals: int
    coll_price: int               # Pc (8 decimals)
    drawn_shares: int
    premium_debt_ray: int
    drawn_index: int              # >= RAY
    total_debt_value_ray: int
    debt_decimals: int
    debt_price: int               # Pdebt (8 decimals)
    debt_to_cover: int
    collateral_factor: int        # bps
    hf_for_max_bonus: int
    bonus_factor: int
    max_lb: int
    target_hf: int
    hf: int
    liquidation_fee: int = 0


def debt_to_target_hf(p: Params, lb: int, debt_unit: int) -> int:
    liquidation_penalty = percent_mul_up(lb * (WAD // BPS), p.collateral_factor)  # bpsToWad().percentMulUp(cf)
    return mul_div_up(p.total_debt_value_ray, debt_unit * (p.target_hf - p.hf),
                      (p.target_hf - liquidation_penalty) * (p.debt_price * WAD))


def calculate_debt_to_liquidate(p: Params, lb: int, debt_unit: int):
    debt_ray_to_target = debt_to_target_hf(p, lb, debt_unit)
    premium_to_liq = min(round_ray_up(debt_ray_to_target), p.premium_debt_ray)
    if p.debt_to_cover < from_ray_up(premium_to_liq):
        premium_to_liq = p.debt_to_cover * RAY
    drawn_to_liq = 0
    if premium_to_liq == p.premium_debt_ray and premium_to_liq < debt_ray_to_target:
        drawn_to_target = ceil_div(debt_ray_to_target - premium_to_liq, p.drawn_index)  # MathUtils.divUp
        drawn_to_cover = mul_div_down(p.debt_to_cover - from_ray_up(premium_to_liq), RAY, p.drawn_index)
        drawn_to_liq = min(drawn_to_target, drawn_to_cover, p.drawn_shares)
    debt_ray_remaining = (p.drawn_shares - drawn_to_liq) * p.drawn_index + p.premium_debt_ray - premium_to_liq
    leaves_debt_dust = drawn_to_liq < p.drawn_shares and \
        to_value(debt_ray_remaining, p.debt_decimals, p.debt_price) < DUST_LIQUIDATION_THRESHOLD * RAY
    if leaves_debt_dust:
        drawn_to_liq = p.drawn_shares
        premium_to_liq = p.premium_debt_ray
    return drawn_to_liq, premium_to_liq


def collateral_to_liquidate(p: Params, drawn_to_liq, premium_to_liq, lb, coll_unit, debt_unit):
    debt_ray = drawn_to_liq * p.drawn_index + premium_to_liq
    coll = mul_div_down(debt_ray, p.debt_price * coll_unit * lb, debt_unit * p.coll_price * BPS * RAY)
    return to_shares_down(coll, p.coll_A, p.coll_S)   # previewAddByAssets


def calculate_liquidation_amounts(p: Params):
    """Returns (collateralSharesToLiquidate, collateralSharesToLiquidator, drawnShares, premiumRay, lb, branch)."""
    coll_unit = 10 ** p.coll_decimals
    debt_unit = 10 ** p.debt_decimals
    lb = calculate_liquidation_bonus(p.hf_for_max_bonus, p.bonus_factor, p.hf, p.max_lb)
    drawn, prem = calculate_debt_to_liquidate(p, lb, debt_unit)
    cshares = collateral_to_liquidate(p, drawn, prem, lb, coll_unit, debt_unit)
    branch = "target"
    leaves_coll_dust = False
    if cshares < p.supplied_shares:
        remaining = to_assets_down(p.supplied_shares - cshares, p.coll_A, p.coll_S)  # previewRemoveByShares
        leaves_coll_dust = to_value(remaining, p.coll_decimals, p.coll_price) < DUST_LIQUIDATION_THRESHOLD
    if cshares > p.supplied_shares or (leaves_coll_dust and drawn < p.drawn_shares):
        branch = "all-collateral"
        cshares = p.supplied_shares
        debt_ray = mul_div_up(to_assets_up(cshares, p.coll_A, p.coll_S),   # previewAddByShares
                              p.coll_price * debt_unit * BPS * RAY,
                              p.debt_price * coll_unit * lb)
        if debt_ray <= p.premium_debt_ray:
            prem = min(round_ray_up(debt_ray), p.premium_debt_ray)
            drawn = 0
        else:
            prem = p.premium_debt_ray
            drawn = ceil_div(debt_ray - prem, p.drawn_index)  # MathUtils.divUp
            if drawn > p.drawn_shares:
                branch = "all-collateral-all-debt"
                drawn = p.drawn_shares
                cshares = min(collateral_to_liquidate(p, drawn, prem, lb, coll_unit, debt_unit), p.supplied_shares)
    if not p.debt_to_cover >= ray_mul_up(drawn, p.drawn_index) + from_ray_up(prem):
        raise AaveRevert("MustNotLeaveDust")
    to_liquidator = cshares - mul_div_up(cshares, p.liquidation_fee * (lb - BPS), lb * BPS)
    return cshares, to_liquidator, drawn, prem, lb, branch


def liquidation_call(p: Params):
    """Validation plus amounts; returns D (debt asset pulled), c (collateral assets to the liquidator),
    the shares removed from the user, the bonus and the branch taken."""
    if p.debt_to_cover == 0:
        raise AaveRevert("InvalidDebtToCover")
    if p.supplied_shares == 0:
        raise AaveRevert("ReserveNotSupplied")
    if p.drawn_shares == 0:
        raise AaveRevert("ReserveNotBorrowed")
    if not p.hf < HEALTH_FACTOR_LIQUIDATION_THRESHOLD:
        raise AaveRevert("HealthFactorNotBelowThreshold")
    if p.collateral_factor == 0:
        raise AaveRevert("ReserveNotEnabledAsCollateral")
    cshares, to_liq, drawn, prem, lb, branch = calculate_liquidation_amounts(p)
    D = ray_mul_up(drawn, p.drawn_index) + from_ray_up(prem)                 # _liquidateDebt amountToRestore
    removed = to_assets_down(cshares, p.coll_A, p.coll_S)                       # previewRemoveByShares
    c = removed if to_liq == cshares else to_assets_down(to_liq, p.coll_A, p.coll_S)
    return dict(D=D, c=c if to_liq > 0 else 0, shares=cshares, lb=lb, branch=branch,
                drawn=drawn, prem=prem, user_coll_empty=(p.supplied_shares - cshares == 0),
                user_debt_empty=(p.drawn_shares - drawn == 0))


def evaluate_deficit(coll_empty: bool, debt_empty: bool, active_collateral_count: int, borrow_count: int) -> bool:
    if not coll_empty or active_collateral_count > 1:
        return False
    return (not debt_empty) or borrow_count > 1


# ---------------------------------------------------------------- account state and the Lens liquidation preview
LENS_DUST_MARGIN_BPS = 500  # 2.17 constant (REQ-LENS-028)


def get_user_total_debt(drawn_shares, premium_debt_ray, drawn_index):
    """Spoke.getUserTotalDebt: drawnShares.rayMulUp(drawnIndex) + premiumDebtRay.fromRayUp()."""
    return ray_mul_up(drawn_shares, drawn_index) + from_ray_up(premium_debt_ray)


def repay_restore(drawn_shares, premium_debt_ray, drawn_index, amount):
    """Spoke.repay on one position: UserPositionUtils.calculateRestoreAmount, premium first, then
    restoredShares = drawnDebtRestored.rayDivDown(drawnIndex). Returns (drawnShares', premiumDebtRay')."""
    drawn_debt = ray_mul_up(drawn_shares, drawn_index)
    premium_debt = from_ray_up(premium_debt_ray)
    if amount >= drawn_debt + premium_debt:
        return 0, 0
    if amount < premium_debt:
        return drawn_shares, premium_debt_ray - amount * RAY
    restored_shares = (amount - premium_debt) * RAY // drawn_index
    return drawn_shares - restored_shares, 0


def account(supplied_shares, coll_price, coll_decimals, collateral_factor, drawn_shares, premium_debt_ray,
            drawn_index, debt_price, debt_decimals, debt_to_cover, other_debt_value_ray=0,
            coll_A=10**30, coll_S=10**30, max_lb=10_500, bonus_factor=4000,
            hf_for_max_bonus=9 * 10**17, target_hf=11 * 10**17, liquidation_fee=0) -> Params:
    """Params with the health factor and total debt value computed as Spoke._calculateUserAccountData does
    for an account whose only collateral is the seized market (other debt reserves enter by value)."""
    coll_value = to_value(to_assets_down(supplied_shares, coll_A, coll_S), coll_decimals, coll_price)
    debt_value_ray = to_value(drawn_shares * drawn_index + premium_debt_ray, debt_decimals, debt_price) \
        + other_debt_value_ray
    hf = mul_div_down(collateral_factor * coll_value * (WAD // BPS), RAY, debt_value_ray)
    return Params(supplied_shares=supplied_shares, coll_A=coll_A, coll_S=coll_S, coll_decimals=coll_decimals,
                  coll_price=coll_price, drawn_shares=drawn_shares, premium_debt_ray=premium_debt_ray,
                  drawn_index=drawn_index, total_debt_value_ray=debt_value_ray, debt_decimals=debt_decimals,
                  debt_price=debt_price, debt_to_cover=debt_to_cover, collateral_factor=collateral_factor,
                  hf_for_max_bonus=hf_for_max_bonus, bonus_factor=bonus_factor, max_lb=max_lb,
                  target_hf=target_hf, hf=hf, liquidation_fee=liquidation_fee)


def lens_units_seized(p: Params, drawn, prem, lb):
    """REQ-LENS-029 as written: Aave's _calculateCollateralToLiquidate on the drawnShares and premiumDebtRay the
    sizing returns, capped by the supplied shares, less the liquidation-fee part; units = previewRemoveByShares."""
    coll_unit, debt_unit = 10 ** p.coll_decimals, 10 ** p.debt_decimals
    assets = mul_div_down(drawn * p.drawn_index + prem, p.debt_price * coll_unit * lb,
                          debt_unit * p.coll_price * BPS * RAY)
    shares = min(to_shares_down(assets, p.coll_A, p.coll_S), p.supplied_shares)
    to_liq = shares - mul_div_up(shares, p.liquidation_fee * (lb - BPS), lb * BPS)
    return to_assets_down(to_liq, p.coll_A, p.coll_S)


def lens_preview(p: Params, is_gho: bool, margin_bps: int = LENS_DUST_MARGIN_BPS):
    """previewLiquidation sizing (REQ-LENS-017), debtToCover (REQ-LENS-028) and expectedUnitsSeized
    (REQ-LENS-029). The compiled sizing is Aave's own code, run with the account's whole debt as the cap."""
    total = get_user_total_debt(p.drawn_shares, p.premium_debt_ray, p.drawn_index)
    r = liquidation_call(Params(**{**p.__dict__, "debt_to_cover": total}))
    d = r["D"]
    near = to_value(total - d, p.debt_decimals, p.debt_price) * BPS < DUST_LIQUIDATION_THRESHOLD * (BPS + margin_bps)
    coll_limited = r["shares"] == p.supplied_shares
    # Final REQ-LENS-028: the margined whole debt for a GHO reserve, a whole-debt repayment, a sizing that seizes all
    # the supplied shares, or a remainder inside the margin; expectedDebtRepaid otherwise. `old_debt_to_cover` is the
    # text before FV-LIQ-F-13/F-14 (unmargined whole debt, no collateral-limited case), kept for the mutant checks.
    whole = is_gho or d == total or near or coll_limited
    x = (total * (BPS + margin_bps) + BPS - 1) // BPS if whole else d
    x_old = total if (is_gho or d == total or near) else d
    return dict(expected_debt_repaid=d, drawn=r["drawn"], prem=r["prem"], lb=r["lb"], branch=r["branch"],
                units=lens_units_seized(p, r["drawn"], r["prem"], r["lb"]), debt_to_cover=x, old_debt_to_cover=x_old,
                total=total, near=near, collateral_limited=coll_limited, aave=r)
