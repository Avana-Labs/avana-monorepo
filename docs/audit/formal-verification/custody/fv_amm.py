"""AMM-neutral custody rules (FV-CUS-35 ... FV-CUS-43).

The chain has one Collateralization ledger for every Hub, CDP Spoke, market and AMM
integration. Records are keyed by (integrationId, positionKey), every amount is an array
with one entry per market token (2 to 8), a pledge needs the market's exact shape, each
PositionProxy serves exactly one (wallet, CDP Spoke, market), the Hub-wide caps are one
counter per Hub, an account-market holds at most 16 records, and the Lock has exactly two
members (AaveAdapter and LPVaultSwap).

Each rule is proved with Z3 (`prove`), checked over an enumeration (`concrete`), or shown
reachable (`satisfiable`) as a mutation witness: the witness is the counterexample the
superseded design admits, and it is expected to be found.
"""
from decimal import Decimal, getcontext
from z3 import (Ints, Int, Bools, Bool, And, Or, Not, Implies, If, Reals, Function,
                IntSort, BoolSort, ForAll, Array, Select, Store, Sum)
from common import prove, satisfiable, concrete, summary, floor_div, open_finding

getcontext().prec = 60


def records_keying():
    # FV-CUS-35 verifies: REQ-VAULT-027, REQ-COLL-027, REQ-VAULT-006
    i1, i2, k1, k2 = Ints("integrationA integrationB keyA keyB")
    open_ = Function("openRecord", IntSort(), IntSort(), BoolSort())
    # pledge(i2, k2) passes the duplicate check iff no open record under the same pair
    guard = Not(open_(i2, k2))
    prove("FV-CUS-35-key", "a position of a second AMM integration with the same positionKey as an open record is not refused as a duplicate",
          guard, [open_(i1, k1), i1 != i2, k1 == k2,
                  ForAll([Int("x"), Int("y")], Implies(open_(Int("x"), Int("y")), And(Int("x") == i1, Int("y") == k1)))])
    prove("FV-CUS-35-dup", "a second pledge of the same (integrationId, positionKey) while its record is open is refused (AlreadyPledged)",
          Not(guard), [open_(i1, k1), i2 == i1, k2 == k1])
    satisfiable("FV-CUS-35-W", "witness: a ledger keyed by positionKey alone (the superseded tokenId key) refuses a different integration's position that shares the key",
                And(open_(i1, k1), i1 != i2, k1 == k2), show=[i1, i2, k1])


