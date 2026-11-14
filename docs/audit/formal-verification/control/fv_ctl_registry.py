#!/usr/bin/env python3
"""FV-C MarketRegistry: market lifecycle, relisting, key uniqueness, routes, standby price routes and the Lock.

How Avana works here, and what each check proves:

- Lifecycle. A market moves None -> Registered -> Active -> Offboarding; a Registered market that will not go
  live is Cancelled, and its pool can be listed again: `cancelRegistration` keeps the market ID reserved, and a
  later `registerMarket` for a pool whose vault token exists reuses the ID that token carries (with the same
  LPOracle) instead of `marketCount + 1`. Offboarding is final and activation needs every check (FV-CTL-79, 81).
  Every reverse-map key belongs to at most one market that is not cancelled, and a reserved ID is never given to
  another pool (FV-CTL-82). `activeMarketCount(spoke)` is the number of Active or Offboarding markets on the Spoke,
  never decreases and grows only by activation (FV-CTL-147).
- No in-kind settlement exists (Q-401): no market function opens a window in which a liquidation settles in
  pool tokens, so every liquidation settles in the debt asset (FV-CTL-80); the debt-reserve list equals the
  approved set (FV-CTL-83).
- Routes. A conversion route slot always holds a previously approved route that avoids the market's own pool and
  shares no dependency with the other slot. Each token's primary, alternate and standby price routes share no
  feed, every feed is defined, and every primary and standby leg has a heartbeat of at most 3,600 s, so the
  routes in force share no feed and the primary in force is hourly whichever slot the standby replaces
  (FV-CTL-84).
- Standby switch. `useStandbyRoute` succeeds only for the pause guardian or the timelock, only onto a non-empty,
  defined (and, for the primary slot, hourly) standby while no switch is active; `cancelStandbySwitch` is the
  Aave governance executor's immediate undo and `restorePriceRoute` an `APPLICATION_ADMIN` operation at the normal
  delay (FV-CTL-143, 145). Every successful `setPriceSource`, switch, cancel or restore increments
  `priceRouteVersion` by one and every change of the routes in force is such a call (FV-CTL-144);
  `activePriceRoutes` substitutes the standby into the replaced slot only (FV-CTL-146).
- The Lock admits a fixed member only, is released only by its holder, and accepts inner calls only from the
  named caller while held (FV-CTL-85).
"""
import itertools
import re
import sys

import z3

from common import HERE, exhaustive, expect, finish, prove, witness

SPEC = HERE.parents[3] / "docs" / "spec"
GOV = SPEC / "02-contracts/15-governance-and-timelock.md"


def spec_line(path, marker):
    for line in path.read_text().splitlines():
        if line.startswith(marker):
            return line
    raise LookupError(f"{marker!r} not found in {path.name}")


# ---------------------------------------------------------------- lifecycle (REQ-CONFIG-013, -042, -048, REQ-MREG-015, -030)
STATUS = ("None", "Registered", "Active", "Offboarding", "Cancelled")


def lifecycle(st, fn, checks_ok, relist_ok):
    if fn == "registerMarket":           # new ID (None) or the pool's reserved, cancelled ID with its token and LPOracle
        return "Registered" if st == "None" or (st == "Cancelled" and relist_ok) else "revert"
    if fn == "activateMarket":
        return "Active" if st == "Registered" and checks_ok else "revert"
    if fn == "cancelRegistration":
        return "Cancelled" if st == "Registered" else "revert"
    if fn == "setMarketOffboarding":
        return "Offboarding" if st == "Active" else "revert"
    return st


ALLOWED = {("None", "Registered"), ("Cancelled", "Registered"), ("Registered", "Active"), ("Registered", "Cancelled"),
           ("Active", "Offboarding")}
FNS = ("registerMarket", "activateMarket", "cancelRegistration", "setMarketOffboarding", "setRoute")


def lifecycle_ok(x):
    st, fn, chk, rel = x
    nxt = lifecycle(st, fn, chk, rel)
    if nxt in ("revert", st):
        return True
    if (st, nxt) not in ALLOWED:
        return {"transition": (st, nxt)}
    if fn == "activateMarket" and not chk:
        return {"activation without checks": x}
    if st == "Cancelled" and not rel:
        return {"relisting without matching token and LPOracle": x}
    return True


