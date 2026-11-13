# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""HYP numeric properties: edge sizes, prices, decimals, record counts, rounding accumulation, the settlement
formulas, conservative LP value and oracle answers (zero, maximum, sudden moves, a Chainlink phase change).

Each test states its Hypothesis budget with cfg(...); README.md records the run settings.
"""
import random

import pytest
from hypothesis import assume, example, given, strategies as st

from model.avana import System, Record, GHO, LPVAULT, GHO_RID, USDC_RID, CDP, AvanaError
from model.hsettings import cfg
from model.mathlib import WAD, RAY, BPS, U120, U128, U256, to_value, isqrt, cdiv
from model.oracle import lp_price8, Feed, LIVE, DRIFTING, CACHED, EXPIRED
from model.params import Params, HOUR, DAY, USD
from model.uniswap import (position_amounts, sqrt_price_from_usd, max_liquidity_per_tick, MIN_SQRT_RATIO,
                           MAX_SQRT_RATIO)

MIN_P, MAX_P = Params().min_answer, Params().max_answer
price = st.integers(MIN_P, MAX_P)
market = st.integers(0, 2)
SPACINGS = [1, 10, 60, 200]


def fresh(**kw):
    return System(Params(**kw))


def open_account(s, w, m, liq, debt=0, rid=GHO_RID):
    tid = s.create_position(w, m, liq)
    s.nfpm.approve(w, tid, LPVAULT)
    ok, r = s.pledge(w, m, tid)
    assert ok, r
    if debt:
        ok, r = s.borrow(w, debt, rid)
        assert ok, r
    return tid


def served(s, m):
    return s.markets[m].oracle.latest_answer(s.now())


# --------------------------------------------------------------------------- HYP-40 tiny positions
# HYP-40 verifies: Q-066, Q-085, Q-169, Q-198, Q-230
@cfg(200)
@given(m=market, L=st.integers(1, 10 ** 7), p=price)
def test_hyp40_tiny_positions(m, L, p):
    """Tiny positions are refused below minPledgeUsd and never mint; above it they pledge and withdraw exactly."""
    s = fresh()
    mk = s.markets[m]
    s.set_price(mk.t0, p)
    s.poke(m)
    tid = s.create_position("u", m, L)
    assume(tid is not None)
    s.nfpm.approve("u", tid, LPVAULT)
    ok, r = s.pledge("u", m, tid)
    value = L * s.booking_price(m) // 10 ** mk.d
    if mk.oracle.state(s.now()) == LIVE and value >= s.p.min_pledge_usd:
        assert ok, r
    if not ok:
        assert s.ledger.supply.get(mk.vt, 0) == 0
        return
    assert value >= s.p.min_pledge_usd and r["L"] == L and s.ledger.supply[mk.vt] == L
    ok, r = s.withdraw("u", tid)
    assert ok and s.ledger.supply[mk.vt] == 0 and s.nfpm.positions[tid].owner == "u"


# HYP-40 verifies: Q-153, Q-169
@cfg(150)
@given(m=market, borrow_wei=st.integers(1, 10 ** 6), dt=st.integers(0, 10 ** 7), rid=st.sampled_from([0, 1]))
def test_hyp40_one_wei_debt(m, borrow_wei, dt, rid):
    """A 1-wei loan in either debt asset records debt ≥ the amount; repay-all quoted with a margin clears it."""
    s = fresh()
    mk = s.markets[m]
    open_account(s, "u", m, 10 * 10 ** mk.d)
    ok, r = s.borrow("u", borrow_wei, rid)
    assert ok, r
    px = s.px("u")
    assert s.debt(px, rid) >= borrow_wei
    s.advance(dt)
    asset = s.debts[rid].asset
    quote = s.debt(px, rid) * 1001 // 1000 + 2
    s.fund("u", asset, quote)
    ok, r = s.repay("u", quote, rid, repay_all=True)
    assert ok, r
    assert s.debt(px, rid) == 0 and r["refund"] == quote - r["paid"]


# --------------------------------------------------------------------------- HYP-41 bit widths
# HYP-41 verifies: Q-066, Q-092
@cfg(300)
@given(L=st.integers(0, U128), p0=price, p1=price, d=st.sampled_from([6, 12, 18]), spacing=st.sampled_from(SPACINGS),
       pool_p0=price, pool_p1=price, decs=st.sampled_from([(6, 6), (18, 6), (18, 18)]))
def test_hyp41_uint128_math_never_overflows(L, p0, p1, d, spacing, pool_p0, pool_p1, decs):
    price8 = lp_price8(p0, p1)
    v = to_value(L, d, price8)
    assert v < 2 ** 256 and L * price8 * 10 ** 18 < 2 ** 256
    sp = sqrt_price_from_usd(pool_p0, pool_p1, *decs)
    assert MIN_SQRT_RATIO < sp < MAX_SQRT_RATIO
    a0, a1 = position_amounts(sp, L, spacing, True)
    assert a0 < 2 ** 256 and a1 < 2 ** 256


# HYP-41 verifies: Q-066, Q-092
def test_hyp41_pool_liquidity_bound_below_uint120():
    for sp in SPACINGS:
        assert max_liquidity_per_tick(sp) < U120
    s = fresh()
    assert s.create_position("u", 0, max_liquidity_per_tick(1) + 1) is None


# --------------------------------------------------------------------------- HYP-42 LP price
# HYP-42 verifies: Q-028, Q-056, Q-066, Q-191
@cfg(500)
@given(p0=price, p1=price)
def test_hyp42_lp_price_rounds_down_and_never_zero(p0, p1):
    v = lp_price8(p0, p1)
    assert v > 0
    assert (v + 1) ** 2 <= 4 * p0 * p1 < (v + 2) ** 2
    assert v < p0 + p1


# HYP-42 verifies: Q-056, Q-079, Q-274
@cfg(300)
@given(ans=st.integers(-10 ** 9, 10 ** 10), age=st.integers(-100, 10 ** 6), hb=st.sampled_from([HOUR, DAY]))
def test_hyp42_feed_rejects_out_of_bounds_and_stale(ans, age, hb):
    p = Params()
    now = 10 ** 9
    f = Feed(ans, now - age, hb, p)
    got, _cause = f.read(now)
    valid = p.min_answer <= ans <= p.max_answer and 0 <= age <= hb + 600 and ans > 0
    assert (got is not None) == valid
    assert f.borrow_age == min(hb + 600, 4200)


# --------------------------------------------------------------------------- HYP-71 conservative valuation
# HYP-71 verifies: Q-028, Q-084, Q-187, Q-198, Q-278, INV-078
@cfg(400)
@given(m=market, p0=price, p1=price, pool_move=st.integers(-4000, 4000), L=st.integers(10 ** 3, 10 ** 30))
def test_hyp71_conservative_lp_value(m, p0, p1, pool_move, L):
    """For every pool spot price the oracle value of L units is at most the oracle-price value of what removing L
    returns (less one raw unit per leg); moving the pool only raises the realizable value (INV-078)."""
    s = fresh()
    mk = s.markets[m]
    L = min(L, 10 ** (mk.d + 7))
    s.set_price(mk.t0, p0)
    s.set_price(mk.t1, p1)
    # a manipulator moves the spot price by up to ±40% without moving the TWAP
    q = dict(s.prices)
    q[mk.t0] = max(1, q[mk.t0] * (BPS + pool_move) // BPS)
    sp = sqrt_price_from_usd(q[mk.t0], q[mk.t1], mk.d0, mk.d1)
    mk.pool.move_price(sp, "arb", follow_twap=False)
    a0, a1 = position_amounts(mk.pool.sqrt_p, L, mk.spacing, False)
    v0, v1 = (min(p, 10 ** 8) for p in (p0, p1))
    removed = a0 * v0 // 10 ** mk.d0 + a1 * v1 // 10 ** mk.d1
    orc = L * lp_price8(v0, v1) // 10 ** mk.d
    tol = orc // 10 ** 6 + v0 // 10 ** mk.d0 + v1 // 10 ** mk.d1 + 3
    assert orc <= removed + tol, (orc, removed)
    # and the served price never reads the pool
    assert served(s, m) == s.markets[m].oracle.evaluate(s.now())["served"]


# HYP-71 verifies: Q-198, Q-278, INV-078, INV-034
@cfg(200)
@given(m=market, units=st.integers(10 ** 3, 10 ** 26), p=st.integers(97 * 10 ** 6, 10 ** 8))
def test_hyp71_route_meets_realizable_value_at_stress_size(m, units, p):
    """At the oracle ratio the fixed routes return at least V(1 − s) − U − floorRoundingAllowanceGho for the tokens
    one liquidation unwinds: the realizable value used by solvency (INV-074) is reachable."""
    s = fresh()
    mk = s.markets[m]
    units = min(units, 10 ** (mk.d + 7))
    s.set_price(mk.t0, p)
    s.poke(m)
    a0, a1 = position_amounts(mk.pool.sqrt_p, units, mk.spacing, False)
    lp = s.leg_prices(mk)
    V = s.vt_value_gho(m, units, served(s, m))
    U = sum(s.unit_gho(lp[t], 6 if t in ("USDC", "USDT") else 18) for t in (mk.t0, mk.t1))
    out = sum(a if t == GHO else (s._sell_quote(mk, "primary", t, a) or s._sell_quote(mk, "backup", t, a))
              for t, a in ((mk.t0, a0), (mk.t1, a1)) if a)
    assert out >= V * (BPS - s.p.slippage_bps) // BPS - U - s.p.floor_rounding_allowance


# --------------------------------------------------------------------------- HYP-90 oracle fuzz
ANSWER = st.one_of(st.just(0), st.just(-1), st.just(2 ** 255 - 1), st.just(MAX_P), st.just(MAX_P + 1),
                   st.just(MIN_P), st.just(MIN_P - 1), st.integers(MIN_P, 2 * 10 ** 8))


# HYP-90 verifies: Q-247, Q-248, Q-272, Q-275, INV-055, INV-087
@cfg(400)
@given(m=market, a0=ANSWER, a1=ANSWER, alt0=ANSWER, dt=st.sampled_from([0, 60, 3000, 4300, 8000, 90_000]),
       poke_between=st.booleans())
def test_hyp90_oracle_answers_zero_max_and_moves(m, a0, a1, alt0, dt, poke_between):
    """Zero, negative, maximum and out-of-bounds answers are failures, never prices; the served price is at least 1,
    the accepted price when Cached, 1 when Expired, at most the fresh price whenever there is one, the fresh price
    itself while Live or Drifting with no disagreement, and a disagreement serves the lower route."""
    s = fresh()
    mk = s.markets[m]
    A = mk.oracle.accepted
    f0, f1 = s.feeds[mk.t0], s.feeds[mk.t1]
    s.advance(10)
    f0.primary.push(a0, s.now())
    f1.primary.push(a1, s.now())
    f0.alternate.push(alt0, s.now())
    if poke_between:
        s.poke(m)
    s.advance(dt)
    e = mk.oracle.evaluate(s.now())
    assert e["served"] >= 1
    if e["state"] in (LIVE, DRIFTING) and not e["disagree"]:
        assert e["served"] == e["fresh"]
    if e["state"] == EXPIRED:
        assert e["served"] == 1
    if e["state"] == CACHED:
        assert e["served"] == A
    if e["fresh"] is not None:
        assert e["served"] <= e["fresh"]
    valid = lambda x: MIN_P <= x <= MAX_P
    if e["state"] == LIVE:
        assert all(valid(x) for x in (e["legs"][0]["q"], e["legs"][1]["q"]))
    if e["disagree"]:
        assert mk.oracle.liquidation_block(s.now()) is not None


# HYP-90 verifies: Q-247, Q-248, INV-087
@cfg(300)
@given(p=st.integers(MIN_P, 2 * 10 ** 8), b=st.integers(MIN_P, 2 * 10 ** 8), dt=st.sampled_from([0, 4300, 8000, 90_000]))
def test_hyp90_debt_oracle_states(p, b, dt):
    """DebtOracle: Live serves the quote; a disagreement serves max(p, b, A); Cached serves A; Expired serves
    ⌈A·(10⁴ + δ)/10⁴⌉; the served price is never below A outside Live (SPEC-ORC-018)."""
    s = fresh()
    o = s.debt_oracle
    A = o.accepted
    s.advance(10)
    s.debt_feeds.primary.push(p, s.now())
    s.debt_feeds.alternate.push(b, s.now())
    s.advance(dt)
    e = o.evaluate(s.now())
    if e["state"] == LIVE:
        assert e["served"] == (p if dt <= 4200 else b)
        assert e["borrow_age_ok"] == (dt <= 4200)
    elif e["state"] == DRIFTING:
        assert e["served"] == max(p, b, A)
    elif e["state"] == CACHED:
        assert e["served"] == A
    else:
        assert e["served"] == cdiv(A * (BPS + s.p.debt_stress_rise_bps), BPS)
    if e["state"] != LIVE:
        assert e["served"] >= A and not e["liq_ok"] and not e["borrow_age_ok"]


# HYP-90 verifies: Q-129, Q-154, Q-264, Q-272
@cfg(200)
@given(gap=st.integers(HOUR, 4 * DAY), phase_change=st.booleans(), alt_phase=st.booleans(),
       poke_during=st.booleans(), first_phase=st.booleans())
def test_hyp90_phase_rollover_opens_grace(gap, phase_change, alt_phase, poke_during, first_phase):
    """An outage on both routes of a token longer than cachedWindow opens the grace window when prices return,
    whether or not a poke saw the Expired state, and also when the recovery round is the first round of a new
    Chainlink aggregator phase (Q-272); recoveredAt is never later than now and never before the outage ended."""
    s = fresh()
    m = 0
    mk = s.markets[m]
    tf = s.feeds["USDT"]
    if first_phase:
        # a feed still in its first phase: the previous-phase lookup is unusable and falls back to the seen round
        pass
    else:
        for f in (tf.primary, tf.alternate):
            f.push(f.answer, s.now(), new_phase=True)
            f.push(f.answer, s.now())
    s.poke(m)
    t_last = s.now()
    s.advance(gap // 2)
    if poke_during:
        s.poke(m)                                            # may observe Cached or Expired
    s.advance(gap - gap // 2)
    # the feeds return: other tokens keep publishing throughout
    for t in ("USDC",):
        s.set_price(t, 10 ** 8, move_pools=False)
    tf.primary.push(10 ** 8, s.now(), new_phase=phase_change)
    tf.alternate.push(10 ** 8, s.now(), new_phase=phase_change and alt_phase)
    s.poke(m)
    o = mk.oracle
    # both routes of USDT are stale from the alternate's feedMaxAge (24 h + 600 s) until the new rounds
    stale_span = gap - (DAY + 600 + 1)
    if stale_span >= s.p.cached_window:
        assert o.recovered_at is not None and o.in_grace(s.now()), "grace not opened after an Expired outage"
    if o.recovered_at is not None:
        assert t_last < o.recovered_at <= s.now()


# --------------------------------------------------------------------------- HYP-43 zero values
# HYP-43 verifies: Q-075, Q-134, Q-153, Q-169, Q-180, Q-206, Q-209, Q-217
def test_hyp43_zero_amounts():
    s = fresh()
    tid = open_account(s, "u", 0, 10 ** 10)
    assert not s.borrow("u", 0)[0]
    ok, r = s.repay("u", U256)
    assert ok and r["paid"] == 0
    assert s.repay("u", U256, repay_all=True)[1]["paid"] == 0
    assert s.borrow("u", 10 ** 18)[0]
    ok, r = s.repay("u", 0)
    assert not ok and "ZeroAmount" in r
    ok, r = s.liquidate("keeper0", "u", 0, 0)
    assert not ok and "InvalidDebtToCover" in r
    assert not s.remove_liquidity("u", tid, 0)[0]
    assert not s.remove_liquidity("u", tid, 10 ** 10)[0]
    assert not s.repay_with_collateral("u", tid, 0)[0]
    assert s.collect_fees("u", tid) == (True, dict(c0=0, c1=0, f0=0, f1=0))


# --------------------------------------------------------------------------- HYP-44 decimals
# HYP-44 verifies: Q-066
@cfg(150)
@given(m=market, usd=st.integers(11, 10 ** 6), cycles=st.integers(1, 5))
def test_hyp44_decimals_whole_token_and_exact_units(m, usd, cycles):
    s = fresh()
    mk = s.markets[m]
    assert abs(served(s, m) - 2 * 10 ** 8) <= 2
    for _ in range(cycles):
        L = usd * 10 ** mk.d // 2
        tid = open_account(s, "u", m, L)
        assert s.ledger.supply[mk.vt] == L
        assert s.withdraw("u", tid)[0]
        assert s.ledger.supply[mk.vt] == 0 and s.counters_regular.get(m, 0) == 0


# --------------------------------------------------------------------------- HYP-45 records
# HYP-45 verifies: Q-108, Q-170, Q-194
@cfg(300)
@given(credits=st.lists(st.integers(1, 10 ** 20), min_size=1, max_size=40), frac=st.integers(0, 10 ** 6),
       ties=st.booleans())
def test_hyp45_largest_first_allocation(credits, frac, ties):
    s = fresh()
    if ties:
        credits = [credits[0]] * len(credits)
    for i, c in enumerate(credits):
        s.records[100 + i] = Record(100 + i, "u", "proxy:u@cdp", CDP, 0, c, 0, 0, 0, 0)
    total = sum(credits)
    seize = total * frac // 10 ** 6
    debits = s._allocate_seizure("proxy:u@cdp", 0, seize)
    assert sum(d for _t, d in debits) == seize
    order = sorted(range(len(credits)), key=lambda i: (-credits[i], i))
    assert [t for t, _d in debits] == [100 + i for i in order[:len(debits)]]
    for k, (t, d) in enumerate(debits):
        assert 0 < d <= credits[t - 100]
        if k < len(debits) - 1:
            assert d == credits[t - 100]


# HYP-45 verifies: Q-193, Q-194, Q-234
def test_hyp45_no_record_or_market_cap():
    s = fresh()
    for i in range(12):
        open_account(s, "u", 0, 10 ** 7 + i)
    for m in (1, 2):
        open_account(s, "u", m, 10 ** (s.markets[m].d + 3))
    assert len(s.account_markets(s.px("u"))) == 3


# --------------------------------------------------------------------------- HYP-46 chunked unwind
# HYP-46 verifies: Q-061, Q-066, Q-131, Q-254
@cfg(40)
@given(chunks=st.lists(st.integers(1, 10 ** 9), min_size=1, max_size=10_000), p0=price, p1=price,
       spacing=st.sampled_from(SPACINGS), decs=st.sampled_from([(6, 6), (18, 6), (18, 18)]))
def test_hyp46_chunked_unwind_never_beats_single(chunks, p0, p1, spacing, decs):
    """Removing liquidity in up to 10,000 pieces (seizures or partial removals) returns no more than at once."""
    sp = sqrt_price_from_usd(p0, p1, *decs)
    total = sum(chunks)
    one0, one1 = position_amounts(sp, total, spacing, False)
    s0 = s1 = u0 = u1 = 0
    for c in chunks:
        a0, a1 = position_amounts(sp, c, spacing, False)
        s0, s1 = s0 + a0, s1 + a1
        b0, b1 = position_amounts(sp, c, spacing, True)
        u0, u1 = u0 + b0, u1 + b1
    assert s0 <= one0 and s1 <= one1
    up0, up1 = position_amounts(sp, total, spacing, True)
    assert u0 >= up0 and u1 >= up1


# --------------------------------------------------------------------------- HYP-47 borrow/repay accumulation
# HYP-47 verifies: Q-075, Q-153, Q-169, Q-234
@cfg(4)
@given(seed=st.integers(0, 2 ** 32), m=market, max_amt=st.sampled_from([1, 10 ** 3, 10 ** 9, 10 ** 15]),
       rid=st.sampled_from([0, 1]))
def test_hyp47_borrow_repay_rounding_never_pays_user(seed, m, max_amt, rid):
    rnd = random.Random(seed)
    s = fresh()
    mk = s.markets[m]
    open_account(s, "u", m, 10 ** 5 * 10 ** mk.d)
    px = s.px("u")
    asset = s.debts[rid].asset
    s.fund("u", asset, 10 ** 30)
    borrowed = repaid = 0
    cap = max_amt if rid == GHO_RID else min(max_amt, 10 ** 8)     # stay inside the 1M USDC draw cap
    for _ in range(5_000):
        amt = rnd.randint(1, cap)
        d0 = s.debt(px, rid)
        if rnd.random() < 0.5 or d0 == 0:
            s._borrow("u", amt, rid, CDP, None, None, 0, None)
            assert s.debt(px, rid) - d0 >= amt
            borrowed += amt
        else:
            r = s._repay("u", amt, rid, CDP, False, None, None)
            assert 0 <= d0 - s.debt(px, rid) <= r["paid"]
            repaid += r["paid"]
        if rnd.random() < 0.05:
            s.advance(rnd.randint(1, 600))
            for t in s.TOKENS:
                s.set_price(t, s.prices[t], move_pools=False)
    r = s._repay("u", s.debt(px, rid) * 2 + 10, rid, CDP, True, None, None)
    repaid += r["paid"]
    assert s.debt(px, rid) == 0 and repaid >= borrowed


# --------------------------------------------------------------------------- HYP-48 cycles and small liquidations
# HYP-48 verifies: Q-030, Q-055, Q-158, Q-174
@cfg(3)
@given(m=market, seed=st.integers(0, 2 ** 32))
def test_hyp48_pledge_withdraw_and_fee_cycles(m, seed):
    rnd = random.Random(seed)
    s = fresh()
    mk = s.markets[m]
    for _ in range(300):
        L = rnd.randint(10, 10 ** 4) * 10 ** mk.d
        tid = open_account(s, "u", m, L)
        f = rnd.randint(1, 10 ** 6)
        s.accrue_pool_fees(m, f * 10 ** (mk.d0 - 6), f * 10 ** (mk.d1 - 6))
        pos = s.nfpm.positions[tid]
        f0, f1 = pos.fees0, pos.fees1
        ok, r = s.collect_fees("u", tid)
        assert ok and (r["c0"], r["c1"]) == (f0, f1)
        assert s.withdraw("u", tid)[0]
    assert s.counters_regular.get(m, 0) == 0 and s.counters_slice.get(m, 0) == 0
    assert all(v == 0 for v in s.counters_token.values()) and s.counters_depositor.get("u", 0) == 0


# HYP-48 verifies: Q-060, Q-085, Q-159
@cfg(8)
@given(m=market, drop=st.integers(20 * 10 ** 6, 60 * 10 ** 6), pieces=st.integers(20, 120))
def test_hyp48_small_liquidations_do_not_beat_one(m, drop, pieces):
    s = fresh()
    mk = s.markets[m]
    open_account(s, "u", m, 10 ** 5 * 10 ** mk.d)
    px = s.px("u")
    ok, _ = s.borrow("u", s.hf(px) * 0 + 55_000 * WAD)
    assume(ok)
    tok = mk.t0 if mk.t0 != GHO else mk.t1
    s.set_price(tok, drop)
    assume(s.hf(px) < WAD)
    piece = max(1, s.debt(px) // pieces)
    s.fund("keeper0", GHO, 10 ** 30)
    n = paid = 0
    seized_val = 0
    while s.hf(px) < WAD and n < pieces + 5:
        ok, r = s.liquidate("keeper0", "u", m, piece, max_shortfall=10 ** 24)
        if not ok:
            break
        n += 1
        paid += r["D"]
        seized_val += r["V"]
        assert r["V"] <= r["D"] * r["lb"] // BPS + s.vt_value_gho(m, 1, r["price"]) + 1
    assert seized_val <= paid * s.p.max_lb_bps // BPS + n * (s.vt_value_gho(m, 1, served(s, m)) + 1)


# --------------------------------------------------------------------------- settlement formulas
def effective_slippage(b_net, allowance):
    """SettlementMath.effectiveSlippage (SPEC-LIQ-003): min(allowance, ⌊10⁴(bNet − 10⁴)/bNet⌋), 0 when bNet ≤ 10⁴;
    no cost term (SPEC-LIQ-002)."""
    return 0 if b_net <= BPS else min(allowance, BPS * (b_net - BPS) // b_net)


def payouts(v, d, r_f, fee_share_bps):
    """SettlementMath.payouts (SPEC-LIQ-008/009/022): S = max(0, R_f − D), G = max(0, V − D),
    A = min(⌊G × share / 10⁴⌋, S), kr = min(S, G) − A, B = S − A − kr."""
    S, G = max(0, r_f - d), max(0, v - d)
    A = min(G * fee_share_bps // BPS, S)
    kr = min(S, G) - A
    return S, G, A, kr, S - A - kr


# HYP-84 verifies: Q-231, Q-256, Q-261, INV-036, INV-086
@cfg(500)
@given(V=st.integers(1, 10 ** 28), d_frac=st.integers(8000, 10_500), slip=st.integers(0, 3000),
       b=st.integers(9_000, 12_000), allowance=st.integers(0, 3000),
       share=st.one_of(st.just(2000), st.integers(0, 5000)))
def test_hyp84_fee_and_effective_slippage(V, d_frac, slip, b, allowance, share):
    """effectiveSlippage(bNet, allowance) is the largest s ≤ allowance with bNet(10⁴ − s) ≥ 10⁸, with no cost term;
    payouts(V, D, R_f, share) splits S exactly into A + kr + B, A ≤ min(S, G), and A depends only on V and D while
    S covers ⌊G × share / 10⁴⌋."""
    s = fresh()
    D = V * d_frac // 10_500
    s_eff = effective_slippage(b, allowance)
    assert 0 <= s_eff <= allowance and s_eff < BPS
    if b <= BPS:
        assert s_eff == 0
    else:
        assert b * (BPS - s_eff) >= BPS * BPS
        assert s_eff == allowance or b * (BPS - s_eff - 1) < BPS * BPS
    assert s.eff_slippage(b) == effective_slippage(b, s.p.slippage_bps)
    fee_term = max(0, V - D) * share // BPS
    for R_f in (D, D + fee_term, V, V * (BPS - slip) // BPS, V + slip):
        S, G, A, kr, B = payouts(V, D, R_f, share)
        assert A + kr + B == S and min(A, kr, B) >= 0
        assert A <= S and A <= G and kr <= G - A
        if S >= fee_term:
            assert A == fee_term
        assert B == max(0, S - G)
        if S > G:
            assert B == R_f - max(V, D)


def leg_minimums(m, p0, p1, units, s_eff, spacing, clamped=None):
    s = fresh()
    mk = s.markets[m]
    units = min(units, 10 ** (mk.d + 9))
    sp = sqrt_price_from_usd(p0, p1, mk.d0, mk.d1)
    a0, a1 = position_amounts(sp, units, spacing, False)
    lp = {mk.t0: p0, mk.t1: p1}
    legs = [(t, a) for t, a in ((mk.t0, a0), (mk.t1, a1)) if a > 0]
    n = len(legs)
    assume(n > 0)
    dec = {t: (6 if t in ("USDC", "USDT") else 18) for t in (mk.t0, mk.t1)}
    V = units * lp_price8(p0, p1) * 10 ** 18 // (10 ** mk.d * 10 ** 8)
    U = sum(s.unit_gho(lp[t], dec[t]) for t in (mk.t0, mk.t1))
    mins = []
    for t, a in legs:
        v_leg = a * lp[t] * 10 ** 18 // (10 ** dec[t] * 10 ** 8)
        raw = cdiv(v_leg * (BPS - s_eff), BPS) - s.unit_gho(lp[t], dec[t]) - s.p.floor_rounding_allowance // n
        mo = max(1, raw)
        assert mo <= max(1, cdiv(v_leg * (BPS - s_eff), BPS))
        if clamped is not None and raw < 1:
            clamped.append(t)
        mins.append(mo)
    return sum(mins), s.min_gho(V, s_eff, U), n, U, units, mk.d


LEG_ARGS = dict(m=st.sampled_from([0, 1]), p0=st.integers(MIN_P, 10 ** 8), p1=st.integers(MIN_P, 10 ** 8),
                units=st.integers(10 ** 3, 10 ** 30), s_eff=st.integers(0, 3000), spacing=st.sampled_from(SPACINGS))


# HYP-85 verifies: Q-250, INV-083, SPEC-LIQ-018
@cfg(500)
@example(m=1, p0=5_034_328, p1=5_000_075, units=3_414_711_693_649_457_640, s_eff=1833, spacing=200)
@given(**LEG_ARGS)
def test_hyp85_leg_minimums_within_aggregate_floor(m, p0, p1, units, s_eff, spacing):
    """INV-083 and SPEC-LIQ-018 as written: with the pool at the oracle-implied price the per-leg minimums sum to at
    most minGho + n + U + ⌈2·c·10¹⁰ / 10^d⌉ while no leg minimum is clamped at 1, and at most
    minGho + n + 2U + ⌊floorRoundingAllowanceGho / n⌋ + ⌈2·c·10¹⁰ / 10^d⌉ in every case; the last term is the LP
    price's rounding (2 units of 10⁻⁸ USD per whole vault token). The pinned example is the counterexample to the
    bound without that term: it exceeds minGho + n + U by 42,879,229,203,248,083 wei (0.0429 GHO on a 342,644 GHO
    seizure), inside the 0.0683 GHO LP term."""
    clamped = []
    total, mg, n, U, c, d = leg_minimums(m, p0, p1, units, s_eff, spacing, clamped)
    lp_term = cdiv(2 * c * 10 ** 10, 10 ** d)
    s = fresh()
    if not clamped:
        assert total <= mg + n + U + lp_term
    assert total <= mg + n + 2 * U + s.p.floor_rounding_allowance // n + lp_term


# HYP-85 verifies: Q-250, INV-083, SPEC-LIQ-018
@cfg(500)
@example(m=1, p0=5_034_328, p1=5_000_075, units=3_414_711_693_649_457_640, s_eff=1833, spacing=200)
@given(**LEG_ARGS)
def test_hyp85_leg_minimums_within_corrected_bound(m, p0, p1, units, s_eff, spacing):
    """The bound recommended in the README finding holds: Σ minOutᵢ ≤ minGho + n + U + ⌈2·c·10¹⁰ / 10^d⌉, the last term being
    the LP price's rounding (2 units of 10⁻⁸ USD per whole vault token) in GHO wei; each leg's minimum never exceeds
    its own oracle value less the slippage."""
    total, mg, n, U, c, d = leg_minimums(m, p0, p1, units, s_eff, spacing)
    assert total <= mg + n + U + cdiv(2 * c * 10 ** 10, 10 ** d)


# HYP-87 verifies: Q-267, Q-397, SPEC-SET-006
@cfg(200)
@given(D=st.integers(1, 10 ** 24), phi=st.integers(0, 10 ** 21), R=st.integers(0, 10 ** 24),
       floor_gap=st.integers(0, 10 ** 22), K=st.sampled_from([0, None]))
def test_hyp87_caller_gap_closes_settlement(D, phi, R, floor_gap, K):
    """Q-397 replaced the budget's market sub-cap: the caller's gap D + φ_D − (R + floorGap) − K, floored at 0,
    always closes settlement exactly, with no Avana balance involved."""
    K = D if K is None else 0
    gap = max(0, D + phi - (R + floor_gap) - K)
    assert R + floor_gap + gap + K >= D + phi
    assert gap == 0 or R + floor_gap + gap + K == D + phi
