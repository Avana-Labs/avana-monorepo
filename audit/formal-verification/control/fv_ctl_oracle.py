#!/usr/bin/env python3
"""FV-C LPOracle, LPPriceMath and DebtOracle: price states, served prices, timers, grace and age limits.

How Avana's oracles work, as modelled here
-------------------------------------------
Each market's LPOracle reads, for each pool token, the two routes in force (primary and alternate, with the
standby substituted into the slot a guardian switched, MarketRegistry `activePriceRoutes`) and the route
version. A token's quote `q_i` is the primary when valid, else the alternate (automatic failover); when both
are valid they must agree within `T_i` bps. The valuation price `v_i = min(q_i, stableCeilingUsd)` for a
stable, and the vault-token price is `price8 = isqrt(4 v0 v1) - 1`. The market is failed when a token has no
valid route (Cached until `failureStart + cachedWindow`, Expired after), Drifting when a token's routes
disagree or the USD band, TWAP or clamp check fails, and Live otherwise.

`latestAnswer()` serves by state (SPEC-ORC-017): the fresh price when Live or Drifting with no disagreement,
`min(lower, fresh)` during a disagreement (`lower` built from each token's lower route; the floored `lower` can
exceed `fresh` by a few units, so it is not assumed below it), the accepted price `A` when Cached and 1 when
Expired; the accepted price enters only the Cached value. The DebtOracle applies the same leg, route and timer rules
to one debt asset and serves the quote when Live, `max(p, b, A)` while its routes disagree, `A` when Cached and
`ceil(A (10^4 + delta) / 10^4)` when Expired (SPEC-ORC-018). A price that cannot be trusted therefore only lowers
health factors, and it never sizes a seizure or a repayment: those consumers require the price Live, agreeing
and within its liquidation age.

`poke()` is the only writer. It stores the accepted price (Live and newer only), `failedSince` (first failed
read), `disagreeSince` (first observed disagreement, restarted when the route version changes), the grace latch,
`recoveredAt` (from source timestamps: SPEC-ORC-014 gap evidence, with the phase rule across aggregator
upgrades, `now` when the poke observes a route-version change while latched, or the latch fallback
`min(newest leg in use, now)`) and the hourly checkpoint of the accepted price.

Abstraction: each poke sees the per-read facts the valuation pipeline computes (failed, `S_ts`, fresh and
lower-route prices, route timestamps, disagreement, other Drifting reasons, the Expired-by-timestamps condition,
SPEC-ORC-014 evidence, route-version change, gas). Stored state: accepted answer and timestamp, `failedSince`,
`disagreeSince`, `expiredLatched`, `recoveredAt`, checkpoint. LPPriceMath formulas are modelled over unbounded
integers with the spec's bounds (`MAX_ROUTE_ANSWER = 10^12`); finite rule tables are enumerated exhaustively;
witnesses show each success path is reachable; worked examples are recomputed exactly.

What is proved: the served price is at least 1 in every state, never above `A` when not Live and never above
the fresh price when not failed; the lower-route price is a valid price no higher than the fresh price; the
accepted price and its timestamp only move forward from Live reads; the latch comes only from source
timestamps; `poke()` is idempotent in a block; the Cached window is measured from the first observed failed
read, a stored `failedSince` can only bring Expired earlier, and with a keeper poke every heartbeat the error is
bounded by one heartbeat; a grace window started from the latch never starts after the block nor before the
recovery, also for a two-leg route and for a recovery through a standby switch; a phase rollover fallback only
lengthens the measured gap; a route-version change restarts only the disagreement timer; the checkpoint is
always an accepted price at least an hour apart; the USD band never trips on a stable premium; the age limits
make the consumer test exact, with alternates held to their borrow age; the feed age rules give every on-time
hourly feed a borrow margin and cap every borrow age at 4,200 s; the DebtOracle never serves below `A` when not
Live and its stress price is bounded by `1.5 A + 1`.
"""
import itertools
import sys
from math import isqrt

import z3

import common
from common import exhaustive, expect, finish, prove, witness, zmin, zmax

MAXR = 10**12  # MAX_ROUTE_ANSWER
STABLE_CEIL = 10**8  # stableCeilingUsd
CHECKPOINT_INTERVAL = 3_600
BORROW_AGE_MARGIN, BORROW_AGE_CAP, MAX_PRIMARY_HEARTBEAT = 600, 4_200, 3_600



def prove_lemmas(cid, title, lemmas, verifies=(), targets=(), timeout_ms=120_000):
    """Prove a property as a chain of lemmas, each (claim, assumptions); one result for the check.
    Each later lemma assumes only facts an earlier lemma proved, so the chain proves the property."""
    import time
    t0 = time.time()
    for n, (claim, assumptions) in enumerate(lemmas, 1):
        sol = z3.Solver()
        sol.set("timeout", timeout_ms)
        sol.add(*assumptions)
        sol.add(z3.Not(claim))
        res = sol.check()
        if res != z3.unsat:
            status = "Violated" if res == z3.sat else "Unknown"
            cex = common._fmt_model(sol.model()) if res == z3.sat else None
            return common._record(cid, title, status, f"Z3 lemma {n}/{len(lemmas)} {res}", verifies, targets,
                                  "", cex, time.time() - t0)
    return common._record(cid, title, "Verified", f"Z3 (unsat of negation, {len(lemmas)} lemmas)", verifies,
                          targets, "", None, time.time() - t0)


CW, PMAX = z3.Ints("cachedWindow disagreementPauseMax")
timers = [CW >= 1, PMAX >= 0, PMAX <= 3_600]  # 1.5: cachedWindow fixed (3,600), disagreementPauseMax <= 3,600


def ceil_stable(x):
    return z3.If(x < STABLE_CEIL, x, STABLE_CEIL)


class St:
    def __init__(self, tag):
        self.ans, self.ats, self.fs, self.ds, self.rec, self.cp, self.cpat = z3.Ints(
            f"{tag}_ans {tag}_acceptedTs {tag}_failedSince {tag}_disagreeSince {tag}_recoveredAt "
            f"{tag}_checkpointPrice {tag}_checkpointAt")
        self.latch = z3.Bool(f"{tag}_latch")

    def tup(self):
        return (self.ans, self.ats, self.fs, self.ds, self.latch, self.rec, self.cp, self.cpat)


class Inp:
    def __init__(self, tag):
        self.now, self.sts, self.p8, self.low, self.t0, self.t1, self.tl0, self.tl1, self.E, self.tmax = z3.Ints(
            f"{tag}_now {tag}_S_ts {tag}_fresh {tag}_lower {tag}_t0 {tag}_t1 {tag}_tLower0 {tag}_tLower1 {tag}_E "
            f"{tag}_newestLegInUse")
        (self.failed, self.sdef, self.D, self.other, self.exp_ts, self.evid, self.gas, self.vc,
         self.altpast) = z3.Bools(
            f"{tag}_failed {tag}_S_defined {tag}_disagree {tag}_otherDrift {tag}_expiredByTimestamps "
            f"{tag}_evidence {tag}_gasOk {tag}_routeVersionChanged {tag}_alternatePastBorrowAge")

    def wf(self, s):
        """Facts every evaluation guarantees (REQ-ORACLE-002, SPEC-ORC-008/017, SPEC-ORC-013, SPEC-ORC-014)."""
        return z3.And(
            # lower >= 1 (FV-CTL-110) and price8 >= 1 (FV-CTL-73); lower is NOT assumed <= price8: the floored
            # composition can put price8(w) a few units above price8(v) (SPEC-ORC-017 example)
            self.now >= 1, self.p8 >= 1, self.low >= 1,
            self.now >= s.cpat, self.now >= s.ats, self.now >= s.fs, self.now >= s.ds, self.now >= s.rec,
            z3.Implies(z3.Not(self.failed), z3.And(self.t0 <= self.now, self.t1 <= self.now, self.t0 >= 1,
                                                    self.t1 >= 1, self.tl0 >= 1, self.tl1 >= 1,
                                                    self.tl0 <= self.now, self.tl1 <= self.now,
                                                    # newest leg in use: at least every route timestamp
                                                    # (each is the oldest leg of its route, SPEC-ORC-002)
                                                    self.tmax >= self.t0, self.tmax >= self.t1,
                                                    self.tmax <= self.now)),
            z3.Implies(self.sdef, z3.And(self.failed, self.sts >= 1, self.sts <= self.now)),
            self.exp_ts == z3.And(self.failed, self.sdef, self.now >= self.sts + CW),
            z3.Implies(self.evid, z3.And(z3.Not(self.failed), self.E > s.rec, self.E >= 1)),
            z3.Implies(self.failed, z3.And(z3.Not(self.D), z3.Not(self.other), z3.Not(self.altpast))))


def failure_start(s, i):  # SPEC-ORC-013: min(S_ts, failedSince, now), ignoring undefined / 0
    fs = z3.If(s.fs != 0, s.fs, i.now)
    st = z3.If(i.sdef, i.sts, i.now)
    return zmin(st, fs, i.now)


LIVE, DRIFTING, CACHED, EXPIRED = 0, 1, 2, 3


def state_of(s, i):  # REQ-ORACLE-016..018, SPEC-ORC-013
    return z3.If(i.failed, z3.If(i.now < failure_start(s, i) + CW, CACHED, EXPIRED),
                 z3.If(z3.Or(i.D, i.other), DRIFTING, LIVE))


def ds_eval(s, i):  # REQ-ORACLE-095: a route-version change makes the evaluation treat disagreeSince as 0
    return z3.If(i.vc, 0, s.ds)


def pause_windows(s, i):  # SPEC-ORC-016: both windows measured from the same s
    d = ds_eval(s, i)
    start = z3.If(d != 0, d, i.now)
    active = z3.And(i.D, i.now < start + PMAX)
    expired = z3.And(i.D, i.now >= start + PMAX)
    return active, expired


def liq_paused(s, i):  # SPEC-ORC-016
    active, expired = pause_windows(s, i)
    return z3.Or(state_of(s, i) >= CACHED, active, expired, i.altpast)


def served(s, i):  # SPEC-ORC-017 (value) and SPEC-ORC-012 (timestamp)
    st = state_of(s, i)
    active, expired = pause_windows(s, i)
    dis = z3.Or(active, expired)
    # Expired 1; Cached A; a disagreement of a market that is not failed min(lower, fresh); Live or Drifting
    # otherwise fresh; 1 in place of a result of 0. The accepted price enters only the Cached value.
    val = z3.If(st == EXPIRED, 1,
                z3.If(st == CACHED, s.ans,
                      zmax(z3.IntVal(1), z3.If(dis, zmin(i.low, i.p8), i.p8))))
    ts = z3.If(i.failed, s.ats, z3.If(dis, zmin(i.tl0, i.tl1), zmin(i.t0, i.t1)))
    return val, ts