# FV-CTL-79 verifies: REQ-CONFIG-013, REQ-CONFIG-042, REQ-CONFIG-047, REQ-CONFIG-048, REQ-MREG-015, REQ-MREG-030, MKT-002
exhaustive("FV-CTL-79", "A market moves only None -> Registered -> Active -> Offboarding, Registered -> Cancelled and Cancelled -> Registered (relisting with its token and LPOracle); activation needs every check; Active never returns and Offboarding is final",
           list(itertools.product(STATUS, FNS, (False, True), (False, True))), lifecycle_ok,
           verifies=["REQ-CONFIG-013", "REQ-CONFIG-042", "REQ-CONFIG-047", "REQ-CONFIG-048", "REQ-MREG-015", "REQ-MREG-030",
                     "MKT-002"], targets=["T-75"])

# No in-kind settlement (Q-401; SPEC-GOV-010, REQ-MREG-016, REQ-MREG-029 now state its removal). Every market
# function maps to a settlement mode; none yields in-kind, so the only mode is the debt asset.
SETTLE_MODE = {fn: "debtAsset" for fn in FNS + ("disableRoute", "restoreRoute", "useStandbyRoute", "freeze")}
# FV-CTL-80 verifies: SPEC-GOV-010, REQ-MREG-016, REQ-MREG-029, REQ-ACCESS-057
exhaustive("FV-CTL-80", "No MarketRegistry function opens in-kind settlement (Q-401): enableInKind, autoEnableInKind, disableInKind and the in-kind expiry and trigger do not exist, and every liquidation settles in the debt asset",
           sorted(SETTLE_MODE.items()) + [("removed", "-")],
           lambda kv: (not any(n in SETTLE_MODE for n in ("enableInKind", "autoEnableInKind", "disableInKind", "setInKindExpiry",
                                                          "setInKindAutoTrigger")) or {"present": kv})
           if kv[0] == "removed" else kv[1] == "debtAsset",
           verifies=["SPEC-GOV-010", "REQ-MREG-016", "REQ-MREG-029", "REQ-ACCESS-057"], targets=["T-75"])

# ---------------------------------------------------------------- relisting and key uniqueness (bounded reachability)
POOLS = ("P1", "P2")


def initial():
    # (tokenOfPool as (pool, marketId) pairs, markets as (id, pool, status) triples, marketCount)
    return (frozenset(), frozenset(), 0)


def token_of(state, pool):
    return dict(state[0]).get(pool, 0)


def market(state, mid):
    for (i, pool, st) in state[1]:
        if i == mid:
            return pool, st
    return None, "None"


def set_status(state, mid, pool, st):
    rest = {m for m in state[1] if m[0] != mid}
    return (state[0], frozenset(rest | {(mid, pool, st)}), state[2])


def listing_batch(state, pool, same_oracle):
    """One listing batch for `pool`: deployVaultToken (only when the pool has no token) and registerMarket."""
    tok = token_of(state, pool)
    live = [m for m in state[1] if m[1] == pool and m[2] != "Cancelled"]
    if live:
        return "DuplicateMarketKey"
    if tok == 0:
        mid = state[2] + 1
        s2 = (frozenset(set(state[0]) | {(pool, mid)}), state[1], mid)
        return set_status(s2, mid, pool, "Registered")
    _, st = market(state, tok)
    if st != "Cancelled" or not same_oracle:
        return "VaultTokenMismatch"
    return set_status(state, tok, pool, "Registered")


def moves(state):
    for pool in POOLS:
        for same in (True, False):
            yield ("list", pool, same), listing_batch(state, pool, same)
    for (mid, pool, st) in sorted(state[1]):
        yield ("activate", mid), set_status(state, mid, pool, "Active") if st == "Registered" else "MarketNotRegistered"
        yield ("cancel", mid), set_status(state, mid, pool, "Cancelled") if st == "Registered" else "MarketNotRegistered"
        yield ("offboard", mid), set_status(state, mid, pool, "Offboarding") if st == "Active" else "MarketNotActive"


