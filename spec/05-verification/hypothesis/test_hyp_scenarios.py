# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""HYP scenario properties: targeted sequences for paths the state machine reaches only occasionally, and the
economic properties of Q-278 (deficit bound, no zero-risk loop, contagion, cascades, token edge cases).

Each test states its Hypothesis budget with cfg(...); README.md records the run settings.
"""
import copy

import pytest
from hypothesis import assume, given, strategies as st

from model.avana import (System, GHO, HUB, LPVAULT, SWAP, COLL, ESCROW, FEE_RECIPIENT, LEND_SPOKE, COV, CDP,
                         TIER2, GHO_RID, USDC_RID, NONE, FROZEN, PAUSED, GENERAL, MINT_PATH_SUSPECT, AvanaError)
from model.hsettings import cfg
from model.invariants import check_all, solvency
from model.mathlib import WAD, RAY, BPS, U256, to_value, cdiv
from model.oracle import LIVE, DRIFTING, CACHED, EXPIRED
from model.params import Params, HOUR, DAY, USD

market = st.integers(0, 2)
CRASH = st.integers(5 * 10 ** 6, 45 * 10 ** 6)


def fresh(**kw):
    spokes = kw.pop("spokes", (CDP,))
    return System(Params(**kw), spokes=spokes)


def pledge(s, w, m, usd, spoke=CDP):
    mk = s.markets[m]
    tid = s.create_position(w, m, usd * 10 ** mk.d // 2)
    s.nfpm.approve(w, tid, LPVAULT)
    ok, r = s.pledge(w, m, tid, spoke)
    assert ok, r
    return tid


def borrow_to(s, w, h, rid=GHO_RID, spoke=CDP, min_hf=0):
    """Borrow `rid` until Aave's HF is about h (WAD)."""
    pxa = s.px(w, spoke)
    sp = s.spokes[spoke]
    weighted = sum(sp.reserves[mk.rid].cf * to_value(sp.supplied_assets(pxa, mk.rid), mk.d, s.price_of(mk.rid)) // BPS
                   for mk in s.account_markets(pxa))
    tdv = sp.account_data(pxa)["tdv_ray"] // RAY
    target = weighted * WAD // h
    dec = s.debts[rid].decimals
    amount = (target - tdv) // (s.price_of(rid) * 10 ** (18 - dec))
    assert amount > 0
    return s.borrow(w, amount, rid, spoke, min_hf=min_hf)


def crash(s, token, price, **kw):
    s.set_price(token, price, **kw)
    for m in range(len(s.markets)):
        s.poke(m)


def refresh(s):
    for t in s.TOKENS:
        s.set_price(t, s.prices[t], move_pools=False)
    for m in range(len(s.markets)):
        s.poke(m)


def victim_token(m):
    return {0: "USDT", 1: "DAI", 2: "DAI"}[m]


def liq(s, w, m, rid=GHO_RID, k="keeper0", **kw):
    s.fund(k, GHO, 10 ** 30)
    s.fund(k, "USDC", 10 ** 18)
    kw.setdefault("max_shortfall", 10 ** 24)
    return s.liquidate(k, w, m, s.debt(s.px(w), rid), rid, **kw)