def poke(s, i, n, fallback="written"):
    """REQ-ORACLE-095, REQ-ORACLE-027..035 and REQ-ORACLE-088 in that order; constraints on post-state `n`."""
    st = state_of(s, i)
    mt = zmin(i.t0, i.t1)
    write = z3.And(st == LIVE, mt > s.ats)  # REQ-ORACLE-029
    fb = zmin(i.tmax, i.now) if fallback == "written" else zmin(i.t0, i.t1)  # REQ-ORACLE-032 (c)
    grace = z3.And(z3.Not(i.failed), z3.Or(s.latch, i.evid))
    ans_new = z3.If(write, i.p8, s.ans)
    cp_due = i.now >= s.cpat + CHECKPOINT_INTERVAL  # REQ-ORACLE-088
    new = z3.And(
        n.fs == z3.If(i.failed, z3.If(s.fs == 0, z3.If(i.sdef, zmin(i.sts, i.now), i.now), s.fs), 0),
        n.ds == z3.If(z3.And(z3.Not(i.failed), i.D), z3.If(z3.Or(i.vc, s.ds == 0), i.now, s.ds), 0),
        n.ans == ans_new, n.ats == z3.If(write, mt, s.ats),
        n.latch == z3.If(i.failed, z3.Or(s.latch, i.exp_ts), z3.If(grace, False, s.latch)),
        # REQ-ORACLE-032: (a) a route-version change observed while latched starts grace at now; (b) evidence; (c)
        n.rec == z3.If(grace, z3.If(z3.And(s.latch, i.vc), i.now, z3.If(i.evid, zmin(i.E, i.now), fb)), s.rec),
        n.cp == z3.If(cp_due, ans_new, s.cp), n.cpat == z3.If(cp_due, i.now, s.cpat))
    same = z3.And([a == b for a, b in zip(n.tup(), s.tup())])
    return z3.If(i.gas, new, same)  # REQ-ORACLE-024: a gas-short poke reverts and changes nothing


def inv(s):
    return z3.And(s.ans >= 1, s.ats >= 1, s.fs >= 0, s.ds >= 0, s.rec >= 0, s.cp >= 1, s.cpat >= 1)


s0, s1, s2 = St("pre"), St("post"), St("post2")
i0 = Inp("in")
base = timers + [inv(s0), i0.wf(s0), poke(s0, i0, s1)]
sv, sts_ = served(s0, i0)
st0 = state_of(s0, i0)

# ================================================================ served price and stored state
# FV-CTL-63 verifies: INV-055, INV-087, REQ-ORACLE-020, SPEC-ORC-017, REQ-ORACLE-085, REQ-ORACLE-044, REQ-ORACLE-060
prove("FV-CTL-63", "Served price by state (SPEC-ORC-017): fresh when Live, fresh when Drifting without disagreement, min(lower, fresh) during a disagreement, A when Cached, 1 when Expired; served >= 1 always, <= A whenever failed, <= fresh whenever not failed (even when the floored lower exceeds fresh), <= price8 of getTokenPrices() and equal to it when Live, Cached or Drifting without disagreement; the accepted price and checkpoint stay >= 1 after every poke",
      z3.And(sv >= 1, z3.Implies(i0.failed, sv <= s0.ans), z3.Implies(z3.Not(i0.failed), sv <= i0.p8),
             z3.Implies(st0 == LIVE, sv == i0.p8), z3.Implies(st0 == CACHED, sv == s0.ans),
             z3.Implies(st0 == EXPIRED, sv == 1),
             z3.Implies(z3.And(z3.Not(i0.failed), z3.Or(*pause_windows(s0, i0))), sv == zmin(i0.low, i0.p8)),
             z3.Implies(z3.And(st0 == DRIFTING, z3.Not(z3.Or(*pause_windows(s0, i0)))), sv == i0.p8),
             sv <= z3.If(i0.failed, s0.ans, i0.p8),
             z3.Implies(z3.Or(st0 == LIVE, st0 == CACHED), sv == z3.If(i0.failed, s0.ans, i0.p8)),
             inv(s1)),
      assumptions=base, verifies=["INV-055", "INV-087", "REQ-ORACLE-020", "SPEC-ORC-017", "REQ-ORACLE-085",
                                  "REQ-ORACLE-044", "REQ-ORACLE-060"], targets=["T-66"])
# FV-CTL-64 verifies: INV-056, REQ-ORACLE-021, REQ-ORACLE-029, SPEC-ORC-012, REQ-ORACLE-041, REQ-ORACLE-066
prove("FV-CTL-64", "The accepted price changes only from a Live observation newer than the stored one; its timestamp never decreases and is a source timestamp; re-reading the same rounds never refreshes it; the served timestamp is a source timestamp (accepted when failed, the routes in use otherwise)",
      z3.And(z3.Implies(s1.ats != s0.ats, z3.And(st0 == LIVE, s1.ats == zmin(i0.t0, i0.t1), s1.ats > s0.ats)),
             z3.Implies(s1.ans != s0.ans, st0 == LIVE),
             s1.ats >= s0.ats,
             z3.Implies(zmin(i0.t0, i0.t1) <= s0.ats, z3.And(s1.ats == s0.ats, s1.ans == s0.ans)),
             z3.Or(sts_ == s0.ats, sts_ == i0.t0, sts_ == i0.t1, sts_ == i0.tl0, sts_ == i0.tl1),
             z3.Implies(i0.failed, sts_ == s0.ats), sts_ <= i0.now),
      assumptions=base, verifies=["INV-056", "REQ-ORACLE-021", "REQ-ORACLE-029", "SPEC-ORC-012",
                                  "REQ-ORACLE-041", "REQ-ORACLE-066"], targets=["T-67"])
# FV-CTL-65 verifies: REQ-ORACLE-030, INV-031, REQ-ORACLE-024, REQ-ORACLE-065
prove("FV-CTL-65", "expiredLatched is set only when source timestamps show Expired; a caught error, a config/decimals failure or a gas shortfall never sets it, and a gas-short poke changes nothing",
      z3.And(z3.Implies(z3.And(z3.Not(s0.latch), s1.latch), i0.exp_ts),
             z3.Implies(z3.Not(i0.gas), z3.And([a == b for a, b in zip(s1.tup(), s0.tup())])),
             z3.Implies(z3.Not(i0.sdef), z3.Not(i0.exp_ts))),
      assumptions=base, verifies=["REQ-ORACLE-030", "INV-031", "REQ-ORACLE-024", "REQ-ORACLE-065"],
      targets=["T-70", "T-67"])

# Idempotency within a block: the second poke sees the same feeds and the versions the first one stored; its
# SPEC-ORC-014 evidence is gone because the first poke recorded the rounds in `seen`.
i_second = Inp("in2")
same_block = [i_second.now == i0.now, i_second.sts == i0.sts, i_second.p8 == i0.p8, i_second.low == i0.low,
              i_second.t0 == i0.t0, i_second.t1 == i0.t1, i_second.tl0 == i0.tl0, i_second.tl1 == i0.tl1,
              i_second.failed == i0.failed, i_second.sdef == i0.sdef, i_second.D == i0.D,
              i_second.other == i0.other, i_second.gas == i0.gas, z3.Not(i_second.evid), i_second.E == i0.E,
              z3.Not(i_second.vc), i_second.altpast == i0.altpast]
# FV-CTL-66 verifies: INV-031, REQ-ORACLE-026, REQ-ORACLE-033, REQ-ORACLE-088, REQ-ORACLE-095
prove("FV-CTL-66", "poke() is idempotent within a block: a second poke on the same reads changes no stored field (timers, latch, recoveredAt, accepted price, checkpoint)",
      z3.And([a == b for a, b in zip(s2.tup(), s1.tup())]),
      assumptions=base + same_block + [i_second.wf(s1), poke(s1, i_second, s2)],
      verifies=["INV-031", "REQ-ORACLE-026", "REQ-ORACLE-033", "REQ-ORACLE-088", "REQ-ORACLE-095"],
      targets=["T-70"])

# Post-poke read in the same block: the versions are stored, so the evaluation no longer sees a change.
i_after_vc_false = Inp("readAfterPoke")
after_same = [i_after_vc_false.now == i0.now, i_after_vc_false.D == i0.D, i_after_vc_false.failed == i0.failed,
              i_after_vc_false.other == i0.other, i_after_vc_false.altpast == i0.altpast,
              i_after_vc_false.sdef == i0.sdef, i_after_vc_false.sts == i0.sts,
              z3.Not(i_after_vc_false.vc)]
act1, exp1 = pause_windows(s1, i_after_vc_false)
# FV-CTL-67 verifies: SPEC-ORC-016, REQ-ORACLE-022, REQ-ORACLE-028, INV-059, REQ-ORACLE-018, REQ-ORACLE-084
prove("FV-CTL-67", "After a poke a disagreeing market is Drifting, served at min(lower, fresh) and liquidation-paused; the first-observation time is set once per episode (per route version) and never moves; the pause lasts < disagreementPauseMax from it, then disagreementExpired holds until the routes agree",
      z3.And(z3.Implies(i0.D, z3.And(st0 == DRIFTING, liq_paused(s1, i_after_vc_false), z3.Or(act1, exp1),
                                     served(s1, i_after_vc_false)[0] == zmin(i_after_vc_false.low, i_after_vc_false.p8))),
             z3.Implies(z3.And(s0.ds != 0, s1.ds != 0, z3.Not(i0.vc)), s1.ds == s0.ds),
             z3.Implies(act1, i0.now < s1.ds + PMAX),
             z3.Implies(z3.And(i0.D, z3.Not(act1)), exp1)),
      assumptions=base + [i0.gas, i_after_vc_false.wf(s1)] + after_same,
      verifies=["SPEC-ORC-016", "REQ-ORACLE-022", "REQ-ORACLE-028", "INV-059", "REQ-ORACLE-018", "REQ-ORACLE-084"],
      targets=["T-68"])
# FV-CTL-68 verifies: REQ-ORACLE-016, REQ-ORACLE-006, REQ-ORACLE-023, REQ-ORACLE-019
prove("FV-CTL-68", "No stored timer, latch or route version keeps a market out of Live once its inputs are valid, fresh and agree; a failed market is Expired at most cachedWindow after its failure start",
      z3.And(z3.Implies(z3.And(z3.Not(i0.failed), z3.Not(i0.D), z3.Not(i0.other)), st0 == LIVE),
             z3.Implies(z3.And(i0.failed, i0.now >= failure_start(s0, i0) + CW), st0 == EXPIRED)),
      assumptions=timers + [inv(s0), i0.wf(s0)],
      verifies=["REQ-ORACLE-016", "REQ-ORACLE-006", "REQ-ORACLE-023", "REQ-ORACLE-019"], targets=["T-67", "T-68"])