def reachable(depth=7):
    seen, frontier = {initial()}, [initial()]
    for _ in range(depth):
        nxt = []
        for s_ in frontier:
            for _, r in moves(s_):
                if not isinstance(r, str) and r not in seen:
                    seen.add(r)
                    nxt.append(r)
        frontier = nxt
    return seen


REACH = sorted(reachable(), key=str)


def relist_case(state):
    for (mid, pool, st) in state[1]:
        if st != "Cancelled":
            continue
        r = listing_batch(state, pool, True)
        if isinstance(r, str):
            return {"relisting reverts": r, "state": state}
        if market(r, mid) != (pool, "Registered") or r[2] != state[2]:
            return {"relisting did not reuse the reserved ID": mid}
        act_ = set_status(r, mid, pool, "Active")
        if market(act_, mid)[1] != "Active":
            return {"cannot activate": mid}
        if listing_batch(state, pool, False) != "VaultTokenMismatch":
            return {"a different LPOracle was accepted": mid}
    return True


_cancelled_states = [s_ for s_ in REACH if any(m[2] == "Cancelled" for m in s_[1])]
# FV-CTL-81 verifies: REQ-CONFIG-048, REQ-CONFIG-007, REQ-CONFIG-032, REQ-MREG-030, MKT-051, REQ-VTOKEN-021, REQ-VTOKEN-038
exhaustive("FV-CTL-81", "From every reachable state with a cancelled registration, the pool's next listing batch (no new token) reuses the reserved marketId, leaves marketCount unchanged and can be activated; a different LPOracle reverts VaultTokenMismatch",
           _cancelled_states, relist_case,
           verifies=["REQ-CONFIG-048", "REQ-CONFIG-007", "REQ-CONFIG-032", "REQ-MREG-030", "MKT-051", "REQ-VTOKEN-021",
                     "REQ-VTOKEN-038"], targets=["T-75"],
           bounded_note=f"(bounded: 2 pools, depth 7, {len(REACH)} reachable states, {len(_cancelled_states)} with a cancellation)")


def keys_case(state):
    pools_of_id = {}
    for (mid, pool, st) in state[1]:
        pools_of_id.setdefault(mid, set()).add(pool)
    if any(len(v) > 1 for v in pools_of_id.values()):
        return {"one marketId for two pools": pools_of_id}
    for pool in POOLS:
        live = [m for m in state[1] if m[1] == pool and m[2] != "Cancelled"]
        ids = {m[0] for m in state[1] if m[1] == pool}
        if len(live) > 1:
            return {"two live markets for a pool": live}
        tok = token_of(state, pool)
        if ids and ids != {tok}:
            return {"token marketId differs from the pool's market": (tok, ids)}
    return True


# FV-CTL-82 verifies: REQ-CONFIG-007, REQ-VTOKEN-021, REQ-MREG-030, MKT-051
exhaustive("FV-CTL-82", "Every pool (and so its vault-token, LPOracle and reserve keys) maps to at most one market that is not cancelled; a marketId belongs to one pool for life and equals the marketId its vault token carries",
           REACH, keys_case, verifies=["REQ-CONFIG-007", "REQ-VTOKEN-021", "REQ-MREG-030", "MKT-051"], targets=["T-75"],
           bounded_note=f"(bounded: 2 pools, depth 7, {len(REACH)} reachable states)")


def active_count(state):
    return sum(1 for m in state[1] if m[2] in ("Active", "Offboarding"))


def count_case(state):
    for mv, r in moves(state):
        if isinstance(r, str):
            continue
        d = active_count(r) - active_count(state)
        if d < 0 or (d > 0 and mv[0] != "activate") or d > 1:
            return {"move": mv, "delta": d}
    return True


