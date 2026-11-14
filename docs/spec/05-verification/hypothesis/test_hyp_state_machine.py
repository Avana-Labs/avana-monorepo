# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""HYP state machine: the multi-actor sequence suite (Q-278).

Actors: borrowers (four wallets, one PositionProxy per wallet per Borrow Spoke, several collateral and debt reserves
per account), an outside LP, approved keepers, a permissionless liquidator, a flash-loan attacker, a pool manipulator,
a public lender on the Lend Spoke (Q-407), the guardians and the token issuers. Markets: USDC/USDT (d = 6), DAI/USDC (d = 12),
GHO/DAI (d = 18). Debt reserves: GHO (fixed price) and USDC (DebtOracle) on the CDP Spoke; GHO only on the second
Spoke when it is listed.

Every rule is one on-chain transaction against the reference model (model/). After every step the global invariants
(model/invariants.py) run, including solvency per debt asset (HYP-70) in the profile whose caps follow the cap-sizing
rule; each rule checks its own postconditions. Property IDs and the decisions they back are listed in README.md.
"""
import copy

from hypothesis import event, note, strategies as st
from hypothesis.stateful import RuleBasedStateMachine, initialize, invariant, rule

from model.avana import (System, GHO, HUB, LPVAULT, SWAP, COLL, ESCROW, LEND_SPOKE, COV, CDP, TIER2, GHO_RID,
                         USDC_RID, NONE, FROZEN, PAUSED, GENERAL, MINT_PATH_SUSPECT, FEE_RECIPIENT)
from model.hsettings import cfg
from model.invariants import check_all
from model.mathlib import WAD, RAY, BPS, U256, to_value
from model.oracle import LIVE, DRIFTING, CACHED, EXPIRED
from model.params import Params, DAY, HOUR, USD

WALLETS = ["w0", "w1", "w2", "atk"]
TOKENS = ["USDC", "USDT", "DAI", "GHO"]
ONE = 10 ** 8
CRASH = st.one_of(st.integers(70 * 10 ** 6, 97 * 10 ** 6), st.integers(5 * 10 ** 6, 40 * 10 ** 6))
STOP_REASONS = ("Paused", "Frozen", "BreakerTripped", "DebtBreakerTripped", "AddressFrozen", "ConfigDrift")


def ev(msg):
    try:
        event(msg)
    except Exception:
        pass


# HYP-96 verifies: Q-224, Q-225, Q-233, Q-234, Q-241, Q-242, Q-247, Q-252, Q-254, Q-255, Q-276, Q-278
class AvanaMachine(RuleBasedStateMachine):

    @initialize(profile=st.sampled_from(["default", "default", "solvency", "solvency", "small"]),
                faulty=st.sampled_from([False] * 5 + [True]), two_spokes=st.booleans())
    def init(self, profile, faulty, two_spokes):
        kw = {}
        if profile == "solvency":
            # caps that follow the cap-sizing rule of Q-249 / SPEC-CAP-007 for both debt assets
            kw = dict(cap_market_usd=100_000 * USD, topup_slice_usd=10_000 * USD, cap_token_usd=300_000 * USD,
                      first_loss={"GHO": 100_000 * WAD, "USDC": 100_000 * 10 ** 6},
                      first_loss_min={"GHO": 100_000 * WAD, "USDC": 100_000 * 10 ** 6})
            faulty = False
        elif profile == "small":
            kw = dict(cap_market_usd=300_000 * USD, topup_slice_usd=30_000 * USD)
        self.profile = profile
        self.s = System(Params(faulty_risk_module=faulty, **kw), spokes=(CDP, TIER2) if two_spokes else (CDP,))
        self.spokes = list(self.s.spokes)
        self.crashed = None
        self.usdc_low = ONE
        self.gho_paused = {sp: False for sp in self.spokes}
        self.lent = 0

    # ---------------------------------------------------------------- helpers
    def proxies_of(self, w):
        return [p for (ww, _sp), p in self.s.proxies.items() if ww == w]

    def active_records(self, w=None):
        return sorted((r for r in self.s.records.values() if r.status == "active" and (w is None or r.depositor == w)),
                      key=lambda r: r.token_id)

    def weighted_value(self, pxa):
        s = self.s
        sp = s.spokes[s.proxy_of_addr[pxa].spoke]
        return sum(sp.reserves[mk.rid].cf * to_value(sp.supplied_assets(pxa, mk.rid), mk.d, s.price_of(mk.rid)) // BPS
                   for mk in s.account_markets(pxa))

    def debt_value(self, pxa):
        return self.s.spokes[self.s.proxy_of_addr[pxa].spoke].account_data(pxa)["tdv_ray"] // RAY

    def check(self):
        self.steps = getattr(self, "steps", 0) + 1
        check_all(self.s, solvency_check=self.profile == "solvency")

    def teardown(self):
        ev(f"steps {min(getattr(self, 'steps', 0) // 10 * 10, 50)}+")

    @invariant()
    def global_invariants(self):
        self.check()

    # ---------------------------------------------------------------- borrowers
    @rule(w=st.sampled_from(WALLETS), spi=st.integers(0, 1), m=st.integers(0, 2),
          usd=st.sampled_from([5, 50, 900, 5_000, 50_000, 250_000]))
    def pledge(self, w, spi, m, usd):
        s = self.s
        spoke = self.spokes[spi % len(self.spokes)]
        mk = s.markets[m]
        L = max(1, usd * 10 ** mk.d // 2)
        tid = s.create_position(w, m, L)
        if tid is None:
            return
        s.nfpm.approve(w, tid, LPVAULT)
        state = mk.oracle.state(s.now())
        pxo = s.proxy(w, spoke)
        had_debt = pxo is not None and s.borrow_count(pxo.addr) > 0
        pause, frozen_w = (s.pause_state, s.pause_reason), w in s.frozen_addresses
        ok, r = s.pledge(w, m, tid, spoke)
        ev(f"pledge ok={ok}" + ("" if ok else f" {r.split('(')[0][:40]}"))
        if not ok:
            note(f"pledge revert: {r}")
            return
        # HYP-22 verifies: Q-054, Q-087, Q-121, Q-132, Q-164, Q-227, Q-230
        assert s.records[tid].credited == L and s.nfpm.positions[tid].owner == LPVAULT
        if not s.p.faulty_risk_module:
            assert state in ((LIVE, DRIFTING) if had_debt else (LIVE,)), f"HYP-22 pledge accepted in {state}"
            assert r["L"] * s.booking_price(m) // 10 ** mk.d >= min(s.p.min_pledge_usd, s.p.rescue_min_pledge_usd), \
                "HYP-22 pledge below the minimum value"
        # HYP-77 verifies: Q-252, Q-253, INV-082
        if not r["rescue"]:
            assert pause[0] == NONE or (pause[0] == FROZEN and had_debt), "HYP-77 non-rescue pledge under a stop"
            assert not frozen_w, "HYP-77 a frozen wallet made a non-rescue pledge"
        else:
            assert had_debt and pause != (PAUSED, MINT_PATH_SUSPECT) and r["rescue_units"] == L, "HYP-77 rescue"
        # HYP-59 verifies: Q-150, Q-157, Q-175, Q-209
        assert r["charge"] >= L * s.p.stress_floor_usd8 // 10 ** mk.d, "HYP-59 charge below the stress floor"
        if r["slice"] > 0:
            assert had_debt, "HYP-59 slice used by an account without debt"
        # HYP-93 verifies: Q-224, Q-225, INV-064, INV-066
        assert s.proxy(w, spoke).addr == r["proxy"] == f"proxy:{w}@{spoke}", "HYP-93 one proxy per wallet and Spoke"

    @rule(w=st.sampled_from(WALLETS), m=st.integers(0, 2), usd=st.sampled_from([5_000, 50_000, 250_000]),
          h_bps=st.integers(10_500, 13_000), rid=st.sampled_from([GHO_RID, GHO_RID, USDC_RID]))
    def open_and_borrow(self, w, m, usd, h_bps, rid):
        self.pledge(w, 0, m, usd)
        self.borrow(w, 0, rid, h_bps, 0, False, 0)

    @rule(w=st.sampled_from(WALLETS), spi=st.integers(0, 1), rid=st.sampled_from([GHO_RID, USDC_RID]),
          h_bps=st.integers(9_800, 14_000), nonce_delta=st.sampled_from([0, 0, 0, 1, -1]),
          late=st.sampled_from([False, False, True]), min_hf=st.sampled_from([0, 0, 3 * WAD]))
    def borrow(self, w, spi, rid, h_bps, nonce_delta, late, min_hf):
        s = self.s
        spoke = self.spokes[spi % len(self.spokes)]
        pxo = s.proxy(w, spoke)
        if pxo is None:
            return
        price = s.price_of(rid)
        target = self.weighted_value(pxo.addr) * WAD // (h_bps * WAD // BPS)
        dec = s.debts[rid].decimals
        amount = max(1, (target - self.debt_value(pxo.addr)) * 10 ** dec // (price * 10 ** 18)) \
            if target > self.debt_value(pxo.addr) else 1000 * 10 ** dec
        nonce0 = pxo.nonce
        deadline = s.now() - 1 if late else s.now() + 600
        evals = [mk.oracle.evaluate(s.now()) for mk in s.account_markets(pxo.addr)]
        frozen_res = [s.spokes[spoke].reserves[mk.rid].frozen for mk in s.account_markets(pxo.addr)]
        asset = s.debts[rid].asset
        bal0 = s.ledger.balance(asset, w)
        stops = (s.pause_state, w in s.frozen_addresses)
        ok, r = s.borrow(w, amount, rid, spoke, deadline=deadline, nonce=nonce0 + nonce_delta, min_hf=min_hf)
        ev(f"borrow rid={rid} ok={ok}" + ("" if ok else f" {r.split('(')[0][:40]}"))
        if not ok:
            note(f"borrow revert: {r}")
            # HYP-15 verifies: Q-075, Q-105, Q-106
            assert s.proxy(w, spoke).nonce == nonce0, "HYP-15 nonce changed on a reverted borrow"
            return
        assert nonce_delta == 0 and not late, "HYP-15 borrow accepted with a wrong nonce or past deadline"
        assert pxo.nonce == nonce0 + 1 and s.ledger.balance(asset, w) - bal0 == amount, "HYP-15 nonce / receiver"
        # HYP-81 verifies: Q-242, INV-085
        assert not stops[1], "HYP-81 a frozen wallet borrowed"
        hf = s.hf(pxo.addr)
        assert hf >= WAD, "HYP-54 Aave's own health check"
        # HYP-61 verifies: Q-203
        assert not any(frozen_res) or s.p.faulty_risk_module, "HYP-61 borrow against an Aave-frozen vault reserve"
        if not s.p.faulty_risk_module:
            # HYP-13 verifies: Q-018, Q-161, Q-182, Q-229, Q-253, Q-398, INV-025
            # HYP-54 verifies: Q-229, Q-253, Q-398, SPEC-PROXY-001, SPEC-CF-003
            assert r["hf_ex"] >= max(WAD, s.p.hard_floor_hf, min_hf), "HYP-13 hfEx below 1.00 or the optional floor"
            assert hf >= r["hf_ex"], "HYP-54 hfEx above Aave's HF"
            # HYP-14 verifies: Q-081, Q-128, Q-195, Q-209, Q-227, Q-234, Q-238, Q-275
            assert all(e["state"] == LIVE and e["borrow_age_ok"] for e in evals), "HYP-14 borrow on a non-Live price"
            assert stops[0] == NONE, "HYP-14 borrow while Frozen or Paused"

    @rule(w=st.sampled_from(WALLETS), spi=st.integers(0, 1), rid=st.sampled_from([GHO_RID, USDC_RID]),
          kind=st.sampled_from(["all", "all", "all-short", "partial", "tiny", "zero"]), frac=st.integers(1, 99),
          third=st.sampled_from([False, False, True]), race=st.booleans())
    def repay(self, w, spi, rid, kind, frac, third, race):
        s = self.s
        spoke = self.spokes[spi % len(self.spokes)]
        pxo = s.proxy(w, spoke)
        if pxo is None:
            return
        payer = "rescuer" if third else w
        asset = s.debts[rid].asset
        debt = s.debt(pxo.addr, rid)
        repay_all = kind.startswith("all")
        quote = debt + debt // 1000 + 1                                      # Lens quoteRepayAll margin (Q-269)
        max_spend = {"all": quote, "all-short": debt * frac // 100, "tiny": 1, "partial": debt * frac // 100,
                     "zero": 0}[kind]
        s.fund(payer, asset, max(0, max_spend - s.ledger.balance(asset, payer)))
        bal0, bw0 = s.ledger.balance(asset, payer), s.ledger.balance(asset, w)
        ok, r = s.repay(w, max_spend, rid, spoke, repay_all=repay_all, payer=payer)
        ev(f"repay {kind} third={third} ok={ok}")
        # HYP-16 verifies: Q-051, Q-118, Q-153, Q-180, Q-206, Q-209, Q-227, Q-260, INV-043
        if debt == 0:
            assert ok and r["paid"] == 0 and s.ledger.balance(asset, payer) == bal0, "HYP-16 zero-debt repay returns 0"
            return
        if not repay_all and max_spend == 0:
            assert not ok and "ZeroAmount" in r, "HYP-16 a partial repay of 0 must revert ZeroAmount"
            return
        if repay_all and debt > max_spend:
            # HYP-60 verifies: Q-180, Q-269
            assert not ok and "RepayExceedsMax" in r and s.ledger.balance(asset, payer) == bal0, "HYP-60"
            return
        paused = s.spokes[spoke].reserves[rid].paused
        # an issuer pause or blocklist on the debt token stops the transfer itself, outside every Avana and Aave
        # stop (3.3 dependency table: "an issuer blocklist on Y or P can block the transfer")
        token_stop = asset in s.ledger.paused or any((asset, a) in s.ledger.blocklist or (asset, a) in s.ledger.blocked
                                                     for a in (payer, w, pxo.addr))
        if token_stop and not ok:
            assert "TokenBlocked" in r, f"HYP-16 repay under an issuer stop failed for another reason: {r}"
            return
        assert ok == (not paused), f"HYP-16 repay ok={ok} with every stop but Aave's own pause ignored: {r}"
        if not ok:
            return
        # HYP-17 verifies: Q-075, Q-153, Q-180, Q-269
        # HYP-95 verifies: Q-268, Q-269
        assert bal0 - s.ledger.balance(asset, payer) == r["paid"], "HYP-17 payer paid a different amount"
        if repay_all:
            assert s.debt(pxo.addr, rid) == 0 and r["refund"] == max_spend - r["paid"], "HYP-95 repay-all refund"
        else:
            assert r["paid"] == min(max_spend, debt), "HYP-17 partial repay pulled a different amount"
        # HYP-64 verifies: Q-212, REQ-PROXY-027, REQ-PROXY-083
        if third:
            assert s.ledger.balance(asset, w) == bw0, "HYP-64 a third-party repay debited the borrower's wallet"
        if race and repay_all:
            other = w if third else "rescuer"
            s.fund(other, asset, quote)
            ob0 = s.ledger.balance(asset, other)
            ok2, r2 = s.repay(w, quote, rid, spoke, repay_all=True, payer=other)
            assert ok2 and r2["paid"] == 0 and s.ledger.balance(asset, other) == ob0, "HYP-64 second repay-all spent"

    @rule(w=st.sampled_from(WALLETS), i=st.integers(0, 50), hf_min=st.sampled_from([0, 0, 2 * WAD]))
    def withdraw(self, w, i, hf_min):
        s = self.s
        recs = self.active_records(w)
        if not recs:
            return
        rec = recs[i % len(recs)]
        pxa = rec.proxy
        debt_free = s.borrow_count(pxa) == 0
        pos = s.nfpm.positions[rec.token_id]
        f0, f1 = pos.fees0, pos.fees1
        aave_block = s.spokes[rec.spoke].reserves[s.markets[rec.market].rid].paused
        ok, r = s.withdraw(w, rec.token_id, rec.spoke, min_hf=hf_min)
        ev(f"withdraw debt_free={debt_free} ok={ok}" + ("" if ok else f" {r.split('(')[0][:40]}"))
        if debt_free:
            # HYP-18 verifies: Q-029, Q-118, Q-134, Q-201, Q-227, Q-241, Q-242, Q-260, INV-045, INV-081
            # HYP-76 verifies: Q-227, Q-241, Q-242, INV-067, INV-081
            assert ok or (aave_block and rec.credited > 0), f"HYP-18 debt-free withdrawal refused: {r}"
        if not ok:
            note(f"withdraw revert: {r}")
            return
        # HYP-19 verifies: Q-009, Q-067, Q-105, Q-134, Q-201
        assert pos.owner == w and pos.fees0 == f0 and pos.fees1 == f1, "HYP-19 NFT or fees not returned whole"
        if not debt_free and not s.p.faulty_risk_module:
            # HYP-20 verifies: Q-018, Q-161, Q-182, Q-229, Q-253, Q-398
            assert s.hf_ex(pxa, s.borrow_price_of) >= max(WAD, s.p.hard_floor_hf, hf_min), "HYP-20 hfEx after withdraw"
            assert s.pause_state != PAUSED and w not in s.frozen_addresses, "HYP-20 withdraw-with-debt under a stop"

    @rule(w=st.sampled_from(WALLETS), i=st.integers(0, 50), frac=st.integers(1, 99))
    def remove_liquidity(self, w, i, frac):
        s = self.s
        recs = [r for r in self.active_records(w) if r.credited > 1]
        if not recs:
            return
        rec = recs[i % len(recs)]
        units = max(1, rec.credited * frac // 100)
        debt_free = s.borrow_count(rec.proxy) == 0
        live0, cred0 = s.nfpm.positions[rec.token_id].liquidity, rec.credited
        ok, r = s.remove_liquidity(w, rec.token_id, units, rec.spoke)
        ev(f"remove debt_free={debt_free} ok={ok}" + ("" if ok else f" {r.split('(')[0][:40]}"))
        if not ok:
            note(f"remove revert: {r}")
            return
        # HYP-78 verifies: Q-254, INV-088
        assert rec.credited == cred0 - units and rec.status == "active", "HYP-78 record not debited by the units"
        assert s.nfpm.positions[rec.token_id].liquidity == live0 - units, "HYP-78 NFT liquidity not reduced by units"
        if not debt_free and not s.p.faulty_risk_module:
            assert s.hf_ex(rec.proxy, s.borrow_price_of) >= max(WAD, s.p.hard_floor_hf), \
                "HYP-78 removal with debt below HF 1.00"
            assert rec.credited * s.accepted_price(rec.market) // 10 ** s.markets[rec.market].d >= s.p.min_pledge_usd

    @rule(w=st.sampled_from(WALLETS), i=st.integers(0, 50), pct=st.integers(1, 50))
    def add_and_recredit(self, w, i, pct):
        s = self.s
        recs = self.active_records(w)
        if not recs:
            return
        rec = recs[i % len(recs)]
        liq = max(1, s.nfpm.positions[rec.token_id].liquidity * pct // 100)
        s.donate_liquidity(w, rec.token_id, liq)
        live, cred0, released0 = s.nfpm.positions[rec.token_id].liquidity, rec.credited, rec.charge
        ok, r = s.recredit(w, rec.token_id, rec.spoke)
        ev(f"recredit ok={ok}")
        if not ok:
            note(f"recredit revert: {r}")
            return
        # HYP-78 verifies: Q-254, INV-088, SPEC-BACK-013
        pos = s.nfpm.positions[rec.token_id]
        assert rec.credited == pos.liquidity and r["added"] > 0, "HYP-78 re-credit is not live − credited"
        assert rec.orig_units == rec.credited and rec.charge == rec.orig_charge, "HYP-78 charge basis rebase"
        if pos.liquidity == live:
            assert r["added"] == live - cred0, "HYP-78 re-credit amount"

    @rule(w=st.sampled_from(WALLETS), i=st.integers(0, 50), frac=st.integers(1, 100),
          rid=st.sampled_from([GHO_RID, USDC_RID]))
    def repay_with_collateral(self, w, i, frac, rid):
        s = self.s
        recs = self.active_records(w)
        if not recs:
            return
        rec = recs[i % len(recs)]
        units = max(1, rec.credited * frac // 100)
        a = s.debts[rid].asset
        fee0 = s.ledger.balance(a, FEE_RECIPIENT)
        ok, r = s.repay_with_collateral(w, rec.token_id, units, rid, rec.spoke)
        ev(f"deleverage rid={rid} ok={ok}" + ("" if ok else f" {r.split('(')[0][:40]}"))
        if not ok:
            note(f"deleverage revert: {r}")
            return
        # HYP-79 verifies: Q-255, INV-089, SPEC-LIQ-020
        assert r["debt_after"] < r["debt_before"], "HYP-79 debt not lower"
        assert all(s.debt(rec.proxy, x) <= v for x, v in r["debts_before"].items()), "HYP-79 another debt rose"
        if s.borrow_count(rec.proxy) > 0:
            assert r["hf_after"] >= r["hf_before"], "HYP-79 health factor fell"
        assert s.ledger.balance(a, FEE_RECIPIENT) == fee0, "HYP-79 fee on a repay with collateral"
        assert s.pause_state != PAUSED and w not in s.frozen_addresses, "HYP-79 ran under Paused or for a frozen wallet"

    @rule(w=st.sampled_from(WALLETS), i=st.integers(0, 50))
    def collect_fees(self, w, i):
        s = self.s
        recs = self.active_records(w)
        if not recs:
            return
        rec = recs[i % len(recs)]
        pos = s.nfpm.positions[rec.token_id]
        f0, f1, liq = pos.fees0, pos.fees1, pos.liquidity
        ok, r = s.collect_fees(w, rec.token_id)
        # HYP-21 verifies: Q-011, Q-030, Q-051, Q-118, Q-227, INV-044
        # Only the token itself may stop it: an issuer pause, an issuer blocklist, or a token refusing delivery to w.
        assert ok or any(t in s.ledger.paused or (t, w) in s.ledger.blocklist or (t, w) in s.ledger.blocked
                         for t in (s.markets[rec.market].t0, s.markets[rec.market].t1)), f"HYP-21 fee collection: {r}"
        if ok:
            assert pos.liquidity == liq and r["c0"] >= f0 and r["c1"] >= f1, "HYP-21 collect changed liquidity"

    # ---------------------------------------------------------------- market, oracle and pool actors
    @rule(m=st.integers(0, 2), f0=st.integers(1, 10 ** 6), f1=st.integers(1, 10 ** 6))
    def pool_fees(self, m, f0, f1):
        mk = self.s.markets[m]
        self.s.accrue_pool_fees(m, f0 * 10 ** (mk.d0 - 6) if mk.d0 > 6 else f0, f1 * 10 ** (mk.d1 - 6) if mk.d1 > 6 else f1)

    @rule(t=st.sampled_from(TOKENS), price=CRASH, mode=st.sampled_from(["all", "all", "primary", "pool", "phase"]))
    def price_move(self, t, price, mode):
        s = self.s
        if self.profile == "solvency":
            # one token fails at a time; the others and the debt asset stay within the sizing assumptions
            if t == "GHO" or (self.crashed not in (None, t) and price < 95 * 10 ** 6):
                price = max(price, 98 * 10 ** 6)
            if price < 95 * 10 ** 6:
                self.crashed = t
            price = min(price, 104 * 10 ** 6)
            if t == "USDC":
                price = self._usdc_bound(price, mode != "pool")
        if mode == "pool":
            for mk in s.markets:
                if t in (mk.t0, mk.t1) and not ({mk.t0, mk.t1} & s.ledger.paused):
                    from model.uniswap import sqrt_price_from_usd
                    p = dict(s.prices)
                    p[t] = price
                    mk.pool.move_price(sqrt_price_from_usd(p[mk.t0], p[mk.t1], mk.d0, mk.d1), "arb", follow_twap=False)
            return
        routes = ("primary",) if mode == "primary" else ("primary", "alternate")
        s.set_price(t, price, routes=routes, new_phase=mode == "phase")

    def _usdc_bound(self, price, record):
        """Solvency profile: USDC is a pool token and a debt asset. It may crash like any pool token, but as a debt
        asset it never rises more than 4% above its lowest price in the run (README: "USDC moving at most 4% up"),
        the bounded rise the incident term of SPEC-CAP-007 sizes the First-Loss Reserve for. INV-074 is not claimed
        past it: a depeg to $0.05 followed by a re-peg is a 20x rise of the USDC debt."""
        price = min(price, self.usdc_low * 104 // 100)
        if record:
            self.usdc_low = min(self.usdc_low, price)
        return price

    @rule(t=st.sampled_from(TOKENS))
    def recover_price(self, t):
        price = ONE
        if self.profile == "solvency" and t == "USDC":
            price = self._usdc_bound(price, True)
        self.s.set_price(t, price)
        if self.crashed == t and price >= 95 * 10 ** 6:
            self.crashed = None

    @rule(t=st.sampled_from(TOKENS), kind=st.sampled_from(["break", "fix", "zero", "max", "standby", "restore"]),
          slot=st.sampled_from(["primary", "alternate"]))
    def feed_fault(self, t, kind, slot):
        s = self.s
        tf = s.feeds[t]
        feed = tf.slots[slot]
        if kind == "break":
            feed.broken = True
        elif kind == "fix":
            feed.broken = False
        elif kind == "zero":
            feed.push(0, s.now())
        elif kind == "max":
            feed.push(2 ** 255 - 1, s.now())
        elif kind == "standby":
            ok, _ = s.use_standby(t, slot)
            ev(f"standby ok={ok}")
        else:
            if slot in tf.replaced:
                tf.restore(slot)
        # HYP-11 verifies: Q-056, Q-128, Q-191, Q-247, INV-055
        for mk in s.markets:
            assert mk.oracle.latest_answer(s.now()) >= 1, "HYP-11 served price below 1"

    @rule(dt=st.sampled_from([60, 600, 1800, 3600, 4300, 3 * 3600, 12 * 3600]), refresh=st.booleans())
    def advance(self, dt, refresh):
        s = self.s
        s.advance(dt)
        if refresh:
            for t in TOKENS:
                s.set_price(t, s.prices[t], move_pools=False)

    @rule(m=st.integers(0, 2), gas_ok=st.sampled_from([True, True, False]))
    def poke(self, m, gas_ok):
        s = self.s
        o = s.markets[m].oracle
        before = copy.deepcopy(o.__dict__)
        try:
            s.poke(m, gas_ok)
        except ValueError:
            # HYP-37 verifies: Q-129, Q-154
            assert not gas_ok and o.__dict__.keys() == before.keys(), "HYP-37 gas-starved poke"
            assert all(o.__dict__[k] == before[k] for k in ("accepted", "failed_since", "recovered_at", "expired_flag"))

    @rule(m=st.integers(0, 2), add=st.booleans(), usd=st.sampled_from([10 ** 6, 10 ** 7, 5 * 10 ** 7]))
    def outside_lp(self, m, add, usd):
        """An outside LP adds or removes full-range liquidity (pool depth, the pool-share breaker)."""
        s = self.s
        mk = s.markets[m]
        mine = [p for p in s.nfpm.positions.values() if p.owner == "lp_out" and p.pool is mk.pool and p.liquidity]
        if add or not mine:
            s.create_position("lp_out", m, usd * 10 ** mk.d // 2)
        else:
            p = mine[0]

            def f():
                s.nfpm.decrease_liquidity("lp_out", p.token_id, p.liquidity)
                s.nfpm.collect("lp_out", p.token_id, "lp_out", U256 >> 128, U256 >> 128)
            s.tx(f)

    @rule(m=st.integers(0, 2), route=st.sampled_from(["primary", "backup"]), bps=st.sampled_from([0, 0, 50, 300, 2000]))
    def manipulator(self, m, route, bps):
        """A pool manipulator or sandwicher worsens a swap route into the debt asset."""
        self.s.route_haircut[(m, route)] = bps

    @rule(amount=st.sampled_from([10 ** 5, 10 ** 6, 10 ** 7]), add=st.booleans(), over=st.booleans())
    def lender(self, amount, add, over):
        """A public lender supplies or withdraws GHO on the Lend Spoke (Q-407): supply is bounded only by the Lend
        Spoke supply cap, never by the credit line; a withdrawal takes only idle liquidity (a cascade lowers it)."""
        s = self.s
        amt = amount * WAD
        a = s.hub.assets[GHO]
        sd = a.spokes[LEND_SPOKE]
        s.hub.accrue(a)  # the cap and the withdrawal are judged on accrued assets, as inside the call
        idle = a.liquidity
        if add:
            room = sd.add_cap * WAD - s.hub.preview_add_by_shares(GHO, sd.added_shares)
            s.fund("lender", GHO, amt)

            def supply():
                s.ledger.transfer(GHO, "lender", HUB, amt)
                return s.hub.add(GHO, LEND_SPOKE, amt)
            ok, r = s.tx(supply)
            # HYP-97 verifies: Q-407, REQ-HUB-017
            assert ok == (amt <= room), f"HYP-97 Lend Spoke supply of {amt} against room {room}: {r}"
            if ok:
                self.lent += amt
            ev(f"lender supply ok={ok}")
        else:
            held = s.hub.preview_remove_by_shares(GHO, sd.added_shares)
            take = min(amt, held) if over else min(amt, idle, held)
            if take > 0:
                ok, r = s.tx(s.hub.remove, GHO, LEND_SPOKE, take, "lender", s.xfer)
                # HYP-97 verifies: Q-407, REQ-HUB-019
                assert ok == (take <= idle), f"HYP-97 Lend Spoke withdrawal of {take} against idle {idle}: {r}"
                ev(f"lender withdraw ok={ok}")

    # ---------------------------------------------------------------- liquidation actors
    def _liq(self, caller, w, spoke, m, rid, funding, route, permissionless, max_shortfall, deadline_off=None,
             min_payout=0, size=None):
        s = self.s
        pxo = s.proxy(w, spoke)
        if pxo is None or s.markets[m] not in s.account_markets(pxo.addr) or rid not in s.account_debts(pxo.addr):
            return None
        X = size or s.debt(pxo.addr, rid)
        asset, dd = s.debts[rid].asset, s.debts[rid].decimals
        if funding == "keeper":
            s.fund(caller, asset, 10 ** 9 * 10 ** dd)
        s.fund(caller, asset, 10 ** 7 * 10 ** dd)
        hf = s.hf(pxo.addr)
        deadline = None if deadline_off is None else s.now() + deadline_off
        fee0 = s.ledger.balance(asset, FEE_RECIPIENT)
        out0 = s.ledger.balance(asset, caller)
        grace = any(x.oracle.in_grace(s.now()) for x in s.account_markets(pxo.addr) + [s.markets[m]])
        swap0 = {t: s.ledger.balance(t, SWAP) for t in TOKENS + [mk.vt for mk in s.markets]}
        full = size is None and len(s.account_debts(pxo.addr)) == 1
        if permissionless:
            ok, r = s.liquidate_permissionless(caller, w, m, X, rid, spoke, funding=funding, deadline=deadline,
                                               min_payout=min_payout, max_shortfall=max_shortfall)
        else:
            ok, r = s.liquidate(caller, w, m, X, rid, spoke, funding=funding, route=route, deadline=deadline,
                                min_payout=min_payout, max_shortfall=max_shortfall)
        ev(f"liquidate perm={permissionless} rid={rid} route={route} ok={ok}" + ("" if ok else f" {r.split('(')[0][:40]}"))
        if not ok:
            note(f"liquidate revert: {r}")
            return False
        # HYP-23 verifies: Q-053, Q-116, Q-213, Q-222
        assert hf < WAD, "HYP-23 liquidation of a healthy account"
        # HYP-50 verifies: Q-088, Q-129, Q-154, Q-206, Q-264
        assert not grace or hf < s.p.grace_hf, "HYP-50 liquidation inside the grace window above graceHealthFactor"
        # HYP-25 verifies: Q-097, Q-124, Q-165, Q-271
        assert all(s.ledger.balance(t, SWAP) == v for t, v in swap0.items()), "HYP-25 LPVaultSwap kept a token"
        # HYP-35 verifies: Q-060, Q-185
        if (full and r["branch"] == "normal" and not r["deficit"] and s.account_debts(r["proxy"])
                and s.account_markets(r["proxy"]) and s.markets[m] in s.account_markets(r["proxy"])):
            assert r["hf_after"] >= s.p.target_hf * 999 // 1000, f"HYP-35 HF {r['hf_after']} below target after sizing"
        assert caller not in s.frozen_addresses, "HYP-81 a frozen caller liquidated"
        # HYP-24 verifies: Q-063, Q-097, Q-135
        for t, v in r["supply_before"].items():
            exp = v - (r["c"] if t == s.markets[m].vt else 0)
            assert s.ledger.supply.get(t, 0) == exp or t.startswith("vt"), f"HYP-24 supply of {t} changed"
        # HYP-26 verifies: Q-069, Q-125, Q-160, Q-189, Q-201, Q-224
        assert sum(d for _t, d in r["debits"]) == r["c"], "HYP-26 records debited != seized"
        # HYP-27 verifies: Q-108, Q-170, Q-194
        ds = r["debits"]
        assert all(s.records[t].credited == 0 for t, _d in ds[:-1]), "HYP-27 only the last debit may be partial"
        # HYP-28 verifies: Q-009, Q-061
        for tid, (g0, g1) in r["fee_tags_before"].items():
            p = s.nfpm.positions[tid]
            assert p.fees0 >= g0 and p.fees1 >= g1 or p.owner != LPVAULT, "HYP-28 liquidation took fees"
        # HYP-29 verifies: Q-085, Q-159, Q-190, Q-198, Q-235, Q-251, INV-034
        assert r["R"] + r["shortfall"] >= r["min_rec"], "HYP-29 recovery below the floor"
        assert r["floor_gap"] <= max_shortfall, "HYP-86 floor shortfall above the caller's maximum"
        # HYP-30 verifies: Q-097, Q-135, Q-190, Q-256, INV-035
        # HYP-84 verifies: Q-231, Q-256, INV-036, INV-086
        exp_a = min(max(0, r["V"] - r["D"] - r["phi_d"]) * s.p.avana_fee_share_bps // BPS, r["surplus"])
        assert r["avana_fee"] == exp_a == s.ledger.balance(asset, FEE_RECIPIENT) - fee0 + r["escrowed"]["fee"], \
            "HYP-84 Avana fee"
        assert r["surplus"] == max(0, r["R"] + r["shortfall"] - r["D"] - r["phi_d"]), "HYP-30 surplus"
        # HYP-38 verifies: Q-159, Q-198, Q-267, Q-397, INV-038 (no budget: the caller pays any settlement gap)
        assert r["R"] + r["shortfall"] + r["K"] >= r["D"] + r["phi_d"], "HYP-38 settlement gap left unfunded"
        assert r["gap"] == max(0, r["D"] + r["avana_fee"] - r["K"] - r["R"]) and r["gap"] <= r["floor_gap"], "HYP-38 caller gap"
        # HYP-83 verifies: Q-235, Q-317, Q-335, Q-358, INV-070, INV-095, REQ-FLASH-002, SPEC-LIQ-015
        assert r["asset"] == asset, "HYP-83 settled in an asset other than the debt repaid"
        if r["flash"]:
            assert r["phi"] == -(-r["flash"] * s.p.flash_fee_bps // BPS), "HYP-83 premium is not the Aave V3 premium"
            assert r["phi"] * BPS <= s.p.max_flash_fee_bps * r["flash"], "HYP-83 premium above maxFlashFeeBps"
        # the caller funds Kf and any shortfall, receives keeperOut directly (never escrowed), and through the helper
        # also receives the loan F and repays F + phi (REQ-HELPER-007, Q-404)
        assert r["escrowed"]["keeper"] == 0, "HYP-83 caller payout escrowed"
        assert s.ledger.balance(asset, caller) - out0 == \
            r["keeper_out"] - r["K"] - r["shortfall"] - r["phi"], "HYP-83 caller not paid in the debt asset"
        # HYP-32 verifies: Q-070, Q-101, Q-193
        if r["deficit"]:
            assert not s.account_markets(r["proxy"]), "HYP-32 deficit with collateral left"
        # HYP-72 verifies: Q-249, Q-278, INV-076
        assert r["deficit_after"] <= r["deficit_before"] + r["V_gho"] * (r["lb"] - BPS) // r["lb"] + 10 ** 13, \
            f"HYP-72 deficit {r['deficit_before']} -> {r['deficit_after']} above the bonus bound"
        # HYP-34 verifies: Q-060, Q-116
        assert r["V_gho"] <= (r["D"] * s.price_of(rid) * 10 ** (18 - s.debts[rid].decimals) // ONE) * r["lb"] // BPS \
            + s.vt_value_gho(m, 1, r["price"]) + 1, "HYP-34 seized more than debt × bonus"
        return True

    @rule(k=st.sampled_from(["keeper0", "keeper1", "standby", "outsider"]), w=st.sampled_from(WALLETS),
          spi=st.integers(0, 1), m=st.integers(0, 2), rid=st.sampled_from([GHO_RID, GHO_RID, USDC_RID]),
          funding=st.sampled_from(["flash", "keeper"]), route=st.sampled_from(["auto", "auto", "backup"]),
          shortfall=st.sampled_from([0, 0, 10 ** 21, 10 ** 23]), deadline=st.sampled_from([None, None, -60, 600]),
          min_payout=st.sampled_from([0, 0, 10 ** 22]))
    def liquidate(self, k, w, spi, m, rid, funding, route, shortfall, deadline, min_payout):
        spoke = self.spokes[spi % len(self.spokes)]
        ok = self._liq(k, w, spoke, m, rid, funding, route, False, shortfall, deadline, min_payout)
        if ok is not None:
            # HYP-68 verifies: Q-216, REQ-SWAP-074, REQ-SWAP-075
            assert not (ok and deadline == -60), "HYP-68 liquidation after its deadline"
            # an unregistered caller ("outsider") liquidates like any other: the committed-operator registry gates no
            # call (REQ-SWAP-001, REQ-SWAP-048, Q-404); _liq checks its result like every other caller's

    @rule(c=st.sampled_from(["anyone", "atk"]), w=st.sampled_from(WALLETS), m=st.integers(0, 2),
          rid=st.sampled_from([GHO_RID, USDC_RID]), shortfall=st.sampled_from([0, 10 ** 22]),
          size=st.sampled_from([None, None, 10 ** 18, 10 ** 6]))
    def liquidate_permissionless(self, c, w, m, rid, shortfall, size):
        """The permissionless liquidator, or the flash-loan attacker liquidating any account, its own included."""
        a = self.s.debts[rid].asset
        fee0 = self.s.ledger.balance(a, FEE_RECIPIENT)
        ok = self._liq(c, w, CDP, m, rid, "flash", "auto", True, shortfall, size=size)
        if ok:
            # HYP-67 verifies: Q-213, Q-397, INV-062 (no Avana balance funds a liquidation; only the fee flows in)
            assert self.s.ledger.balance(a, FEE_RECIPIENT) >= fee0, "HYP-67 an Avana balance funded a liquidation"

    def _routes_clear_floor(self, mk, rid):
        """True when the swap routes' market price clears the oracle minimum of every leg at the keeper's sLeg
        (SPEC-LIQ-018, SPEC-LIQ-019 with maxShortfall saturated). A market price far below the LPOracle's leg price
        (a lagging or fallback feed) must make the liquidation revert NoRouteAvailable rather than sell below the
        oracle floor (REQ-SWAP-059, SPEC-LIQ-013), so liveness is not claimed there."""
        s = self.s
        T = s.debts[rid].asset
        lp = s.leg_prices(mk)
        s_leg = min(BPS - 1, s.p.slippage_bps + s.p.max_shortfall_bps)
        p_debt, p_t = s.price_of(rid), s.debt_price(T)
        return all(s.prices[t] * (BPS - s.p.dex_slippage_bps) * p_debt >= lp[t] * (BPS - s_leg + 1) * p_t
                   for t in (mk.t0, mk.t1) if t != T)

    @rule(rid=st.sampled_from([GHO_RID, USDC_RID]))
    def keepers_sweep(self, rid):
        """Approved keepers liquidate every account below HF 1 at full size (HYP-36 liveness)."""
        s = self.s
        for (w, spoke), pxo in sorted(s.proxies.items()):
            if s.hf(pxo.addr) >= WAD or rid not in s.account_debts(pxo.addr):
                continue
            for mk in s.account_markets(pxo.addr):
                ok = self._liq("keeper0", w, spoke, mk.idx, rid, "flash", "auto", False, 10 ** 24)
                live = (mk.oracle.liquidation_block(s.now()) is None and not mk.oracle.in_grace(s.now())
                        and (rid == GHO_RID or s.debt_oracle.evaluate(s.now())["liq_ok"])
                        and not s.spokes[spoke].reserves[mk.rid].paused and not s.spokes[spoke].reserves[rid].paused
                        and s.hub.shares_equal_assets(mk.aid) and not s.hostile_swap and "keeper0" in s.keepers
                        and "keeper0" not in s.frozen_addresses
                        and all(v == 0 for v in s.route_haircut.values())
                        and not s.ledger.paused and not s.ledger.fee_bps and mk.route_backup_up
                        and self._routes_clear_floor(mk, rid))
                if ok is False and live:
                    # HYP-36 verifies: Q-128, Q-154, Q-198, Q-199, Q-208, Q-227, Q-247, INV-046
                    ok2, r2 = s.liquidate("keeper0", w, mk.idx, s.debt(pxo.addr, rid), rid, spoke,
                                          max_shortfall=10 ** 24)
                    if not ok2 and any(x in r2 for x in ("FlashFeeTooHigh", "InsufficientFlashLiquidity",
                                                         "InsufficientProceeds")):
                        # HYP-83: a short or repriced flash source, or a flash loan whose unused part's premium the
                        # surplus cannot pay (SPEC-LIQ-010), falls back to the caller-funded path. A short Pool
                        # makes the liquidation helper revert InsufficientFlashLiquidity (LIQ-F-036, REQ-SWAP-053);
                        # FlashLiquidityShort is the deleverage error and liquidation never raises it.
                        s.fund("keeper0", s.debts[rid].asset, 10 ** 9 * 10 ** s.debts[rid].decimals)
                        ok2, r2 = s.liquidate("keeper0", w, mk.idx, s.debt(pxo.addr, rid), rid, spoke,
                                              funding="keeper", max_shortfall=10 ** 24)
                    assert ok2 or any(x in r2 for x in ("NothingSeized", "CapExceeded", "MustNotLeaveDust",
                                                        "HealthFactorNotBelowThreshold", "ReserveNotBorrowed",
                                                        "ReserveNotSupplied")), f"HYP-36 liveness: {r2}"
                break

    @rule(t=st.sampled_from(TOKENS[:3]), price=st.integers(5 * 10 ** 6, 60 * 10 ** 6), rid=st.sampled_from([GHO_RID,
          USDC_RID]), route=st.sampled_from(["auto", "permissionless"]))
    def crash_and_liquidate(self, t, price, rid, route):
        """A depeg followed by liquidations of every account it pushed below HF 1 (sequential liquidations)."""
        self.price_move(t, price, "all")
        for m in range(3):
            self.s.poke(m)
        for (w, spoke), pxo in sorted(self.s.proxies.items()):
            for mk in self.s.account_markets(pxo.addr):
                if self.s.hf(pxo.addr) < WAD and rid in self.s.account_debts(pxo.addr):
                    if route == "permissionless":
                        self._liq("anyone", w, spoke, mk.idx, rid, "flash", "auto", True, 10 ** 24)
                    else:
                        self._liq("keeper1", w, spoke, mk.idx, rid, "flash", route, False, 10 ** 24)
        self.keepers_sweep(rid)

    @rule(w=st.sampled_from(WALLETS), m=st.integers(0, 2), usd=st.sampled_from([50_000, 250_000]),
          h_bps=st.integers(10_500, 11_500), rid=st.sampled_from([GHO_RID, USDC_RID]))
    def open_and_borrow_near_floor(self, w, m, usd, h_bps, rid):
        self.pledge(w, 0, m, usd)
        self.borrow(w, 0, rid, h_bps, 0, False, 0)
        self.borrow(w, 0, GHO_RID if rid != GHO_RID else USDC_RID, h_bps, 0, False, 0)

    @rule(m=st.integers(0, 2), w=st.sampled_from(WALLETS))
    def report_shortfall(self, m, w):
        s = self.s
        pxo = s.proxy(w, CDP)
        if pxo is None or GHO_RID not in s.account_debts(pxo.addr):
            return
        before = copy.deepcopy(s.records)
        ok, r = s.report_shortfall("keeper1", w, m, s.debt(pxo.addr, GHO_RID))
        ev(f"report ok={ok}" + ("" if ok else f" {r.split('(')[0][:40]}"))
        # HYP-86 verifies: Q-251
        assert {k: (v.credited, v.status) for k, v in before.items()} == \
            {k: (v.credited, v.status) for k, v in s.records.items()}, "HYP-86 a shortfall report changed a record"

    @rule(m=st.integers(0, 2), caller=st.sampled_from(["anyone", "w0"]))
    def settle_pending(self, m, caller):
        s = self.s
        p0 = s.pending[m]["units"]
        cov0 = s.funded_balance(GHO)
        ok, r = s.settle_pending(caller, m)
        ev(f"settle_pending ok={ok}" + ("" if ok else f" {r.split('(')[0][:40]}"))
        if ok:
            # HYP-58 verifies: Q-201, Q-211, Q-236
            assert s.pending[m]["units"] == p0 - r["units"] and r["gho"] >= r["min_pending"], "HYP-58 pending"
            assert s.funded_balance(GHO) >= cov0 + r["gho"] - 1, "HYP-58 proceeds not in the GHO First-Loss Reserve"

    @rule(w=st.sampled_from(WALLETS), m=st.integers(0, 2), frac=st.integers(5, 100), orphan=st.booleans())
    def hostile_seizure(self, w, m, frac, orphan):
        """An LPVaultSwap version that seizes and never settles, optionally burning without a debit (Q-201, Q-257)."""
        s = self.s
        pxo = s.proxy(w, CDP)
        if pxo is None or s.hf(pxo.addr) >= WAD or GHO_RID not in s.account_debts(pxo.addr):
            return
        ok, la = s.hostile_swap_seize(w, m, max(1, s.debt(pxo.addr) * frac // 100))
        ev(f"hostile seize ok={ok}")
        if ok and orphan:
            s.orphan_burn(m, max(1, la["cshares"] // 3))

    @rule(asset=st.sampled_from([GHO, "USDC"]), spi=st.integers(0, 1), frac=st.sampled_from([1, 50, 100]))
    def cover_deficit(self, asset, spi, frac):
        s = self.s
        spoke = self.spokes[spi % len(self.spokes)]
        sd = s.hub.assets[asset].spokes.get(spoke)
        if sd is None or sd.deficit_ray == 0:
            return
        d0, f0 = sd.deficit_ray, s.funded_balance(asset)
        ok, r = s.cover_deficit(asset, spoke, max(1, -(-d0 // RAY) * frac // 100))
        # HYP-33 verifies: Q-070, Q-101, Q-142, Q-236, INV-042, INV-071
        if ok:
            assert sd.deficit_ray == d0 - min(d0, r["eliminated"] * RAY) and r["eliminated"] <= f0, "HYP-33 coverage"

    # ---------------------------------------------------------------- guardians, issuers, Aave, misc
    @rule(op=st.sampled_from(["unpause", "unfreeze", "unpause", "unfreeze", "freeze", "pause", "pause_mint"]))
    def guardian_pause(self, op):
        s = self.s
        f = {"freeze": s.freeze, "pause": lambda: s.pause(GENERAL), "pause_mint": lambda: s.pause(MINT_PATH_SUSPECT),
             "unpause": s.unpause, "unfreeze": s.unfreeze}[op]
        ok, _ = s.tx(f)
        ev(f"{op} ok={ok}")

    @rule(who=st.sampled_from(WALLETS + ["keeper0", "keeper1", "keeper2", "standby", "lpvaultswap", "hub"]),
          on=st.booleans())
    def address_freeze(self, who, on):
        s = self.s
        if on:
            ok, r = s.freeze_address("emergency_guardian", who)
            # HYP-81 verifies: Q-242, INV-085
            assert not ok or not s.is_protected(who), "HYP-81 a protected address was frozen"
        else:
            s.unfreeze_address(who)

    @rule(m=st.integers(0, 2), rid=st.sampled_from([GHO_RID, USDC_RID]), on=st.booleans(), market=st.booleans())
    def manual_breaker(self, m, rid, on, market):
        if market:
            self.s.trip_market_breaker(m, on)
        else:
            self.s.trip_debt_breaker(CDP, rid, on)

    @rule(flag=st.sampled_from(["drift", "vt_pause", "vt_freeze", "debt_pause", "route_p", "route_b", "flash_short",
                                "flash_fee", "usdt_fee", "usdc_pause", "blocklist", "gas_burner"]),
          m=st.integers(0, 2), on=st.booleans(), w=st.sampled_from(WALLETS))
    def external_flags(self, flag, m, on, w):
        s = self.s
        mk = s.markets[m]
        if flag == "drift":
            s.config_drift = on
        elif flag in ("vt_pause", "vt_freeze"):
            for sp in s.spokes.values():
                setattr(sp.reserves[mk.rid], "paused" if flag == "vt_pause" else "frozen", on)
        elif flag == "debt_pause":
            for sp in s.spokes.values():
                sp.reserves[GHO_RID].paused = on
        elif flag == "route_p":
            mk.route_primary_up = on
        elif flag == "route_b":
            mk.route_backup_up = on
        elif flag == "flash_short":
            s.p.flash_capacity = 0 if on else 5_000_000 * WAD        # the Aave V3 Pool's idle liquidity drains
        elif flag == "flash_fee":
            s.p.flash_fee_bps = 15 if on else 5                       # Aave governance raises the flash premium
        elif flag == "usdt_fee":
            s.ledger.fee_bps["USDT"] = 10 if on else 0
        elif flag == "usdc_pause":
            (s.ledger.paused.add if on else s.ledger.paused.discard)("USDC")
        elif flag == "blocklist":
            (s.ledger.blocked.add if on else s.ledger.blocked.discard)(("USDC", w))
        else:
            (s.gas_burners.add if on else s.gas_burners.discard)(("USDT", w))

    @rule(token=st.sampled_from(TOKENS), to=st.sampled_from([SWAP, LPVAULT, ESCROW, "proxy"]),
          amt=st.integers(1, 10 ** 6))
    def dust(self, token, to, amt):
        s = self.s
        if to == "proxy":
            if not s.proxies:
                return
            to = sorted(p.addr for p in s.proxies.values())[0]
        s.donate("dusty", token, to, amt)

    @rule(w=st.sampled_from(WALLETS), t=st.sampled_from(["USDC", "USDT", "DAI"]))
    def claim_escrow(self, w, t):
        s = self.s
        amt = s.escrow_claimable.get((t, w), 0)
        ok, r = s.claim_escrow(w, t, f"{w}:cold")
        # HYP-65 verifies: Q-214, REQ-ESCROW-004, REQ-ESCROW-005
        if amt == 0:
            assert not ok
        elif ok:
            assert r == amt and s.escrow_claimable[(t, w)] == 0

    @rule(k=st.sampled_from(["keeper0", "keeper1", "keeper2", "standby"]))
    def remove_keeper(self, k):
        ok, _ = self.s.remove_keeper(k)
        # HYP-39 verifies: Q-053, Q-139, Q-155, Q-242, Q-400 (a removal never leaves fewer than keeperFloor unfrozen
        # keepers; a guardian freeze may, which halts new borrowing)
        if ok:
            assert len(self.s.unfrozen_keepers()) >= self.s.p.keeper_floor


AvanaMachine.TestCase.settings = cfg(400, 60)
TestAvanaStateMachine = AvanaMachine.TestCase