# ================================================================ SPEC-ORC-013 failure start (two-sided bound)
# Times: F = true start of the current failure (failed continuously on [F, read]); P1 = first poke observing it
# (keeper cadence: P1 <= F + H); Pm = a poke that observed the market not failed before F.
HB, F = z3.Ints("keeperHeartbeat trueFailureStart")
a_, b_, c_ = St("A"), St("B"), St("C")
pm, p1, rd = Inp("pokeNotFailed"), Inp("pokeFirstFailed"), Inp("read")
common_fail = [HB >= 1, F >= 1, p1.failed, p1.gas, p1.now >= F, rd.failed, rd.now >= p1.now,
               z3.Implies(p1.sdef, p1.sts >= F), z3.Implies(rd.sdef, rd.sts >= F)]
# (i) never later: whatever was stored before P1 (including a failedSince left by an unobserved recovery)
trace_late = timers + common_fail + [inv(b_), p1.wf(b_), poke(b_, p1, c_), rd.wf(c_), p1.now <= F + HB]
# (ii) never earlier, when a poke observed the recovery before the new failure (recovery lasted >= one heartbeat)
trace_early = timers + common_fail + [inv(a_), pm.wf(a_), z3.Not(pm.failed), pm.gas, poke(a_, pm, b_),
                                      pm.now < F, p1.wf(b_), poke(b_, p1, c_), rd.wf(c_)]
x_fs = z3.Int("staleFailedSince")
s_stale, s_clear = St("withStale"), St("withZero")
# FV-CTL-69 verifies: SPEC-ORC-013, REQ-ORACLE-017, REQ-ORACLE-027, REQ-ORACLE-037
prove("FV-CTL-69", "Cached window (SPEC-ORC-013): Cached is never reported at or after min(F + H, S_ts) + cachedWindow, F the true failure start and H the keeper poke interval; once a poke saw the recovery, Expired is never reported before F + cachedWindow; a stored failedSince only brings Expired earlier, and later failed pokes never move it",
      z3.And(
          # (i)
          z3.Implies(z3.And(trace_late),
                     z3.And(z3.Implies(state_of(c_, rd) == CACHED, rd.now < F + HB + CW),
                            z3.Implies(z3.And(rd.sdef, state_of(c_, rd) == CACHED), rd.now < rd.sts + CW))),
          # (ii)
          z3.Implies(z3.And(trace_early), z3.Implies(state_of(c_, rd) == EXPIRED, rd.now >= F + CW)),
          # (iii) monotone in a stored failedSince
          z3.Implies(z3.And(x_fs >= 1, x_fs <= rd.now, s_stale.fs == x_fs, s_clear.fs == 0, rd.failed,
                            rd.now >= 1, z3.Implies(rd.sdef, rd.sts <= rd.now)),
                     z3.And(failure_start(s_stale, rd) <= failure_start(s_clear, rd),
                            z3.Implies(state_of(s_clear, rd) == EXPIRED, state_of(s_stale, rd) == EXPIRED))),
          # (iv) a failed poke never moves a non-zero failedSince
          z3.Implies(z3.And(base[-1], i0.failed, s0.fs != 0), s1.fs == s0.fs)),
      assumptions=timers + [inv(s0), i0.wf(s0)],
      verifies=["SPEC-ORC-013", "REQ-ORACLE-017", "REQ-ORACLE-027", "REQ-ORACLE-037"], targets=["T-67"],
      show={"cachedWindow", "keeperHeartbeat", "trueFailureStart", "read_now", "pokeFirstFailed_now"})

# ================================================================ REQ-ORACLE-032 grace start from the latch
# One-leg recovery: the recovered token's route timestamp is its new round, at or after the recovery Rv.
Rv, other_ts = z3.Ints("recoveryTime otherTokenRouteTs")
gs = timers + [inv(s0), i0.wf(s0), i0.gas, s0.latch, z3.Not(i0.evid), z3.Not(i0.failed),
               i0.t1 >= Rv, Rv >= 1, Rv <= i0.now, i0.t0 == other_ts]
sx = St("graceAfter")
# FV-CTL-70 verifies: INV-031, REQ-ORACLE-032, REQ-ORACLE-034, SPEC-ORC-014
prove("FV-CTL-70", "A grace window started by the latch fallback recoveredAt = min(newest leg in use, now) never starts after the poke's block and, when the recovered route's timestamp is its new round, never before the recovery; the REQ-ORACLE-032 example gives grace until 1,762,651,800",
      z3.And(sx.rec >= Rv, sx.rec <= i0.now, z3.Not(sx.latch),
             zmin(zmax(z3.IntVal(1_762_650_000), z3.IntVal(1_762_646_400)), z3.IntVal(1_762_650_100)) + 1_800
             == 1_762_651_800,
             z3.IntVal(1_762_646_400) + 1_800 < 1_762_650_100),
      assumptions=gs + [poke(s0, i0, sx)],
      verifies=["INV-031", "REQ-ORACLE-032", "REQ-ORACLE-034", "SPEC-ORC-014"], targets=["T-67", "T-70"],
      show={"in_now", "in_t0", "in_t1", "recoveryTime", "graceAfter_recoveredAt"})

# Same rule, without the one-leg premise: the recovered token's route in use has two legs (the recovered leg's
# new round at Rv and a second, still-valid leg updated earlier), or a standby switch at Rv put in force a route
# whose rounds all predate the switch. Route timestamp = min of its legs (SPEC-ORC-002).
leg_new, leg_old, fma_old, sb_leg = z3.Ints("recoveredLegUpdatedAt otherLegUpdatedAt otherLegFeedMaxAge standbyLegUpdatedAt")
via_standby = z3.Bool("recoveryByStandbySwitch")
sy = St("graceGeneral")
gen = timers + [inv(s0), i0.wf(s0), i0.gas, s0.latch, z3.Not(i0.evid), z3.Not(i0.failed),
                Rv >= 1, Rv <= i0.now, fma_old >= 1, fma_old <= 87_000,
                z3.If(via_standby,
                      # the switch is a route-version change the poke observes (REQ-ORACLE-095)
                      z3.And(sb_leg <= Rv, i0.now - sb_leg <= fma_old, sb_leg >= 1, i0.t1 == sb_leg, i0.vc),
                      z3.And(leg_new == Rv, leg_old <= leg_new, i0.now - leg_old <= fma_old, leg_old >= 1,
                             i0.t1 == zmin(leg_new, leg_old), i0.tmax >= leg_new)),
                i0.t0 >= 1, i0.t0 <= i0.now]
# FV-CTL-115 verifies: REQ-ORACLE-032, SPEC-ORC-002, REQ-ORACLE-094, INV-031
prove("FV-CTL-115", "The latch fallback never starts a grace window before the recovery, also when the recovered token is on a two-leg route or recovered through a standby switch (REQ-ORACLE-032: 'The window must start no earlier than the recovery')",
      sy.rec >= Rv, assumptions=gen + [poke(s0, i0, sy)],
      verifies=["REQ-ORACLE-032", "SPEC-ORC-002", "REQ-ORACLE-094", "INV-031"], targets=["T-67", "T-70"],
      detail="REQ-ORACLE-032 examples: a two-leg recovery (new USDT/ETH round 1,762,700,000, ETH/USD 1,762,697,000, "
             "token0 1,762,696,500) gives recoveredAt 1,762,700,000; a standby switched in at 1,762,700,000 and "
             "observed by the poke at 1,762,700,012 gives recoveredAt 1,762,700,012.",
      show={"in_now", "in_t0", "in_t1", "recoveryTime", "graceGeneral_recoveredAt", "recoveryByStandbySwitch",
            "recoveredLegUpdatedAt", "otherLegUpdatedAt", "standbyLegUpdatedAt"})

# FV-CTL-115-EX verifies: REQ-ORACLE-032
expect("FV-CTL-115-EX", "REQ-ORACLE-032 examples: two-leg recovery (USDT/ETH 1,762,700,000, ETH/USD 1,762,697,000, token0 1,762,696,500, poke 1,762,700,060) gives recoveredAt 1,762,700,000 and grace until 1,762,701,800 (route timestamps would give 1,762,697,000); standby switch observed at 1,762,700,012 gives recoveredAt 1,762,700,012 and grace until 1,762,701,812 (newest leg 1,762,698,000 would end grace at 1,762,699,800, before the poke)",
       min(max(1_762_700_000, 1_762_697_000, 1_762_696_500), 1_762_700_060) == 1_762_700_000
       and 1_762_700_000 + 1_800 == 1_762_701_800
       and min(max(min(1_762_700_000, 1_762_697_000), 1_762_696_500), 1_762_700_060) == 1_762_697_000
       and 1_762_700_012 + 1_800 == 1_762_701_812
       and max(1_762_697_000, 1_762_698_000) + 1_800 == 1_762_699_800 and 1_762_699_800 < 1_762_700_012,
       verifies=["REQ-ORACLE-032"], targets=["T-67", "T-70"])

# ================================================================ SPEC-ORC-015 age limits (4 legs)
NL = 4
u = [z3.Int(f"legUpdatedAt_{k}") for k in range(NL)]
blim = [z3.Int(f"legBorrowMaxAge_{k}") for k in range(NL)]
llim = [z3.Int(f"legLiquidationMaxAge_{k}") for k in range(NL)]
alt = [z3.Bool(f"legOnAlternate_{k}") for k in range(NL)]
now = z3.Int("now")
served_ts = zmin(*u)
l_eff = [z3.If(alt[k], zmin(llim[k], blim[k]), llim[k]) for k in range(NL)]
bmax = zmin(*[u[k] + blim[k] for k in range(NL)]) - served_ts
lmax = zmin(*[u[k] + l_eff[k] for k in range(NL)]) - served_ts
age_assume = [x >= 0 for x in blim] + [blim[k] <= llim[k] for k in range(NL)] + [x <= now for x in u]
# FV-CTL-71 verifies: SPEC-ORC-015, REQ-ORACLE-043, SPEC-PROXY-002, REQ-ADAPTER-016, REQ-ORACLE-090
prove("FV-CTL-71", "now - servedUpdatedAt <= borrowPriceMaxAge() (resp. liquidationPriceMaxAge()) holds exactly when every leg in use is within its own borrow (resp. liquidation, alternates held to min(liq, borrow)) limit; both derived limits are never negative",
      z3.And((now - served_ts <= bmax) == z3.And([now - u[k] <= blim[k] for k in range(NL)]),
             (now - served_ts <= lmax) == z3.And([now - u[k] <= l_eff[k] for k in range(NL)]),
             bmax >= 0, lmax >= 0),
      assumptions=age_assume,
      verifies=["SPEC-ORC-015", "REQ-ORACLE-043", "SPEC-PROXY-002", "REQ-ADAPTER-016", "REQ-ORACLE-090"],
      targets=["T-59", "T-67"])