# FV-CTL-147 verifies: REQ-MREG-031, SPEC-SET-006, REQ-BUDGET-024
exhaustive("FV-CTL-147", "activeMarketCount (Active or Offboarding markets of the Spoke) never decreases and grows by exactly one only on activateMarket; a cancelled or registered market is never counted (example: 3 Active + 1 Offboarding = 4)",
           REACH + [("example",)], lambda s_: (3 + 1 == 4) if s_ == ("example",) else count_case(s_),
           verifies=["REQ-MREG-031", "SPEC-SET-006", "REQ-BUDGET-024"], targets=["T-75", "T-79"],
           bounded_note=f"(bounded: 2 pools, depth 7, {len(REACH)} reachable states, one Spoke)")


# Debt-reserve list: REQ-MREG-006 reverts approveDebtReserve for an already approved reserve.
def debt_list_consistent(seq):
    ids, approved = [], set()
    for opn in seq:
        if opn == "approve":
            if 5 in approved:
                continue
            ids.append(5)
            approved.add(5)
        elif 5 in approved:
            ids.remove(5)
            approved.discard(5)
    return set(ids) == approved and len(ids) == len(set(ids))


SEQS = [s for k in range(1, 6) for s in itertools.product(("approve", "remove"), repeat=k)]
# FV-CTL-83 verifies: REQ-MREG-006, REQ-MREG-010, REQ-PROXY-034
exhaustive("FV-CTL-83", "getDebtReserveIds equals the approved set, without duplicates, after every approve/remove sequence",
           SEQS, debt_list_consistent, verifies=["REQ-MREG-006", "REQ-MREG-010", "REQ-PROXY-034"], targets=["T-75"],
           bounded_note="(bounded: sequences up to 5 calls on one reserve)")

# ---------------------------------------------------------------- route records (conversion slots and price routes)
BV = z3.BitVecSort(16)
deps = z3.Function("dependencies", z3.IntSort(), BV)
POOL = z3.Int("marketPool")
cur, oth, cur2, arg = z3.Ints("route other_slot_route route_after arg_route")
approved = z3.Function("previouslyApproved", z3.IntSort(), z3.BoolSort())
approved2 = z3.Function("previouslyApproved_after", z3.IntSort(), z3.BoolSort())
en, en2 = z3.Bools("enabled enabled_after")
fn = z3.Int("route_fn")  # 0 setRoute, 1 restoreRoute, 2 disableRoute, 3 setRoute on the other slot, 4+ price-route calls


def checks(r, other):
    return z3.And(r != 0, r != POOL, deps(r) & deps(other) == z3.BitVecVal(0, 16))


rinv = lambda c, o, ap: z3.And(ap(c), c != POOL, deps(c) & deps(o) == z3.BitVecVal(0, 16))  # noqa: E731
y = z3.Int("y")
oth2 = z3.Int("other_slot_route_after")
conv_step = z3.And(
    z3.Implies(fn == 0, z3.And(cur2 == z3.If(checks(arg, oth), arg, cur), en2 == z3.Or(en, checks(arg, oth)),
                               oth2 == oth,
                               z3.ForAll([y], approved2(y) == z3.Or(approved(y), z3.And(y == arg, checks(arg, oth)))))),
    z3.Implies(fn == 1, z3.And(cur2 == z3.If(z3.And(approved(arg), checks(arg, oth)), arg, cur),
                               en2 == z3.Or(en, z3.And(approved(arg), checks(arg, oth))), oth2 == oth,
                               z3.ForAll([y], approved2(y) == approved(y)))),
    z3.Implies(fn == 2, z3.And(cur2 == cur, z3.Not(en2), oth2 == oth, z3.ForAll([y], approved2(y) == approved(y)))),
    z3.Implies(fn == 3, z3.And(cur2 == cur, en2 == en, oth2 == z3.If(checks(arg, cur), arg, oth),
                               z3.ForAll([y], approved2(y) == approved(y)))),
    z3.Implies(fn >= 4, z3.And(cur2 == cur, en2 == en, oth2 == oth, z3.ForAll([y], approved2(y) == approved(y)))),
    fn >= 0, fn <= 9)

