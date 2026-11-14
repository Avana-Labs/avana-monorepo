# SPDX-License-Identifier: LicenseRef-BUSL
# Copyright (c) 2026 Avana Labs
# Contains a port of Aave V4 code (aave/aave-v4 commit a3ef63e, (c) Aave Labs), used only in test environments under
# the Aave V4 license in LICENSES/LicenseRef-BUSL-AaveV4.md; see THIRD_PARTY_LICENSES.md.
"""Aave V4 Hub and Spoke subset, ported from a3ef63ea6415d25237a9775bf66e76e9993561c2.

Ported line for line (rounding and order of operations):
  Hub.add/remove/draw/restore/reportDeficit/eliminateDeficit/refreshPremium, _validateDraw
  AssetLogic (drawn index accrual, totalAddedAssets, added-share conversions)
  Spoke.supply/withdraw/borrow/repay/setUsingAsCollateral/liquidationCall,
  Spoke._processUserAccountData (health factor, risk premium), _notifyRiskPremiumUpdate
  UserPositionUtils (calculatePremiumDelta, calculateRestoreAmount, getDebt)
  LiquidationLogic (calculateLiquidationBonus, _calculateLiquidationAmounts,
  _calculateDebtToLiquidate, _calculateDebtToTargetHealthFactor,
  _calculateCollateralToLiquidate, _liquidateCollateral, _liquidateDebt,
  _evaluateDeficit, notifyReportDeficit)

Simplifications (stated in README): liquidityFee = 0 and nothing swept, so
totalAddedAssets = liquidity + owed + deficit; each debt asset's drawn rate follows Aave V4's kinked
utilization curve (AssetInterestRateStrategy.calculateInterestRate, Q-408), recomputed after every Hub
entry point as AssetLogic.updateDrawnRate does; riskPremiumThreshold is left at its maximum (Q-141 is
covered elsewhere); no position managers (the proxy is the account, Q-064).
"""
from .mathlib import (RAY, BPS, WAD, HF_LIQ, DUST_VALUE, U120, U200, chk, cdiv, mul_div,
                      ray_mul_up, ray_mul_down, ray_div_up, ray_div_down, from_ray_up, to_ray,
                      round_ray_up, percent_mul_up, percent_mul_down, bps_to_wad, div_up,
                      to_shares_down, to_shares_up, to_assets_down, to_assets_up, to_value,
                      linear_interest)

MAX_CAP = 2 ** 40 - 1   # MAX_ALLOWED_SPOKE_CAP (no cap)


class AaveError(Exception):
    pass


def req(cond, err):
    if not cond:
        raise AaveError(err)


# ----------------------------------------------------------------------------- Hub

class SpokeData:
    def __init__(self, add_cap=MAX_CAP, draw_cap=0):
        self.added_shares = 0
        self.drawn_shares = 0
        self.premium_shares = 0
        self.premium_offset_ray = 0
        self.deficit_ray = 0
        self.add_cap = add_cap
        self.draw_cap = draw_cap
        self.active = True
        self.halted = False


BPS_TO_RAY = 10 ** 23


def curve_rate(ir, liquidity, drawn, swept=0):
    """AssetInterestRateStrategy.calculateInterestRate, line for line (deficit is not an input)."""
    base, before, after, opt = ir
    req(100 <= opt <= 9900, "InvalidOptimalUsageRatio")
    req(base + before + after <= 1000_00, "InvalidMaxDrawnRate")
    rate = base * BPS_TO_RAY
    if drawn == 0:
        return rate
    u = ray_div_up(drawn, liquidity + drawn + swept)
    o = opt * BPS_TO_RAY
    if u <= o:
        return rate + ray_div_up(ray_mul_up(before * BPS_TO_RAY, u), o)
    return rate + before * BPS_TO_RAY + ray_div_up(ray_mul_up(after * BPS_TO_RAY, u - o), RAY - o)


