# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""LPOracle and DebtOracle models (2.10): routes, price states, served prices, age limits, grace latch.

Rules modelled (final text):
  SPEC-ORC-001/008   price of one whole vault token = isqrt(4 v0 v1) − 1 (8 dec), at least 1
  SPEC-ORC-003       agreement |p − b|·10⁴ ≤ T·min(p, b) on uncapped route values
  SPEC-ORC-004       valuation price v = min(q, stableCeilingUsd) for USD stables
  SPEC-ORC-011       USD band: lower bound on uncapped q0·q1, upper bound on capped v0·v1 (Q-275); outside → Drifting
  SPEC-ORC-013       Cached from the first failed read for cachedWindow, then Expired
  SPEC-ORC-014       recovery evidence from source timestamps, with the Chainlink phase rule (Q-272)
  SPEC-ORC-015       borrowPriceMaxAge = min(heartbeat + 600, 4,200); a serving alternate is held to it for
                     liquidation as well (Q-274)
  SPEC-ORC-016       liquidation of the market paused while Cached, Expired, disagreeing or alternate past borrow age
  SPEC-ORC-017       served price: fresh (Live, Drifting), max(1, min(lower, fresh)) (disagreement), A (Cached),
                     1 (Expired); the accepted price bounds borrowing only (REQ-RISK-026, REQ-RISK-059)
  SPEC-ORC-018       DebtOracle served price: q (Live), max(p, b, A) (disagreement), A (Cached),
                     ⌈A·(10⁴ + δ)/10⁴⌉ (Expired)
  Q-248              standby route per token replaces the primary or alternate slot at once
  Q-264              without timestamp evidence recoveredAt = max(t0, t1), never later than now
  SPEC-BRK-001       hourly checkpoint of the accepted price for the price-drop alert (monitoring only, Q-399)
"""
import itertools

from .mathlib import isqrt, BPS, cdiv

_KEYS = itertools.count(1)

LIVE, DRIFTING, CACHED, EXPIRED = "Live", "Drifting", "Cached", "Expired"
ONE = 10 ** 8


class Feed:
    """A Chainlink proxy: round IDs are phaseId·2⁶⁴ + aggregatorRoundId; history keeps every round's updatedAt."""

    def __init__(self, answer, updated_at, heartbeat, params):
        self.answer, self.updated_at = answer, updated_at
        self.heartbeat = heartbeat
        self.p = params
        self.phase, self.agg_round = 1, 1
        self.history = {(1, 1): updated_at}
        self.broken = False           # latestRoundData reverts
        self.key = next(_KEYS)        # stable identity across state snapshots

    @property
    def round_id(self):
        return (self.phase << 64) | self.agg_round

    @property
    def max_age(self):
        return self.p.feed_max_age(self.heartbeat)

    @property
    def borrow_age(self):
        return self.p.borrow_max_age(self.heartbeat)

    def push(self, answer, t, new_phase=False):
        if new_phase:
            self.phase += 1
            self.agg_round = 1
        else:
            self.agg_round += 1
        self.history[(self.phase, self.agg_round)] = t
        self.answer, self.updated_at = answer, t

    def read(self, now, gas_ok=True):
        """((answer, updatedAt) or None, cause)."""
        if not gas_ok:
            return None, "gas"
        if self.broken:
            return None, "error"
        a, t = self.answer, self.updated_at
        if a <= 0 or t == 0 or t > now:
            return None, "invalid"
        if a < self.p.min_answer or a > self.p.max_answer:
            return None, "invalid"
        if now - t > self.max_age:
            return None, "stale"
        return (a, t), "ok"

    def stale_from(self):
        return self.updated_at + self.max_age + 1

    def prev_updated_at(self, seen_ts):
        """SPEC-ORC-014 lookup of the previous round; None when unusable (no evidence)."""
        if self.agg_round == 1:
            prev = None
            if self.phase > 1:
                rounds = [r for (ph, r) in self.history if ph == self.phase - 1]
                if rounds:
                    prev = self.history[(self.phase - 1, max(rounds))]
            if prev is None or prev == 0 or prev >= self.updated_at:
                return seen_ts                     # Q-272 fallback: the last round the oracle recorded
            return prev
        prev = self.history.get((self.phase, self.agg_round - 1))
        if prev is None or prev == 0 or prev >= self.updated_at:
            return None
        return prev