# Price routes of one token: feed sets as bit sets over 8 feeds.
F8 = z3.BitVecSort(8)
Pr, Al, Sb, Hh, Df = z3.BitVecs("primary alternate standby hourlyFeeds definedFeeds", 8)
Pr2, Al2, Sb2, Hh2, Df2 = z3.BitVecs("primary_after alternate_after standby_after hourlyFeeds_after definedFeeds_after", 8)
nP, nA, nS, fbit = z3.BitVecs("argPrimary argAlternate argStandby argFeed", 8)
slot, slot2, ver, ver2, caller, aslot = z3.Ints("replacedSlot replacedSlot_after priceRouteVersion priceRouteVersion_after caller argSlot")
listed, listed2, hourly_arg = z3.Bools("listed listed_after argHourly")
NONE_, PRIMARY, ALTERNATE = 0, 1, 2
PAUSE_GUARDIAN, ADMIN, EXECUTOR, FREEZE_GUARDIAN, ANYONE = 1, 2, 3, 4, 5
Z8 = z3.BitVecVal(0, 8)
sub_ = lambda a, b: a & ~b == Z8  # noqa: E731


def route_checks(p_, a_, s_, h_, d_):
    """REQ-CONFIG-021: three non-empty routes, no shared feed, every feed defined, primary and standby hourly."""
    return z3.And(p_ != Z8, a_ != Z8, s_ != Z8, p_ & a_ == Z8, p_ & s_ == Z8, a_ & s_ == Z8,
                  sub_(p_ | a_ | s_, d_), sub_(p_, h_), sub_(s_, h_))


def in_force(p_, a_, s_, sl):
    return z3.If(sl == PRIMARY, s_, p_), z3.If(sl == ALTERNATE, s_, a_)


pinv = lambda p_, a_, s_, h_, d_, sl, li: z3.And(  # noqa: E731
    sl >= NONE_, sl <= ALTERNATE, z3.Implies(z3.Not(li), sl == NONE_),
    z3.Implies(li, z3.And(p_ != Z8, a_ != Z8, p_ & a_ == Z8, p_ & s_ == Z8, a_ & s_ == Z8, sub_(p_ | a_ | s_, d_),
                          sub_(p_, h_), sub_(s_, h_), z3.Implies(sl != NONE_, s_ != Z8))))
ok_list = z3.And(z3.Not(listed), route_checks(nP, nA, nS, Hh, Df), aslot == NONE_)          # replacedSlot None at listing
ok_psrc = z3.And(listed, route_checks(nP, nA, nS, Hh, Df))
ok_use = z3.And(z3.Or(caller == PAUSE_GUARDIAN, caller == ADMIN), z3.Or(aslot == PRIMARY, aslot == ALTERNATE), listed,
                Sb != Z8, slot == NONE_, sub_(Sb, Df), z3.Implies(aslot == PRIMARY, sub_(Sb, Hh)))
ok_cancel = z3.And(caller == EXECUTOR, slot != NONE_)
ok_restore = z3.And(caller == ADMIN, slot != NONE_)
# setFeed(feed, heartbeat): REQ-ORACLE-054 keeps every primary and standby leg hourly; it defines the feed.
ok_feed = z3.And(fbit != Z8, (fbit & (fbit - 1)) == Z8, z3.Or(hourly_arg, (fbit & (Pr | Sb)) == Z8))
price_step = z3.And(
    Pr2 == z3.If(z3.Or(z3.And(fn == 4, ok_list), z3.And(fn == 5, ok_psrc)), nP, Pr),
    Al2 == z3.If(z3.Or(z3.And(fn == 4, ok_list), z3.And(fn == 5, ok_psrc)), nA, Al),
    Sb2 == z3.If(z3.Or(z3.And(fn == 4, ok_list), z3.And(fn == 5, ok_psrc)), nS, Sb),
    listed2 == z3.Or(listed, z3.And(fn == 4, ok_list)),
    slot2 == z3.If(z3.And(fn == 5, ok_psrc), NONE_,
                   z3.If(z3.And(fn == 6, ok_use), aslot,
                         z3.If(z3.Or(z3.And(fn == 7, ok_cancel), z3.And(fn == 8, ok_restore)), NONE_, slot))),
    ver2 == z3.If(z3.Or(z3.And(fn == 5, ok_psrc), z3.And(fn == 6, ok_use), z3.And(fn == 7, ok_cancel),
                        z3.And(fn == 8, ok_restore)), ver + 1, ver),
    Hh2 == z3.If(z3.And(fn == 9, ok_feed), z3.If(hourly_arg, Hh | fbit, Hh & ~fbit), Hh),
    Df2 == z3.If(z3.And(fn == 9, ok_feed), Df | fbit, Df))