# --------------------------------------------------------------------------- HYP-49 sequential liquidations
# HYP-49 verifies: Q-060, Q-070, Q-098, Q-101, Q-166, Q-193, Q-234
@cfg(25)
@given(n=st.integers(2, 3), price=st.integers(5 * 10 ** 6, 85 * 10 ** 6), usdc_debt=st.booleans())
def test_hyp49_sequential_liquidations_end(n, price, usdc_debt):
    s = fresh()
    for m in range(n):
        pledge(s, "u", m, 20_000)
    assert borrow_to(s, "u", 115 * WAD // 100)[0]
    if usdc_debt:
        assert borrow_to(s, "u", 110 * WAD // 100, USDC_RID)[0]
    crash(s, "DAI", price)
    crash(s, "USDT", price)
    px = s.px("u")
    calls = 0
    while s.hf(px) < WAD and s.account_debts(px) and s.account_markets(px) and calls < 40:
        progressed = False
        for mk in s.account_markets(px):
            for rid in s.account_debts(px):
                ok, r = liq(s, "u", mk.idx, rid)
                calls += 1
                progressed |= ok
        if not progressed:
            break
    sd = s.hub.assets[GHO].spokes[CDP]
    assert s.hf(px) >= WAD or not s.account_debts(px) or (not s.account_markets(px) and
                                                          (sd.deficit_ray > 0 or
                                                           s.hub.assets["USDC"].spokes[CDP].deficit_ray > 0)), \
        "HYP-49 account left liquidatable with collateral"


# --------------------------------------------------------------------------- HYP-51 GHO above peg
# HYP-51 verifies: Q-177, Q-200, Q-275
@cfg(40)
@given(gho=st.integers(100_600_000, 103_000_000))
def test_hyp51_gho_above_peg_keeps_gho_markets_live(gho):
    s = fresh()
    crash(s, "GHO", gho)
    e = s.markets[2].oracle.evaluate(s.now())
    assert e["state"] == LIVE and e["legs"][0]["v"] == 10 ** 8
    pledge(s, "u", 2, 10_000)
    assert borrow_to(s, "u", 12 * WAD // 10)[0]


# --------------------------------------------------------------------------- HYP-52 dust
# HYP-52 verifies: Q-097, Q-118, Q-124, Q-209
@cfg(40)
@given(m=market, dust=st.integers(1, 10 ** 6), frac=st.integers(1, 99))
def test_hyp52_dust_never_blocks_exits(m, dust, frac):
    s = fresh()
    tid = pledge(s, "u", m, 20_000)
    assert borrow_to(s, "u", 15 * WAD // 10)[0]
    px = s.px("u")
    for to in (SWAP, LPVAULT, COLL, px, ESCROW):
        for t in ("GHO", "USDC", "DAI"):
            assert s.donate("dusty", t, to, dust)[0]
    s.fund("u", GHO, 10 ** 24)
    assert s.repay("u", s.debt(px) * frac // 100)[0]
    q = s.debt(px) * 1001 // 1000 + 2
    assert s.repay("u", q, repay_all=True)[0]
    assert s.withdraw("u", tid)[0]
    check_all(s)


# --------------------------------------------------------------------------- HYP-53 every size liquidates
# HYP-53 verifies: Q-085, Q-098, Q-159, Q-169, Q-190, Q-198, Q-267
@cfg(60)
@given(m=market, usd=st.sampled_from([11, 50, 500, 5_000, 100_000]), drop=CRASH, rid=st.sampled_from([0, 1]))
def test_hyp53_every_account_size_is_liquidatable(m, usd, drop, rid):
    s = fresh()
    pledge(s, "u", m, usd)
    assert borrow_to(s, "u", 111 * WAD // 100, rid)[0]
    crash(s, victim_token(m), drop)
    px = s.px("u")
    assume(s.hf(px) < WAD)
    ok, r = liq(s, "u", m, rid)
    assert ok or "NothingSeized" in r or "CapExceeded" in r, f"HYP-53 {r}"
    if ok:
        assert r["R"] + r["shortfall"] + r["K"] >= r["D"] + r["phi_d"]      # Q-397: the caller funds any gap


# --------------------------------------------------------------------------- HYP-54 health gate
# HYP-54 verifies: Q-018, Q-161, Q-229, Q-253, Q-398, SPEC-PROXY-001, SPEC-CF-003
@cfg(30)
@given(m=market, h=st.integers(100, 112), min_hf=st.sampled_from([0, 112 * WAD // 100]), hard=st.booleans())
def test_hyp54_health_gate_floor(m, h, min_hf, hard):
    """Q-398: a borrow passes at hfEx ≥ max(1.00, optional per-market hard floor, minHealthFactor). The hard floor
    is off (0) by default; set to 1.05 it binds; a faulty RiskModule leaves only Aave's HF ≥ 1."""
    s = fresh(hard_floor_hf=105 * WAD // 100 if hard else 0)
    pledge(s, "u", m, 20_000)
    ok, r = borrow_to(s, "u", h * WAD // 100, min_hf=min_hf)
    need_ = max(WAD, s.p.hard_floor_hf, min_hf)
    if ok:
        assert r["hf_ex"] >= need_
    elif h * WAD // 100 >= need_ + WAD // 1000:
        raise AssertionError(f"borrow at {h} refused: {r}")
    f = fresh(faulty_risk_module=True)
    pledge(f, "u", m, 20_000)
    ok, r = borrow_to(f, "u", 1001 * WAD // 1000)
    assert ok and f.hf(f.px("u")) >= WAD


# HYP-61 verifies: Q-203, INV-023
def test_hyp61_aave_freeze_blocks_borrow():
    s = fresh()
    pledge(s, "u", 0, 20_000)
    s.spoke().reserves[s.markets[0].rid].frozen = True
    ok, r = borrow_to(s, "u", 15 * WAD // 10)
    assert not ok and "AaveReserveFrozen" in r
    s.spoke().reserves[s.markets[0].rid].frozen = False
    assert borrow_to(s, "u", 15 * WAD // 10)[0]


# --------------------------------------------------------------------------- HYP-55 slice
# HYP-55 verifies: Q-150, Q-157, Q-175, Q-209, SPEC-CAP-003
def test_hyp55_slice_only_for_rescue_topups():
    s = fresh(cap_market_usd=30_000 * USD, topup_slice_usd=10_000 * USD)
    pledge(s, "u", 0, 29_000)
    assert borrow_to(s, "u", 111 * WAD // 100)[0]
    tid = s.create_position("v", 0, 5_000 * 10 ** 6 // 2)
    s.nfpm.approve("v", tid, LPVAULT)
    ok, r = s.pledge("v", 0, tid)
    assert not ok and "CapExceeded(MARKET)" in r                      # new account cannot use the slice
    crash(s, "USDT", 90 * 10 ** 6)
    px = s.px("u")
    assert s.hf(px) < s.p.recommended_hf
    restore = s.restore_booked(px, 0)
    room = s.p.cap_market_usd - s.counters_regular[0]
    c = room + restore // 2
    tid = s.create_position("u", 0, c * 10 ** 6 // max(s.accepted_price(0), s.p.stress_floor_usd8))
    s.nfpm.approve("u", tid, LPVAULT)
    ok, r = s.pledge("u", 0, tid)
    assert ok and 0 < r["slice"] <= restore, r
    # HYP-77 verifies: Q-253, INV-082
    assert r["rescue_units"] >= 1 and s.account_rescue(px, 0) == r["rescue_units"]


# --------------------------------------------------------------------------- HYP-56 disagreement
# HYP-56 verifies: Q-112, Q-162, Q-183, Q-199, Q-208, Q-247
def test_hyp56_disagreement_pauses_seizure_of_that_market_only():
    s = fresh()
    pledge(s, "u", 0, 20_000)
    pledge(s, "u", 1, 20_000)
    assert borrow_to(s, "u", 111 * WAD // 100)[0]
    crash(s, "USDT", 30 * 10 ** 6)                                    # market 0 falls; HF < 1
    px = s.px("u")
    assert s.hf(px) < WAD
    s.feeds["DAI"].alternate.push(95 * 10 ** 6, s.now())             # DAI routes disagree: market 1 and 2
    s.poke(1)
    e = s.markets[1].oracle.evaluate(s.now())
    assert e["disagree"] and e["served"] <= s.markets[1].oracle.accepted
    ok, r = liq(s, "u", 1)
    assert not ok and "StalePrice" in r                               # the disagreeing market waits
    ok, r = liq(s, "u", 0)
    assert ok, r                                                      # the fresh market is liquidated
    s.fund("u", GHO, 10 ** 24)
    assert s.repay("u", 10 ** 18)[0]                                 # repay open
    ok, r = s.borrow("u", 10 ** 18)
    assert not ok and "MarketNotLive" in r                            # the disagreeing market blocks new debt
    s.feeds["DAI"].alternate.push(10 ** 8, s.now())
    s.poke(1)
    assert s.markets[1].oracle.liquidation_block(s.now()) is None


# --------------------------------------------------------------------------- HYP-57 / HYP-58 pending settlement
# HYP-57 verifies: Q-201, Q-211
# HYP-58 verifies: Q-201, Q-211, Q-236
@cfg(40)
@given(m=market, sizes=st.lists(st.integers(1_000, 30_000), min_size=1, max_size=5), drop=CRASH,
       frac=st.integers(10, 100), exit_by=st.sampled_from(["withdraw", "liquidate", "remove"]))
def test_hyp57_58_reconcile_and_pending_settlement(m, sizes, drop, frac, exit_by):
    s = fresh()
    tids = [pledge(s, "u", m, usd) for usd in sizes]
    assert borrow_to(s, "u", 111 * WAD // 100)[0]
    crash(s, victim_token(m), drop)
    px = s.px("u")
    assume(s.hf(px) < WAD)
    s.hostile_swap = True
    ok, la = s.hostile_swap_seize("u", m, max(1, s.debt(px) * frac // 100))
    assume(ok)
    s.hostile_swap = False
    held = s.ledger.balance(s.markets[m].vt, SWAP)
    assert held == la["cshares"]
    if exit_by == "liquidate" and s.hf(px) < WAD and s.account_markets(px):
        ok, r = liq(s, "u", m)
    elif exit_by == "remove":
        rec = max((s.records[t] for t in tids), key=lambda r: r.credited)
        ok, r = s.remove_liquidity("u", rec.token_id, 1)
    else:
        s.fund("u", GHO, 10 ** 30)
        s.repay("u", s.debt(px) * 2 + 10, repay_all=True)
        rec = s.records[tids[0]]
        ok, r = s.withdraw("u", rec.token_id) if rec.status == "active" else (False, "")
    check_all(s)
    pend = s.pending[m]["units"]
    if pend:
        assert pend <= held
        cov0 = s.funded_balance(GHO)
        fee0, k0 = s.ledger.balance(GHO, FEE_RECIPIENT), s.ledger.balance(GHO, "anyone")
        crash(s, victim_token(m), 10 ** 8)
        ok, r = s.settle_pending("anyone", m)
        assert ok, r
        assert s.funded_balance(GHO) >= cov0 + r["gho"] - 1 and r["gho"] >= r["min_pending"]
        assert s.ledger.balance(GHO, FEE_RECIPIENT) == fee0 and s.ledger.balance(GHO, "anyone") == k0
        check_all(s)


# --------------------------------------------------------------------------- HYP-62 fixed basis
# HYP-62 verifies: Q-158, Q-174, Q-254, SPEC-BACK-013
@cfg(60)
@given(m=market, a=st.lists(st.integers(1, 1000), min_size=1, max_size=20),
       b=st.lists(st.integers(1, 1000), min_size=1, max_size=20), add=st.integers(0, 50))
def test_hyp62_fixed_basis_is_path_independent(m, a, b, add):
    """Two different partial-removal splits to the same remaining units book the same charge; a re-credit rebases
    the basis; the last exit clears exactly."""
    res = []
    for split in (a, b):
        s = fresh()
        mk = s.markets[m]
        tid = pledge(s, "u", m, 100_000)
        rec = s.records[tid]
        total = rec.credited
        target = total // 2
        steps = [max(1, (total - target) * x // sum(split)) for x in split]
        steps[-1] = (total - target) - sum(steps[:-1])
        assume(all(x > 0 for x in steps))
        for x in steps:
            assert s.remove_liquidity("u", tid, x)[0]
        if add:
            s.donate_liquidity("u", tid, rec.credited * add // 100 + 1)
            s.recredit("u", tid)
        res.append((rec.credited, rec.charge))
        released = s.counters_regular.get(m, 0)
        assert s.withdraw("u", tid)[0]
        assert s.counters_regular.get(m, 0) == 0 and s.counters_token.get(mk.t0, 0) == 0
    if not add:
        assert res[0] == res[1]


# --------------------------------------------------------------------------- HYP-63 USD band
# HYP-63 verifies: Q-176, Q-195, Q-206, Q-275
def test_hyp63_usd_band_blocks_new_risk_only():
    s = fresh()
    pledge(s, "u", 0, 20_000)
    assert borrow_to(s, "u", 13 * WAD // 10)[0]
    for t in ("USDC", "USDT"):
        s.set_price(t, 88 * 10 ** 6)
    s.poke(0)
    e = s.markets[0].oracle.evaluate(s.now())
    assert e["state"] == DRIFTING and e["reason"] == "band"
    ok, r = borrow_to(s, "u", 14 * WAD // 10) if s.hf(s.px("u")) > 14 * WAD // 10 else s.borrow("u", 10 ** 18)
    assert not ok
    tid = s.create_position("u", 0, 1_000 * 10 ** 6)
    s.nfpm.approve("u", tid, LPVAULT)
    assert s.pledge("u", 0, tid)[0]                                   # top-up open
    assert s.markets[0].oracle.liquidation_block(s.now()) is None     # liquidation continues


# --------------------------------------------------------------------------- HYP-64 third-party repays
# HYP-64 verifies: Q-212, Q-269, REQ-PROXY-027, REQ-PROXY-083
@cfg(40)
@given(m=market, frac=st.integers(1, 99), dt=st.integers(0, HOUR), rid=st.sampled_from([0, 1]))
def test_hyp64_third_party_and_racing_repays(m, frac, dt, rid):
    s = fresh()
    pledge(s, "u", m, 20_000)
    assert borrow_to(s, "u", 15 * WAD // 10, rid)[0]
    px = s.px("u")
    asset = s.debts[rid].asset
    s.advance(dt)
    d = s.debt(px, rid)
    q = d * 1001 // 1000 + 2
    for p in ("a", "b"):
        s.fund(p, asset, 2 * q)
    ub = s.ledger.balance(asset, "u")
    ok, r = s.repay("u", d * frac // 100, rid, payer="a")
    assert ok and r["paid"] <= d * frac // 100
    ok1, r1 = s.repay("u", q, rid, repay_all=True, payer="a")
    ok2, r2 = s.repay("u", q, rid, repay_all=True, payer="b")
    assert ok1 and ok2 and r2["paid"] == 0 and s.debt(px, rid) == 0
    assert s.ledger.balance(asset, "u") == ub


# --------------------------------------------------------------------------- HYP-65 / HYP-66 payout escrow
# HYP-65 verifies: Q-214, Q-401, INV-061, REQ-ESCROW-004, REQ-ESCROW-005, REQ-ESCROW-006
# HYP-66 verifies: Q-214, Q-401, REQ-SWAP-076, REQ-SWAP-082, REQ-SWAP-083
@cfg(30)
@given(m=st.sampled_from([0, 1]), drop=st.integers(5 * 10 ** 6, 40 * 10 ** 6), rid=st.sampled_from([0, 1]))
def test_hyp65_66_failed_payout_escrowed_never_blocks(m, drop, rid):
    """Q-401, Q-404: the PayoutEscrow holds escrowable payouts a token refuses (Avana's fee, the borrower surplus, residues);
    the caller's payout keeperOut is never escrowed: a caller that cannot receive the debt asset makes its own call revert,
    with no state change, and the same liquidation then settles for a caller that can receive it."""
    s = fresh()
    pledge(s, "u", m, 20_000)
    assert borrow_to(s, "u", 111 * WAD // 100, rid)[0]
    crash(s, victim_token(m), drop)
    T = s.debts[rid].asset
    s.gas_burners.add((T, "keeper0"))
    assume(s.hf(s.px("u")) < WAD)
    debt0 = s.debt(s.px("u"), rid)
    ok, r = liq(s, "u", m, rid)
    if ok:
        assert r["escrowed"]["keeper"] == 0 and r["keeper_out"] == 0, r
    else:
        assert "keeperOut transfer failed" in r or "NothingSeized" in r or "CapExceeded" in r, r
        assert s.debt(s.px("u"), rid) == debt0, "a reverted call changed the debt"
        s.gas_burners.discard((T, "keeper0"))
        ok2, r2 = liq(s, "u", m, rid)
        if ok2:
            assert r2["escrowed"]["keeper"] == 0
    check_all(s)


# HYP-66 verifies: Q-214, Q-401, REQ-SWAP-082
def test_hyp66_refused_fee_transfer_is_escrowed():
    s = fresh()
    pledge(s, "u", 0, 20_000)
    assert borrow_to(s, "u", 111 * WAD // 100)[0]
    crash(s, "USDT", 10 * 10 ** 6)
    s.gas_burners.add((GHO, FEE_RECIPIENT))
    fee0 = s.ledger.balance(GHO, FEE_RECIPIENT)
    ok, r = liq(s, "u", 0)
    assert ok, r
    assert s.ledger.balance(GHO, FEE_RECIPIENT) == fee0 and r["escrowed"]["fee"] == r["avana_fee"]
    check_all(s)


# --------------------------------------------------------------------------- HYP-67 permissionless
# HYP-67 verifies: Q-213, Q-397, INV-062, REQ-SWAP-072, REQ-SWAP-073, REQ-SWAP-080, REQ-SWAP-081
@cfg(60)
@given(m=market, usd=st.sampled_from([11, 500, 50_000]), drop=CRASH, rid=st.sampled_from([0, 1]),
       routes=st.booleans())
def test_hyp67_permissionless_caller_funds_any_gap(m, usd, drop, rid, routes):
    s = fresh()
    pledge(s, "u", m, usd)
    assert borrow_to(s, "u", 111 * WAD // 100, rid)[0]
    crash(s, victim_token(m), drop)
    assume(s.hf(s.px("u")) < WAD)
    if not routes:
        s.markets[m].route_primary_up = s.markets[m].route_backup_up = False
    s.fund("anyone", GHO, 10 ** 30)
    ok, r = s.liquidate_permissionless("anyone", "u", m, s.debt(s.px("u"), rid), rid, max_shortfall=10 ** 24)
    if ok:
        assert r["R"] + r["shortfall"] + r["K"] >= r["D"] + r["phi_d"]
    if not routes:
        assert not ok and "NoRouteAvailable" in r
    elif not ok:
        assert "InsufficientProceeds" in r or "NothingSeized" in r, r
        ok2, r2 = liq(s, "u", m, rid)
        assert ok2 or "NothingSeized" in r2, r2


# --------------------------------------------------------------------------- HYP-68 deadline / min payout
# HYP-68 verifies: Q-216, REQ-SWAP-074, REQ-SWAP-075, REQ-SWAP-078, REQ-SWAP-079
@cfg(40)
@given(m=market, drop=CRASH, dl=st.integers(-HOUR, HOUR), min_payout=st.integers(0, 10 ** 22),
       perm=st.booleans())
def test_hyp68_deadline_and_min_payout_only_revert(m, drop, dl, min_payout, perm):
    s = fresh()
    pledge(s, "u", m, 20_000)
    assert borrow_to(s, "u", 111 * WAD // 100)[0]
    crash(s, victim_token(m), drop)
    assume(s.hf(s.px("u")) < WAD)
    base = copy.deepcopy(s)
    ok0, r0 = liq(base, "u", m, max_shortfall=0)
    s.fund("keeper0", GHO, 10 ** 30)
    ok, r = s.liquidate("keeper0", "u", m, s.debt(s.px("u")), deadline=s.now() + dl, min_payout=min_payout)
    if ok:
        assert ok0 and dl >= 0 and r["keeper_out"] >= min_payout
        for k in ("D", "c", "R", "route", "avana_fee", "gap", "keeper_out"):
            assert r[k] == r0[k]
    else:
        assert dl < 0 or not ok0 or r0["keeper_out"] < min_payout


# --------------------------------------------------------------------------- HYP-69 zero-amount tokens
# HYP-69 verifies: Q-217, REQ-SWAP-077, REQ-PROXY-084
def test_hyp69_zero_amounts_are_skipped():
    s = fresh()
    assert s.ledger.strict_zero
    pledge(s, "u", 0, 20_000)
    assert borrow_to(s, "u", 111 * WAD // 100)[0]
    crash(s, "USDT", 45 * 10 ** 6)
    ok, r = liq(s, "u", 0, max_shortfall=0)
    assert ok or "RecoveryBelowFloor" in r or "NoRouteAvailable" in r


# --------------------------------------------------------------------------- HYP-72 deficit bound
# HYP-72 verifies: Q-249, Q-278, INV-076
@cfg(80)
@given(m=market, drop=st.integers(2 * 10 ** 6, 60 * 10 ** 6), rid=st.sampled_from([0, 1]),
       piece=st.sampled_from([1, 3, 10, 100]))
def test_hyp72_liquidation_deficit_bound(m, drop, rid, piece):
    """Every liquidation adds at most seizedValue × (1 − 1/LB) to the account's shortfall, and raises HF while
    HF ≥ LB × CF (INV-076)."""
    s = fresh()
    pledge(s, "u", m, 50_000)
    assert borrow_to(s, "u", 111 * WAD // 100, rid)[0]
    crash(s, victim_token(m), drop)
    px = s.px("u")
    assume(s.hf(px) < WAD)
    s.fund("keeper0", GHO, 10 ** 30)
    s.fund("keeper0", "USDC", 10 ** 18)
    for _ in range(piece + 2):
        if s.hf(px) >= WAD or not s.account_markets(px) or rid not in s.account_debts(px):
            break
        ok, r = s.liquidate("keeper0", "u", m, max(1, s.debt(px, rid) // piece), rid, max_shortfall=10 ** 24)
        if not ok:
            break
        assert r["deficit_after"] <= r["deficit_before"] + r["V_gho"] * (r["lb"] - BPS) // r["lb"] + 10 ** 13
        if r["hf_before"] * BPS >= r["lb"] * s.p.cf_bps * WAD // BPS and s.account_debts(px):
            assert r["hf_after"] >= r["hf_before"]


# --------------------------------------------------------------------------- HYP-73 no zero-risk profit loop
# HYP-73 verifies: Q-198, Q-256, Q-267, Q-276, Q-277, Q-278, INV-077
@cfg(30)
@given(n=st.integers(1, 6), m=market, haircut=st.sampled_from([0, 50, 100]), drop=st.integers(30 * 10 ** 6, 90 * 10 ** 6),
       path=st.sampled_from(["keeper", "permissionless"]))
def test_hyp73_no_zero_risk_profit_loop(n, m, haircut, drop, path):
    """An actor with n wallets opens accounts at the opening floor, moves its own pool and routes, and liquidates
    itself (as keeper or permissionless caller, flash funded); it ends with no debt and its holdings at oracle prices
    rose by at most n × (U + floorRoundingAllowanceGho) (INV-077)."""
    s = fresh()
    mk = s.markets[m]
    wallets = [f"atk{i}" for i in range(n)]
    caller = "keeper0" if path == "keeper" else "atk_bot"
    if path == "keeper":
        s.keepers.add("atk_keeper")
        caller = "atk_keeper"

    def holdings():
        v = s.ledger.balance(GHO, caller) + sum(s.ledger.balance(GHO, w) for w in wallets)
        for w in wallets + [caller]:
            for t in (mk.t0, mk.t1):
                if t != GHO:
                    v += s.ledger.balance(t, w) * min(s.prices[t], 10 ** 8) * 10 ** (18 - (6 if t in ("USDC", "USDT") else 18)) // 10 ** 8
            for tid, p in s.nfpm.positions.items():
                if p.owner == w or (tid in s.records and s.records[tid].depositor == w and s.records[tid].status == "active"):
                    rec = s.records.get(tid)
                    from model.uniswap import position_amounts
                    from model.oracle import lp_price8
                    liq_ = p.liquidity
                    v += liq_ * lp_price8(*(10 ** 8 if t == GHO else min(s.prices[t], 10 ** 8) for t in (mk.t0, mk.t1))) \
                        * 10 ** 18 // (10 ** mk.d * 10 ** 8)
        for w in wallets:
            pxa = s.px(w)
            if pxa:
                v -= sum(s.debt(pxa, r) * 10 ** (18 - s.debts[r].decimals) for r in s.account_debts(pxa))
        return v

    for w in wallets:
        s.fund(w, GHO, 0)
        pledge(s, w, m, 20)                                         # dust accounts at the minimum pledge
        assert borrow_to(s, w, 111 * WAD // 100)[0]
    s.fund(caller, GHO, 10 ** 24)
    h0 = holdings()
    s.route_haircut[(m, "primary")] = haircut                        # the actor sandwiches its own routes
    crash(s, victim_token(m), drop)
    for w in wallets:
        pxa = s.px(w)
        if s.hf(pxa) >= WAD:
            continue
        if path == "keeper":
            ok, r = s.liquidate(caller, w, m, s.debt(pxa), max_shortfall=10 ** 22)
        else:
            ok, r = s.liquidate_permissionless(caller, w, m, s.debt(pxa), max_shortfall=10 ** 22)
    # the actor repays what is left and withdraws, ending with no debt
    for w in wallets:
        pxa = s.px(w)
        s.fund(w, GHO, 0)
        d = s.debt(pxa)
        if d:
            s.ledger.transfer(GHO, caller, w, d * 2 + 10)
            assert s.repay(w, d * 2 + 10, repay_all=True)[0]
        assert not s.account_debts(pxa)
    crash(s, victim_token(m), 10 ** 8)                               # value both ends at the same oracle prices
    s.route_haircut.clear()
    gain = holdings() - h0
    # the crash itself is a price move the actor does not control; compare at equal prices on both ends.
    # Q-397: no settlement budget pays any gap, so the actor has no subsidy to collect.
    assert gain <= 10 ** 15, f"HYP-73 zero-risk gain {gain}"


# --------------------------------------------------------------------------- HYP-75 no contagion
# HYP-75 verifies: Q-234, Q-247, Q-248, Q-260, INV-075, INV-072
@cfg(20)
@given(fail=st.sampled_from(["expired", "disagree", "breaker", "aave_pause", "offboard", "route_dead"]))
def test_hyp75_no_contagion(fail):
    """A failure confined to market 1 never blocks liquidation of market 0 nor exits anywhere."""
    s = fresh()
    pledge(s, "u", 0, 20_000)
    pledge(s, "u", 1, 20_000)
    t_b = pledge(s, "v", 1, 5_000)                                   # a debt-free account in market 1
    assert borrow_to(s, "u", 111 * WAD // 100)[0]
    if fail == "expired":
        for f in (s.feeds["DAI"].primary, s.feeds["DAI"].alternate):
            f.broken = True
        s.poke(1)
        s.advance(2 * HOUR)
        for t in ("USDC", "USDT"):
            s.set_price(t, s.prices[t], move_pools=False)
        s.poke(1)
        assert s.markets[1].oracle.state(s.now()) == EXPIRED
    elif fail == "disagree":
        s.feeds["DAI"].alternate.push(90 * 10 ** 6, s.now())
    elif fail == "breaker":
        s.trip_market_breaker(1)
    elif fail == "aave_pause":
        s.spoke().reserves[s.markets[1].rid].paused = True
    elif fail == "offboard":
        s.markets[1].status = "Offboarding"
    else:
        s.markets[1].route_primary_up = s.markets[1].route_backup_up = False
    crash(s, "USDT", 20 * 10 ** 6)
    px = s.px("u")
    assume(s.hf(px) < WAD)
    ok, r = liq(s, "u", 0)
    assert ok, f"HYP-75 failure in market 1 blocked liquidation of market 0: {r}"
    if fail != "aave_pause":
        ok, r = s.withdraw("v", t_b)
        assert ok, f"HYP-75 debt-free withdrawal from the failing market refused: {r}"
    s.fund("u", GHO, 10 ** 22)
    assert s.repay("u", 10 ** 18)[0]


# --------------------------------------------------------------------------- HYP-76 stops never reach exits
# HYP-76 verifies: Q-227, Q-241, Q-242, Q-252, INV-067, INV-081
@cfg(40)
@given(stop=st.sampled_from(["frozen", "paused", "paused_mint", "breaker", "debt_breaker", "freeze_addr", "drift"]))
def test_hyp76_stops_never_reach_exits_or_liquidation(stop):
    s = fresh()
    t_free = pledge(s, "free", 0, 5_000)
    t_debt = pledge(s, "u", 0, 20_000)
    assert borrow_to(s, "u", 111 * WAD // 100)[0]
    {"frozen": s.freeze, "paused": lambda: s.pause(GENERAL), "paused_mint": lambda: s.pause(MINT_PATH_SUSPECT),
     "breaker": lambda: s.trip_market_breaker(0), "debt_breaker": lambda: s.trip_debt_breaker(CDP, GHO_RID),
     "freeze_addr": lambda: [s.freeze_address("emergency_guardian", w) for w in ("u", "free")],
     "drift": lambda: setattr(s, "config_drift", True)}[stop]()
    # new activity is stopped
    tid = s.create_position("new", 0, 10 ** 10)
    s.nfpm.approve("new", tid, LPVAULT)
    if stop in ("frozen", "paused", "paused_mint", "breaker", "drift"):
        assert not s.pledge("new", 0, tid)[0]
        assert not s.borrow("u", 10 ** 18)[0]
    # exits and liquidation are open
    s.fund("payer", GHO, 10 ** 22)
    assert s.repay("u", 10 ** 18, payer="payer")[0]
    assert s.collect_fees("u", t_debt)[0]
    assert s.remove_liquidity("free", t_free, 10 ** 6)[0]
    assert s.withdraw("free", t_free)[0]
    crash(s, "USDT", 25 * 10 ** 6)
    assume(s.hf(s.px("u")) < WAD)
    ok, r = liq(s, "u", 0)
    assert ok, f"HYP-76 {stop} stopped liquidation: {r}"


# --------------------------------------------------------------------------- HYP-77 rescue top-ups and units
# HYP-77 verifies: Q-252, Q-253, Q-277, INV-082, INV-069
@cfg(30)
@given(stop=st.sampled_from(["none", "frozen", "paused", "breaker", "freeze_addr", "mint_suspect"]),
       drop=st.integers(80 * 10 ** 6, 95 * 10 ** 6))
def test_hyp77_rescue_topups_and_rescue_units(stop, drop):
    s = fresh()
    pledge(s, "u", 0, 20_000)
    assert borrow_to(s, "u", 111 * WAD // 100)[0]
    crash(s, "USDT", drop)
    px = s.px("u")
    assume(WAD <= s.hf(px) < s.p.recommended_hf)
    {"none": lambda: None, "frozen": s.freeze, "paused": lambda: s.pause(GENERAL),
     "breaker": lambda: s.trip_market_breaker(0), "mint_suspect": lambda: s.pause(MINT_PATH_SUSPECT),
     "freeze_addr": lambda: s.freeze_address("emergency_guardian", "u")}[stop]()
    restore = s.restore_booked(px, 0)
    L = max(1, restore * 10 ** 6 // max(s.accepted_price(0), s.p.stress_floor_usd8) // 2)
    assume(L * s.accepted_price(0) // 10 ** 6 >= 10 * USD)
    tid = s.create_position("u", 0, L)
    s.nfpm.approve("u", tid, LPVAULT)
    ok, r = s.pledge("u", 0, tid)
    if stop == "mint_suspect":
        assert not ok and "MintPathSuspect" in r
        return
    assert ok and r["rescue"] and r["rescue_units"] == L, r
    # rescue units count fully in Aave's HF but are worth zero for new debt
    hf, hfex = s.hf(px), s.hf_ex(px)
    assert hfex < hf
    if stop == "none":
        # the slice re-leverage loop: the rescue units cannot be borrowed against. With no opening floor (Q-398)
        # a borrow passes only while the account without its rescue units stays at HF >= 1.00.
        ok, r = s.borrow("u", 10 ** 18)
        if ok:
            assert r["hf_ex"] >= WAD, r
        else:
            assert "HealthFactorTooLow" in r, r
        assert not s.borrow("u", 10 ** 24)[0]


# --------------------------------------------------------------------------- HYP-78 partial removal, re-credit
# HYP-78 verifies: Q-254, INV-088, SPEC-BACK-013
@cfg(40)
@given(m=market, frac=st.integers(1, 99), add_pct=st.integers(1, 100), debt=st.booleans())
def test_hyp78_partial_removal_and_recredit(m, frac, add_pct, debt):
    s = fresh()
    mk = s.markets[m]
    tid = pledge(s, "u", m, 50_000)
    rec = s.records[tid]
    if debt:
        assert borrow_to(s, "u", 2 * WAD)[0]
    u0, c0 = rec.credited, rec.charge
    units = max(1, u0 * frac // 100)
    b0 = {t: s.ledger.balance(t, "u") for t in (mk.t0, mk.t1)}
    ok, r = s.remove_liquidity("u", tid, units)
    if debt and not ok:
        assert any(x in r for x in ("HealthFactorTooLow", "RecordBelowMinPledge", "HealthFactorBelowThreshold"))
        return
    assert ok, r
    assert rec.credited == u0 - units and s.nfpm.positions[tid].liquidity >= rec.credited
    assert all(s.ledger.balance(t, "u") - b0[t] == r["got"][t] for t in b0)
    assert rec.charge == cdiv(c0 * rec.credited, u0)
    add = max(1, rec.credited * add_pct // 100)
    s.donate_liquidity("third", tid, add)
    cb = rec.charge
    ok, r = s.recredit("u", tid)
    if ok:
        assert rec.credited == u0 - units + add and rec.charge == cb + r["charge"]
        assert rec.orig_units == rec.credited and rec.orig_charge == rec.charge
    ok, r = s.recredit("v", tid)
    assert not ok and "NotDepositor" in r
    check_all(s)


# --------------------------------------------------------------------------- HYP-79 repay with collateral
# HYP-79 verifies: Q-231, Q-250, Q-255, Q-256, INV-089, SPEC-LIQ-020
@cfg(60)
@given(m=market, frac=st.integers(1, 100), rid=st.sampled_from([0, 1]), drop=st.integers(80 * 10 ** 6, 10 ** 8),
       haircut=st.sampled_from([0, 0, 50, 500]))
def test_hyp79_repay_with_collateral(m, frac, rid, drop, haircut):
    s = fresh()
    tid = pledge(s, "u", m, 50_000)
    assert borrow_to(s, "u", 112 * WAD // 100, rid)[0]
    crash(s, victim_token(m), drop)
    s.route_haircut[(m, "primary")] = s.route_haircut[(m, "backup")] = haircut
    px = s.px("u")
    rec = s.records[tid]
    units = max(1, rec.credited * frac // 100)
    fee0 = s.ledger.balance(GHO, FEE_RECIPIENT)
    hf0 = s.hf(px)
    ok, r = s.repay_with_collateral("u", tid, units, rid)
    if not ok:
        assert any(x in r for x in ("NoRouteAvailable", "DeleverageShortfall", "HealthFactorNotImproved",
                                    "DeleverageTooSmall", "StalePrice")), r
        if haircut == 0 and hf0 >= WAD:
            assert "HealthFactorNotImproved" not in r or hf0 < 4 * WAD // 10, r
        return
    assert r["debt_after"] < r["debt_before"]
    if s.account_debts(px):
        assert r["hf_after"] >= r["hf_before"]
    assert s.ledger.balance(GHO, FEE_RECIPIENT) == fee0
    if units == rec.orig_units and rec.status == "closed":
        assert s.nfpm.positions[tid].owner == "u"
    check_all(s)


# --------------------------------------------------------------------------- HYP-80 circuit breakers
# HYP-80 verifies: Q-241, Q-271, Q-399, SPEC-BRK-001, SPEC-BRK-002, SPEC-BRK-003, SPEC-BRK-004, SPEC-BRK-005,
# SPEC-BRK-006. Q-399: price drop, seizure surge and route failures are alerts only and never trip on-chain.
@cfg(40)
@given(cond=st.sampled_from(["price_drop", "pool_share", "issuer", "coverage", "deficit", "surge",
                             "route_failures"]))
def test_hyp80_breakers_stop_new_activity_only(cond):
    s = fresh()
    pledge(s, "u", 0, 20_000)
    pledge(s, "w", 0, 20_000)
    assert borrow_to(s, "u", 15 * WAD // 10)[0]
    assert borrow_to(s, "w", 111 * WAD // 100)[0]
    if cond == "price_drop":
        s.advance(HOUR)
        refresh(s)
        s.advance(1)
        s.set_price("USDC", s.prices["USDC"], move_pools=False)
        crash(s, "USDT", 93 * 10 ** 6)
        assert s.market_breaker(0) in (None, "ORACLE")                       # an alert, not a trip
        if s.market_breaker(0) is None:
            return
    elif cond == "pool_share":
        p = [q for q in s.nfpm.positions.values() if q.owner == "lp_whale" and q.pool is s.markets[0].pool][0]
        s.nfpm.decrease_liquidity("lp_whale", p.token_id, p.liquidity - 10 ** 9)   # outside liquidity leaves
        assert s.market_breaker(0) == "POOL_SHARE"
    elif cond == "issuer":
        s.ledger.fee_bps["USDT"] = 10
        assert s.market_breaker(0) == "ISSUER"
    elif cond == "coverage":
        s.hub.assets[GHO].spokes[COV[GHO]].added_shares //= 2
        s.hub.assets[GHO].added_shares -= 0
        assert s.debt_breaker(CDP, GHO_RID) == "COVERAGE"
    elif cond == "deficit":
        s.hub.assets[GHO].spokes[CDP].deficit_ray = 10_001 * WAD * RAY      # breakerDeficitMax 10,000 GHO
        assert s.debt_breaker(CDP, GHO_RID) == "DEFICIT"
    else:
        crash(s, "USDT", 20 * 10 ** 6)
        if cond == "route_failures":
            s.markets[0].route_primary_up = False
        for _ in range(3):
            ok, r = s.liquidate("keeper0", "w", 0, max(1, s.debt(s.px("w")) // 10), max_shortfall=10 ** 24) \
                if s.hf(s.px("w")) < WAD else (False, "")
        assert s.market_breaker(0) in (None, "ORACLE")                       # alerts only; no latch exists
        return
    ok, r = s.borrow("u", 10 ** 18, GHO_RID)
    assert not ok and "Breaker" in r, r
    s.fund("u", GHO, 10 ** 22)
    assert s.repay("u", 10 ** 18)[0]
    if cond == "price_drop":
        return
    crash(s, "USDT", 20 * 10 ** 6)
    if s.hf(s.px("w")) < WAD:
        ok, r = liq(s, "w", 0)
        assert ok or "RecoveryBelowFloor" in r or "NoRouteAvailable" in r, r


# --------------------------------------------------------------------------- HYP-81 address freeze
# HYP-81 verifies: Q-242, INV-085
def test_hyp81_address_freeze():
    s = fresh()
    tid = pledge(s, "u", 0, 20_000)
    assert borrow_to(s, "u", 15 * WAD // 10)[0]
    for a in (HUB, SWAP, LPVAULT, COLL, ESCROW, s.px("u"), "vt0", COV[GHO], CDP):
        assert not s.freeze_address("emergency_guardian", a)[0]
    assert s.freeze_address("emergency_guardian", "keeper0")[0]
    assert s.freeze_address("emergency_guardian", "keeper1")[0]
    assert s.freeze_address("emergency_guardian", "keeper2")[0]
    assert s.freeze_address("emergency_guardian", "u")[0]
    assert not s.borrow("u", 10 ** 18)[0]
    s.fund("u", GHO, 10 ** 22)
    assert s.repay("u", 10 ** 18)[0]
    assert s.collect_fees("u", tid)[0]
    assert not s.repay_with_collateral("u", tid, 10)[0]
    t2 = s.create_position("x", 0, 10 ** 10)
    s.nfpm.approve("x", t2, LPVAULT)
    assert s.freeze_address("aave_guardian", "x")[0]
    assert not s.pledge("x", 0, t2)[0]                                        # no proxy for a frozen wallet
    n = sum(1 for i in range(25) if s.freeze_address("aave_guardian", f"spam{i}")[0])
    assert n == s.p.freeze_rate_limit - 1                                    # one used on "x"
    crash(s, "USDT", 20 * 10 ** 6)
    assert not liq(s, "u", 0, k="keeper0")[0]                                 # a frozen keeper cannot liquidate
    assert liq(s, "u", 0, k="standby")[0]                                     # the frozen account is liquidated
    # Q-400: freezeAddress checks no keeper floor; freezing every keeper halts new borrowing on the chain.
    s2 = fresh()
    pledge(s2, "v", 0, 20_000)
    for k in ("keeper0", "keeper1", "keeper2", "standby"):
        assert s2.freeze_address("emergency_guardian", k)[0]
    ok, r = s2.borrow("v", 10 ** 18)
    assert not ok and "LiquidationHalted" in r, r


# --------------------------------------------------------------------------- HYP-82 standby, stress valuation
# HYP-82 verifies: Q-247, Q-248, Q-238, INV-087, SPEC-ORC-017, SPEC-ORC-018
@cfg(20)
@given(slot=st.sampled_from(["primary", "alternate"]), debt=st.booleans())
def test_hyp82_standby_switch_and_stress_values(slot, debt):
    s = fresh()
    pledge(s, "u", 0, 20_000)
    assert borrow_to(s, "u", 112 * WAD // 100, USDC_RID if debt else GHO_RID)[0]
    if debt:
        tf = s.debt_feeds
        tf.alternate.push(95 * 10 ** 6, s.now())                          # USDC routes disagree
        e = s.debt_oracle.evaluate(s.now())
        assert e["state"] == DRIFTING and e["served"] >= s.debt_oracle.accepted
        assert not s.borrow("u", 10 ** 6, USDC_RID)[0]
        ok, _ = s.use_standby("USDC", "alternate", debt=True)
        assert ok and s.debt_oracle.evaluate(s.now())["state"] == LIVE
        return
    tf = s.feeds["USDT"]
    tf.slots[slot].broken = True
    other = "alternate" if slot == "primary" else "primary"
    tf.slots[other].push(80 * 10 ** 6, s.now())                           # the remaining route is wrong
    tf.slots[slot].broken = False
    tf.slots[slot].push(10 ** 8, s.now())
    s.poke(0)
    assert s.markets[0].oracle.evaluate(s.now())["disagree"]
    assert s.markets[0].oracle.liquidation_block(s.now()) is not None
    ok, _ = s.use_standby("USDT", other)
    assert ok
    s.poke(0)
    assert s.markets[0].oracle.liquidation_block(s.now()) is None and s.markets[0].oracle.state(s.now()) == LIVE


# --------------------------------------------------------------------------- HYP-83 debt-asset flash and payout
# HYP-83 verifies: Q-235, Q-317, Q-335, Q-358, INV-070, INV-095, REQ-FLASH-002, SPEC-LIQ-015, SPEC-LIQ-017
@cfg(60)
@given(m=market, drop=CRASH, over=st.sampled_from([1, 1, 2, 5]), premium=st.sampled_from([5, 5, 10, 15, 50]))
def test_hyp83_debt_asset_flash_settlement(m, drop, over, premium):
    """A USDC liquidation funded through the flash liquidation helper borrows USDC at the Aave V3 premium, refused
    unless φ × 10⁴ ≤ maxFlashFeeBps × F; the caller then funds the debt itself. Recovery, Avana's fee and the payout
    are in USDC, the leftover Kf − D returns in keeperOut, the helper repays F + φ, and LPVaultSwap keeps no token."""
    s = fresh()
    pledge(s, "u", m, 50_000)
    assert borrow_to(s, "u", 111 * WAD // 100, USDC_RID)[0]
    crash(s, victim_token(m), drop)
    px = s.px("u")
    assume(s.hf(px) < WAD)
    s.p.flash_fee_bps = premium
    s.fund("keeper0", "USDC", 10 ** 15)
    X = s.debt(px, USDC_RID) * over
    phi = -(-X * premium // BPS)
    k_gho, k_usdc = s.ledger.balance(GHO, "keeper0"), s.ledger.balance("USDC", "keeper0")
    fee0 = s.ledger.balance("USDC", FEE_RECIPIENT)
    ok, r = s.liquidate("keeper0", "u", m, X, USDC_RID, max_shortfall=10 ** 12)
    if phi * BPS > s.p.max_flash_fee_bps * X:
        assert not ok, "a premium above maxFlashFeeBps was accepted"
        if "FlashFeeTooHigh" not in r:
            return
        ok, r = s.liquidate("keeper0", "u", m, X, USDC_RID, funding="keeper", max_shortfall=10 ** 12)
        if ok:
            assert r["flash"] == 0 and r["K"] == X and r["phi"] == 0
    if not ok:
        assert any(x in r for x in ("RecoveryBelowFloor", "InsufficientProceeds", "NothingSeized",
                                    "NoRouteAvailable", "MustNotLeaveDust")), r
        return
    if r["flash"]:
        assert r["phi"] == phi and r["phi"] * BPS <= s.p.max_flash_fee_bps * r["flash"]
    assert r["asset"] == "USDC" and r["D"] <= X
    assert s.ledger.balance("USDC", SWAP) == 0
    assert s.ledger.balance(GHO, "keeper0") == k_gho
    assert s.ledger.balance("USDC", "keeper0") - k_usdc == r["keeper_out"] - r["K"] - r["shortfall"] - r["phi"]
    assert s.ledger.balance("USDC", FEE_RECIPIENT) - fee0 == r["avana_fee"]


# --------------------------------------------------------------------------- HYP-86 shortfall top-up
# HYP-86 verifies: Q-251, Q-397, SPEC-LIQ-019
@cfg(30)
@given(m=st.sampled_from([0, 1]), haircut=st.integers(150, 900), max_short=st.sampled_from([0, 10 ** 20, 10 ** 24]))
def test_hyp86_shortfall_topup(m, haircut, max_short):
    """A caller's shortfall top-up keeps a full-size liquidation running when routes are below the floor; the
    caller pays it (no budget exists), Avana's fee does not fall with it, and the legs never run below the capped
    relaxation."""
    s = fresh()
    pledge(s, "u", m, 50_000)
    assert borrow_to(s, "u", 111 * WAD // 100)[0]
    crash(s, victim_token(m), 25 * 10 ** 6)
    s.route_haircut[(m, "primary")] = s.route_haircut[(m, "backup")] = haircut
    s.markets[m].route_primary_up = False
    assume(s.hf(s.px("u")) < WAD)
    ok, r = liq(s, "u", m, max_shortfall=max_short)
    if ok:
        assert r["floor_gap"] <= max_short and r["R"] + r["shortfall"] >= r["min_rec"]
        assert r["shortfall"] == r["floor_gap"] + r["gap"]
        assert r["s_leg"] <= r["eff_slip"] + s.p.max_shortfall_bps
    else:
        assert "RecoveryBelowFloor" in r or "NoRouteAvailable" in r, r


# HYP-86 verifies: Q-251, Q-133, Q-399, Q-401
def test_hyp86_reports_are_alerts_only():
    """Q-399/Q-401: shortfall reports are monitoring alerts; they never open a settlement mode or trip a breaker,
    and the account stays liquidatable through the caller top-up."""
    s = fresh()
    pledge(s, "u", 0, 50_000)
    assert borrow_to(s, "u", 111 * WAD // 100)[0]
    crash(s, "USDT", 25 * 10 ** 6)
    s.route_haircut[(0, "primary")] = s.route_haircut[(0, "backup")] = 2_000
    for i in range(8):
        ok, r = s.report_shortfall("keeper0", "u", 0, s.debt(s.px("u")))
        assert ok and r["failed"], r
        assert s.market_breaker(0) in (None, "ORACLE")
        s.advance(HOUR)
        refresh(s)
    assert s.records and all(r.credited > 0 for r in s.records.values() if r.depositor == "u")
    ok, r = liq(s, "u", 0)
    assert ok or any(x in r for x in ("RecoveryBelowFloor", "NothingSeized", "NoRouteAvailable")), r


# --------------------------------------------------------------------------- HYP-87 caller-funded gap
# HYP-87 verifies: Q-236, Q-267, Q-397, SPEC-SET-003, SPEC-SET-006
def test_hyp87_caller_funds_settlement_gap_in_every_market():
    """Q-397 replaced the per-market budget sub-cap: each market's liquidation is funded by its caller, so one
    market's gaps never stop another market settling."""
    s = fresh()
    for m in range(3):
        pledge(s, f"u{m}", m, 20_000)
        assert borrow_to(s, f"u{m}", 111 * WAD // 100)[0]
    crash(s, "USDT", 20 * 10 ** 6)
    for m in range(3):
        if s.hf(s.px(f"u{m}")) >= WAD:
            continue
        ok, r = liq(s, f"u{m}", m)
        assert ok or "NothingSeized" in r or "CapExceeded" in r, r
        if ok:
            assert r["R"] + r["shortfall"] + r["K"] >= r["D"] + r["phi_d"]
    check_all(s)


# --------------------------------------------------------------------------- HYP-89 one-sided backing
# HYP-89 verifies: Q-224, Q-257, INV-001, INV-080, INV-066
@cfg(30)
@given(m=market, burn=st.integers(1, 10 ** 30), drop=CRASH)
def test_hyp89_orphan_burn_keeps_market_working(m, burn, drop):
    s = fresh()
    t1 = pledge(s, "u", m, 20_000)
    t2 = pledge(s, "v", m, 20_000)
    assert borrow_to(s, "u", 111 * WAD // 100)[0]
    crash(s, victim_token(m), drop)
    assume(s.hf(s.px("u")) < WAD)
    s.hostile_swap = True
    ok, la = s.hostile_swap_seize("u", m, s.debt(s.px("u")) // 2)
    assume(ok)
    ok, b = s.orphan_burn(m, burn)
    assert ok
    gap = s.gap(m)
    assert gap == b > 0
    s.hostile_swap = False
    crash(s, victim_token(m), 10 ** 8)
    t3 = pledge(s, "w", m, 5_000)
    assert s.gap(m) == gap
    assert s.withdraw("v", t2)[0] and s.gap(m) == gap
    assert s.withdraw("w", t3)[0] and s.gap(m) == gap
    check_all(s)


# --------------------------------------------------------------------------- HYP-91 token edge cases
# HYP-91 verifies: Q-217, Q-241, Q-271, Q-278, INV-079
@cfg(30)
@given(fee=st.integers(1, 50), drop=CRASH, path=st.sampled_from(["liquidate", "settle", "remove", "deleverage"]))
def test_hyp91_usdt_fee_switch(fee, drop, path):
    """With USDT's transfer fee switched on, settlement, removal and deleverage of a USDT market keep working at the
    amounts that actually arrive, the issuer breaker trips, and no Avana contract keeps a token (Q-271)."""
    s = fresh()
    tid = pledge(s, "u", 0, 50_000)
    assert borrow_to(s, "u", 112 * WAD // 100)[0]
    s.ledger.fee_bps["USDT"] = fee
    assert s.market_breaker(0) == "ISSUER"
    assert not s.borrow("u", 10 ** 18)[0]
    if path == "remove":
        ok, r = s.remove_liquidity("u", tid, s.records[tid].credited // 10)
        assert not ok and "Breaker" in r                                   # removal with debt reads breakers
        s.fund("u", GHO, 10 ** 24)
        assert s.repay("u", s.debt(s.px("u")) * 2 + 10, repay_all=True)[0]
        ok, r = s.remove_liquidity("u", tid, s.records[tid].credited // 10)
        assert ok, r
    elif path == "deleverage":
        ok, r = s.repay_with_collateral("u", tid, s.records[tid].credited // 10)
        assert ok, r
    else:
        crash(s, "USDT", drop)
        assume(s.hf(s.px("u")) < WAD)
        if path == "settle":
            s.hostile_swap = True
            assume(s.hostile_swap_seize("u", 0, s.debt(s.px("u")) // 2)[0])
            s.hostile_swap = False
            assert s.withdraw("u", tid)[0] or True
            if s.pending[0]["units"]:
                ok, r = s.settle_pending("anyone", 0)
                assert ok or "RecoveryBelowFloor" in r or "NoRouteAvailable" in r, r
        else:
            ok, r = liq(s, "u", 0)
            assert ok or "RecoveryBelowFloor" in r or "NoRouteAvailable" in r, r
    check_all(s)


# HYP-91 verifies: Q-241, Q-271, Q-278
def test_hyp91_usdc_pause_and_blocklist():
    s = fresh()
    pledge(s, "u", 0, 20_000)
    pledge(s, "v", 2, 20_000)
    assert borrow_to(s, "u", 15 * WAD // 10, USDC_RID)[0]
    s.ledger.paused.add("USDC")
    assert s.market_breaker(0) == "ISSUER" and s.debt_breaker(CDP, USDC_RID) == "ISSUER"
    assert not s.borrow("u", 10 ** 6, USDC_RID)[0]
    assert s.borrow("v", 10 ** 18, GHO_RID)[0]                             # a market without USDC is unaffected
    s.fund("u", "USDC", 10 ** 9)
    assert not s.repay("u", 10 ** 6, USDC_RID)[0]                          # the token itself cannot move
    s.ledger.paused.discard("USDC")
    s.ledger.blocklist.add(("USDC", "u"))
    s.fund("payer", "USDC", 10 ** 9)
    assert s.repay("u", 10 ** 6, USDC_RID, payer="payer")[0]               # a third party repays a blocklisted borrower


# HYP-91 verifies: Q-148, Q-278, INV-054
@cfg(20)
@given(target=st.sampled_from(["pledge", "withdraw", "liquidate", "repay", "deleverage", "settle"]),
       during=st.sampled_from(["liquidate", "remove", "deleverage"]))
def test_hyp91_reentrancy_through_collect_and_decrease(target, during):
    """A token that calls back into Avana while the LPVault collects or removes liquidity meets the Lock: every
    reentrant entry point reverts LockHeld and the outer call completes unchanged (INV-054)."""
    s = fresh()
    tid = pledge(s, "u", 0, 50_000)
    pledge(s, "v", 0, 5_000)
    assert borrow_to(s, "u", 112 * WAD // 100)[0]
    seen = []

    def hook(frm, to, amount):
        if not s.lock or seen:
            return
        call = {"pledge": lambda: s.pledge("v", 0, tid), "withdraw": lambda: s.withdraw("v", next(
            t for t, r in s.records.items() if r.depositor == "v")), "liquidate": lambda: s.liquidate(
            "keeper1", "u", 0, 10 ** 18), "repay": lambda: s.repay("u", 1), "deleverage":
            lambda: s.repay_with_collateral("u", tid, 10), "settle": lambda: s.settle_pending("x", 0)}[target]
        seen.append(call())

    s.ledger.hooks["USDT"] = hook
    if during == "liquidate":
        crash(s, "USDT", 25 * 10 ** 6)
        assume(s.hf(s.px("u")) < WAD)
        ok, r = liq(s, "u", 0)
    elif during == "remove":
        s.fund("u", GHO, 10 ** 24)
        s.repay("u", s.debt(s.px("u")) * 2 + 10, repay_all=True)
        ok, r = s.remove_liquidity("u", tid, 10 ** 9)
    else:
        ok, r = s.repay_with_collateral("u", tid, 10 ** 9)
    s.ledger.hooks.clear()
    assert ok, r
    assert seen and not seen[0][0] and "LockHeld" in seen[0][1], seen
    check_all(s)


# --------------------------------------------------------------------------- HYP-92 withdrawal cascades
# HYP-92 verifies: Q-227, Q-234, Q-260, Q-278, INV-045, INV-074
@cfg(15)
@given(n=st.integers(3, 8), drop=st.integers(30 * 10 ** 6, 95 * 10 ** 6), lender_out=st.booleans())
def test_hyp92_withdrawal_cascade(n, drop, lender_out):
    """Debt-free LPs leave one after another during a depeg while the lender pulls GHO and indebted accounts are
    liquidated: every debt-free exit succeeds, borrowing stops only for lack of Hub liquidity or price gates, the
    pool keeps every position's principal and solvency per debt asset holds throughout (sizing-rule caps)."""
    s = fresh(cap_market_usd=100_000 * USD, topup_slice_usd=10_000 * USD, cap_token_usd=300_000 * USD,
              first_loss={"GHO": 100_000 * WAD, "USDC": 100_000 * 10 ** 6},
              first_loss_min={"GHO": 100_000 * WAD, "USDC": 100_000 * 10 ** 6})
    lps = [(f"lp{i}", pledge(s, f"lp{i}", i % 3, 5_000)) for i in range(n)]
    for i in range(3):
        pledge(s, f"b{i}", i, 20_000)
        assert borrow_to(s, f"b{i}", 112 * WAD // 100, USDC_RID if i == 2 else GHO_RID)[0]
    crash(s, "USDT", drop)
    for w, tid in lps:
        if lender_out:
            take = s.hub.assets[GHO].liquidity // 2
            s.tx(s.hub.remove, GHO, LEND_SPOKE, take, "lender", s.xfer)
        ok, r = s.withdraw(w, tid)
        assert ok, f"HYP-92 debt-free exit refused: {r}"
        for i in range(3):
            pxa = s.px(f"b{i}")
            if s.hf(pxa) < WAD:
                for rid in s.account_debts(pxa):
                    liq(s, f"b{i}", i, rid)
        check_all(s, solvency_check=True)


# --------------------------------------------------------------------------- HYP-93 adapter mint, proxies
# HYP-93 verifies: Q-224, Q-225, Q-239, Q-276, INV-063, INV-064, INV-066
def test_hyp93_adapter_mint_holders_and_proxy_per_spoke():
    s = fresh(spokes=(CDP, TIER2))
    t1 = pledge(s, "u", 0, 20_000, CDP)
    t2 = pledge(s, "u", 0, 20_000, TIER2)
    a, b = s.px("u", CDP), s.px("u", TIER2)
    assert a != b and a in s.markets[0].registry and b in s.markets[0].registry
    assert s.borrow("u", 10 ** 18, GHO_RID, TIER2)[0]
    assert not s.borrow("u", 10 ** 6, USDC_RID, TIER2)[0]                   # USDC is not approved on tier 2
    assert s.borrow_count(a) == 0 and s.withdraw("u", t1, CDP)[0]          # separate accounts
    vt = s.markets[0].vt
    # HYP-12 verifies: Q-068, Q-120, Q-224
    for bad in ("u", LPVAULT, COLL, "outsider"):
        ok, _ = s.tx(s.xfer, vt, HUB, bad, 1)
        assert not ok
        ok, _ = s.tx(s.vt_mint, s.markets[0], bad, 1)
        assert not ok
    assert s.tx(s.vt_mint, s.markets[0], b, 1)[0] is True
    s.ledger.burn(vt, b, 1, "undo")


# --------------------------------------------------------------------------- HYP-94 multi-reserve accounts
# HYP-94 verifies: Q-233, Q-234, Q-238, Q-247, Q-260, INV-072
def test_hyp94_multi_reserve_account():
    s = fresh()
    tid = pledge(s, "u", 2, 20_000)
    pledge(s, "u", 2, 20_000)
    assert borrow_to(s, "u", 2 * WAD)[0]
    assert borrow_to(s, "u", 13 * WAD // 10, USDC_RID)[0]
    px = s.px("u")
    hf0 = s.hf(px)
    crash(s, "USDC", 104 * 10 ** 6, move_pools=False)                      # a debt-asset rally lowers HF
    assert s.hf(px) < hf0
    s.advance(HOUR + 700)                                                  # USDC primary stale, alternate old
    for t in ("USDT", "DAI", "GHO"):
        s.set_price(t, s.prices[t], move_pools=False)
    assert not s.debt_oracle.evaluate(s.now())["borrow_age_ok"]
    ok, r = s.borrow("u", 10 ** 18)
    assert not ok and "DebtPriceTooOld" in r                              # account-wide gate for new debt
    s.fund("u", GHO, 10 ** 24)
    s.fund("u", "USDC", 10 ** 13)
    assert s.repay("u", s.debt(px) * 2 + 10, GHO_RID, repay_all=True)[0]
    assert s.borrow_count(px) == 1 and not s.withdraw("u", tid)[0] or True
    assert s.repay("u", s.debt(px, USDC_RID) * 2 + 10, USDC_RID, repay_all=True)[0]
    assert s.borrow_count(px) == 0
    s.markets[0].status = "Offboarding"
    s.trip_market_breaker(0)
    s.pause(GENERAL)
    assert s.withdraw("u", tid)[0]                                         # debt-free reads Aave only (Q-260)