class TokenFeeds:
    """Primary, alternate and standby route of one token (each route one leg)."""

    def __init__(self, token, primary, alternate, standby, stable=True):
        self.token, self.stable = token, stable
        self.slots = {"primary": primary, "alternate": alternate}
        self.standby = standby
        self.replaced = {}            # slot -> original feed while the standby serves it

    @property
    def primary(self):
        return self.slots["primary"]

    @property
    def alternate(self):
        return self.slots["alternate"]

    def use_standby(self, slot):
        """Q-248: useStandbyRoute(token, slot) replaces the slot with the pre-approved standby at once."""
        if slot in self.replaced or self.standby in self.slots.values():
            raise ValueError("StandbyInUse")
        self.replaced[slot] = self.slots[slot]
        self.slots[slot] = self.standby

    def restore(self, slot):
        if slot not in self.replaced:
            raise ValueError("NotSwitched")
        self.slots[slot] = self.replaced.pop(slot)

    def read(self, now, tol_bps, ceiling, gas_ok=True):
        (p, pc) = self.primary.read(now, gas_ok)
        (b, bc) = self.alternate.read(now, gas_ok)
        if not p and not b:
            return None, (pc, bc)
        disagree = bool(p and b and abs(p[0] - b[0]) * BPS > tol_bps * min(p[0], b[0]))
        use, route = (p, "primary") if p else (b, "alternate")
        q = use[0]
        v = min(q, ceiling) if self.stable else q
        w = (min(min(p[0], b[0]), ceiling) if self.stable else min(p[0], b[0])) if (p and b) else v
        feed = self.primary if route == "primary" else self.alternate
        return dict(q=q, v=v, w=w, t=use[1], route=route, feed=feed, p=p[0] if p else None,
                    b=b[0] if b else None, disagree=disagree), (pc, bc)


def lp_price8(v0, v1):
    """SPEC-ORC-008: isqrt(4·v0·v1) − 1, never below 1."""
    return max(1, isqrt(4 * v0 * v1) - 1)


class _StateMachine:
    """Shared failure-start, recovery-evidence and disagreement bookkeeping (SPEC-ORC-013, 014, 016)."""

    def _failure_state(self, now, causes_by_token):
        s_ts = None
        for tf, causes in causes_by_token:
            if causes is not None and causes[0] == "stale" and causes[1] == "stale":
                at = max(tf.primary.stale_from(), tf.alternate.stale_from())
                s_ts = at if s_ts is None else min(s_ts, at)
        start = now
        if s_ts is not None:
            start = min(start, s_ts)
        if self.failed_since is not None:
            start = min(start, self.failed_since)
        st = CACHED if now < start + self.p.cached_window else EXPIRED
        both_stale = all(c is None or (c[0] == "stale" and c[1] == "stale") for _tf, c in causes_by_token)
        return st, both_stale

    def _evidence(self, now):
        """SPEC-ORC-014: recoveredAt candidate from source timestamps, or None."""
        best = None
        for tf in self.tokens:
            spans = []
            for feed in (tf.primary, tf.alternate):
                r, cause = feed.read(now)
                if r is None:
                    if cause == "stale":
                        spans.append((feed.stale_from(), now))
                        continue
                    spans = None
                    break
                seen = self.seen.get(feed.key)
                if seen is None or seen[0] == feed.round_id or feed.updated_at - seen[1] <= feed.max_age:
                    spans.append(None)
                    continue
                prev = feed.prev_updated_at(seen[1])
                if prev is None:
                    spans = None
                    break
                spans.append((prev + feed.max_age + 1, feed.updated_at))
            if not spans or any(sp is None for sp in spans):
                continue
            lo = max(sp[0] for sp in spans)
            hi = min(sp[1] for sp in spans)
            if hi - lo >= self.p.cached_window and (self.recovered_at is None or hi > self.recovered_at):
                best = hi if best is None else max(best, hi)
        return None if best is None else min(best, now)

    def _remember_rounds(self):
        for tf in self.tokens:
            for feed in (tf.primary, tf.alternate):
                self.seen[feed.key] = (feed.round_id, feed.updated_at)

    def in_grace(self, now):
        return self.recovered_at is not None and now < self.recovered_at + self.p.grace_period