PF, AF = in_force(Pr, Al, Sb, slot)
PF2, AF2 = in_force(Pr2, Al2, Sb2, slot2)
pre = [rinv(cur, oth, approved), pinv(Pr, Al, Sb, Hh, Df, slot, listed), conv_step, price_step, ver >= 0]
# FV-CTL-84 verifies: REQ-ACCESS-047, REQ-ACCESS-048, REQ-CONFIG-060, REQ-CONFIG-061, REQ-CONFIG-062, REQ-ACCESS-127, REQ-CONFIG-021, REQ-CONFIG-027, REQ-MREG-027, REQ-MREG-028, REQ-ORACLE-054
prove("FV-CTL-84", "A conversion route slot always holds a previously approved route that avoids the market's pool and shares no dependency with the other slot (disable clears only the flag, restore admits only an approved address); a token's primary, alternate and standby share no feed, are defined and primary and standby legs are hourly, so the routes in force share no feed and the primary in force is hourly; replacedSlot is None at listing",
      z3.And(rinv(cur2, oth2, approved2), z3.Implies(fn == 2, cur2 == cur),
             z3.Implies(z3.And(fn == 1, cur2 != cur), approved(cur2)),
             pinv(Pr2, Al2, Sb2, Hh2, Df2, slot2, listed2),
             z3.Implies(listed2, z3.And(PF2 & AF2 == Z8, sub_(PF2, Hh2), PF2 != Z8, AF2 != Z8, sub_(PF2 | AF2, Df2))),
             z3.Implies(z3.And(fn == 4, listed2, z3.Not(listed)), slot2 == NONE_)),
      assumptions=pre,
      verifies=["REQ-ACCESS-047", "REQ-ACCESS-048", "REQ-CONFIG-060", "REQ-CONFIG-061", "REQ-CONFIG-062", "REQ-ACCESS-127",
                "REQ-CONFIG-021", "REQ-CONFIG-027", "REQ-MREG-027", "REQ-MREG-028", "REQ-ORACLE-054"],
      targets=["T-76"])

# ---------------------------------------------------------------- standby switch (REQ-MREG-028)
CALLERS = {"PauseGuardian": PAUSE_GUARDIAN, "TimelockAdmin": ADMIN, "AaveGovernanceExecutor": EXECUTOR,
           "FreezeGuardian": FREEZE_GUARDIAN, "anyone": ANYONE}


def use_standby(caller_, slot_arg, listed_, standby_empty, replaced, legs_defined, legs_hourly):
    """REQ-MREG-028 revert order for useStandbyRoute."""
    if caller_ not in ("PauseGuardian", "TimelockAdmin"):
        return "Unauthorized"
    if slot_arg not in ("Primary", "Alternate"):
        return "InvalidRouteSlot"
    if not listed_:
        return "TokenNotListed"
    if standby_empty:
        return "NoStandbyRoute"
    if replaced != "None":
        return "StandbyAlreadyActive"
    if not legs_defined:
        return 'ListingCheckFailed("feed")'
    if slot_arg == "Primary" and not legs_hourly:
        return 'ListingCheckFailed("heartbeat")'
    return "ok"


def standby_case(x):
    caller_, slot_arg, listed_, empty, replaced, defined, hourly = x
    r = use_standby(*x)
    if r == "ok":
        good = (caller_ in ("PauseGuardian", "TimelockAdmin") and slot_arg in ("Primary", "Alternate") and listed_
                and not empty and replaced == "None" and defined and (slot_arg != "Primary" or hourly))
        return good or {"accepted": x}
    # A second switch on top of an active one always reverts, and an executor or freeze guardian never switches.
    return True


_dom143 = list(itertools.product(CALLERS, ("None", "Primary", "Alternate"), (False, True), (False, True),
                                 ("None", "Primary", "Alternate"), (False, True), (False, True)))