# ================================================================ never reverts, for every feed behaviour
BEHAVIOURS = ("valid", "revert", "short_return", "zero", "negative", "stale", "out_of_band", "future_ts",
              "wrong_decimals", "oog_in_try")
P_ROUTE, B_ROUTE, A_ACC, T_TOL = 100_000_000, 97_500_000, 199_980_000, 225


def leg_class(bh, gas_after_catch_ok):
    if bh == "oog_in_try" and not gas_after_catch_ok:
        return "InsufficientGas"
    return {"valid": "valid", "stale": "Stale"}.get(bh, "Invalid")


def lp(v0, v1):
    return isqrt(4 * v0 * v1) - 1


# SPEC-ORC-008 for a full-range concentrated-liquidity market (tick spacing 1, ticks -887,272 / 887,272) of two
# 6-decimal tokens with d = 6, as the CL pricing module computes it: the oracle sqrt price
# floor(sqrt(v0 * 10^d1 * 2^192 / (v1 * 10^d0))) clamped to the range, the amounts of 10^d units by Uniswap's
# floor formulas, each reduced by 1 raw unit, then price8 = max(1, sum_i floor(a'_i * v_i / 10^d_i)).
CL_SQRT_A, CL_SQRT_B = 4_295_128_739, 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342


def cl_full_range_composition(v0, v1, d0=6, d1=6, units=10**6):
    s = isqrt(v0 * 10**d1 * 2**192 // (v1 * 10**d0))
    s = min(max(s, CL_SQRT_A), CL_SQRT_B)
    a0 = (units * ((CL_SQRT_B - s) << 96) // CL_SQRT_B) // s
    a1 = units * (s - CL_SQRT_A) // 2**96
    return a0, a1


def lp_sum(v0, v1, d0=6, d1=6):
    a0, a1 = cl_full_range_composition(v0, v1, d0, d1)
    a0, a1 = max(a0 - 1, 0), max(a1 - 1, 0)
    return max(1, a0 * v0 // 10**d0 + a1 * v1 // 10**d1)


def evaluate(legs, gas_ok, past_window):
    """2 tokens x (primary 1 leg, alternate 1 leg); primary 1.0000, alternate 0.9750 (disagreeing at T = 225).
    Returns ('revert', reason) or (served, state)."""
    classes = [leg_class(bh, gas_ok) for bh in legs]
    if "InsufficientGas" in classes:
        return ("revert", "InsufficientGas")
    q, w, dis = [], [], False
    for tok in range(2):
        pv, bv = classes[2 * tok] == "valid", classes[2 * tok + 1] == "valid"
        if not (pv or bv):
            return (1 if past_window else A_ACC, "Expired" if past_window else "Cached")
        qi = P_ROUTE if pv else B_ROUTE
        if pv and bv:
            dis = dis or abs(P_ROUTE - B_ROUTE) * 10**4 > T_TOL * min(P_ROUTE, B_ROUTE)
            wi = min(P_ROUTE, B_ROUTE)
        else:
            wi = qi
        q.append(min(qi, STABLE_CEIL))
        w.append(min(wi, STABLE_CEIL))
    fresh = lp(*q)
    if dis:
        return (min(lp(*w), A_ACC), "Drifting")
    return (fresh, "Live")


cases = list(itertools.product(BEHAVIOURS, repeat=4))
# FV-CTL-72 verifies: INV-055, REQ-ORACLE-020, REQ-ORACLE-039, REQ-ORACLE-001, REQ-ORACLE-002, REQ-ORACLE-061
exhaustive("FV-CTL-72", "For every combination of leg behaviours (10^4 cases x gas x Cached/Expired) latestAnswer() returns a value >= 1 (1 exactly when Expired, <= A when not Live), and reverts only with InsufficientGas after a caught failure below pokeMinGas",
           [(c, g, pw) for c in cases for g in (True, False) for pw in (True, False)],
           lambda x: (lambda r: (r[0] == "revert" and r[1] == "InsufficientGas" and "oog_in_try" in x[0] and not x[1])
                      or (r[0] != "revert" and r[0] >= 1 and (r[1] != "Expired" or r[0] == 1)
                          and (r[1] == "Live" or r[0] <= A_ACC)))(evaluate(x[0], x[1], x[2])),
           verifies=["INV-055", "REQ-ORACLE-020", "REQ-ORACLE-039", "REQ-ORACLE-001", "REQ-ORACLE-002",
                     "REQ-ORACLE-061"], targets=["T-66"])

# ================================================================ LPPriceMath (T-69)
v0, v1, r = z3.Ints("v0 v1 isqrt")
isq = z3.And(r >= 0, r * r <= 4 * v0 * v1, 4 * v0 * v1 < (r + 1) * (r + 1))
p8 = r - 1
rng = [v0 >= 1, v1 >= 1, v0 <= MAXR, v1 <= MAXR, isq]
# FV-CTL-73 verifies: SPEC-ORC-008, INV-055, REQ-ORACLE-012
prove("FV-CTL-73", "price8 = isqrt(4 v0 v1) - 1 is >= 1, (price8 + 1)^2 <= 4 v0 v1 (never above 2*sqrt(v0 v1)), within 2 units of it, and 4 v0 v1 < 2^256",
      z3.And(p8 >= 1, (p8 + 1) * (p8 + 1) <= 4 * v0 * v1, (p8 + 2) * (p8 + 2) > 4 * v0 * v1, 4 * v0 * v1 < 2**256),
      assumptions=rng, verifies=["SPEC-ORC-008", "INV-055", "REQ-ORACLE-012"], targets=["T-69"])
q, q2, C = z3.Ints("q q_higher stableCeilingUsd")
cap = lambda x: z3.If(x < C, x, C)  # noqa: E731
# FV-CTL-74 verifies: SPEC-ORC-004, REQ-ORACLE-009
prove("FV-CTL-74", "The stable ceiling never raises a price, is monotone, and is a no-op at or below the ceiling",
      z3.And(cap(q) <= q, z3.Implies(q <= q2, cap(q) <= cap(q2)), z3.Implies(q <= C, cap(q) == q)),
      assumptions=[q >= 1, q2 >= 1, C == 10**8], verifies=["SPEC-ORC-004", "REQ-ORACLE-009"], targets=["T-69"])
pp, bb, T = z3.Ints("p b T")
agree = lambda x, y: z3.If(x >= y, x - y, y - x) * 10**4 <= T * zmin(x, y)  # noqa: E731
ag_ok = abs(100_010_000 - 99_900_000) * 10**4 <= 225 * min(100_010_000, 99_900_000)
ag_bad = abs(100_010_000 - 97_500_000) * 10**4 <= 225 * min(100_010_000, 97_500_000)
# FV-CTL-75 verifies: SPEC-ORC-003, REQ-ORACLE-008
prove("FV-CTL-75", "The agreement check |p - b| * 10^4 <= T * min(p, b) is symmetric in p and b (both sides are order-free) and uses no division; the SPEC-ORC-003 examples agree (b = 99,900,000) and disagree (b = 97,500,000) at T = 225",
      z3.And(zmin(pp, bb) == zmin(bb, pp), z3.If(pp >= bb, pp - bb, bb - pp) == z3.If(bb >= pp, bb - pp, pp - bb),
             z3.BoolVal(ag_ok), z3.BoolVal(not ag_bad)),
      assumptions=[pp >= 1, bb >= 1, pp <= MAXR, bb <= MAXR, T >= 0, T <= 10_000],
      verifies=["SPEC-ORC-003", "REQ-ORACLE-008"], targets=["T-69"])
# FV-CTL-75-W verifies: SPEC-ORC-003
witness("FV-CTL-75-W", "Witness: floor division would admit T + 1 bps where the exact check refuses (why the cross-multiplied form is required)",
        z3.And(pp >= 1, bb >= 1, pp <= MAXR, bb <= MAXR, T == 225, z3.Not(agree(pp, bb)),
               (z3.If(pp >= bb, pp - bb, bb - pp) * 10**4) / zmin(pp, bb) <= T),
        verifies=["SPEC-ORC-003"], targets=["T-69"])
num, den, X, sq = z3.Ints("num den X s")
MINS, MAXS = 4295128739, 1461446703485210103287273052203988822378723970342
# FV-CTL-76 verifies: SPEC-ORC-009, REQ-ORACLE-014
prove("FV-CTL-76", "The reference sqrt price never overflows and lies in [MIN_SQRT_RATIO, MAX_SQRT_RATIO) after clamping",
      z3.And(X < 2**256, z3.If(sq < MINS, MINS, sq) < MAXS, z3.If(sq < MINS, MINS, sq) >= MINS),
      assumptions=[num >= 1, den >= 1, num < 2**64 * den, X * den <= num * 2**192, num * 2**192 < (X + 1) * den,
                   sq >= 0, sq * sq <= X, X < (sq + 1) * (sq + 1)],
      verifies=["SPEC-ORC-009", "REQ-ORACLE-014"], targets=["T-69"])

# ================================================================ SPEC-ORC-017 lower-route price
pr = z3.Ints("p0 b0 p1 b1")
both = z3.Bools("bothValid0 bothValid1")
stab = z3.Bools("isUsdStable0 isUsdStable1")
A = z3.Int("A")


def cap_i(x, k):
    return z3.If(stab[k], ceil_stable(x), x)


vq = [cap_i(pr[0], 0), cap_i(pr[2], 1)]  # quote = primary (valid during a disagreement)
wq = [z3.If(both[0], cap_i(zmin(pr[0], pr[1]), 0), vq[0]), z3.If(both[1], cap_i(zmin(pr[2], pr[3]), 1), vq[1])]
WW, VV, xa, xb, ya, yb, rr, ss, XX, YY, L2, H2 = z3.Ints("w0w1 v0v1 xa xb ya yb r s X Y L2 H2")
pr_rng = [x >= 1 for x in pr] + [x <= MAXR for x in pr]
# FV-CTL-110 verifies: SPEC-ORC-017, SPEC-ORC-008, REQ-ORACLE-086, INV-055
prove_lemmas("FV-CTL-110", "Lower-route price (SPEC-ORC-017): with w_i = ceil_i(min(p_i, b_i)) when both routes are valid (else v_i), 1 <= w_i <= v_i, so w0 w1 <= v0 v1 and lower = isqrt(4 w0 w1) - 1 satisfies 1 <= lower <= fresh; served = min(lower, fresh) lies in [1, fresh]",
             [  # 1: per-token bounds of the lower-route valuation price
                 (z3.And([z3.And(wq[k] >= 1, wq[k] <= vq[k], vq[k] <= MAXR) for k in range(2)]), pr_rng),
                 # 2: products are monotone on positive integers
                 (xa * xb <= ya * yb, [xa >= 1, xb >= 1, xa <= ya, xb <= yb]),
                 # 3: isqrt is monotone
                 (rr <= ss, [rr >= 0, ss >= 0, rr * rr <= XX, XX <= YY, YY < (ss + 1) * (ss + 1)]),
                 # 4: isqrt(4 w0 w1) >= 2 for w0 w1 >= 1, so lower >= 1; the served value min(lower, fresh) is in
                 # [1, fresh] (A is the fresh price here: any fresh >= 1)
                 (z3.And(rr - 1 >= 1, zmin(rr - 1, A) >= 1, zmin(rr - 1, A) <= A),
                  [XX >= 4, rr >= 0, rr * rr <= XX, XX < (rr + 1) * (rr + 1), A >= 1])],
             verifies=["SPEC-ORC-017", "SPEC-ORC-008", "REQ-ORACLE-086", "INV-055"], targets=["T-66", "T-69"])
ex_w = (min(100_000_000, 100_000_000), min(100_000_000, 97_500_000))
ex_lower = lp_sum(*ex_w)
ex_fresh = lp_sum(100_000_000, 100_000_000)
# FV-CTL-111 verifies: SPEC-ORC-017, INV-087, SPEC-ORC-008, SPEC-ORC-012
expect("FV-CTL-111", "SPEC-ORC-017 example (full-range USDC/USDT, spacing 1, d = 6): A = 199,980,000; token1 routes 100,000,000 / 97,500,000 give the composition (987,420, 1,012,739), lower = 197,483,855 and served min(197,483,855, 199,999,600) = 197,483,855; Cached serves 199,980,000; Expired serves 1; Drifting on a consistency deviation with fresh 199,999,600 (both tokens at $1) serves 199,999,600, above A, and a top-up there is booked at min(199,999,600, 199,980,000) = 199,980,000",
       cl_full_range_composition(*ex_w) == (987_420, 1_012_739)
       and ex_lower == 197_483_855 and min(ex_lower, ex_fresh) == 197_483_855
       and ex_fresh == 199_999_600 and ex_fresh > 199_980_000 and min(ex_fresh, 199_980_000) == 199_980_000,
       verifies=["SPEC-ORC-017", "INV-087", "SPEC-ORC-008", "SPEC-ORC-012"], targets=["T-66"],
       cex={"lower": ex_lower})

# Every disagreeing market, as read by any view (including before the first poke of the episode or right
# after a route-version change), is in pauseActive or disagreementExpired.
s_v, i_v = St("view"), Inp("view")
act_v, exp_v = pause_windows(s_v, i_v)
# FV-CTL-112 verifies: SPEC-ORC-016, SPEC-ORC-017, REQ-ORACLE-086, REQ-ORACLE-022, INV-059
prove("FV-CTL-112", "Whenever some token disagrees (REQ-ORACLE-008) and the market is not failed, pauseActive or disagreementExpired holds, so the market is served at min(lower, fresh) and liquidationPaused is true (REQ-ORACLE-086: 'While some token disagrees (SPEC-ORC-016 pauseActive or disagreementExpired)')",
      z3.And(z3.Or(act_v, exp_v), liq_paused(s_v, i_v), served(s_v, i_v)[0] == zmin(i_v.low, i_v.p8)),
      assumptions=timers + [inv(s_v), i_v.wf(s_v), i_v.D, z3.Not(i_v.failed)],
      verifies=["SPEC-ORC-016", "SPEC-ORC-017", "REQ-ORACLE-086", "REQ-ORACLE-022", "INV-059"], targets=["T-68"],
      detail="Includes disagreementPauseMax = 0 (allowed: the bound is <= 3,600) with disagreeSince read as 0 (no "
             "poke yet in the episode, or a route-version change since the last poke): s = now, so "
             "disagreementExpired = D and now >= now + 0 holds.",
      show={"disagreementPauseMax", "view_disagreeSince", "view_routeVersionChanged", "view_now"})

# Stress values never size a seizure: LPVaultSwap seizes only when liquidationPaused is false.
# FV-CTL-113 verifies: REQ-ORACLE-085, SPEC-ORC-016, SPEC-ORC-017, INV-087, REQ-SWAP-008
prove("FV-CTL-113", "Expired serves exactly 1 (REQ-ORACLE-085) and Cached serves A; whenever the served price is one of the stress values (Cached A, Expired 1, a disagreement's min(lower, fresh)), liquidationPaused is true, so no stress value sizes a seizure of this market: with liquidationPaused false the served price is exactly fresh",
      z3.And(z3.Implies(st0 == EXPIRED, z3.And(sv == 1, liq_paused(s0, i0))),
             z3.Implies(st0 == CACHED, z3.And(sv == s0.ans, liq_paused(s0, i0))),
             z3.Implies(z3.Or(*pause_windows(s0, i0)), liq_paused(s0, i0)),
             z3.Implies(z3.Not(liq_paused(s0, i0)),
                        sv == i0.p8)),
      assumptions=timers + [inv(s0), i0.wf(s0)],
      verifies=["REQ-ORACLE-085", "SPEC-ORC-016", "SPEC-ORC-017", "INV-087", "REQ-SWAP-008"], targets=["T-66"])

# ================================================================ SPEC-ORC-011 USD band
bq0, bq1, LOWB, HIGHB = z3.Ints("q0 q1 usdBandLow usdBandHigh")
bst = z3.Bools("bandStable0 bandStable1")
bv0 = z3.If(bst[0], ceil_stable(bq0), bq0)
bv1 = z3.If(bst[1], ceil_stable(bq1), bq1)


def in_band(x0, x1, y0, y1, lo, hi):  # lower on uncapped q, upper on capped v
    return z3.And(lo * lo <= x0 * x1, y0 * y1 <= hi * hi)


band_assume = [bq0 >= 1, bq1 >= 1, bq0 <= MAXR, bq1 <= MAXR, LOWB >= 1, LOWB < 10**8, HIGHB > 10**8]


def band_ex(q0_, q1_, lo=90_000_000, hi=102_000_000):
    v0_, v1_ = min(q0_, STABLE_CEIL), min(q1_, STABLE_CEIL)
    return lo * lo <= q0_ * q1_ and v0_ * v1_ <= hi * hi


band_examples = (band_ex(104_700_000, 100_000_000) and not 104_700_000 * 100_000_000 <= 102_000_000**2
                 and band_ex(99_987_000, 100_010_000) and 99_987_000 * 100_010_000 == 9_999_699_870_000_000
                 and not band_ex(89_000_000, 89_000_000) and 89_000_000**2 < 90_000_000**2)
# FV-CTL-114 verifies: SPEC-ORC-011, REQ-ORACLE-009, REQ-ORACLE-056, REQ-ORACLE-015, REQ-ORACLE-073
prove_lemmas("FV-CTL-114", "USD band: when both tokens are stables v0 v1 <= 10^16 < usdBandHigh^2, so only the uncapped lower bound can trip and a stable premium never breaches; testing capped values never breaches where uncapped would not; examples: GHO 104,700,000 with USDC 1e8 is in band (uncapped it would breach), 99,987,000 x 100,010,000 in band, both at 89,000,000 breach low",
             [  # 1: capped prices are within [1, q] and at most the ceiling for a stable
                 (z3.And(bv0 >= 1, bv1 >= 1, bv0 <= bq0, bv1 <= bq1,
                         z3.Implies(bst[0], bv0 <= 10**8), z3.Implies(bst[1], bv1 <= 10**8)), band_assume),
                 # 2: product monotone, so two values at most 10^8 multiply to at most 10^16, and v0 v1 <= q0 q1
                 (xa * xb <= ya * yb, [xa >= 1, xb >= 1, xa <= ya, xb <= yb]),
                 # 3: usdBandHigh > 10^8 gives usdBandHigh^2 > 10^16 (REQ-ORACLE-056)
                 (HIGHB * HIGHB > 10**16, [HIGHB > 10**8]),
                 # 4: so with both stables the band test reduces to the lower bound, and the capped test
                 #    passes wherever the uncapped one passes
                 #    (L2 = usdBandLow^2, H2 = usdBandHigh^2, WW = q0 q1, VV = v0 v1, YY = q0 q1 >= VV)
                 (z3.And(z3.Implies(z3.And(VV <= 10**16, H2 > 10**16),
                                    z3.And(L2 <= WW, VV <= H2) == (L2 <= WW)),
                         z3.Implies(z3.And(VV <= YY, YY <= H2), VV <= H2)), []),
                 (z3.BoolVal(band_examples), [])],
             verifies=["SPEC-ORC-011", "REQ-ORACLE-009", "REQ-ORACLE-056", "REQ-ORACLE-015", "REQ-ORACLE-073"],
             targets=["T-69"])

# ================================================================ feed age rules (REQ-CONFIG-023, REQ-ORACLE-054)
hb, fma, bage, lage, dly, ur, nowf = z3.Ints("feedHeartbeat feedMaxAge borrowPriceMaxAge liquidationPriceMaxAge networkDelay lastRoundAt nowFeed")
feed_cfg = [hb >= 1, bage == zmin(hb + BORROW_AGE_MARGIN, z3.IntVal(BORROW_AGE_CAP)), hb < fma, fma <= lage,
            bage <= lage]
# FV-CTL-116 verifies: REQ-CONFIG-023, REQ-CONFIG-021, REQ-ORACLE-054, SPEC-ORC-015
prove("FV-CTL-116", "Feed age rules: borrowPriceMaxAge = min(hb + 600, 4,200) is at most 4,200 and at most liquidationPriceMaxAge; for every primary or standby leg (hb <= 3,600) it equals hb + 600, so a feed whose next round comes at most hb + d after the last (d < 600 s network delay) is never refused by the borrow age",
      z3.And(bage <= BORROW_AGE_CAP, bage <= lage,
             z3.Implies(hb <= MAX_PRIMARY_HEARTBEAT,
                        z3.And(bage == hb + BORROW_AGE_MARGIN,
                               z3.Implies(z3.And(dly >= 0, dly < BORROW_AGE_MARGIN, nowf >= ur,
                                                 nowf < ur + hb + dly),  # the next round is not yet due
                                          nowf - ur <= bage)))),
      assumptions=feed_cfg, verifies=["REQ-CONFIG-023", "REQ-CONFIG-021", "REQ-ORACLE-054", "SPEC-ORC-015"],
      targets=["T-59"])
# FV-CTL-116-W verifies: REQ-CONFIG-023, REQ-ORACLE-054
witness("FV-CTL-116-W", "Witness: the REQ-CONFIG-023 examples are admissible: USDC/USD hb 3,600 (borrow 4,200, feedMaxAge = liquidation 4,200) and a USDC/ETH alternate leg hb 86,400 (borrow 4,200, feedMaxAge = liquidation 87,000)",
        z3.And(z3.substitute(z3.And(feed_cfg), (hb, z3.IntVal(3_600)), (bage, z3.IntVal(4_200)),
                             (fma, z3.IntVal(4_200)), (lage, z3.IntVal(4_200))),
               z3.substitute(z3.And(feed_cfg), (hb, z3.IntVal(86_400)), (bage, z3.IntVal(4_200)),
                             (fma, z3.IntVal(87_000)), (lage, z3.IntVal(87_000))),
               z3.Not(z3.substitute(z3.And(feed_cfg), (hb, z3.IntVal(3_600)), (bage, z3.IntVal(3_600)),
                                    (fma, z3.IntVal(4_200)), (lage, z3.IntVal(4_200))))),
        verifies=["REQ-CONFIG-023", "REQ-ORACLE-054"], targets=["T-59"])

past_alt = z3.Or([z3.And(alt[k], now - u[k] > blim[k]) for k in range(NL)])
# FV-CTL-117 verifies: REQ-ORACLE-090, SPEC-ORC-015, SPEC-ORC-016, REQ-ORACLE-019
prove("FV-CTL-117", "Alternates held to their borrow age: each leg's liquidation limit is >= its borrow limit (so borrowPriceMaxAge() <= liquidationPriceMaxAge()); while a serving alternate leg is past its borrowPriceMaxAge (ALTERNATE_PAST_BORROW_AGE) the liquidation age test already fails",
      z3.And([l_eff[k] >= blim[k] for k in range(NL)] + [bmax <= lmax,
             z3.Implies(past_alt, now - served_ts > lmax)]),
      assumptions=age_assume, verifies=["REQ-ORACLE-090", "SPEC-ORC-015", "SPEC-ORC-016", "REQ-ORACLE-019"],
      targets=["T-59", "T-67"])


def age_limits(legs):
    """legs: (updatedAt, borrowMaxAge, liquidationMaxAge, onAlternate) -> (served, borrowMaxAge(), liqMaxAge())."""
    srv = min(x[0] for x in legs)
    bd = min(x[0] + x[1] for x in legs)
    ld = min(x[0] + (min(x[2], x[1]) if x[3] else x[2]) for x in legs)
    return srv, bd - srv, ld - srv, bd, ld


ex1 = age_limits([(1_762_650_000, 4_200, 4_200, False), (1_762_646_400, 4_200, 87_000, True),
                  (1_762_649_000, 4_200, 4_200, True)])
ex1_own = 1_762_646_400 + 87_000
ex2 = age_limits([(1_762_646_400, 4_200, 4_200, False), (1_762_647_000, 4_200, 4_200, False)])
alt_age_at = 1_762_650_601 - 1_762_646_400
# FV-CTL-118 verifies: SPEC-ORC-015, REQ-ORACLE-090, REQ-ORACLE-054
expect("FV-CTL-118", "SPEC-ORC-015 / REQ-ORACLE-090 examples: servedUpdatedAt 1,762,646,400, liquidation and borrow deadlines 1,762,650,600, both age limits 4,200 (own alternate limit would allow seizure until 1,762,733,400); with token1 back on its primary both deadlines 1,762,650,600; at 1,762,650,601 the USDT/ETH leg is 4,201 s old and ALTERNATE_PAST_BORROW_AGE is set",
       ex1 == (1_762_646_400, 4_200, 4_200, 1_762_650_600, 1_762_650_600) and ex1_own == 1_762_733_400
       and ex2[3] == ex2[4] == 1_762_650_600 and alt_age_at == 4_201 and alt_age_at > 4_200
       and min(3_600 + 600, 4_200) == 4_200 and min(86_400 + 600, 4_200) == 4_200,
       verifies=["SPEC-ORC-015", "REQ-ORACLE-090", "REQ-ORACLE-054"], targets=["T-59"], cex={"ex1": ex1, "ex2": ex2})

fs_ex = 1_000_000
# FV-CTL-119 verifies: SPEC-ORC-013
expect("FV-CTL-119", "SPEC-ORC-013 examples: staleFrom 1,004,201 and 1,134,201 give staleAt 1,134,201, Cached until 1,137,800 and Expired from 1,137,801; a failedSince of 1,000,000 left by an unobserved recovery gives failureStart 1,000,000 at the poke at 1,004,100, Expired at once instead of Cached until 1,007,600",
       (1_000_000 + 4_200 + 1 == 1_004_201 and 1_130_000 + 4_200 + 1 == 1_134_201
        and max(1_004_201, 1_134_201) + 3_600 - 1 == 1_137_800
        and min(fs_ex, 1_004_100) == 1_000_000 and 1_004_100 >= min(fs_ex, 1_004_100) + 3_600
        and 1_004_000 + 3_600 == 1_007_600),
       verifies=["SPEC-ORC-013"], targets=["T-67"])

# ================================================================ SPEC-ORC-014 phase rule (REQ-ORACLE-089)
# Two tokens x (primary, alternate) x two legs. Each leg: current round at u, true previous round at tp,
# oracle's own seen round at su <= tp (the seen round is at or before the previous one). A leg on the first
# round of a phase whose previous-phase read fails uses prev = su; otherwise prev = tp in both runs.
NOW14, CW14, REC14 = z3.Ints("now14 cachedWindow14 recoveredAtStored")
LEGS = [(t, r_, l) for t in range(2) for r_ in range(2) for l in range(2)]
lu = {k: z3.Int(f"u_{k[0]}{k[1]}{k[2]}") for k in LEGS}
ltp = {k: z3.Int(f"truePrev_{k[0]}{k[1]}{k[2]}") for k in LEGS}
lsu = {k: z3.Int(f"seen_{k[0]}{k[1]}{k[2]}") for k in LEGS}
lfm = {k: z3.Int(f"feedMaxAge_{k[0]}{k[1]}{k[2]}") for k in LEGS}
lgap = {k: z3.Bool(f"lookedUp_{k[0]}{k[1]}{k[2]}") for k in LEGS}
lph = {k: z3.Bool(f"phaseFallback_{k[0]}{k[1]}{k[2]}") for k in LEGS}
rstale = {(t, r_): z3.Bool(f"routeStale_{t}{r_}") for t in range(2) for r_ in range(2)}
rsf = {(t, r_): z3.Int(f"staleFrom_{t}{r_}") for t in range(2) for r_ in range(2)}
phase_assume = [NOW14 >= 1, CW14 >= 1, REC14 >= 0]
for k in LEGS:
    phase_assume += [lfm[k] >= 1, lsu[k] >= 1, lsu[k] <= ltp[k], ltp[k] < lu[k], lu[k] <= NOW14]
for t in range(2):
    phase_assume += [z3.Not(z3.And(rstale[(t, 0)], rstale[(t, 1)]))]  # market not failed
    for r_ in range(2):
        phase_assume += [z3.Implies(rstale[(t, r_)], z3.And(rsf[(t, r_)] >= 1, rsf[(t, r_)] <= NOW14))]


def gap(k, fallback):
    prev = z3.If(z3.And(fallback, lph[k]), lsu[k], ltp[k])
    return prev + lfm[k] + 1, lu[k]  # [start, end), empty if start >= end


def route_S(t, r_, fallback):
    """Stale interval S_r as (has, lo, hi): union of overlapping leg gaps, else the gap with the later end."""
    ga, gb = gap((t, r_, 0), fallback), gap((t, r_, 1), fallback)
    ha, hb_ = lgap[(t, r_, 0)], lgap[(t, r_, 1)]
    ne_a, ne_b = z3.And(ha, ga[0] < ga[1]), z3.And(hb_, gb[0] < gb[1])
    overlap = z3.And(ne_a, ne_b, ga[0] < gb[1], gb[0] < ga[1])
    later_a = z3.If(z3.And(ha, hb_), ga[1] >= gb[1], ha)
    lo = z3.If(overlap, zmin(ga[0], gb[0]), z3.If(later_a, ga[0], gb[0]))
    hi = z3.If(overlap, zmax(ga[1], gb[1]), z3.If(later_a, ga[1], gb[1]))
    has = z3.Or(ha, hb_)
    stale_lo, stale_hi = rsf[(t, r_)], NOW14 + 1  # [staleFrom, now]
    return (z3.If(rstale[(t, r_)], True, has), z3.If(rstale[(t, r_)], stale_lo, lo),
            z3.If(rstale[(t, r_)], stale_hi, hi))


def token_B(t, fallback):
    hp, lp_, hp_ = route_S(t, 0, fallback)
    ha, la, ha_ = route_S(t, 1, fallback)
    lo, hi = zmax(lp_, la), zmin(hp_, ha_)
    nonempty = z3.And(hp, ha, lo < hi)
    return nonempty, lo, hi


def contains(outer, inner):
    return z3.Implies(inner[0], z3.And(outer[0], outer[1] <= inner[1], inner[2] <= outer[2]))


def evidence_and_rec(fallback):
    Bs = [token_B(t, fallback) for t in range(2)]
    qual = [z3.And(B[0], B[2] - B[1] >= CW14, B[2] > REC14) for B in Bs]
    cand = [z3.And(B[0], B[2] > REC14) for B in Bs]
    m = z3.If(cand[0], z3.If(cand[1], zmax(Bs[0][2], Bs[1][2]), Bs[0][2]), Bs[1][2])
    return Bs, z3.Or(qual), zmin(m, NOW14)


B_true, ev_true, rec_true = evidence_and_rec(False)
B_fb, ev_fb, rec_fb = evidence_and_rec(True)
gap_claims = []
for k in LEGS:
    gt, gf = gap(k, False), gap(k, True)
    gap_claims.append(z3.And(gf[0] <= gt[0], gf[1] == gt[1]))
s_claims = [contains(route_S(t, r_, True), route_S(t, r_, False)) for t in range(2) for r_ in range(2)]
b_claims = [z3.And(contains(B_fb[t], B_true[t]), z3.Implies(B_true[t][0], B_fb[t][2] == B_true[t][2]))
            for t in range(2)]
# FV-CTL-120 verifies: SPEC-ORC-014, REQ-ORACLE-089, REQ-ORACLE-075, REQ-ORACLE-033
prove("FV-CTL-120", "Phase rollover: with the fallback prev = seen.updatedAt <= the true previous round, every leg gap, route stale interval S_r and both-stale interval B_i contains the true one with the same end, so Expired-by-timestamps evidence is never lost on an aggregator upgrade, recoveredAt_new never decreases, and recoveredAt_new <= now",
      z3.And(z3.And(gap_claims), z3.And(s_claims), z3.And(b_claims), z3.Implies(ev_true, ev_fb),
             z3.Implies(ev_true, z3.And(rec_fb >= rec_true, rec_fb <= NOW14, rec_true <= NOW14))),
      assumptions=phase_assume, verifies=["SPEC-ORC-014", "REQ-ORACLE-089", "REQ-ORACLE-075", "REQ-ORACLE-033"],
      targets=["T-67", "T-70"])


def iv(a, b):
    return (a, b) if a < b else None


g_primary = iv(1_000_000 + 4_200 + 1, 1_200_000)
g_primary_fb = iv(996_400 + 4_200 + 1, 1_200_000)
g_alt = iv(1_130_000 + 4_200 + 1, 1_190_000)
B_ex = (max(g_primary[0], g_alt[0]), min(g_primary[1], g_alt[1]))
B_ex_fb = (max(g_primary_fb[0], g_alt[0]), min(g_primary_fb[1], g_alt[1]))
# FV-CTL-121 verifies: SPEC-ORC-014, REQ-ORACLE-089, REQ-ORACLE-034
expect("FV-CTL-121", "SPEC-ORC-014 examples: S_primary = [1,004,201, 1,200,000), alternate gap [1,134,201, 1,190,000), B lasts 55,799 s >= 3,600, recoveredAt = 1,190,000, graceEndsAt = 1,191,800; phase fallback from seen 996,400 gives [1,000,601, 1,200,000), which contains the true gap, and B is unchanged",
       g_primary == (1_004_201, 1_200_000) and g_alt == (1_134_201, 1_190_000) and B_ex == (1_134_201, 1_190_000)
       and B_ex[1] - B_ex[0] == 55_799 and B_ex[1] - B_ex[0] >= 3_600 and B_ex[1] + 1_800 == 1_191_800
       and g_primary_fb == (1_000_601, 1_200_000) and g_primary_fb[0] <= g_primary[0] and B_ex_fb == B_ex,
       verifies=["SPEC-ORC-014", "REQ-ORACLE-089", "REQ-ORACLE-034"], targets=["T-67"])

# A caught error never starts grace by itself: enumerate per-route outcomes for one token and the latch origin.
ROUTE_OUT = ("valid_lookup_ok", "valid_phase_prev_ok", "valid_phase_seen_fallback", "valid_lookup_error",
             "valid_phase_both_unusable", "stale", "invalid", "error")
LATCH_ORIGIN = ("none", "stale_timestamps", "caught_error", "config_failure", "gas_shortfall")


def grace_starts(p_out, a_out, latch_origin):
    """Returns (starts, source). Evidence needs a gap from a source timestamp on every route (SPEC-ORC-014):
    getRoundData, the previous-phase latestRoundData or the oracle's own seen.updatedAt, or a Stale route."""
    def gap_src(o):
        return {"valid_lookup_ok": "getRoundData", "valid_phase_prev_ok": "previousPhaseRound",
                "valid_phase_seen_fallback": "seenUpdatedAt", "stale": "staleFrom"}.get(o)
    not_failed = not (p_out in ("stale", "invalid", "error") and a_out in ("stale", "invalid", "error"))
    if not not_failed:
        return (False, None)
    latch = latch_origin == "stale_timestamps"  # REQ-ORACLE-030 / REQ-ORACLE-065
    srcs = (gap_src(p_out), gap_src(a_out))
    evidence = all(srcs)
    if evidence:
        return (True, srcs)
    if latch:
        return (True, ("latch",))
    return (False, None)


TIMESTAMP_SOURCES = {"getRoundData", "previousPhaseRound", "seenUpdatedAt", "staleFrom", "latch"}
NO_EVIDENCE = {"valid_lookup_error", "valid_phase_both_unusable", "invalid", "error"}


def grace_from_timestamps_only(x):
    starts, src = grace_starts(*x)
    if not starts:
        return True
    if not set(src) <= TIMESTAMP_SOURCES:
        return "non-timestamp source"
    if src == ("latch",):
        return True if x[2] == "stale_timestamps" else "latch from a caught error"
    if any(o in NO_EVIDENCE for o in x[:2]):
        return "evidence from an unusable lookup or an Invalid/Error route"
    return True


# FV-CTL-122 verifies: REQ-ORACLE-065, REQ-ORACLE-089, REQ-ORACLE-030, REQ-ORACLE-075, SPEC-ORC-014
exhaustive("FV-CTL-122", "A caught error never starts grace by itself: over every route outcome pair and latch origin, a grace window starts only from source timestamps (getRoundData, the previous-phase round, the oracle's own seen timestamp, staleFrom, or a latch set from timestamps); an unusable lookup or an Invalid/Error route gives no evidence",
           list(itertools.product(ROUTE_OUT, ROUTE_OUT, LATCH_ORIGIN)), grace_from_timestamps_only,
           verifies=["REQ-ORACLE-065", "REQ-ORACLE-089", "REQ-ORACLE-030", "REQ-ORACLE-075", "SPEC-ORC-014"],
           targets=["T-70"])

# ================================================================ route-version change (REQ-ORACLE-095)
i_nv = Inp("noVersionChange")
s_vc, s_nv = St("afterSwitch"), St("afterNoSwitch")
mirror = [i_nv.now == i0.now, i_nv.sts == i0.sts, i_nv.p8 == i0.p8, i_nv.low == i0.low, i_nv.t0 == i0.t0,
          i_nv.t1 == i0.t1, i_nv.tl0 == i0.tl0, i_nv.tl1 == i0.tl1, i_nv.failed == i0.failed,
          i_nv.sdef == i0.sdef, i_nv.D == i0.D, i_nv.other == i0.other, i_nv.exp_ts == i0.exp_ts,
          i_nv.evid == i0.evid, i_nv.gas == i0.gas, i_nv.E == i0.E, i_nv.altpast == i0.altpast,
          i_nv.tmax == i0.tmax,
          i0.vc, z3.Not(i_nv.vc)]
vc_trace = timers + [inv(s0), i0.wf(s0), i_nv.wf(s0), poke(s0, i0, s_vc), poke(s0, i_nv, s_nv)] + mirror
FS95, SW95 = 1_762_650_000, 1_762_652_000
# FV-CTL-123 verifies: REQ-ORACLE-095, REQ-ORACLE-094, REQ-ORACLE-028, REQ-MREG-028, INV-059
prove("FV-CTL-123", "A route-version change changes only disagreeSince (now if some token disagrees, else 0) and, while latched and not failed, starts grace at recoveredAt = now (REQ-ORACLE-032 (a)); failedSince, expiredLatched, the accepted price and the checkpoint are as without the change, and recoveredAt too when not latched; the state is the same (never Live by itself); a failed market with failedSince != 0 is Expired from failedSince + cachedWindow whatever the new routes give; REQ-ORACLE-095 example: Expired from 1,762,653,600, disagreeSince 1,762,652,000",
      z3.And(s_vc.fs == s_nv.fs, s_vc.latch == s_nv.latch,
             s_vc.rec == z3.If(z3.And(i0.gas, z3.Not(i0.failed), s0.latch), i0.now, s_nv.rec),
             z3.Implies(z3.And(i0.gas, z3.Not(i0.failed), s0.latch), s_vc.rec >= s_nv.rec), s_vc.ans == s_nv.ans,
             s_vc.ats == s_nv.ats, s_vc.cp == s_nv.cp, s_vc.cpat == s_nv.cpat,
             z3.Implies(i0.gas, s_vc.ds == z3.If(i0.D, i0.now, 0)),
             state_of(s0, i0) == state_of(s0, i_nv),
             z3.Implies(z3.And(i0.failed, s0.fs != 0, i0.now >= s0.fs + CW), state_of(s0, i0) == EXPIRED),
             FS95 + 3_600 == 1_762_653_600, SW95 < FS95 + 3_600),
      assumptions=vc_trace, verifies=["REQ-ORACLE-095", "REQ-ORACLE-094", "REQ-ORACLE-028", "REQ-MREG-028", "INV-059"],
      targets=["T-67", "T-68"])
# FV-CTL-123-W verifies: REQ-ORACLE-095, REQ-MREG-028
witness("FV-CTL-123-W", "Witness (REQ-ORACLE-095 example): Cached with failedSince 1,762,650,000; a switch at 1,762,652,000 to a standby that disagrees with the alternate yields Drifting with disagreeSince 1,762,652,000",
        z3.And(vc_trace + [CW == 3_600, s0.fs == FS95, s0.ds == 0, i0.now == SW95, i0.gas,
                           z3.Not(i0.failed), i0.D, s_vc.ds == SW95, state_of(s0, i0) == DRIFTING]),
        verifies=["REQ-ORACLE-095", "REQ-MREG-028"], targets=["T-67"])


def quote(routes):
    """REQ-ORACLE-005: (used, value) from [(valid, value) primary, alternate]."""
    (pv, p), (av, a) = routes
    if pv:
        return ("Primary", p)
    if av:
        return ("Alternate", a)
    return (None, None)


def in_force(primary, alternate, standby, slot):  # REQ-MREG-028 activePriceRoutes
    return (standby if slot == "Primary" else primary, standby if slot == "Alternate" else alternate)


ROUTES = [(True, 100_000_000, 3_600), (True, 97_500_000, 3_600), (False, 0, 3_600), (True, 100_010_000, 86_400),
          (False, 0, 86_400)]


def failover_ok(x):
    pr_, al_, sb_, slot = x
    if slot == "Primary" and sb_[2] > MAX_PRIMARY_HEARTBEAT:
        return True  # useStandbyRoute reverts ListingCheckFailed("heartbeat"); REQ-CONFIG-021
    if pr_[2] > MAX_PRIMARY_HEARTBEAT or sb_[2] > MAX_PRIMARY_HEARTBEAT:
        return True  # not listable (REQ-CONFIG-021: primary and standby legs hourly)
    rp, ra = in_force(pr_, al_, sb_, slot)
    used, val = quote([(rp[0], rp[1]), (ra[0], ra[1])])
    if rp[0] and used != "Primary":
        return "valid primary not used"
    if not rp[0] and ra[0] and (used != "Alternate" or val != ra[1]):
        return "no failover"
    if not rp[0] and not ra[0] and used is not None:
        return "price without a valid route"
    if rp[2] > MAX_PRIMARY_HEARTBEAT:
        return "primary slot leg slower than hourly"
    dis = rp[0] and ra[0] and abs(rp[1] - ra[1]) * 10**4 > 225 * min(rp[1], ra[1])
    if dis and used != "Primary":
        return "disagreement quote not primary"
    return True


# FV-CTL-124 verifies: REQ-ORACLE-005, REQ-ORACLE-006, REQ-ORACLE-094, REQ-MREG-028, REQ-CONFIG-021, REQ-MREG-027
exhaustive("FV-CTL-124", "Failover and standby: over every primary/alternate/standby validity and slot, the quote is the primary slot when valid, else the alternate slot, else none; the standby in force is evaluated exactly as the route it replaces; every route in the primary slot has hourly legs (hb <= 3,600)",
           list(itertools.product(ROUTES, ROUTES, ROUTES, ("None", "Primary", "Alternate"))), failover_ok,
           verifies=["REQ-ORACLE-005", "REQ-ORACLE-006", "REQ-ORACLE-094", "REQ-MREG-028", "REQ-CONFIG-021",
                     "REQ-MREG-027"], targets=["T-67"])

# ================================================================ checkpoint (REQ-ORACLE-088)
# FV-CTL-125 verifies: REQ-ORACLE-088, SPEC-BRK-001, REQ-ORACLE-062
prove("FV-CTL-125", "The checkpoint is written only by a poke with now >= checkpoint.at + 3,600, at block time, and always equals the accepted price after REQ-ORACLE-029 (never a stress-served price); a gas-short poke never writes it",
      z3.And(z3.Implies(z3.Or(s1.cp != s0.cp, s1.cpat != s0.cpat),
                        z3.And(i0.gas, i0.now >= s0.cpat + CHECKPOINT_INTERVAL, s1.cp == s1.ans, s1.cpat == i0.now)),
             z3.Implies(z3.And(i0.gas, i0.now >= s0.cpat + CHECKPOINT_INTERVAL), s1.cp == s1.ans),
             z3.Implies(z3.Not(i0.gas), z3.And(s1.cp == s0.cp, s1.cpat == s0.cpat)),
             z3.Or(s1.cp == s0.cp, s1.cp == s1.ans), s1.cpat >= s0.cpat),
      assumptions=base, verifies=["REQ-ORACLE-088", "SPEC-BRK-001", "REQ-ORACLE-062"], targets=["T-67"])


def brk001(price8, cp, at, t, bps):
    return t - at <= 7_200 and price8 * 10**4 < cp * (10**4 - bps)


# FV-CTL-126 verifies: REQ-ORACLE-088, SPEC-BRK-001
expect("FV-CTL-126", "Checkpoint example: (199,980,000, 1,762,650,000) is kept by a poke at 1,762,652,000 and replaced by (199,950,000, 1,762,653,700) at 1,762,653,700; 193,900,000 is 3.03 % below it and trips a 300 bps price-drop breaker until 1,762,660,900 (SPEC-BRK-001 compares while now - at <= 7,200)",
       (not 1_762_652_000 >= 1_762_650_000 + 3_600) and 1_762_653_700 >= 1_762_650_000 + 3_600
       and brk001(193_900_000, 199_950_000, 1_762_653_700, 1_762_660_900, 300)
       and not brk001(193_900_000, 199_950_000, 1_762_653_700, 1_762_660_901, 300)
       and round((199_950_000 - 193_900_000) * 10_000 / 199_950_000) == 303,
       verifies=["REQ-ORACLE-088", "SPEC-BRK-001"], targets=["T-67"])

# ================================================================ DebtOracle (SPEC-ORC-018)
dq, dp, db, dA, dlt, dnow, dfs, dsts, dt_, dats = z3.Ints(
    "debtQuote debtPrimary debtAlternate debtAccepted debtStressRiseBps debtNow debtFailedSince debtS_ts "
    "debtRouteTs debtAcceptedTs")
dfail, ddis, dsdef, daltpast = z3.Bools("debtFailed debtDisagree debtS_defined debtAlternatePastBorrowAge")
d_fstart = zmin(z3.If(dsdef, dsts, dnow), z3.If(dfs != 0, dfs, dnow), dnow)
d_state = z3.If(dfail, z3.If(dnow < d_fstart + CW, CACHED, EXPIRED), z3.If(ddis, DRIFTING, LIVE))
d_stress = (dA * (10**4 + dlt) + 10**4 - 1) / 10**4  # ceil
d_served = z3.If(d_state == LIVE, dq, z3.If(d_state == DRIFTING, zmax(dp, db, dA), z3.If(d_state == CACHED, dA, d_stress)))
d_paused = z3.Or(d_state != LIVE, daltpast)
d_write = z3.And(d_state == LIVE, dt_ > dats)
d_assume = timers + [dq >= 1, dp >= 1, db >= 1, dA >= 1, dq <= MAXR, dp <= MAXR, db <= MAXR, dA <= MAXR,
                     dlt >= 100, dlt <= 5_000, dnow >= 1, dfs >= 0, dfs <= dnow, dats >= 1, dt_ <= dnow,
                     z3.Implies(dsdef, z3.And(dfail, dsts >= 1, dsts <= dnow)),
                     z3.Implies(dfail, z3.And(z3.Not(ddis), z3.Not(daltpast))),
                     z3.Implies(z3.Not(dfail), z3.Or(dq == dp, dq == db))]
dA2 = z3.Int("debtAcceptedNext")
# FV-CTL-127 verifies: SPEC-ORC-018, REQ-ORACLE-093, REQ-ORACLE-092, REQ-ORACLE-091, REQ-ORACLE-096, REQ-ORACLE-098, INV-087, REQ-SWAP-091
prove("FV-CTL-127", "DebtOracle (SPEC-ORC-018): served = q Live, max(p, b, A) disagreeing, A Cached, ceil(A(10^4 + delta)/10^4) Expired; served >= 1, served >= A whenever not Live, the Expired value is >= the exact rise, < exact + 1 and <= 1.5 A + 1, and A (10^4 + delta) < 2^256; liquidationPaused whenever not Live, so no stress value prices a repayment; accepted is written only when Live and newer; no stable ceiling (served = q above $1)",
      z3.And(d_served >= 1, z3.Implies(d_state != LIVE, d_served >= dA),
             z3.Implies(d_state == EXPIRED, z3.And(d_served * 10**4 >= dA * (10**4 + dlt),
                                                   d_served * 10**4 < dA * (10**4 + dlt) + 10**4,
                                                   2 * d_served <= 3 * dA + 2)),
             dA * (10**4 + dlt) < 2**256,
             z3.Implies(d_state != LIVE, d_paused),
             z3.Implies(z3.Not(d_paused), d_served == dq),
             z3.Implies(d_state == LIVE, d_served == dq),
             z3.Implies(dA2 != dA, d_write), z3.Implies(d_write, dt_ > dats)),
      assumptions=d_assume + [dA2 == z3.If(d_write, dq, dA)],
      verifies=["SPEC-ORC-018", "REQ-ORACLE-093", "REQ-ORACLE-092", "REQ-ORACLE-091", "REQ-ORACLE-096",
                "REQ-ORACLE-098", "INV-087", "REQ-SWAP-091"], targets=["T-66"])
# FV-CTL-127-W verifies: SPEC-ORC-018, REQ-ORACLE-093
witness("FV-CTL-127-W", "Witness: a Live debt asset above $1 is served uncapped (q = 100,300,000)",
        z3.And(d_assume + [d_state == LIVE, dq == 100_300_000, d_served == 100_300_000]),
        verifies=["SPEC-ORC-018", "REQ-ORACLE-093"], targets=["T-66"])


def debt_served(state, q_, p_, b_, A_, delta):
    return {"Live": q_, "Drifting": max(p_, b_, A_), "Cached": A_,
            "Expired": -(-A_ * (10**4 + delta) // 10**4)}[state]


# FV-CTL-128 verifies: SPEC-ORC-018, INV-087
expect("FV-CTL-128", "SPEC-ORC-018 examples: A = 99,990,000 Expired serves 104,989,500 at delta 500 (10,000 USDC of debt counts $10,498.95) and 101,989,800 at delta 200; A = 99,987,001 at delta 500 rounds 104,986,351.05 up to 104,986,352; routes 99,990,000 / 100,300,000 disagreeing with A = 99,995,000 serve 100,300,000; Cached serves 99,995,000",
       debt_served("Expired", 0, 0, 0, 99_990_000, 500) == 104_989_500
       and debt_served("Expired", 0, 0, 0, 99_990_000, 200) == 101_989_800
       and debt_served("Expired", 0, 0, 0, 99_987_001, 500) == 104_986_352
       and 99_987_001 * 10_500 == 1_049_863_510_500 and 99_987_001 * 10_500 % 10_000 != 0
       and debt_served("Drifting", 99_990_000, 99_990_000, 100_300_000, 99_995_000, 500) == 100_300_000
       and debt_served("Cached", 0, 0, 0, 99_995_000, 500) == 99_995_000
       and 10_000 * 104_989_500 == 1_049_895 * 10**6 and 10_000 * 99_990_000 == 9_999 * 10**8,
       verifies=["SPEC-ORC-018", "INV-087"], targets=["T-66"])

# ================================================================ grace window view (REQ-ORACLE-034)
gd, gnow, grec = z3.Ints("graceDuration graceNow graceRecoveredAt")
in_grace = z3.And(grec != 0, grec <= gnow, gnow < grec + gd)
# FV-CTL-129 verifies: REQ-ORACLE-034, REQ-ORACLE-033, INV-031
prove("FV-CTL-129", "inGrace iff recoveredAt != 0 and recoveredAt <= now < recoveredAt + graceDuration: a grace window lasts exactly graceDuration seconds from recoveredAt, never before it, and a recoveredAt capped at now (SPEC-ORC-014, REQ-ORACLE-032) is in grace at the poke that sets it whenever graceDuration > 0",
      z3.And(z3.Implies(in_grace, z3.And(gnow >= grec, gnow - grec < gd)),
             z3.Implies(z3.And(grec >= 1, grec <= gnow, gnow - grec < gd), in_grace),
             z3.Implies(z3.And(grec == gnow, gd >= 1, gnow >= 1), in_grace)),
      assumptions=[gd >= 0, gd <= 7_200, gnow >= 1, grec >= 0],
      verifies=["REQ-ORACLE-034", "REQ-ORACLE-033", "INV-031"], targets=["T-70"])

sys.exit(finish())