class Asset:
    def __init__(self, token, decimals, drawn_rate_ray=0, drawn_index=RAY, ir=None):
        self.token, self.decimals = token, decimals
        self.liquidity = 0
        self.added_shares = 0
        self.drawn_shares = 0
        self.premium_shares = 0
        self.premium_offset_ray = 0
        self.deficit_ray = 0
        self.drawn_index = drawn_index
        self.drawn_rate = drawn_rate_ray
        self.ir = ir                 # (baseDrawnRate, rateGrowthBeforeOptimal, rateGrowthAfterOptimal, optimal) bps
        self.rate_index = drawn_index
        if ir is not None:
            self.drawn_rate = ir[0] * BPS_TO_RAY
        self.last_update = 0
        self.spokes = {}


def premium_ray(premium_shares, offset_ray, idx):
    v = premium_shares * idx - offset_ray
    req(v >= 0, "SafeCastOverflowedIntToUint")
    return v


class Hub:
    def __init__(self, clock, ledger, addr="hub"):
        self.clock, self.ledger, self.addr = clock, ledger, addr
        self.assets = {}

    # --- AssetLogic
    def drawn_index(self, a):
        if a.last_update == self.clock.now or (a.drawn_shares == 0 and a.premium_shares == 0):
            return a.drawn_index
        return ray_mul_up(a.drawn_index, linear_interest(a.drawn_rate, self.clock.now - a.last_update))

    def accrue(self, a):
        if a.last_update == self.clock.now:
            return
        a.drawn_index = chk(self.drawn_index(a), U120, "uint120 drawnIndex")
        a.last_update = self.clock.now

    def update_rate(self, a):
        """AssetLogic.updateDrawnRate: rate from the stored index after the action (no-op without a curve)."""
        if a.ir is not None:
            a.drawn_rate = chk(curve_rate(a.ir, a.liquidity, ray_mul_up(a.drawn_shares, a.drawn_index)), 2 ** 96,
                               "uint96 drawnRate")
            a.rate_index = a.drawn_index     # ghost: the index the rate was computed at (an accrue alone moves the index)

    def total_added_assets(self, a):
        idx = self.drawn_index(a)
        owed_ray = a.drawn_shares * idx + premium_ray(a.premium_shares, a.premium_offset_ray, idx) + a.deficit_ray
        return a.liquidity + from_ray_up(owed_ray)

    def preview_add_by_assets(self, aid, x):
        a = self.assets[aid]
        return to_shares_down(x, self.total_added_assets(a), a.added_shares)

    def preview_add_by_shares(self, aid, s):
        a = self.assets[aid]
        return to_assets_up(s, self.total_added_assets(a), a.added_shares)

    def preview_remove_by_shares(self, aid, s):
        a = self.assets[aid]
        return to_assets_down(s, self.total_added_assets(a), a.added_shares)

    def shares_equal_assets(self, aid):
        a = self.assets[aid]
        return self.total_added_assets(a) == a.added_shares

    def spoke_owed(self, a, sd):
        idx = self.drawn_index(a)
        drawn = ray_mul_up(sd.drawn_shares, idx)
        prem = from_ray_up(premium_ray(sd.premium_shares, sd.premium_offset_ray, idx))
        return drawn + prem

    # --- Hub entry points (spoke = caller name)
    def _sd(self, a, spoke):
        req(spoke in a.spokes, "SpokeNotActive")
        return a.spokes[spoke]

    def add(self, aid, spoke, amount):
        a = self.assets[aid]
        sd = self._sd(a, spoke)
        self.accrue(a)
        req(amount > 0, "InvalidAmount")
        req(sd.active, "SpokeNotActive")
        req(not sd.halted, "SpokeHalted")
        if sd.add_cap != MAX_CAP:
            req(sd.add_cap * 10 ** a.decimals >= self.preview_add_by_shares(aid, sd.added_shares) + amount,
                "AddCapExceeded")
        liquidity = a.liquidity + amount
        req(self.ledger.balance(a.token, self.addr) >= liquidity, "InsufficientTransferred")
        shares = chk(to_shares_down(amount, self.total_added_assets(a), a.added_shares), U120, "uint120")
        req(shares > 0, "InvalidShares")
        a.added_shares += shares
        sd.added_shares += shares
        a.liquidity = chk(liquidity, U120, "uint120 liquidity")
        self.update_rate(a)
        return shares

    def remove(self, aid, spoke, amount, to, transfer):
        a = self.assets[aid]
        sd = self._sd(a, spoke)
        self.accrue(a)
        req(amount > 0, "InvalidAmount")
        req(to != self.addr, "InvalidAddress")
        req(sd.active, "SpokeNotActive")
        req(not sd.halted, "SpokeHalted")
        req(amount <= a.liquidity, "InsufficientLiquidity")
        shares = to_shares_up(amount, self.total_added_assets(a), a.added_shares)
        req(shares <= sd.added_shares, "underflow")
        a.added_shares -= shares
        sd.added_shares -= shares
        a.liquidity -= amount
        self.update_rate(a)
        transfer(a.token, self.addr, to, amount)
        return shares

    def draw(self, aid, spoke, amount, to, transfer):
        a = self.assets[aid]
        sd = self._sd(a, spoke)
        self.accrue(a)
        req(to != self.addr, "InvalidAddress")
        req(amount > 0, "InvalidAmount")
        req(sd.active, "SpokeNotActive")
        req(not sd.halted, "SpokeHalted")
        owed = self.spoke_owed(a, sd)
        req(sd.draw_cap == MAX_CAP or
            sd.draw_cap * 10 ** a.decimals >= owed + amount + from_ray_up(sd.deficit_ray), "DrawCapExceeded")
        req(amount <= a.liquidity, "InsufficientLiquidity")
        ds = chk(ray_div_up(amount, a.drawn_index), U120, "uint120")
        a.drawn_shares += ds
        sd.drawn_shares += ds
        a.liquidity -= amount
        self.update_rate(a)
        transfer(a.token, self.addr, to, amount)
        return ds

    def _apply_premium_delta(self, a, sd, delta):
        sh, off, restored = delta
        for obj in (a, sd):
            before = premium_ray(obj.premium_shares, obj.premium_offset_ray, a.drawn_index)
            obj.premium_shares += sh
            obj.premium_offset_ray += off
            req(obj.premium_shares >= 0, "premium shares underflow")
            after = premium_ray(obj.premium_shares, obj.premium_offset_ray, a.drawn_index)
            req(after + restored == before, "InvalidPremiumChange")

    def restore(self, aid, spoke, drawn_amount, delta):
        a = self.assets[aid]
        sd = self._sd(a, spoke)
        self.accrue(a)
        req(drawn_amount > 0 or delta[2] > 0, "InvalidAmount")
        req(sd.active, "SpokeNotActive")
        req(not sd.halted, "SpokeHalted")
        req(drawn_amount <= ray_mul_up(sd.drawn_shares, a.drawn_index), "SurplusDrawnRestored")
        ds = ray_div_down(drawn_amount, a.drawn_index)
        a.drawn_shares -= ds
        sd.drawn_shares -= ds
        self._apply_premium_delta(a, sd, delta)
        liquidity = a.liquidity + drawn_amount + from_ray_up(delta[2])
        req(self.ledger.balance(a.token, self.addr) >= liquidity, "InsufficientTransferred")
        a.liquidity = chk(liquidity, U120, "uint120 liquidity")
        self.update_rate(a)
        return ds

    def report_deficit(self, aid, spoke, drawn_amount, delta):
        a = self.assets[aid]
        sd = self._sd(a, spoke)
        self.accrue(a)
        req(drawn_amount > 0 or delta[2] > 0, "InvalidAmount")
        req(sd.active, "SpokeNotActive")
        req(drawn_amount <= ray_mul_up(sd.drawn_shares, a.drawn_index), "SurplusDrawnDeficitReported")
        ds = ray_div_down(drawn_amount, a.drawn_index)
        a.drawn_shares -= ds
        sd.drawn_shares -= ds
        self._apply_premium_delta(a, sd, delta)
        d = ds * a.drawn_index + delta[2]
        a.deficit_ray = chk(a.deficit_ray + d, U200, "uint200")
        sd.deficit_ray = chk(sd.deficit_ray + d, U200, "uint200")
        self.update_rate(a)
        return ds, from_ray_up(d)

    def eliminate_deficit(self, aid, caller_spoke, amount, covered_spoke):
        a = self.assets[aid]
        csd = self._sd(a, caller_spoke)
        cov = self._sd(a, covered_spoke)
        self.accrue(a)
        d_ray = cov.deficit_ray
        amt_ray = to_ray(amount) if amount < from_ray_up(d_ray) else d_ray
        req(amt_ray > 0, "InvalidAmount")
        elim = from_ray_up(amt_ray)
        shares = to_shares_up(elim, self.total_added_assets(a), a.added_shares)
        req(shares <= csd.added_shares, "underflow")
        a.added_shares -= shares
        csd.added_shares -= shares
        a.deficit_ray -= amt_ray
        cov.deficit_ray -= amt_ray
        self.update_rate(a)
        return shares, elim

    def refresh_premium(self, aid, spoke, delta):
        a = self.assets[aid]
        sd = self._sd(a, spoke)
        self.accrue(a)
        req(delta[2] == 0, "InvalidPremiumChange")
        self._apply_premium_delta(a, sd, delta)
        self.update_rate(a)