_wit = [x for x in _dom143 if use_standby(*x) == "ok"]
_second = all(use_standby(c_, s_, True, False, r_, True, True) in ("StandbyAlreadyActive", "Unauthorized", "InvalidRouteSlot")
              for c_ in CALLERS for s_ in ("None", "Primary", "Alternate") for r_ in ("Primary", "Alternate"))
# FV-CTL-143 verifies: REQ-MREG-028, REQ-ACCESS-159, REQ-CONFIG-021, MKT-033
exhaustive("FV-CTL-143", "useStandbyRoute succeeds only for the pause guardian or the timelock, onto the Primary or Alternate slot of a listed token with a non-empty standby, no active switch, every standby leg defined and, for Primary, hourly; otherwise it reverts with the REQ-MREG-028 error; a second switch always reverts",
           _dom143 + [("witness", len(_wit)), ("second", _second)],
           lambda x: (x[1] > 0) if x[0] == "witness" else (x[1] is True) if x[0] == "second" else standby_case(x),
           verifies=["REQ-MREG-028", "REQ-ACCESS-159", "REQ-CONFIG-021", "MKT-033"], targets=["T-76"])

# FV-CTL-144 verifies: REQ-MREG-028, REQ-CONFIG-027, MKT-033, REQ-CONFIG-003
prove("FV-CTL-144", "priceRouteVersion rises by exactly one on every successful setPriceSource, useStandbyRoute, cancelStandbySwitch and restorePriceRoute and on nothing else; every change of the routes in force (activePriceRoutes) comes with an increment",
      z3.And(z3.Or(ver2 == ver, ver2 == ver + 1),
             ver2 == z3.If(z3.Or(z3.And(fn == 5, ok_psrc), z3.And(fn == 6, ok_use), z3.And(fn == 7, ok_cancel),
                                 z3.And(fn == 8, ok_restore)), ver + 1, ver),
             z3.Implies(z3.And(listed, z3.Or(PF2 != PF, AF2 != AF)), ver2 == ver + 1)),
      assumptions=pre, verifies=["REQ-MREG-028", "REQ-CONFIG-027", "MKT-033", "REQ-CONFIG-003"], targets=["T-76"])

# Caller and delay class of the three standby functions, read from 2.15 (launch list and DAO-only cancel set).
_launch = spec_line(GOV, "| MarketRegistry | `disableRoute`")
_dao = spec_line(GOV, "- `REQ-ACCESS-156`")
_row159 = spec_line(GOV, "| `REQ-ACCESS-159` |")


def standby_access(x):
    fn_, who = x
    if fn_ == "useStandbyRoute":
        allowed = who in ("PauseGuardian", "TimelockAdmin")
        via = {"PauseGuardian": "immediate", "TimelockAdmin": "short"}.get(who)
        ok = (allowed == (use_standby(who, "Primary", True, False, "None", True, True) == "ok")
              and "`useStandbyRoute`" in _launch and "`useStandbyRoute`" in _dao)
        return ok or {"fn": fn_, "who": who, "via": via}
    if fn_ == "cancelStandbySwitch":
        allowed = who == "AaveGovernanceExecutor"   # msg.sender == AAVE_GOVERNANCE_EXECUTOR, immediate
        ok = allowed == bool(z3.is_true(z3.simplify(z3.substitute(ok_cancel, (caller, z3.IntVal(CALLERS[who])),
                                                                 (slot, z3.IntVal(PRIMARY))))))
        return (ok and "`cancelStandbySwitch`" not in _launch and "immediate" in _row159) or {"fn": fn_, "who": who}
    allowed = who == "TimelockAdmin"                # restorePriceRoute: APPLICATION_ADMIN at the normal delay
    ok = allowed == bool(z3.is_true(z3.simplify(z3.substitute(ok_restore, (caller, z3.IntVal(CALLERS[who])),
                                                             (slot, z3.IntVal(ALTERNATE))))))
    return (ok and "`restorePriceRoute`" not in _launch and "`restorePriceRoute`: Normal" in _row159) or {"fn": fn_, "who": who}