class LPOracle(_StateMachine):
    def __init__(self, market, feeds0, feeds1, pool, params, now):
        self.market, self.f0, self.f1, self.pool = market, feeds0, feeds1, pool
        self.tokens = (feeds0, feeds1)
        self.p = params
        e = self.evaluate(now, seeding=True)
        assert e["state"] == LIVE, "a valid Live price is seeded before listing (Q-128)"
        self.accepted, self.accepted_ts = e["fresh"], e["ts"]
        self.failed_since = None
        self.expired_flag = False
        self.recovered_at = None
        self.disagree_since = None
        self.checkpoint = (self.accepted, now)
        self.seen = {}
        self._remember_rounds()

    def twap_deviates(self, q0, q1):
        from .uniswap import sqrt_price_from_usd
        s_or = sqrt_price_from_usd(q0, q1, self.pool.d0, self.pool.d1)
        s_tw = self.pool.twap_sqrt_p
        po, pt = s_or * s_or, s_tw * s_tw
        return abs(pt - po) * BPS > self.p.twap_tol_bps * po

    def evaluate(self, now, gas_ok=True, seeding=False):
        ce = self.p.stable_ceiling
        r0, c0 = self.f0.read(now, self.p.alt_tol_bps, ce, gas_ok)
        r1, c1 = self.f1.read(now, self.p.alt_tol_bps, ce, gas_ok)
        if r0 is None or r1 is None:
            st, both_stale = self._failure_state(now, ((self.f0, c0 if r0 is None else None),
                                                       (self.f1, c1 if r1 is None else None)))
            return dict(state=st, served=self.accepted if st == CACHED else 1, fresh=None, ts=self.accepted_ts,
                        reason="stale" if both_stale else "error", borrow_age_ok=False, liq_paused=True,
                        legs=None, disagree=False)
        fresh = lp_price8(r0["v"], r1["v"])
        ts = min(r0["t"], r1["t"])
        disagree = r0["disagree"] or r1["disagree"]
        low, high = self.p.band_low, self.p.band_high
        band_out = not (low * low <= r0["q"] * r1["q"] and r0["v"] * r1["v"] <= high * high)
        if disagree:
            st, reason = DRIFTING, "disagree"
        elif self.twap_deviates(r0["q"], r1["q"]):
            st, reason = DRIFTING, "twap"
        elif band_out:
            st, reason = DRIFTING, "band"
        else:
            st, reason = LIVE, "ok"
        if disagree:
            served = max(1, min(lp_price8(r0["w"], r1["w"]), fresh))
        else:
            served = fresh
        borrow_ok = all(now - r["t"] <= r["feed"].borrow_age for r in (r0, r1))
        alt_late = any(r["route"] == "alternate" and now - r["t"] > r["feed"].borrow_age for r in (r0, r1))
        return dict(state=st, served=served, fresh=fresh, ts=ts, reason=reason, borrow_age_ok=borrow_ok,
                    liq_paused=disagree or alt_late, legs=(r0, r1), disagree=disagree, band=band_out,
                    t_max=max(r0["t"], r1["t"]))

    def state(self, now):
        return self.evaluate(now)["state"]

    def latest_answer(self, now):
        """What the AaveOracle reads: never reverts, at least 1 (INV-055)."""
        return self.evaluate(now)["served"]

    def leg_prices(self, now):
        """Capped leg prices LPOracle uses for valuation (SPEC-LIQ-012); accepted-time legs if failed."""
        e = self.evaluate(now)
        if e["legs"] is None:
            return None
        return e["legs"][0]["v"], e["legs"][1]["v"]

    def observe(self, now):
        """Storage writes made by poke() and every successful Avana call that reads the market."""
        e = self.evaluate(now)
        st = e["state"]
        if e["fresh"] is None:
            if self.failed_since is None:
                self.failed_since = now
            if st == EXPIRED and e["reason"] == "stale":
                self.expired_flag = True
        else:
            ev = self._evidence(now)
            if self.expired_flag:
                cand = min(e["t_max"], now)                       # Q-264: max(t0, t1), never later than now
                ev = cand if ev is None else max(ev, cand)
                self.expired_flag = False
            if ev is not None and (self.recovered_at is None or ev > self.recovered_at):
                self.recovered_at = ev
            self.failed_since = None
            if st == LIVE and e["ts"] > self.accepted_ts:
                self.accepted, self.accepted_ts = e["fresh"], e["ts"]
        if e["disagree"]:
            if self.disagree_since is None:
                self.disagree_since = now
        else:
            self.disagree_since = None
        if now - self.checkpoint[1] >= 3600:
            self.checkpoint = (self.accepted, now)
        self._remember_rounds()
        return st

    def poke(self, now, gas_ok=True):
        if not gas_ok:
            raise ValueError("poke: below minimum gas (Q-154)")
        return self.observe(now)

    def liquidation_block(self, now):
        """Reason seizure of this market is refused, or None (SPEC-ORC-016)."""
        e = self.evaluate(now)
        if e["state"] in (CACHED, EXPIRED):
            return e["state"]
        if e["disagree"]:
            return "disagreement"
        if e["liq_paused"]:
            return "alternate past borrow age"
        return None

    def price_drop_tripped(self, now, drop_bps):
        cp, at = self.checkpoint
        return now - at <= 7200 and self.accepted * BPS < cp * (BPS - drop_bps)