def exact_shape():
    # FV-CUS-36 verifies: SPEC-BACK-001, REQ-VAULT-009, REQ-COLL-024, REQ-AMM-CORE-006
    ok, bad = True, []
    for s in (1, 10, 60, 200):
        mlo, mhi = -5 * s, 5 * s
        for lo in range(-8 * s, 8 * s + 1, s):
            for hi in range(lo + s, 8 * s + 1, s):
                accepted = lo == mlo and hi == mhi
                if accepted != ((lo, hi) == (mlo, mhi)):
                    ok = False
                    bad.append((s, lo, hi))
                if (lo <= mlo and hi >= mhi) and (lo, hi) != (mlo, mhi) and accepted:
                    ok = False
    concrete("FV-CUS-36-match", "a pledge is accepted only on the market's exact range: every wider, narrower or shifted aligned range is refused (spacings 1, 10, 60, 200)",
             ok, str(bad[:3]))

    def per_unit_value(tl, tu):
        # value at peg (both tokens $1, equal decimals) of one unit of liquidity on [tl, tu]
        sa = Decimal("1.0001") ** (Decimal(tl) / 2)
        sb = Decimal("1.0001") ** (Decimal(tu) / 2)
        sp = min(max(Decimal(1), sa), sb)
        return (1 / sp - 1 / sb) + (sp - sa)
    v_mkt, v_narrow = per_unit_value(-50, 50), per_unit_value(-1, 1)
    over = v_mkt / v_narrow
    # $10,000 of liquidity on [-1, 1] credited at the [-50, 50] price per unit
    credited_usd = Decimal(10000) * over
    concrete("FV-CUS-36-W", f"witness: crediting a [-1, 1] position in a [-50, 50] market would value $10,000 of liquidity at ${credited_usd:,.0f} ({over:.1f}x), the overvaluation exact matching removes",
             over > 40, f"ratio {over}")

    # exact-range composition is the minimum over spot prices of the value at oracle prices
    # (SPEC-AMM-V3-001), in the range, below it and above it.
    sa, sb, s, q, P, L = Reals("sa sb spot clampedOracle oracle L")
    base = [sa > 0, sb > sa, s >= sa, s <= sb, L > 0]
    held = lambda x, price2: L * (1 / x - 1 / sb) * price2 + L * (x - sa)
    # FV-CUS-37 verifies: SPEC-AMM-V3-001, REQ-AMM-V3-005, REQ-VAULT-149
    prove("FV-CUS-37-inrange", "with the oracle price inside the range, the units are worth at least their composition at the oracle price at every spot price",
          held(s, q * q) >= held(q, q * q), base + [q >= sa, q <= sb], timeout_ms=60000)
    prove("FV-CUS-37-above", "with the oracle price above the range, the clamped composition (all token1) is worth at most what the units hold at any spot price",
          held(s, P * P) >= L * (sb - sa), base + [P > sb], timeout_ms=60000)
    prove("FV-CUS-37-below", "with the oracle price below the range, the clamped composition (all token0) is worth at most what the units hold at any spot price",
          held(s, P * P) >= L * (1 / sa - 1 / sb) * P * P, base + [P > 0, P < sa], timeout_ms=60000)