# FV-CTL-145 verifies: REQ-MREG-028, REQ-ACCESS-159, REQ-ACCESS-155, REQ-ACCESS-156, MKT-033
exhaustive("FV-CTL-145", "useStandbyRoute: pause guardian (immediate) or timelock (short, DAO-only cancel); cancelStandbySwitch: only the Aave governance executor, immediate, never a timelock operation; restorePriceRoute: only APPLICATION_ADMIN, not short-eligible, so at the normal delay",
           list(itertools.product(("useStandbyRoute", "cancelStandbySwitch", "restorePriceRoute"), CALLERS)),
           standby_access, verifies=["REQ-MREG-028", "REQ-ACCESS-159", "REQ-ACCESS-155", "REQ-ACCESS-156", "MKT-033"],
           targets=["T-76", "T-54"])

# FV-CTL-146 verifies: REQ-MREG-028, REQ-MREG-027, REQ-CONFIG-027
prove("FV-CTL-146", "activePriceRoutes substitutes the standby into the replaced slot only: the other slot is its recorded route, None gives the recorded pair, and switch, cancel and restore never change the recorded primary, alternate or standby",
      z3.And(z3.Implies(slot2 == NONE_, z3.And(PF2 == Pr2, AF2 == Al2)),
             z3.Implies(slot2 == PRIMARY, z3.And(PF2 == Sb2, AF2 == Al2)),
             z3.Implies(slot2 == ALTERNATE, z3.And(PF2 == Pr2, AF2 == Sb2)),
             z3.Implies(z3.And(fn >= 6, fn <= 8), z3.And(Pr2 == Pr, Al2 == Al, Sb2 == Sb))),
      assumptions=pre, verifies=["REQ-MREG-028", "REQ-MREG-027", "REQ-CONFIG-027"], targets=["T-76"])

# ---------------------------------------------------------------- Lock (T-72)
M = (11, 12, 13, 14)  # AaveAdapter, Collateralization, LPVault, LPVaultSwap
h, h2, caller_l, named, sender = z3.Ints("holder holder_after caller namedCaller msg_sender")
self_ctx = z3.Bool("address_this_is_SELF")  # false when reached through delegatecall
op = z3.Int("lock_op")  # 0 acquire, 1 release, 2 inner call
member = z3.Or([caller_l == k for k in M])
acq_ok = z3.And(self_ctx, member, h == 0)
rel_ok = z3.And(self_ctx, h == caller_l, caller_l != 0)
inner_ok = z3.And(h == named, sender == named, named != 0)
lstep = z3.And(z3.Implies(op == 0, h2 == z3.If(acq_ok, caller_l, h)), z3.Implies(op == 1, h2 == z3.If(rel_ok, 0, h)),
               z3.Implies(op == 2, h2 == h), op >= 0, op <= 2)
linv = lambda x: z3.Or(x == 0, *[x == k for k in M])  # noqa: E731
# FV-CTL-85 verifies: INV-054, REQ-LOCK-019, REQ-LOCK-020, REQ-LOCK-021, REQ-LOCK-022, REQ-ROLE-021
prove("FV-CTL-85", "Only a fixed member acquires a free Lock, only the holder releases it, nothing runs through delegatecall, and an inner call succeeds only while its named caller holds the Lock",
      z3.And(linv(h2), z3.Implies(z3.And(op == 0, h2 != h), z3.And(member, h == 0, self_ctx)),
             z3.Implies(z3.And(op == 1, h2 != h), h == caller_l), z3.Implies(z3.And(op == 2, inner_ok), h == sender)),
      assumptions=[linv(h), lstep],
      verifies=["INV-054", "REQ-LOCK-019", "REQ-LOCK-020", "REQ-LOCK-021", "REQ-LOCK-022", "REQ-ROLE-021"],
      targets=["T-72"])
# FV-CTL-85-W verifies: REQ-LOCK-019
witness("FV-CTL-85-W", "Witness: the Adapter acquires the free Lock",
        z3.And(h == 0, op == 0, caller_l == 11, self_ctx, lstep, h2 == 11), verifies=["REQ-LOCK-019"], targets=["T-72"])

sys.exit(finish())