class DebtOracle(_StateMachine):
    """Price source of a non-GHO debt reserve (Q-248): routes, failover, agreement, Cached and Expired."""

    def __init__(self, token, feeds, params, now):
        self.token, self.feeds = token, feeds
        self.tokens = (feeds,)
        self.p = params
        e = self.evaluate(now, seeding=True)
        assert e["state"] == LIVE
        self.accepted, self.accepted_ts = e["q"], e["ts"]
        self.failed_since = None
        self.expired_flag = False
        self.recovered_at = None
        self.disagree_since = None
        self.seen = {}
        self._remember_rounds()

    def evaluate(self, now, gas_ok=True, seeding=False):
        r, c = self.feeds.read(now, self.p.alt_tol_bps, 2 ** 255, gas_ok)
        if r is None:
            st, both_stale = self._failure_state(now, ((self.feeds, c),))
            A = self.accepted
            served = A if st == CACHED else cdiv(A * (BPS + self.p.debt_stress_rise_bps), BPS)
            return dict(state=st, served=served, q=None, ts=self.accepted_ts, reason="stale" if both_stale else "error",
                        borrow_age_ok=False, liq_ok=False, disagree=False)
        if r["disagree"]:
            served = max(r["p"], r["b"], self.accepted) if not seeding else r["q"]
            st = DRIFTING
        else:
            served, st = r["q"], LIVE
        age_ok = now - r["t"] <= r["feed"].borrow_age
        alt_late = r["route"] == "alternate" and not age_ok
        return dict(state=st, served=served, q=r["q"], ts=r["t"], reason="disagree" if r["disagree"] else "ok",
                    borrow_age_ok=age_ok and st == LIVE, liq_ok=st == LIVE and not alt_late,
                    disagree=r["disagree"], t_max=r["t"])

    def latest_answer(self, now):
        return self.evaluate(now)["served"]

    def observe(self, now):
        e = self.evaluate(now)
        if e["q"] is None:
            if self.failed_since is None:
                self.failed_since = now
            if e["state"] == EXPIRED and e["reason"] == "stale":
                self.expired_flag = True
        else:
            if self.expired_flag:
                self.recovered_at = min(e["t_max"], now)
                self.expired_flag = False
            self.failed_since = None
            if e["state"] == LIVE and e["ts"] > self.accepted_ts:
                self.accepted, self.accepted_ts = e["q"], e["ts"]
        self.disagree_since = (self.disagree_since or now) if e["disagree"] else None
        self._remember_rounds()
        return e["state"]

    def poke(self, now, gas_ok=True):
        if not gas_ok:
            raise ValueError("poke: below minimum gas")
        return self.observe(now)