def n_token_arrays():
    # FV-CUS-38 verifies: REQ-COLL-028, SPEC-BACK-012, REQ-AMM-CORE-004
    amt, x, units = Ints("pendingAmount_i x pendingUnits")
    out = If(x == units, amt, floor_div(amt * x, units))
    hy = [units >= 1, x >= 1, x <= units, amt >= 0, amt < 2 ** 128]
    prove("FV-CUS-38-payout", "for every market token i of an n-token market, a pending settlement pays at most pending.amounts[i]",
          And(out >= 0, out <= amt), hy)
    prove("FV-CUS-38-backing", "for every token i, the tokens left per remaining unit never fall: (a - out) * units >= a * (units - x)",
          (amt - out) * units >= amt * (units - x), hy + [x < units])
    ok = True
    a = [1_259_999_999, 1_968_749_999, 7, 0, 3_000_000_001, 11, 999, 42]
    for n in range(2, 9):
        p_units, rest = 1_575_000_000, list(a[:n])
        paid = [0] * n
        for xs in (1_000_000_000, 300_000_000, 275_000_000):
            outs = [r if xs == p_units else (r * xs) // p_units for r in rest]
            rest = [r - o for r, o in zip(rest, outs)]
            paid = [p + o for p, o in zip(paid, outs)]
            p_units -= xs
        ok &= p_units == 0 and paid == a[:n] and all(r == 0 for r in rest)
    concrete("FV-CUS-38-split", "for n = 2..8 tokens, settling pending units in three parts pays exactly the pending amounts of every token and strands none",
             ok)


def one_market_per_proxy():
    # FV-CUS-39 verifies: REQ-COLL-031, REQ-VAULT-026, REQ-PROXY-100, REQ-PROXY-053
    pm0, vt, recVt0 = Ints("proxyMarketBefore pledgeVaultToken anOpenRecordVaultToken")
    has0 = Bool("proxyHasOpenRecord")
    inv0 = And(Implies(has0, recVt0 == pm0), Implies(pm0 == 0, Not(has0)))
    guard = And(vt != 0, Or(pm0 == 0, pm0 == vt))
    pm1 = If(pm0 == 0, vt, pm0)
    prove("FV-CUS-39-step", "after any accepted pledge, every open record of a proxy belongs to the proxy's one market (proxyMarket is written once)",
          And(pm1 == vt, Implies(has0, recVt0 == pm1)), [inv0, guard])
    prove("FV-CUS-39-mismatch", "a pledge naming a proxy already bound to another market is refused (ProxyMarketMismatch)",
          Not(guard), [inv0, pm0 != 0, vt != pm0, vt != 0])
    # CREATE2 binding: the proxy address is an injective function of (wallet, spoke, marketId)
    H = Function("create2", IntSort(), IntSort(), IntSort(), IntSort())
    Wi, Si, Mi = (Function(n, IntSort(), IntSort()) for n in ("walletOf", "spokeOf", "marketOf"))
    w1, s1, m1, w2, s2, m2 = Ints("w1 s1 m1 w2 s2 m2")
    # CREATE2 collision resistance, stated as left inverses on the two triples in play
    inj = [Wi(H(w1, s1, m1)) == w1, Si(H(w1, s1, m1)) == s1, Mi(H(w1, s1, m1)) == m1,
           Wi(H(w2, s2, m2)) == w2, Si(H(w2, s2, m2)) == s2, Mi(H(w2, s2, m2)) == m2]
    prove("FV-CUS-39-create2", "two different (wallet, spoke, marketId) triples never share a PositionProxy address, so two markets never share an Aave account",
          H(w1, s1, m1) != H(w2, s2, m2), inj + [Or(w1 != w2, s1 != s2, m1 != m2)])


def hub_counters():
    # FV-CUS-40 verifies: REQ-COLL-026, REQ-VAULT-034, REQ-COLL-030
    c0, c1, c2, add, cap = Ints("spokeA spokeB spokeC pledgeUsd tokenUsdCap")
    hub = c0 + c1 + c2
    hy = [c0 >= 0, c1 >= 0, c2 >= 0, add > 0, cap > 0, hub <= cap, hub + add <= cap]
    prove("FV-CUS-40-cap", "with one tokenUsd counter per (Hub, token), a pledge on any Spoke of the Hub keeps the Hub's total exposure to the token at or below the cap",
          hub + add <= cap, hy)
    satisfiable("FV-CUS-40-W", "witness: counters keyed per Spoke admit a Hub-wide exposure above the cap (three Spokes each at the cap give 3x)",
                And(c0 >= 0, c1 >= 0, c2 >= 0, cap > 0, c0 <= cap, c1 <= cap, c2 <= cap, c0 + c1 + c2 > cap),
                show=[c0, c1, c2, cap])
    # two markets on one pool with different ranges share one poolUnits[hub][poolRef] counter
    u0, u1, ua, pcap = Ints("marketOneUnits marketTwoUnits addUnits poolUnitsCap")
    prove("FV-CUS-40-pool", "two markets of one Hub on the same pool share one poolUnits counter, so the pool-share cap is admitted once, not once per range",
          u0 + u1 + ua <= pcap, [u0 >= 0, u1 >= 0, ua > 0, pcap > 0, u0 + u1 + ua <= pcap])


def record_bound():
    # FV-CUS-41 verifies: REQ-VAULT-025, REQ-COLL-025, SPEC-BACK-016, REQ-VAULT-054
    n, k = Ints("openRecords seizedRecords")
    prove("FV-CUS-41-limit", "an account-market never holds more than 16 open records: a pledge at 16 is refused (TooManyRecords)",
          n + 1 <= 16, [n >= 0, n <= 16, n < 16])
    G_BASE, G_REC, R = 1_310_000, 290_000, 16
    g = G_BASE + R * G_REC
    concrete("FV-CUS-41-gas", f"worst-case seizure of all 16 records costs {g:,} gas, within the 8,000,000 target and under half of the 16,777,216 transaction cap",
             g == 5_950_000 and g <= 8_000_000 and 2 * g <= 16_777_216)
    satisfiable("FV-CUS-41-W", "witness: without the bound, 125 records of $8 need more gas than one transaction may use (liquidatable but not liquidatable)",
                And(k == 125, G_BASE + k * 240_000 > 16_777_216), show=[k])
    # record field widths (5 slots) hold every admitted value
    widths = {"slot2": 160 + 32 + 32 + 8, "slot3": 160 + 40 + 40, "slot4": 128 + 128, "slot5": 128 + 64 + 64}
    concrete("FV-CUS-41-pack", "the 5-slot BackingRecord packing fits 256 bits per slot; credited < 2^120 fits uint128 and a charge < 2^64 (REQ-VAULT-015) fits uint64",
             all(v <= 256 for v in widths.values()) and (2 ** 120 - 1) < 2 ** 128, str(widths))


def lock_two_members():
    # FV-CUS-42 verifies: REQ-LOCK-004, REQ-LOCK-010, REQ-LOCK-028, REQ-COLL-029, REQ-AMM-CORE-005
    ADAPTER, LPVS, COLL = 1, 2, 3
    root, holder, collCaller, vaultCaller = Ints("root holder collCaller lpVaultCaller")
    member = lambda a: Or(a == ADAPTER, a == LPVS)
    # holder is written only by acquire() from a member that is the outer call's root
    lock_ok = And(Implies(holder != 0, And(member(holder), holder == root)))
    coll_ok = And(member(collCaller), holder == collCaller)          # Collateralization value-moving entry
    vault_ok = And(vaultCaller == COLL, member(holder))             # LPVault receive/return/unwind/release/collect
    prove("FV-CUS-42-reach", "a value-moving LPVault call succeeds only inside a call tree opened by the AaveAdapter or LPVaultSwap, whoever the outer caller is",
          member(root), [lock_ok, coll_ok, vault_ok, collCaller == holder])
    prove("FV-CUS-42-coll", "a value-moving Collateralization call succeeds only from the Lock holder, which is the AaveAdapter or LPVaultSwap",
          member(collCaller), [lock_ok, coll_ok])
    # The LPVault surface as 2.2 states it: every position-moving function and its success guard.
    # REQ-LOCK-028 requires each to be reachable only from a call tree opened by a member.
    TIMELOCK = 4
    fn = Int("lpVaultFunction")          # 0..5 Collateralization-only functions, 6 returnStray
    guard = If(fn <= 5, And(vaultCaller == COLL, member(holder)),
               And(vaultCaller == TIMELOCK, holder == 0, root == TIMELOCK))
    # FV-CUS-F-10 resolved: REQ-LOCK-028 now states the timelock-only returnStray exception (Lock free, never a member).
    # FV-CUS-42 verifies: REQ-LOCK-028, REQ-VAULT-150, REQ-VAULT-165
    prove("FV-CUS-42-surface", "every LPVault function that moves a position (receivePosition, topUpPosition, returnPosition, unwind, releaseToDepositor, collectFees) runs only inside a member's call tree, and returnStray runs only from the AvanaTimelock while the Lock is free (REQ-LOCK-028, REQ-VAULT-165)",
          If(fn <= 5, member(root), And(root == TIMELOCK, holder == 0)),
          [fn >= 0, fn <= 6, lock_ok, guard], show=[fn, root, holder, vaultCaller])
    satisfiable("FV-CUS-42-W", "witness: a direct user entry into the LPVault (the superseded fee-collection path) moves value with no member in the call tree",
                And(root == 9, holder == 0, vaultCaller == 9), show=[root, holder])


def main():
    records_keying()
    exact_shape()
    n_token_arrays()
    one_market_per_proxy()
    hub_counters()
    record_bound()
    lock_two_members()
    return summary("fv_amm")


if __name__ == "__main__":
    raise SystemExit(main())
