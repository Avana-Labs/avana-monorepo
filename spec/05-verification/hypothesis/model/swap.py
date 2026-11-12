# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""LPVaultSwap, its SettlementMath, the swap routes into the debt asset, the flash liquidation helper, the Aave V3
flash source of repay with collateral, pending settlement, the caller shortfall top-up, the PayoutEscrow for failed
payouts, keeper shortfall reports, and repay with collateral (2.11, 2.12, 2.13). There is no settlement budget (Q-397).

Every liquidation is funded by its caller (Q-404): LPVaultSwap pulls debtToCover from the caller and takes no flash
loan. With funding="flash" the caller goes through the flash liquidation helper (REQ-HELPER-004..008): the helper
borrows the debt asset from the Aave V3 Pool, funds liquidate, and repays the Pool from keeperOut plus a top-up from
the caller. LPVaultSwap swaps the released pool tokens over the market's swap routes straight into that asset and pays
Avana's fee and the caller in that same asset. Formulas follow SPEC-LIQ-001…020 and SPEC-SET-001…006
with their rounding directions, in debt units (10^dd per unit of the debt asset, priced at Pdebt). Every amount
received is measured by balance delta (Q-271). Mixed into `System` (avana.py).
"""
import copy

from .mathlib import WAD, RAY, BPS, U256, cdiv, mul_div
from .tokens import DECIMALS
from .const import (GHO, HUB, LPVAULT, COLL, ADAPTER, SWAP, FEE_RECIPIENT, FLASH_SOURCE, DEX, ESCROW, COV,
                    CDP, GHO_RID, DEBT_RIDS, PAUSED, REVERTS, AvanaError,
                    need)

PGHO = 10 ** 8


class ProbeResult(Exception):
    """reportRecoveryShortfall runs the liquidation inside a call that always reverts with its result (Q-251)."""

    def __init__(self, R, min_rec):
        super().__init__(f"probe R={R} minRec={min_rec}")
        self.R, self.min_rec = R, min_rec


def flash_fee(amount, fee_bps):
    """Aave V3 Pool flash premium: ceil(amount x FLASHLOAN_PREMIUM_TOTAL / 10^4) of the borrowed asset."""
    return cdiv(amount * fee_bps, BPS)


def scaled(v_wad, dd):
    """A WAD-denominated launch value expressed in an asset with dd decimals (about the same dollar amount)."""
    return v_wad * 10 ** dd // WAD


class SwapMixin:
    # ------------------------------------------------------------------ SettlementMath
    def leg_prices(self, mk):
        """Capped 8-decimal leg prices the LPOracle uses (SPEC-LIQ-012). A GHO leg is priced like any other
        stable, from its GHO/USD feed capped at $1 (SPEC-ORC-004, REQ-ORACLE-052); Pgho is only GHO's price as
        a debt asset."""
        lp = mk.oracle.leg_prices(self.now())
        if lp is None:
            lp = (min(self.prices[mk.t0], 10 ** 8), min(self.prices[mk.t1], 10 ** 8))
        return {mk.t0: lp[0], mk.t1: lp[1]}

    @staticmethod
    def unit_debt(price, dec, p_debt, dd):
        """One raw unit of a token valued in debt units, rounded up (SPEC-LIQ-005)."""
        return cdiv(price * 10 ** dd, 10 ** dec * p_debt)

    @staticmethod
    def unit_gho(price, dec):
        """One raw unit valued in GHO, rounded up (SPEC-LIQ-005 with GHO debt)."""
        return cdiv(price * 10 ** 18, 10 ** dec * PGHO)

    def vt_value_debt(self, m, units, price, p_debt, dd):
        """SPEC-LIQ-004: V = mulDiv(c·Pc, 10^dd, 10^dv·Pdebt), down."""
        return units * price * 10 ** dd // (10 ** self.markets[m].d * p_debt)

    def units_allowance(self, mk, T, p_debt, dd):
        """U of SPEC-LIQ-005: one raw unit of each released token in debt units; a token that is T counts 1."""
        lp = self.leg_prices(mk)
        return sum(1 if t == T else self.unit_debt(lp[t], DECIMALS[t], p_debt, dd) for t in (mk.t0, mk.t1))

    def rounding_allowance(self, dd):
        """floorRoundingAllowance of a debt reserve: about $1 of the asset (10^18 GHO, 10^6 USDC)."""
        return scaled(self.p.floor_rounding_allowance, dd)

    def eff_slippage(self, b_net, costs_bps=0):
        """SPEC-LIQ-003: no buy leg and no premium term (costs_bps is 0 in a liquidation, Q-404)."""
        lhs, rhs = b_net * BPS, (BPS + costs_bps) * BPS
        if lhs <= rhs:
            return 0
        return min(self.p.slippage_bps, BPS * (lhs - rhs) // lhs)

    def min_rec(self, V, s, U, eps):
        """SPEC-LIQ-005: minRec = max(0, ⌈V(10⁴ − s)/10⁴⌉ − U − ε), in debt units."""
        return max(0, cdiv(V * (BPS - s), BPS) - U - eps)

    def min_gho(self, V, s, U):
        """SPEC-LIQ-005 for a GHO debt reserve."""
        return self.min_rec(V, s, U, self.p.floor_rounding_allowance)

    def debt_price(self, T):
        """Market price of the debt asset the swap routes pay out (GHO at $1)."""
        return PGHO if T == GHO else self.prices[T]

    # ------------------------------------------------------------------ swap routes
    def _sell_quote(self, mk, route, token, amt, T=GHO):
        """Units of the debt asset T a swap route returns for `amt` of a pool token, or None when it is down. Both
        routes trade at the market price ratio less the route's fee; a haircut models a sandwich or a manipulated
        pool on that route."""
        up = mk.route_primary_up if route == "primary" else mk.route_backup_up
        if not up or token in self.ledger.paused or T in self.ledger.paused:
            return None
        recv = amt - self.ledger.fee_of(token, DEX, amt)
        dd = DECIMALS[T]
        out = recv * self.prices[token] * 10 ** dd // (10 ** DECIMALS[token] * self.debt_price(T))
        out = out * (BPS - self.p.dex_slippage_bps) // BPS
        out = out * (BPS - self.route_haircut.get((mk.idx, route), 0)) // BPS     # sandwich / manipulated pool
        return out

    def _convert(self, mk, amounts, s_leg, mode, probe=False, T=GHO, p_debt=PGHO, eps=None, dust_to=None):
        """Swap the pool tokens LPVaultSwap holds into the debt asset T with an oracle minimum on every leg
        (SPEC-LIQ-018); a token that is T is not swapped. A dust leg (Vleg <= Uleg, REQ-SWAP-121) is not swapped:
        it goes to `dust_to` and counts 0 toward R. Returns (route used, primary failed) or raises
        NoRouteAvailable."""
        dd = DECIMALS[T]
        eps = self.rounding_allowance(dd) if eps is None else eps
        lp = self.leg_prices(mk)
        legs = []
        for t, a in amounts.items():
            if a <= 0 or t == T:
                continue
            if a * lp[t] * 10 ** dd // (10 ** DECIMALS[t] * p_debt) <= self.unit_debt(lp[t], DECIMALS[t], p_debt, dd):
                self._send(t, SWAP, dust_to, a)
                continue
            legs.append((t, a))
        n = len(legs)
        routes = ("primary", "backup") if mode == "auto" else ("backup",)
        primary_failed = False
        if not legs:
            self.last_legs = []
            return ("primary" if mode == "auto" else "backup"), False
        for route in routes:
            plan = []
            ok = True
            for t, a in legs:
                d = DECIMALS[t]
                v_leg = a * lp[t] * 10 ** dd // (10 ** d * p_debt)
                min_out = 1 if probe else max(1, cdiv(v_leg * (BPS - s_leg), BPS)
                                              - self.unit_debt(lp[t], d, p_debt, dd) - eps // n)
                out = self._sell_quote(mk, route, t, a, T)
                if out is None or out < min_out:
                    ok = False
                    break
                plan.append((t, a, out, min_out))
            if not ok:
                if route == "primary":
                    primary_failed = True
                continue
            for t, a, out, _mo in plan:
                self._send(t, SWAP, DEX, a)
                self._send(T, DEX, SWAP, out)
            self.last_legs = plan
            return route, primary_failed
        raise AvanaError("NoRouteAvailable")

    # ------------------------------------------------------------------ liquidation
    def liquidate(self, keeper, wallet, m, debt_to_cover, rid=GHO_RID, spoke=CDP, funding="flash", route="auto",
                  deadline=None, min_payout=0, max_shortfall=0, gas=10 ** 7, extra_flash=0):
        """The one liquidation entry point, open to any caller that is not frozen (Q-404)."""
        return self.tx(self.locked, self._liquidate, keeper, wallet, m, debt_to_cover, rid, spoke, funding, route,
                       deadline, min_payout, max_shortfall, gas, extra_flash, False, False)

    def liquidate_permissionless(self, caller, wallet, m, debt_to_cover, rid=GHO_RID, spoke=CDP, funding="flash",
                                 deadline=None, min_payout=0, max_shortfall=0, extra_flash=0):
        """`liquidate` with PrimaryThenBackup by any caller: the same entry point and checks (Q-404)."""
        return self.tx(self.locked, self._liquidate, caller, wallet, m, debt_to_cover, rid, spoke, funding, "auto",
                       deadline, min_payout, max_shortfall, 10 ** 7, extra_flash, True, False)

    def _gate_liquidation(self, caller, pxo, mk, rid, spoke, permissionless, route):
        now = self.now()
        # no keeper check: the committed-operator registry gates no call (REQ-SWAP-001, Q-404)
        need(caller not in self.frozen_addresses, "AddressFrozen")
        need(rid in self.approved[spoke], "DebtReserveNotApproved")
        need(self.hub.shares_equal_assets(mk.aid), "HubSharesNotAssets")
        mk.oracle.poke(now)
        blk = mk.oracle.liquidation_block(now)
        need(blk is None, f"StalePrice(market {mk.idx}: {blk})")
        d = self.debts[rid]
        if d.oracle is not None:
            d.oracle.poke(now)
            need(d.oracle.evaluate(now)["liq_ok"], f"DebtPriceStale({rid})")
        hf = self.spokes[spoke].health_factor(pxo.addr)
        if any(x.oracle.in_grace(now) for x in self.account_markets(pxo.addr)) or mk.oracle.in_grace(now):
            need(hf < self.p.grace_hf, "RecoveryGrace")
        return hf

    def account_value_gho(self, proxy_addr, use_prices=None):
        """Collateral value and debt value of an account in GHO at the prices Aave uses (deficit-bound ghost)."""
        sp = self.spokes[self.proxy_of_addr[proxy_addr].spoke]
        coll = sum(self.vt_value_gho(mk.idx, sp.supplied_assets(proxy_addr, mk.rid), self.price_of(mk.rid))
                   for mk in self.account_markets(proxy_addr))
        debt = sum(sp.user_debt(proxy_addr, r) * self.price_of(r) * 10 ** (18 - self.debts[r].decimals) // PGHO
                   for r in self.account_debts(proxy_addr))
        return coll, debt

    def _liquidate(self, caller, wallet, m, X, rid, spoke, funding, route, deadline, min_payout, max_shortfall, gas,
                   extra_flash, permissionless, probe):
        now = self.now()
        need(deadline is None or now <= deadline, "DeadlineExpired")
        need(not self.hostile_swap, "LPVaultSwap does not settle")
        need(X > 0, "InvalidDebtToCover")
        pxo = self.proxies.get((wallet, spoke))
        need(pxo is not None, "NoProxy")
        mk, sp, d = self.markets[m], self.spokes[spoke], self.debts[rid]
        T, dd = d.asset, d.decimals                      # the debt asset: flash loan, settlement and payout
        hf = self._gate_liquidation(caller, pxo, mk, rid, spoke, permissionless, route)
        coll0, debt0 = self.account_value_gho(pxo.addr)
        deficit_before = max(0, debt0 - coll0)
        p_debt = self.price_of(rid)
        eps = self.rounding_allowance(dd)
        snap = {t: self.ledger.balance(t, SWAP) for t in self.TOKENS + (mk.vt,)}
        supply0 = dict(self.ledger.supply)
        F = phi = 0
        if funding == "flash":
            # the helper's pre-loan checks (REQ-HELPER-003, REQ-HELPER-005, SPEC-LIQ-015): liquidity, premium bound;
            # the loan goes to the caller's helper, never to LPVaultSwap (REQ-SWAP-012)
            F = X
            need(F <= self.flash_available(T), f"InsufficientFlashLiquidity({self.flash_available(T)})")
            phi = flash_fee(F, self.p.flash_fee_bps)
            need(phi * BPS <= self.p.max_flash_fee_bps * F, "FlashFeeTooHigh")
            self.ledger.mint(T, caller, F, "Aave V3 flash loan to the helper")
        # LPVaultSwap pulls X from the caller and measures Kf (REQ-SWAP-011)
        K = self._send(T, caller, SWAP, X)
        need(0 < K <= X, "FundingMismatch")
        shares0 = sp.up(pxo.addr, mk.rid).supplied_shares
        vt0 = self.ledger.balance(mk.vt, SWAP)
        a0 = self.ledger.balance(T, SWAP)
        la = sp.liquidation_call(SWAP, mk.rid, rid, pxo.addr, X, False)
        D = a0 - self.ledger.balance(T, SWAP)
        c = self.ledger.balance(mk.vt, SWAP) - vt0
        need(c > 0, "NothingSeized")
        need(D == la["restored"], "PaidMismatch")
        need(D <= K, "D above the caller funding")
        # the leftover Kf − D stays in LPVaultSwap's T balance and returns in keeperOut (SPEC-LIQ-017)
        # burnSeized, then Collateralization.settleSeizure (SPEC-BACK-007, SPEC-BACK-011)
        t_before_burn = self.ledger.balance(T, SWAP)
        supply_b = self.ledger.supply.get(mk.vt, 0)
        self.vt_burn(mk, SWAP, c)
        need(shares0 - sp.up(pxo.addr, mk.rid).supplied_shares == c, "DebitMismatch")
        need(supply_b - self.ledger.supply.get(mk.vt, 0) == c, "SupplyDropMismatch")
        reconciled = self._reconcile(pxo.addr, m, S=shares0)
        debits = self._allocate_seizure(pxo.addr, m, c)
        amounts = {mk.t0: 0, mk.t1: 0}
        fee_tags = {tid: (p.fees0, p.fees1) for tid, p in self.nfpm.positions.items()}
        for tid, u in debits:
            self._release(self.records[tid], u)
            got = self._unwind(tid, u, SWAP)
            for t in got:
                amounts[t] += got[t]
        Pc = self.price_of(mk.rid)
        V = self.vt_value_debt(m, c, Pc, p_debt, dd)
        U = self.units_allowance(mk, T, p_debt, dd)
        b_net = la["lb"]
        s = self.eff_slippage(b_net)
        mr = self.min_rec(V, s, U, eps)
        s_leg = min(9999, s + (min(self.p.max_shortfall_bps, max_shortfall * BPS // V) if V > 0 else 0))
        used, sell_primary_failed = self._convert(mk, amounts, s_leg, route, probe, T, p_debt, eps, caller)
        R = self.ledger.balance(T, SWAP) - t_before_burn
        if probe:
            raise ProbeResult(R, mr)
        phi_d = 0                                        # no premium term in a liquidation (SPEC-LIQ-007, Q-404)
        # Waterfall on R_f = max(R, minRec) (SPEC-LIQ-008/009), then the settlement gap of SPEC-SET-001; the caller's
        # top-up closes the floor gap, and the gap never exceeds it because Kf >= D. No budget exists (Q-397).
        floor_gap = max(0, mr - R)
        need(floor_gap <= max_shortfall, f"RecoveryBelowFloor({R}, {mr})")
        Rf = R + floor_gap
        S = max(0, Rf - D)
        A = min(max(0, V - D) * self.p.avana_fee_share_bps // BPS, S)
        gap = max(0, D + A - K - R)
        need(gap <= max_shortfall, "InsufficientProceeds")
        shortfall = max(floor_gap, gap)
        if shortfall:
            got = self._send(T, caller, SWAP, shortfall)
            need(got == shortfall, "FundingMismatch")
        R1 = R + shortfall
        keeper_out = (K + R1) - (D + A)
        need(keeper_out >= 0, "InsufficientProceeds")
        need(keeper_out >= min_payout, f"PayoutTooLow({keeper_out}, {min_payout})")
        # Avana's fee may go to the PayoutEscrow (Q-401); the caller's payout is a plain transfer, never escrowed
        fee_escrowed = self._pay_or_escrow(T, FEE_RECIPIENT, A)
        keeper_escrowed = 0
        if keeper_out:
            need((T, caller) not in self.gas_burners, "keeperOut transfer failed")
            self.ledger.transfer(T, SWAP, caller, keeper_out)
        for t, b in snap.items():
            need(self.ledger.balance(t, SWAP) == b, f"LPVaultSwap {t} delta != 0")
        top_up = 0
        if F:
            # the helper repays the lender from keeperOut, the unused shortfall budget it pulled beforehand
            # (REQ-HELPER-006) and a top-up from its caller (REQ-HELPER-007)
            top_up = max(0, F + phi - keeper_out - (max_shortfall - shortfall))
            self._send(T, caller, FLASH_SOURCE, F + phi)
            self.ledger.burn(T, FLASH_SOURCE, F, "flash repay by the helper")
        mk.last_routed = now
        coll1, debt1 = self.account_value_gho(pxo.addr)
        out = dict(keeper_out=keeper_out, permissionless=permissionless, eff_slip=s, s_leg=s_leg, U=U, D=D, X=X, c=c,
                   received=c, amounts=amounts, V=V, V_gho=self.vt_value_gho(m, c, Pc), min_rec=mr, R=R, shortfall=shortfall, route=used, gap=gap,
                   floor_gap=floor_gap, escrowed=dict(fee=fee_escrowed, keeper=keeper_escrowed),
                   flash=F, K=K, phi=phi, phi_d=phi_d, top_up=top_up, surplus=S, asset=T, p_debt=p_debt, eps=eps,
                   avana_fee=A, deficit=la["deficit"], reported=la["reported"], lb=b_net, branch=la["branch"],
                   hf_before=hf, price=Pc, debits=debits, fee_tags_before=fee_tags,
                   supply_before=supply0, funding=funding, proxy=pxo.addr, market=m, rid=rid, spoke=spoke,
                   reconciled=reconciled, deficit_before=deficit_before, deficit_after=max(0, debt1 - coll1),
                   coll_before=coll0, debt_before=debt0, hf_after=sp.health_factor(pxo.addr),
                   sell_primary_failed=sell_primary_failed)
        self.settlements.append(out)
        return out

    def flash_available(self, T):
        """IFlashSource.maxFlashLoan(T): the Aave V3 Pool's idle liquidity of T (flash_capacity, about $5M)."""
        return scaled(self.p.flash_capacity, DECIMALS[T])

    def _pay_or_escrow(self, t, to, amount):
        """PayoutEscrow, failed payouts only (Q-401): a payout the token refuses (modelled by gas_burners) is credited
        to the recipient in the escrow and claimed later; the liquidation never reverts on it."""
        if amount == 0:
            return 0
        if (t, to) not in self.gas_burners:
            try:
                self.ledger.transfer(t, SWAP, to, amount)
                return 0
            except Exception:          # the transfer's failure is caught, never reverts the liquidation
                pass
        b0 = self.ledger.balance(t, ESCROW)
        self.ledger.transfer(t, SWAP, ESCROW, amount)
        got = self.ledger.balance(t, ESCROW) - b0
        self.escrow_claimable[(t, to)] = self.escrow_claimable.get((t, to), 0) + got
        self.escrow_total[t] = self.escrow_total.get(t, 0) + got
        self.escrow_credited[(t, to)] = self.escrow_credited.get((t, to), 0) + got
        return got

    # ------------------------------------------------------------------ keeper shortfall report (Q-251)
    def report_shortfall(self, keeper, wallet, m, debt_to_cover, rid=GHO_RID, spoke=CDP, funding="flash"):
        def f():
            need(keeper in self.keepers and keeper not in self.frozen_addresses, "NotKeeper")
            snap = copy.deepcopy(self.__dict__, {id(self): self})
            res = None
            try:
                self.locked(self._liquidate, keeper, wallet, m, debt_to_cover, rid, spoke, funding, "auto", None, 0,
                            0, 10 ** 7, 0, False, True)
            except ProbeResult as pr:
                res = pr
            except REVERTS:
                res = None
            self.__dict__.clear()
            self.__dict__.update(snap)
            need(res is not None, "ProbeReverted")
            mk = self.markets[m]
            now = self.now()
            failed = res.R < res.min_rec
            need(failed, f"ShortfallNotShown({res.R}, {res.min_rec})")
            if failed:
                if not mk.reports or now - mk.reports[-1] > 3600 or mk.last_routed >= mk.reports[0]:
                    mk.reports = []
                mk.reports.append(now)          # an alert for monitoring only (Q-399); no on-chain trip
            return dict(R=res.R, min_rec=res.min_rec, failed=failed)
        return self.tx(f)

    # ------------------------------------------------------------------ pending settlement (Q-201, Q-211, Q-236)
    def settle_pending(self, caller, m):
        return self.tx(self.locked, self._settle_pending, caller, m)

    def _settle_pending(self, caller, m):
        need(not self.hostile_swap, "LPVaultSwap does not settle")
        mk = self.markets[m]
        p = self.pending[m]
        x = min(self.ledger.balance(mk.vt, SWAP), p["units"])
        need(x > 0, "NothingPending")
        snap = {t: self.ledger.balance(t, SWAP) for t in self.TOKENS + (mk.vt,)}
        self.vt_burn(mk, SWAP, x)
        need(self.ledger.supply.get(mk.vt, 0) + x <= self.credited_total(m) + p["units"], "SupplyDropMismatch")
        outs = {}
        for t in (mk.t0, mk.t1):
            outs[t] = p["amounts"][t] if x == p["units"] else mul_div(p["amounts"][t], x, p["units"])
        p["units"] -= x
        got = {}
        for t in (mk.t0, mk.t1):
            p["amounts"][t] -= outs[t]
            got[t] = self._send(t, COLL, SWAP, outs[t])
        # the recovered value goes to the Coverage Spoke of the market's (Hub, debt asset); every modelled market
        # settles pending units in GHO, its first debt reserve
        T, p_debt, dd = GHO, PGHO, DECIMALS[GHO]
        lp = self.leg_prices(mk)
        VP = sum(cdiv(a * lp[t] * 10 ** dd, 10 ** DECIMALS[t] * p_debt) for t, a in got.items())
        U = self.units_allowance(mk, T, p_debt, dd)
        sP = min(self.p.slippage_bps, 30)
        minp = self.min_rec(VP, sP, U, self.rounding_allowance(dd))
        g0 = self.ledger.balance(T, SWAP) - got.get(T, 0)
        self._convert(mk, got, sP, "auto", False, T, p_debt, dust_to=caller)
        R = self.ledger.balance(T, SWAP) - g0
        need(R >= minp, f"RecoveryBelowFloor({R}, {minp})")
        if R:
            self._send(T, SWAP, HUB, R)
            self.hub.add(T, COV[T], R)
            self.coverage_in[T] += R
        for t, b in snap.items():
            if t != mk.vt:
                need(self.ledger.balance(t, SWAP) == b, f"LPVaultSwap {t} delta != 0")
        return dict(units=x, gho=R, VP=VP, min_pending=minp, got=got)

    # ------------------------------------------------------------------ faulty LPVaultSwap versions
    def hostile_swap_seize(self, wallet, m, debt_to_cover, spoke=CDP):
        """An upgraded LPVaultSwap that liquidates with its own GHO and keeps the vault tokens (Q-201)."""
        def f():
            pxo = self.proxies.get((wallet, spoke))
            need(pxo is not None, "NoProxy")
            self.fund("attacker", GHO, debt_to_cover)
            self._send(GHO, "attacker", SWAP, debt_to_cover)
            g0 = self.ledger.balance(GHO, SWAP)
            la = self.spokes[spoke].liquidation_call(SWAP, self.markets[m].rid, GHO_RID, pxo.addr, debt_to_cover, False)
            self._send(GHO, SWAP, "attacker", debt_to_cover - (g0 - self.ledger.balance(GHO, SWAP)))
            key = (pxo.addr, m)
            self.unsettled[key] = self.unsettled.get(key, 0) + la["cshares"]
            return la
        return self.tx(f)

    def orphan_burn(self, m, units):
        """A faulty LPVaultSwap has the Adapter burnSeized without settling (Q-257)."""
        def f():
            mk = self.markets[m]
            u = min(units, self.ledger.balance(mk.vt, SWAP))
            need(u > 0, "NothingHeld")
            self.vt_burn(mk, SWAP, u)
            self.orphan_burned[m] += u
            return u
        return self.tx(f)

    # ------------------------------------------------------------------ repay with collateral (Q-255, SPEC-LIQ-020)
    def repay_with_collateral(self, wallet, token_id, units, rid=GHO_RID, spoke=CDP, min_debt_repaid=1,
                              deadline=None, min_hf=0):
        return self.tx(self.locked, self._deleverage, wallet, token_id, units, rid, spoke, min_debt_repaid,
                       deadline, min_hf)

    def _deleverage(self, wallet, token_id, units, rid, spoke, min_debt_repaid, deadline, min_hf):
        now = self.now()
        need(deadline is None or now <= deadline, "DeadlineExpired")
        need(units > 0, "ZeroAmount")
        pxo = self.proxies.get((wallet, spoke))
        need(pxo is not None, "NoProxy")
        rec = self.records.get(token_id)
        need(rec is not None and rec.status == "active" and rec.depositor == wallet and rec.proxy == pxo.addr,
             "NotDepositor")
        need(wallet not in self.frozen_addresses, "AddressFrozen")
        need(self.pause_state != PAUSED, "Paused")
        m, mk, sp, d = rec.market, self.markets[rec.market], self.spokes[spoke], self.debts[rid]
        need(rid in sp.reserves, "ReserveNotListed")
        mk.oracle.poke(now)
        need(mk.oracle.liquidation_block(now) is None, "StalePrice")
        if d.oracle is not None:
            d.oracle.poke(now)
            need(d.oracle.evaluate(now)["liq_ok"], f"DebtPriceStale({rid})")
        need(self.hub.shares_equal_assets(mk.aid), "HubSharesNotAssets")
        gap0 = self.gap(m)
        self._reconcile(pxo.addr, m)
        need(units <= rec.credited, "InvalidUnits")
        T, dd = d.asset, d.decimals
        p_debt = self.price_of(rid)
        Pc = self.price_of(mk.rid)
        V = self.vt_value_debt(m, units, Pc, p_debt, dd)
        s = self.p.slippage_bps
        U = self.units_allowance(mk, T, p_debt, dd)
        v_net = max(0, V * (BPS - s) // BPS - U)
        cap = v_net * BPS // (BPS + self.p.max_flash_fee_bps)
        debt_r = sp.user_debt(pxo.addr, rid)
        x = min(debt_r, cap)
        F = x
        need(x > 0 and x >= min_debt_repaid, f"DeleverageTooSmall({x}, {min_debt_repaid})")
        hf0 = sp.health_factor(pxo.addr)
        debts0 = {r: sp.user_debt(pxo.addr, r) for r in self.account_debts(pxo.addr)}
        snap = {t: self.ledger.balance(t, SWAP) for t in self.TOKENS + (mk.vt,)}
        need(F <= self.flash_available(T), f"FlashLiquidityShort({self.flash_available(T)}, {F})")
        phi = flash_fee(F, self.p.flash_fee_bps)
        need(phi * BPS <= self.p.max_flash_fee_bps * F, "FlashFeeTooHigh")
        self.ledger.mint(T, SWAP, F, "Aave V3 flash loan")
        # Adapter.deleverageRepay: SW -> proxy -> Spoke, refund to SW
        recv = self._send(d.asset, SWAP, pxo.addr, x)
        b1 = self.ledger.balance(d.asset, pxo.addr)
        sp.repay(pxo.addr, rid, recv, pxo.addr)
        spent = b1 - self.ledger.balance(d.asset, pxo.addr)
        self._send(d.asset, pxo.addr, SWAP, recv - spent)
        # release the units: proxy withdraws, Adapter burns, Collateralization debits, LPVault unwinds to LPVaultSwap
        b0 = self.ledger.balance(mk.vt, pxo.addr)
        sp.withdraw(pxo.addr, mk.rid, units, pxo.addr)
        need(self.ledger.balance(mk.vt, pxo.addr) - b0 == units, "WithdrawIncomplete")
        if sp.up(pxo.addr, mk.rid).supplied_shares == 0:
            sp.set_using_as_collateral(pxo.addr, mk.rid, False, pxo.addr)
        self.vt_burn(mk, pxo.addr, units)
        self._release(rec, units)
        amounts = self._unwind(token_id, units, SWAP)
        if rec.credited == 0:
            rec.status = "closed"
            self.nfpm.transfer_from(LPVAULT, LPVAULT, rec.depositor, token_id)
        t_before = self.ledger.balance(T, SWAP) - amounts.get(T, 0)
        self._convert(mk, amounts, s, "auto", False, T, p_debt, dust_to=wallet)
        R = self.ledger.balance(T, SWAP) - t_before
        have = self.ledger.balance(T, SWAP) - snap[T]
        need(have >= F + phi, f"DeleverageShortfall({have}, {F + phi})")
        self._send(T, SWAP, FLASH_SOURCE, F + phi)
        self.ledger.burn(T, FLASH_SOURCE, F, "flash repay")
        asset_out = self._send(T, SWAP, wallet, self.ledger.balance(T, SWAP) - snap[T])
        for t, b in snap.items():
            need(self.ledger.balance(t, SWAP) == b, f"LPVaultSwap {t} delta != 0")
        debt_after = sp.user_debt(pxo.addr, rid)
        need(debts0.get(rid, 0) - debt_after >= min_debt_repaid, "DeleverageTooSmall")
        hf1 = sp.health_factor(pxo.addr)
        if sp.account_data(pxo.addr)["n_borrow"] > 0:
            need(hf1 >= max(hf0, min_hf), f"HealthFactorNotImproved({hf1}, {hf0})")
        self._backing_check(m, gap0)
        out = dict(x=x, spent=spent, F=F, phi=phi, V=V, R=R, asset=T, asset_out=asset_out, hf_before=hf0, hf_after=hf1,
                   debt_before=debts0.get(rid, 0), debt_after=debt_after, debts_before=debts0, units=units, rid=rid,
                   cap=cap)
        self.deleverages.append(out)
        return out