# ----------------------------------------------------------------------------- Spoke

class Reserve:
    def __init__(self, rid, aid, token, decimals, cf=0, max_lb=BPS, liq_fee=0, collateral_risk=0,
                 borrowable=False, receive_shares=False):
        self.rid, self.aid, self.token, self.decimals = rid, aid, token, decimals
        self.cf, self.max_lb, self.liq_fee, self.collateral_risk = cf, max_lb, liq_fee, collateral_risk
        self.borrowable, self.receive_shares = borrowable, receive_shares
        self.paused = False
        self.frozen = False


class UserPos:
    def __init__(self):
        self.supplied_shares = 0
        self.drawn_shares = 0
        self.premium_shares = 0
        self.premium_offset_ray = 0


class Status:
    def __init__(self):
        self.collateral = set()
        self.borrowing = set()
        self.risk_premium = 0


class Spoke:
    def __init__(self, hub, name, price_of, target_hf, hf_for_max_bonus, lb_factor, transfer):
        self.hub, self.name, self.price_of = hub, name, price_of
        self.target_hf, self.hf_for_max_bonus, self.lb_factor = target_hf, hf_for_max_bonus, lb_factor
        self.transfer = transfer
        self.reserves = {}
        self.manager = None          # LIQUIDATION_MANAGER of the liquidation-manager Spoke (Q-222)
        self.max_user_reserves = 2 ** 16
        self.pos = {}
        self.status = {}
        self.last_liquidation = None

    def up(self, user, rid):
        return self.pos.setdefault((user, rid), UserPos())

    def st(self, user):
        return self.status.setdefault(user, Status())

    def add_reserve(self, r):
        self.reserves[r.rid] = r

    # --- views
    def idx(self, r):
        return self.hub.drawn_index(self.hub.assets[r.aid])

    def premium_debt_ray(self, up, idx):
        return premium_ray(up.premium_shares, up.premium_offset_ray, idx)

    def user_debt(self, user, rid):
        """getUserTotalDebt: drawnShares.rayMulUp(idx) + premiumRay.fromRayUp()."""
        r = self.reserves[rid]
        up = self.up(user, rid)
        i = self.idx(r)
        return ray_mul_up(up.drawn_shares, i) + from_ray_up(self.premium_debt_ray(up, i))

    def supplied_assets(self, user, rid):
        r = self.reserves[rid]
        return self.hub.preview_remove_by_shares(r.aid, self.up(user, rid).supplied_shares)

    def account_data(self, user):
        st = self.st(user)
        tcv = 0
        avg = 0
        n_coll = 0
        tdv = 0
        n_borrow = 0
        info = []
        for rid in sorted(self.reserves, reverse=True):
            r = self.reserves[rid]
            up = self.up(user, rid)
            price = self.price_of(rid)
            if rid in st.collateral and r.cf > 0 and up.supplied_shares > 0:
                v = to_value(self.hub.preview_remove_by_shares(r.aid, up.supplied_shares), r.decimals, price)
                tcv += v
                info.append((r.collateral_risk, v))
                avg += r.cf * v
                n_coll += 1
            if rid in st.borrowing:
                i = self.idx(r)
                debt_ray = up.drawn_shares * i + self.premium_debt_ray(up, i)
                tdv += to_value(debt_ray, r.decimals, price)
                n_borrow += 1
        hf = mul_div(bps_to_wad(avg), RAY, tdv) if tdv > 0 else 2 ** 256 - 1
        avg_cf = bps_to_wad(avg) // tcv if tcv > 0 else 0
        info.sort(key=lambda kv: (kv[0], -kv[1]))
        tdv_plain = from_ray_up(tdv)
        left = tdv_plain
        rp = 0
        for risk, v in info:
            if left == 0:
                break
            v = min(v, left)
            rp += v * risk
            left -= v
        if left < tdv_plain:
            rp = div_up(rp, tdv_plain - left)
        return dict(hf=hf, tdv_ray=tdv, tcv=tcv, avg_cf=avg_cf, n_coll=n_coll, n_borrow=n_borrow, rp=rp)

    def health_factor(self, user):
        return self.account_data(user)["hf"]

    # --- premium helpers (UserPositionUtils)
    def premium_delta(self, up, taken, idx, rp, restored_ray):
        old_sh, old_off = up.premium_shares, up.premium_offset_ray
        prem = premium_ray(old_sh, old_off, idx)
        new_sh = percent_mul_up(up.drawn_shares - taken, rp)
        new_off = new_sh * idx - (prem - restored_ray)
        return (new_sh - old_sh, new_off - old_off, restored_ray)

    @staticmethod
    def apply_premium_delta(up, d):
        up.premium_shares = chk(up.premium_shares + d[0], U120, "uint120")
        up.premium_offset_ray += d[1]

    def _notify_rp(self, user, new_rp):
        st = self.st(user)
        if new_rp == 0 and st.risk_premium == 0:
            return
        st.risk_premium = new_rp
        for rid in sorted(st.borrowing, reverse=True):
            r = self.reserves[rid]
            up = self.up(user, rid)
            d = self.premium_delta(up, 0, self.idx(r), new_rp, 0)
            self.hub.refresh_premium(r.aid, self.name, d)
            self.apply_premium_delta(up, d)

    def _refresh_and_validate(self, user):
        ad = self.account_data(user)
        req(ad["hf"] >= HF_LIQ, "HealthFactorBelowThreshold")
        return ad

    # --- user entry points (caller must be onBehalfOf: no position managers, Q-064)
    def supply(self, caller, rid, amount, on_behalf):
        req(caller == on_behalf, "Unauthorized")
        r = self.reserves[rid]
        req(not r.paused, "ReservePaused")
        req(not r.frozen, "ReserveFrozen")
        self.transfer(r.token, caller, self.hub.addr, amount)
        sh = self.hub.add(r.aid, self.name, amount)
        up = self.up(on_behalf, rid)
        up.supplied_shares = chk(up.supplied_shares + sh, U120, "uint120")
        return sh

    def withdraw(self, caller, rid, amount, on_behalf):
        req(caller == on_behalf, "Unauthorized")
        r = self.reserves[rid]
        req(not r.paused, "ReservePaused")
        up = self.up(on_behalf, rid)
        amt = min(amount, self.hub.preview_remove_by_shares(r.aid, up.supplied_shares))
        sh = self.hub.remove(r.aid, self.name, amt, caller, self.transfer)
        req(sh <= up.supplied_shares, "underflow")
        up.supplied_shares -= sh
        if rid in self.st(on_behalf).collateral:
            rp = self._refresh_and_validate(on_behalf)["rp"]
            self._notify_rp(on_behalf, rp)
        return sh, amt

    def borrow(self, caller, rid, amount, on_behalf):
        req(caller == on_behalf, "Unauthorized")
        r = self.reserves[rid]
        req(not r.paused, "ReservePaused")
        req(not r.frozen, "ReserveFrozen")
        req(r.borrowable, "ReserveNotBorrowable")
        st0 = self.st(on_behalf)
        req(len(st0.collateral | st0.borrowing | {rid}) <= self.max_user_reserves, "MaximumUserReservesExceeded")
        ds = self.hub.draw(r.aid, self.name, amount, caller, self.transfer)
        up = self.up(on_behalf, rid)
        up.drawn_shares = chk(up.drawn_shares + ds, U120, "uint120")
        self.st(on_behalf).borrowing.add(rid)
        rp = self._refresh_and_validate(on_behalf)["rp"]
        self._notify_rp(on_behalf, rp)
        return ds

    def repay(self, caller, rid, amount, on_behalf):
        req(caller == on_behalf, "Unauthorized")
        r = self.reserves[rid]
        req(not r.paused, "ReservePaused")
        a = self.hub.assets[r.aid]
        i = self.hub.drawn_index(a)
        up = self.up(on_behalf, rid)
        drawn_debt = ray_mul_up(up.drawn_shares, i)
        prem_ray = self.premium_debt_ray(up, i)
        prem = from_ray_up(prem_ray)
        if amount >= drawn_debt + prem:
            dr, pr = drawn_debt, prem_ray
        elif amount < prem:
            dr, pr = 0, to_ray(amount)
        else:
            dr, pr = amount - prem, prem_ray
        restored_shares = ray_div_down(dr, i)
        d = self.premium_delta(up, restored_shares, i, self.st(on_behalf).risk_premium, pr)
        total = dr + from_ray_up(pr)
        self.transfer(r.token, caller, self.hub.addr, total)
        self.hub.restore(r.aid, self.name, dr, d)
        self.apply_premium_delta(up, d)
        up.drawn_shares -= restored_shares
        if up.drawn_shares == 0:
            self.st(on_behalf).borrowing.discard(rid)
        return restored_shares, total

    def set_using_as_collateral(self, caller, rid, using, on_behalf):
        req(caller == on_behalf, "Unauthorized")
        st = self.st(on_behalf)
        if (rid in st.collateral) == using:
            return
        r = self.reserves[rid]
        req(not r.paused, "ReservePaused")
        if using:
            req(not r.frozen, "ReserveFrozen")
            req(len(st.collateral | st.borrowing | {rid}) <= self.max_user_reserves, "MaximumUserReservesExceeded")
            st.collateral.add(rid)
        else:
            st.collateral.discard(rid)
            rp = self._refresh_and_validate(on_behalf)["rp"]
            self._notify_rp(on_behalf, rp)

    # --- liquidation (LiquidationLogic)
    def liquidation_bonus(self, hf, max_lb):
        if hf <= self.hf_for_max_bonus:
            return max_lb
        min_lb = percent_mul_down(max_lb - BPS, self.lb_factor) + BPS
        return min_lb + mul_div(max_lb - min_lb, HF_LIQ - hf, HF_LIQ - self.hf_for_max_bonus)

    def _debt_to_target(self, tdv_ray, dunit, dprice, cf, lb, hf):
        penalty = percent_mul_up(bps_to_wad(lb), cf)
        return mul_div(tdv_ray, dunit * (self.target_hf - hf), (self.target_hf - penalty) * (dprice * WAD), up=True)

    def _coll_to_liq(self, caid, cunit, cprice, drawn, prem_ray, idx, dunit, dprice, lb):
        debt_ray = drawn * idx + prem_ray
        c = mul_div(debt_ray, dprice * cunit * lb, dunit * cprice * BPS * RAY)
        return self.hub.preview_add_by_assets(caid, c)

    def liquidation_amounts(self, cr, dr, user, debt_to_cover, ad):
        up_c, up_d = self.up(user, cr.rid), self.up(user, dr.rid)
        supplied = up_c.supplied_shares
        idx = self.idx(dr)
        ds = up_d.drawn_shares
        prem_all = self.premium_debt_ray(up_d, idx)
        cunit, dunit = 10 ** cr.decimals, 10 ** dr.decimals
        cprice, dprice = self.price_of(cr.rid), self.price_of(dr.rid)
        hf = ad["hf"]
        lb = self.liquidation_bonus(hf, cr.max_lb)
        # _calculateDebtToLiquidate
        to_target = self._debt_to_target(ad["tdv_ray"], dunit, dprice, cr.cf, lb, hf)
        prem = min(round_ray_up(to_target), prem_all)
        if debt_to_cover < from_ray_up(prem):
            prem = to_ray(debt_to_cover)
        drawn = 0
        if prem == prem_all and prem < to_target:
            s_target = div_up(to_target - prem, idx)
            s_cover = mul_div(debt_to_cover - from_ray_up(prem), RAY, idx)
            drawn = min(s_target, s_cover, ds)
        remaining = (ds - drawn) * idx + prem_all - prem
        if drawn < ds and to_value(remaining, dr.decimals, dprice) < to_ray(DUST_VALUE):
            drawn, prem = ds, prem_all
        # _calculateCollateralToLiquidate
        cshares = self._coll_to_liq(cr.aid, cunit, cprice, drawn, prem, idx, dunit, dprice, lb)
        coll_dust = False
        if cshares < supplied:
            rem = self.hub.preview_remove_by_shares(cr.aid, supplied - cshares)
            coll_dust = to_value(rem, cr.decimals, cprice) < DUST_VALUE
        branch = "normal"
        if cshares > supplied or (coll_dust and drawn < ds):
            branch = "collateral-cap" if cshares > supplied else "collateral-dust"
            cshares = supplied
            debt_ray = mul_div(self.hub.preview_add_by_shares(cr.aid, cshares),
                               cprice * dunit * BPS * RAY, dprice * cunit * lb, up=True)
            if debt_ray <= prem_all:
                prem = min(round_ray_up(debt_ray), prem_all)
                drawn = 0
            else:
                prem = prem_all
                drawn = div_up(debt_ray - prem, idx)
                if drawn > ds:
                    drawn = ds
                    cshares = min(self._coll_to_liq(cr.aid, cunit, cprice, drawn, prem, idx, dunit, dprice, lb),
                                  supplied)
        paid = ray_mul_up(drawn, idx) + from_ray_up(prem)
        req(debt_to_cover >= paid, "MustNotLeaveDust")
        to_liquidator = cshares - mul_div(cshares, cr.liq_fee * (lb - BPS), lb * BPS, up=True)
        return dict(lb=lb, drawn=drawn, prem=prem, cshares=cshares, to_liquidator=to_liquidator,
                    paid=paid, idx=idx, branch=branch, hf=hf)

    def preview_liquidation(self, coll_rid, debt_rid, user, debt_to_cover):
        cr, dr = self.reserves[coll_rid], self.reserves[debt_rid]
        ad = self.account_data(user)
        return self.liquidation_amounts(cr, dr, user, debt_to_cover, ad)

    def liquidation_call(self, caller, coll_rid, debt_rid, user, debt_to_cover, receive_shares):
        cr, dr = self.reserves[coll_rid], self.reserves[debt_rid]
        ad = self.account_data(user)
        st = self.st(user)
        up_c, up_d = self.up(user, coll_rid), self.up(user, debt_rid)
        # liquidation-manager Spoke (Q-222): only the manager, never receiveShares
        req(self.manager is None or caller == self.manager, "Unauthorized")
        req(self.manager is None or not receive_shares, "UnsupportedLiquidationCall")
        # _validateLiquidationCall
        req(user != caller, "SelfLiquidation")
        req(debt_to_cover > 0, "InvalidDebtToCover")
        req(not cr.paused and not dr.paused, "ReservePaused")
        req(up_c.supplied_shares > 0, "ReserveNotSupplied")
        req(up_d.drawn_shares > 0, "ReserveNotBorrowed")
        req(ad["hf"] < HF_LIQ, "HealthFactorNotBelowThreshold")
        req(cr.cf > 0 and coll_rid in st.collateral, "ReserveNotEnabledAsCollateral")
        if receive_shares:
            req(not cr.frozen and cr.receive_shares, "CannotReceiveShares")
        la = self.liquidation_amounts(cr, dr, user, debt_to_cover, ad)
        # _liquidateCollateral
        up_c.supplied_shares -= la["cshares"]
        removed = self.hub.preview_remove_by_shares(cr.aid, la["cshares"])
        if la["to_liquidator"] > 0:
            if receive_shares:
                self.up(caller, coll_rid).supplied_shares += la["to_liquidator"]
            else:
                amt = removed
                if la["to_liquidator"] < la["cshares"]:
                    amt = self.hub.preview_remove_by_shares(cr.aid, la["to_liquidator"])
                self.hub.remove(cr.aid, self.name, amt, caller, self.transfer)
        req(la["cshares"] == la["to_liquidator"], "fee shares unsupported in model (liquidationFee=0)")
        coll_empty = up_c.supplied_shares == 0
        # _liquidateDebt
        idx = la["idx"]
        d = self.premium_delta(up_d, la["drawn"], idx, st.risk_premium, la["prem"])
        drawn_amt = ray_mul_up(la["drawn"], idx)
        restore_amt = drawn_amt + from_ray_up(la["prem"])
        self.transfer(dr.token, caller, self.hub.addr, restore_amt)
        self.hub.restore(dr.aid, self.name, drawn_amt, d)
        self.apply_premium_delta(up_d, d)
        up_d.drawn_shares -= la["drawn"]
        debt_empty = False
        if up_d.drawn_shares == 0:
            st.borrowing.discard(debt_rid)
            debt_empty = True
        # _evaluateDeficit
        deficit = (coll_empty and ad["n_coll"] <= 1) and (not debt_empty or ad["n_borrow"] > 1)
        reported = 0
        if deficit:
            reported = self._notify_report_deficit(user)
        else:
            self._notify_rp(user, self.account_data(user)["rp"])
        la.update(removed=removed, restored=restore_amt, deficit=deficit, reported=reported,
                  received=la["to_liquidator"] and (removed if la["to_liquidator"] == la["cshares"] else None))
        self.last_liquidation = la
        return la

    def _notify_report_deficit(self, user):
        st = self.st(user)
        st.risk_premium = 0
        total = 0
        for rid in sorted(st.borrowing, reverse=True):
            r = self.reserves[rid]
            up = self.up(user, rid)
            i = self.idx(r)
            ds = up.drawn_shares
            prem = self.premium_debt_ray(up, i)
            d = self.premium_delta(up, ds, i, 0, prem)
            _sh, amt = self.hub.report_deficit(r.aid, self.name, ray_mul_up(ds, i), d)
            total += amt
            self.apply_premium_delta(up, d)
            up.drawn_shares -= ds
            st.borrowing.discard(rid)
        return total
