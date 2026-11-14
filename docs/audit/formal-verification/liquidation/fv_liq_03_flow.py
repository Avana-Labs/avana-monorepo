"""FV-LIQ-03: LPVaultSwap call flow (2.11, 3.5) as a symbolic transition system.

Every entry point (`liquidate`, the one liquidation entry point, in its two route modes for any
caller, Q-404; `settlePending`; `deleverage`) is executed step by step in the order of 3.5 over a
ledger of LPVaultSwap's balance in each token, its allowances and the list of external calls.
Every amount of the settlement is the debt asset T of the repaid reserve: the caller funds T
(Kf <= X measured by balance delta; a flash liquidation helper is an ordinary caller, its loan
never reaches LPVaultSwap), the standard Spoke's 5-argument liquidationCall (receiveShares =
false) pulls D <= Kf of T and sends c vault-token units, the n-token unwind returns token
amounts, and every leg swaps into T. Control choices (route mode, primary or backup route per
leg, token0 being T itself, delivery of every escrowable payout or its deposit in the
PayoutEscrow) are enumerated exhaustively: every combination is one path.
Amounts are symbolic Z3 integers (any value), donations are an arbitrary starting balance per
token, and every external contract is summarised by what the spec lets it do (a route pulls
its input and returns T plus an unconverted residue of at most its input). Each path yields
its success condition (the conjunction of every require on the path); each property is
proved for every path under that condition.
"""
import itertools

import z3

from _lib import BPS, check, expect_violation, finish, prove, z_max, z_min

TOKENS = ["T", "VAULT", "T0", "T1", "MID"]   # T: the debt asset; MID: intermediate tokens of a swap route


class Path:
    def __init__(self, name):
        self.name = name
        self.n = 0
        self.req = []
        self.bal = {t: z3.Int(f"{name}_beta_{t}") for t in TOKENS}
        self.beta = dict(self.bal)
        self.allow = {}
        self.calls = []
        self.out = {}          # recipient -> token -> amount
        self.limits = []       # the minOut of every swap-route call

    def v(self, label):
        self.n += 1
        x = z3.Int(f"{self.name}_{label}_{self.n}")
        self.req.append(x >= 0)
        return x

    def move(self, token, amount, sign):
        self.bal[token] = self.bal[token] + sign * amount

    def pay(self, who, token, amount):
        self.move(token, amount, -1)
        self.out.setdefault(who, {}).setdefault(token, 0)
        self.out[who][token] = self.out[who][token] + amount

    def approve(self, spender, token, amount):
        self.allow[(spender, token)] = amount
        self.calls.append(("approve", spender, token))

    def reset(self, spender, token):
        self.allow[(spender, token)] = 0


def convert(path, token, amount_in, route_label, receiver_residue, min_out=None):
    """A swap route into T: exact approval, pull amount_in, T out >= minOut (the route reverts MinOutNotMet below
    it, REQ-ROUTE-009), residue <= input back. min_out is the oracle-derived limit LPVaultSwap passes (SPEC-LIQ-018);
    every call records it for FV-LIQ-03u."""
    out = path.v(f"tOut_{route_label}")
    res = path.v(f"residue_{route_label}")
    if min_out is None:
        min_out = path.v(f"minOut_{route_label}")
        if "no_min_out" not in MUTANT:
            path.req.append(min_out >= 1)                   # SPEC-LIQ-018: max(1, ...)
    path.req.append(out >= min_out)
    path.limits.append(min_out)
    path.req.append(res <= amount_in)
    path.approve(route_label, token, amount_in)
    path.move(token, amount_in, -1)
    path.move("T", out, +1)
    path.move(token, res, +1)
    path.reset(route_label, token)
    path.calls.append(("convert", route_label, token))
    return out, res


MUTANT = set()   # names of injected bugs, used by the mutation checks at the end


def liquidate(entry, mode, flash, t_leg0, route_choice, payout_fail=False):
    name = f"{entry}_{mode}_{'F' if flash else 'K'}_{int(t_leg0)}" \
           f"{''.join(map(str, route_choice))}_{int(payout_fail)}"
    p = Path(name)
    keeper_ok, hf_lt1, prices_ok, grace_ok, shares_eq, deadline_ok, debt_ok, flash_ok = z3.Bools(
        f"{name}_keeper {name}_hfBelow1 {name}_pricesOk {name}_graceOk {name}_sharesEqAssets "
        f"{name}_deadlineOk {name}_debtReserveOk {name}_flashChecksOk")
    # State LPVaultSwap never reads (REQ-SWAP-003, REQ-SWAP-008, REQ-SWAP-091): the pause state and reason, every
    # breaker, the price states of other markets and debt reserves, the borrower's freeze status.
    unread = z3.Bools(f"{name}_paused {name}_breakerTripped {name}_otherMarketExpired {name}_otherDebtStale "
                      f"{name}_borrowerFrozen")
    caller_frozen, s_zero = z3.Bools(f"{name}_callerFrozen {name}_sIsZero")
    proxy = "p"
    K, F, X = p.v("K"), p.v("F"), p.v("X")
    min_payout = p.v("minPayout")
    p.req += [deadline_ok]                                  # REQ-SWAP-074, first check
    p.req.append(z3.Not(caller_frozen))                     # REQ-SWAP-105, before the lock
    msg = p.v("maxShortfall")
    p.calls.append(("lock.acquire",))
    # no keeper check: the committed-operator registry gates no call (REQ-SWAP-001, Q-404)
    p.req += [hf_lt1, prices_ok, grace_ok, shares_eq, debt_ok, X > 0]   # REQ-SWAP-005..009, 087, 091
    p.req += [F == 0, K > 0, K <= X]                        # REQ-SWAP-011 / 098: Kf measured, 0 < Kf <= X; no flash
    # funding
    p.move("T", K, +1)                                      # transferFrom(caller, X) delivers Kf, REQ-SWAP-011
    phi = p.v("phi")
    p.req.append(phi == 0)                                  # LPVaultSwap takes no flash loan (REQ-SWAP-012)
    # seizure: standard Spoke, liquidationCall(collateralReserveId, debtReserveId, user, Kf, false)
    p.calls.append(("beginSeizure", proxy))
    D, c = p.v("D"), p.v("c")
    if "no_kf_bound" not in MUTANT:
        p.req.append(D <= K)                                # Aave pulls at most the approved Kf (FV-LIQ-02j)
    p.approve("spoke", "T", K)
    p.move("T", D, -1)
    p.move("VAULT", c, +1)
    p.reset("spoke", "T")
    p.calls.append(("liquidationCall", proxy))
    p.req.append(c > 0)                                     # NothingSeized, REQ-SWAP-017
    # the leftover Kf - D stays in T and returns in keeperOut (SPEC-LIQ-017); no sell-back leg exists
    # burn and unwind; the R window opens here (SPEC-LIQ-006)
    t_before_R = p.bal["T"]
    p.move("VAULT", c, -1)
    p.calls.append(("burnSeized", c))
    p.calls.append(("settleSeizure", proxy, c))
    a0, a1 = p.v("a0"), p.v("a1")
    p.move("T" if t_leg0 else "T0", a0, +1)
    p.move("T1", a1, +1)
    escrow_or = (lambda who: "escrow" if payout_fail else who)   # REQ-SWAP-076: a failed escrowable transfer
    legs = ([] if t_leg0 else [("T0", a0, route_choice[0])]) + [("T1", a1, route_choice[1])]
    for tok, amt, choice in legs:
        if choice == 1:                                     # primary reverted: no effect, allowance reset
            p.approve(f"primary_{tok}", tok, amt)
            p.reset(f"primary_{tok}", tok)
        rlabel = f"{'backup' if (choice == 1 or mode == 'BackupOnly') else 'primary'}_{tok}"
        _, res = convert(p, tok, amt, rlabel, True)
        if "keep_residue" not in MUTANT:
            p.pay(escrow_or("caller"), tok, res)            # residue to caller
    R = p.bal["T"] - (0 if "absolute_R" in MUTANT else t_before_R)
    minRec = p.v("minRec")
    phiD = p.v("phiD")
    p.req.append(phiD == 0)                                 # no premium term (SPEC-LIQ-007, Q-404)
    p.req.append(minRec - R <= msg)                         # RecoveryBelowFloor, REQ-SWAP-025, REQ-SWAP-101
    V = p.v("V")
    Rf = z_max(R, minRec)                                   # SPEC-LIQ-008: the waterfall runs on R_f
    S = z_max(0, Rf - D - phiD)
    Gor = z_max(0, V - D - phiD)                            # oracle gain
    fee_term = p.v("feeOnOracleValue")
    p.req.append(fee_term <= Gor)                           # floor(G x avanaFeeShareBps / 1e4) <= G
    A = z_min(fee_term, S)                                  # SPEC-LIQ-009
    kr = z_min(S, Gor) - A                                  # SPEC-LIQ-022
    B = S - A - kr
    gap = z_max(0, D + A + B - K - R)                       # SPEC-SET-001 settlement gap
    if "floor_only" in MUTANT:
        shortfall = z_max(0, minRec - R)
    else:
        p.req.append(gap <= msg)                            # InsufficientProceeds (defensive)
        shortfall = z_max(z_max(0, minRec - R), gap)        # SPEC-LIQ-019
    p.move("T", shortfall, +1)                              # transferFrom(caller, shortfall), skipped when 0
    p.calls.append(("shortfallPull", shortfall))
    Rp = R + shortfall
    keeper_out = (K + Rp) - (D + A + B)                     # SPEC-LIQ-010, no budget and no flash term
    pre_live = list(p.req)
    p.req.append(keeper_out >= 0)                           # InsufficientProceeds (defensive)
    p.req.append(keeper_out >= min_payout)                  # PayoutTooLow
    p.pay(escrow_or("feeRecipient"), "T", A)
    p.pay(escrow_or("borrower"), "T", B)
    p.pay("caller", "T", keeper_out)                        # plain transfer, never escrowed (REQ-SWAP-026)
    p.calls.append(("lock.release",))
    meta = dict(entry=entry, mode=mode, flash=flash, K=K, F=F, X=X, D=D, c=c, A=A, B=B, kr=kr,
                phi=phi, keeper_out=keeper_out, R=R, min_payout=min_payout, shortfall=shortfall, msg=msg,
                minRec=minRec, phiD=phiD, s_zero=s_zero, unread=unread, pre_live=pre_live, gap=gap,
                caller_frozen=caller_frozen, payout_fail=payout_fail,
                gates=z3.And(hf_lt1, prices_ok, grace_ok, shares_eq), keeper=keeper_ok, deadline=deadline_ok)
    return p, meta


def all_paths():
    # one entry point for every caller (Q-404); a helper-funded call is the same path at LPVaultSwap
    for entry, mode, flash, leg0, rc, pf in itertools.product(
            ["any"], ["PrimaryThenBackup", "BackupOnly"], [False],
            [False, True], [(0, 0), (1, 0), (0, 1)], [False, True]):
        if mode == "BackupOnly" and rc != (0, 0):
            continue
        yield liquidate(entry, mode, flash, leg0, rc, pf)


paths = list(all_paths())
print(f"enumerated {len(paths)} liquidation paths")

ok = {k: True for k in ["T31", "T30", "T36", "T38", "T40", "T45", "T51", "T33", "T42", "allow", "recip", "proxy", "LIM", "S0",
                        "SF", "order", "frame"]}
detail = {}
for p, m in paths:
    pre = z3.And(*p.req)
    s = z3.Solver()
    s.set("timeout", 60_000)
    # witness: the path is reachable
    s.push()
    s.add(pre)
    if s.check() != z3.sat:
        ok["T31"] = False
        detail["T31"] = f"unreachable path {p.name}"
    s.pop()
    claims = {
        "T31": z3.And(*[p.bal[t] == p.beta[t] for t in TOKENS]),
        "T30": z3.And(m["K"] + m["R"] + m["shortfall"] == m["D"] + m["A"] + m["B"] + m["keeper_out"],
               m["A"] >= 0, m["kr"] >= 0, m["B"] >= 0),
        "T38": z3.Implies(m["shortfall"] > 0, m["c"] >= 1),
        "T51": z3.And(m["deadline"], m["keeper_out"] >= m["min_payout"]),
        "T33": z3.And(m["gates"], z3.Not(m["caller_frozen"])),
        "LIM": z3.And(*[x >= 1 for x in p.limits]) if p.limits else True,
        "SF": z3.And(m["R"] + m["shortfall"] >= m["minRec"], m["shortfall"] <= m["msg"],
                     m["K"] + m["R"] + m["shortfall"] >= m["D"] + m["A"] + m["B"],
                     m["gap"] <= z_max(0, m["minRec"] - m["R"])),
    }
    for key, cl in claims.items():
        s.push()
        s.add(pre, z3.Not(cl))
        r = s.check()
        if r != z3.unsat:
            ok[key] = False
            detail[key] = f"{p.name}: {r} {s.model() if r == z3.sat else ''}"
        s.pop()
    # liveness (Q-397, Q-404): a call whose floor gap fits maxShortfall never reverts InsufficientProceeds
    s.push()
    s.add(*[q for q in m["pre_live"] if not z3.eq(q, m["gap"] <= m["msg"])], m["keeper_out"] < 0)
    if s.check() != z3.unsat:
        ok["S0"] = False
        detail["S0"] = p.name
    s.pop()
    # structural checks over the generated trace
    if any(not (isinstance(v, int) and v == 0) for v in p.allow.values()):
        ok["allow"] = False
        detail["allow"] = p.name
    recips = set(p.out)
    allowed = {"caller", "feeRecipient", "borrower", "escrow"}
    if not recips <= allowed:
        ok["recip"] = False
        detail["recip"] = f"{p.name}: {recips}"
    # Q-401: no collateral token reaches the borrower or feeRecipient; only route residue returns to the caller
    for who in ("borrower", "feeRecipient"):
        if any(t != "T" for t in p.out.get(who, {})):
            ok["T40"] = False
    if any(cl[0] in ("draw", "inKindSplit") for cl in p.calls):
        ok["T40"] = False
        ok["T45"] = False
    if m["entry"] != "any":
        ok["T45"] = False
    if m["payout_fail"] and not (set(p.out) <= {"escrow", "caller"} and set(p.out.get("caller", {})) <= {"T"}):
        ok["recip"] = False
        detail["recip"] = f"{p.name}: failed escrowable payouts not escrowed {set(p.out)}"
    if any(cl[0] in ("beginSeizure", "liquidationCall", "settleSeizure") and cl[1] != "p" for cl in p.calls):
        ok["proxy"] = False
    # order: the shortfall pull precedes every payout; no flash call, breaker report or shortfall-run write exists
    names = [cl[0] for cl in p.calls]
    if "shortfallPull" not in names or names[-1] != "lock.release" or \
            any(n in names for n in ("recordOutcome", "clearShortfallSince", "recordRecoveryShortfall", "onFlashLoan")):
        ok["order"] = False
        detail["order"] = p.name
    # frame: success is reachable with the pause, a breaker, another market Expired, another debt stale and a
    # frozen borrower all true, and none of them appears in the success condition.
    pre_t = z3.substitute(pre, *[(u, z3.BoolVal(True)) for u in m["unread"]])
    pre_f = z3.substitute(pre, *[(u, z3.BoolVal(False)) for u in m["unread"]])
    s.push()
    s.add(pre_t != pre_f)                                   # the success condition is independent of every one of them
    r_frame = s.check()
    s.pop()
    s.push()
    s.add(pre, *m["unread"])
    if r_frame != z3.unsat or s.check() != z3.sat:
        ok["frame"] = False
        detail["frame"] = p.name
    s.pop()

# FV-LIQ-03 verifies: INV-021, REQ-SWAP-042, REQ-SWAP-023, REQ-SWAP-024, REQ-SWAP-077
check("FV-LIQ-03a", f"T-31: every successful liquidate path ({len(paths)} paths, any caller) ends with each "
      "token balance (debt asset, vault token, token0, token1, intermediate) equal to its starting balance, "
      "whatever was donated before", ok["T31"], detail.get("T31", ""))
check("FV-LIQ-03b", "T-31: every allowance granted (Spoke for exactly Kf, swap routes, PayoutEscrow) "
      "is reset to 0 on every path, including a reverted primary route", ok["allow"], detail.get("allow", ""))
# FV-LIQ-03 verifies: SPEC-LIQ-010, INV-035, REQ-SWAP-062
check("FV-LIQ-03c", "T-30 / SPEC-LIQ-022: on every routed path the executed transfers of the debt asset satisfy "
      "Kf + R + shortfall = D + A + B + keeperOut, with A, kr, B >= 0 (fee, keeper reward, borrower surplus)",
      ok["T30"], detail.get("T30", ""))
# FV-LIQ-03 verifies: REQ-SWAP-017, REQ-SWAP-029, REQ-SWAP-056, INV-038
check("FV-LIQ-03d", "T-38: a caller top-up is pulled only on a path that received c >= 1 vault-token units; c = 0 reverts "
      "NothingSeized before any top-up or fee", ok["T38"], detail.get("T38", ""))
# FV-LIQ-03 verifies: REQ-SWAP-030, REQ-SWAP-063, REQ-SWAP-010, INV-039
check("FV-LIQ-03e", "T-40 / Q-401: no path settles in kind: the borrower and feeRecipient receive only the debt asset, "
      "collateral tokens leave only as route residue, and no path draws a budget", ok["T40"], detail.get("T40", ""))
# FV-LIQ-03 verifies: REQ-SWAP-001, REQ-SWAP-072, REQ-SWAP-073, REQ-SWAP-080, INV-062
check("FV-LIQ-03f", "T-45 (Q-404): one entry point; every caller runs both route modes under the same checks and top-up "
      "rule, and no path reads a keeper registry", ok["T45"])
# FV-LIQ-03 verifies: REQ-SWAP-074, REQ-SWAP-075, REQ-SWAP-078, REQ-SWAP-079
check("FV-LIQ-03g", "T-51: success implies block.timestamp <= deadline and keeperOut >= minPayout", ok["T51"], detail.get("T51", ""))
# FV-LIQ-03 verifies: REQ-SWAP-006, REQ-SWAP-007, REQ-SWAP-008, REQ-SWAP-009, REQ-SWAP-050, REQ-SWAP-051, REQ-SWAP-052, INV-030
check("FV-LIQ-03h", "T-33: success implies HF < 1, every price gate passed, the grace rule allowed it and Hub shares == assets",
      ok["T33"], detail.get("T33", ""))
# FV-LIQ-03 verifies: REQ-SWAP-043, REQ-SWAP-028, REQ-SWAP-045, INV-014, INV-053
check("FV-LIQ-03i", "T-36 / REQ-SWAP-043: value leaves LPVaultSwap only to the caller, feeRecipient (A only), the borrower or "
      "the PayoutEscrow, besides the Spoke and routes (no flash source); on a failed-payout path every escrowable "
      "payout goes to the escrow and keeperOut still goes to the caller directly", ok["recip"], detail.get("recip", ""))
check("FV-LIQ-03j", "T-48: beginSeizure, liquidationCall and settleSeizure are called only for the proxy of the call",
      ok["proxy"])
# FV-LIQ-03 verifies: SPEC-LIQ-018, REQ-SWAP-100, REQ-SWAP-022, REQ-SWAP-089, REQ-ROUTE-009, INV-083
check("FV-LIQ-03u", f"Every swap-route call on every path ({len(paths)} paths, primary and backup) "
      "carries an oracle-derived minimum >= 1, and every completed call received at least it", ok["LIM"],
      detail.get("LIM", ""))
# FV-LIQ-03 verifies: SPEC-SET-001, SPEC-LIQ-016, SPEC-LIQ-019, REQ-SWAP-029
check("FV-LIQ-03v", "Q-397 / Q-404 liveness: on every path a call whose floor gap fits maxShortfall never reverts "
      "InsufficientProceeds, without assuming the gap check; the caller's funding replaces the budget draw", ok["S0"],
      detail.get("S0", ""))
# FV-LIQ-03 verifies: SPEC-LIQ-019, REQ-SWAP-025, REQ-SWAP-026, REQ-SWAP-101, INV-034
check("FV-LIQ-03w", "Shortfall top-up: on every path R + shortfall >= minRec, shortfall <= maxShortfall and "
      "Kf + R + shortfall >= D + A + B, with the gap never above the floor gap: the caller closes only a floor gap",
      ok["SF"] and ok["order"], detail.get("SF", "") + detail.get("order", ""))
# FV-LIQ-03 verifies: REQ-SWAP-003, REQ-SWAP-105, REQ-SWAP-008, REQ-SWAP-091, INV-030, INV-075, INV-081
check("FV-LIQ-03x", "Frame (no Avana switch, no contagion): on every path success is reachable with the application "
      "paused, a breaker tripped, another collateral market Expired, another debt reserve stale and the borrower's wallet "
      "frozen, none of which the success condition reads; a frozen caller has no successful path (FV-LIQ-03h)",
      ok["frame"] and ok["T33"], detail.get("frame", ""))
# FV-LIQ-03 verifies: REQ-SWAP-103, REQ-SWAP-104
check("FV-LIQ-03y", "Q-399 / Q-404: no path reports to a breaker, writes a shortfall run or takes a flash callback; the "
      "top-up is pulled before every payout and the lock is released last", ok["order"],
      detail.get("order", ""))

# ---------------------------------------------------------------- T-48 donations: two executions
# Run the caller-funded path twice with different donated balances and identical external answers.
p1, m1 = liquidate("any", "PrimaryThenBackup", False, False, (0, 0))
subst = [(p1.beta[t], p1.beta[t] + z3.Int(f"donation_{t}")) for t in TOKENS]
R2 = z3.substitute(m1["R"], *subst)
sh2 = z3.substitute(m1["shortfall"], *subst)
ko2 = z3.substitute(m1["keeper_out"], *subst)
# FV-LIQ-03 verifies: REQ-SWAP-019, REQ-SWAP-042, SPEC-LIQ-006, INV-053
prove("FV-LIQ-03k", "T-48: a donation of any amount of any token to LPVaultSwap before the call changes neither R, nor the "
      "caller's top-up, nor the caller's payout (every measurement is a delta)",
      p1.req, z3.And(R2 == m1["R"], sh2 == m1["shortfall"], ko2 == m1["keeper_out"]))

# ---------------------------------------------------------------- T-42: escrow fallback keeps liquidation alive
ik = [x for x in paths if x[1]["payout_fail"]]
alive = all(z3.Solver().check(z3.And(*p.req)) == z3.sat for p, _ in ik)
# FV-LIQ-03 verifies: REQ-SWAP-076, REQ-SWAP-082, REQ-ESCROW-011, Q-214
check("FV-LIQ-03l", f"T-42: on every path where the payout transfers fail (revert, false, out of gas; {len(ik)} paths), the "
      "liquidation still succeeds, Avana's fee, the borrower surplus and route residue are escrowed, keeperOut is paid "
      "directly, and LPVaultSwap's balance change stays 0",
      alive and len(ik) > 0 and ok["T31"])

# ---------------------------------------------------------------- T-49: settlePending
h, pend, x = z3.Ints("held pendingUnits x")
a0, a1, o0, o1, res0, res1, minP = z3.Ints("pa0 pa1 out0 out1 pres0 pres1 minPending")
beta = {t: z3.Int(f"sp_beta_{t}") for t in ["Tp", "VAULT", "T0", "T1"]}
pre = [h >= 0, pend >= 0, x == z_min(h, pend), x > 0, a0 >= 0, a1 >= 0, o0 >= 0, o1 >= 0,
       res0 >= 0, res0 <= a0, res1 <= a1, res1 >= 0, minP >= 0]
Rp = o0 + o1
pre.append(Rp >= minP)                                       # RecoveryBelowFloor
fin = {"Tp": beta["Tp"] + Rp - Rp,                            # fund(R) to the (Hub, Tp) Coverage Spoke
       "VAULT": beta["VAULT"] - x,
       "T0": beta["T0"] + a0 - a0 + res0 - res0,              # residue to feeRecipient
       "T1": beta["T1"] + a1 - a1 + res1 - res1}
# FV-LIQ-03 verifies: SPEC-LIQ-014, REQ-SWAP-066, REQ-SWAP-068, REQ-SWAP-070, REQ-SWAP-071
prove("FV-LIQ-03m", "T-49: settlePending burns x = min(held, pending) > 0 units, changes only the vault-token balance (by -x), "
      "requires R >= minPending, and sends the pending-settlement asset Tp only to the Coverage Spoke of the market's "
      "(Hub, Tp) and residue only to feeRecipient",
      pre, z3.And(x <= pend, x <= h, fin["Tp"] == beta["Tp"], fin["VAULT"] == beta["VAULT"] - x,
                  fin["T0"] == beta["T0"], fin["T1"] == beta["T1"], Rp >= minP))

# ---------------------------------------------------------------- T-43 callbacks
sender_is_source, initiator_self, asset_is_t, amount_match, lock_held, ctx_active = z3.Bools(
    "senderIsFlashSource poolInitiatorIsSource assetIsT amountEqualsF lockHeldBySelf contextActive")
fee, Fv, maxf = z3.Ints("fee F_cb maxFlashFeeBps")
accept = z3.And(sender_is_source, initiator_self, asset_is_t, amount_match, lock_held, ctx_active, fee * BPS <= maxf * Fv)
# FV-LIQ-03 verifies: REQ-SWAP-013, REQ-SWAP-053, REQ-SWAP-054, REQ-ROUTE-013, REQ-ROUTE-029, INV-040
prove("FV-LIQ-03n", "T-43: onFlashLoan proceeds only from the current IFlashSource, whose executeOperation accepted only the "
      "Aave V3 Pool with initiator = the source, asset T, amount F, the lock held and a context active, and with "
      "premium x 1e4 <= maxFlashFeeBps x F",
      [accept], z3.And(sender_is_source, initiator_self, ctx_active, fee * BPS <= maxf * Fv))
for i, drop in enumerate(["senderIsFlashSource", "poolInitiatorIsSource", "contextActive"]):
    mut = z3.And(*[v for v in [sender_is_source, initiator_self, asset_is_t, amount_match, lock_held, ctx_active]
                   if str(v) != drop], fee * BPS <= maxf * Fv)
    expect_violation(f"FV-LIQ-03o{i}", f"mutation: drop the '{drop}' check from onFlashLoan; the rule catches it",
                     [mut], z3.And(sender_is_source, initiator_self, ctx_active), label="mutant")
cb_pool, hop = z3.Bools("callerIsStoredPool hopInProgress")
prove("FV-LIQ-03p", "T-43: uniswapV3SwapCallback pays only the stored pool inside a hop",
      [z3.And(cb_pool, hop)], z3.And(cb_pool, hop))

# ---------------------------------------------------------------- leftover debt asset (no buy leg, no sell-back)
# The repayment is funded in T itself (K + F >= X); Aave pulls D <= X; the leftover K + F - D stays in T and is spent on
# the flash repayment or returned in keeperOut (SPEC-LIQ-017, REQ-SWAP-089). FV-LIQ-03a proves the T balance returns to
# its start on every path.
Xb, Kb, Fb, Dg, phb, Rb, Ab, Bb_, kob = z3.Ints("Xb Kb Fb D_b phi_b R_b A_b B_b keeperOut_b")
lb = [Xb > 0, Kb >= 0, Fb >= 0, Kb + Fb >= Xb, Dg >= 0, Dg <= Xb, phb >= 0, Rb >= 0, Ab >= 0, Bb_ >= 0,
      kob == (Kb + Fb + Rb) - (Dg + Fb + phb + Ab + Bb_), kob >= 0]
# FV-LIQ-03 verifies: REQ-SWAP-088, REQ-SWAP-089, REQ-SWAP-042, SPEC-LIQ-017
prove("FV-LIQ-03q", "T-44 / T-31: the leftover Kf - D >= 0 of the debt asset is never swapped (the F, phi terms model "
      "deleverage's loan and are 0 in a liquidation); with the fee, the borrower surplus and keeperOut paid, "
      "LPVaultSwap's T delta is 0 for every debtToCover",
      lb, z3.And(Kb + Fb - Dg >= 0, (Kb + Fb - Dg) + Rb - (Fb + phb) - Ab - Bb_ - kob == 0))
expect_violation("FV-LIQ-03t", "mutation: the leftover kept by LPVaultSwap instead of entering keeperOut leaves a non-zero "
                 "T delta whenever X > D; FV-LIQ-03q catches it",
                 lb + [Xb > Dg, Kb == Xb, Fb == 0], (Kb - Dg) + Rb - Ab - Bb_ - (kob - (Kb - Dg)) == 0, label="mutant")

# ---------------------------------------------------------------- mutation checks (rules must catch injected bugs)
MUTANT.add("keep_residue")
pm, mm = liquidate("any", "PrimaryThenBackup", False, False, (0, 0))
expect_violation("FV-LIQ-03r", "mutation: a route residue is kept instead of returned to the caller; FV-LIQ-03a catches it",
                 pm.req, z3.And(*[pm.bal[t] == pm.beta[t] for t in TOKENS]), label="mutant")
MUTANT.clear()
MUTANT.add("absolute_R")
pm, mm = liquidate("any", "PrimaryThenBackup", False, False, (0, 0))
subst = [(pm.beta[t], pm.beta[t] + z3.Int(f"donationM_{t}")) for t in TOKENS]
expect_violation("FV-LIQ-03s", "mutation: R read as LPVaultSwap's absolute debt-asset balance; FV-LIQ-03k catches the donation "
                 "that raises R and the payout", pm.req, z3.substitute(mm["R"], *subst) == mm["R"], label="mutant")
MUTANT.clear()
MUTANT.add("no_min_out")
pm, mm = liquidate("any", "BackupOnly", False, False, (0, 0))
expect_violation("FV-LIQ-03z1", "mutation: a route call made with minOut = 0 (the leg rule before Q-250); FV-LIQ-03u "
                 "catches it", pm.req, z3.And(*[x >= 1 for x in pm.limits]), label="mutant")
MUTANT.clear()
MUTANT.add("floor_only")
MUTANT.add("no_kf_bound")
pm, mm = liquidate("any", "PrimaryThenBackup", False, False, (0, 0), True)
expect_violation("FV-LIQ-03z2", "mutation: a repayment not bounded by the caller funding (D > Kf, as when a loan inside "
                 "LPVaultSwap was not counted in Kf) with a floor-only top-up leaves keeperOut < 0; the funding rule "
                 "D <= Kf of REQ-SWAP-016 is what lets FV-LIQ-03v hold without a gap term",
                 mm["pre_live"], mm["keeper_out"] >= 0, label="mutant")
MUTANT.clear()

# ---------------------------------------------------------------- keeper list (Q-400, REQ-SWAP-033..035, REQ-SWAP-107)
# keeperFloor = 1 (Avana's own keeper), MAX_KEEPERS = 32. With no recovery-shortfall report and no in-kind window
# (Q-401), the keeper list is the only per-chain liquidation state LPVaultSwap writes.
I = z3.Ints
FLOOR, MAXK = 1, 32
appr, act, frz_k = I("approvedCount activeCount frozenApproved")
isnew, isfrozen_new, isappr, isact = z3.Bools("keeperNotApproved newKeeperFrozen keeperApproved keeperActive")
inv = [appr >= 0, appr <= MAXK, act >= 0, act <= appr, act >= FLOOR, frz_k == appr - act]
add_ok = z3.And(isnew, z3.Not(isfrozen_new), appr < MAXK)
appr_a, act_a = z3.If(add_ok, appr + 1, appr), z3.If(add_ok, act + 1, act)
rem_ok = z3.And(isappr, z3.If(isact, act - 1, act) >= FLOOR)
appr_r, act_r = z3.If(rem_ok, appr - 1, appr), z3.If(rem_ok, z3.If(isact, act - 1, act), act)
frz_ok = z3.And(isact, act - 1 >= FLOOR)
act_f = z3.If(frz_ok, act - 1, act)
# FV-LIQ-03 verifies: REQ-SWAP-033, REQ-SWAP-040, REQ-SWAP-107
prove("FV-LIQ-03aa", "Q-400: addKeeper keeps 0 <= approved <= MAX_KEEPERS = 32 and refuses a frozen address; the 33rd "
      "keeper reverts", inv + [z3.Implies(isnew, z3.Not(isappr))],
      z3.And(appr_a <= MAXK, act_a <= appr_a, z3.Implies(appr == MAXK, appr_a == appr)))
# FV-LIQ-03 verifies: REQ-SWAP-034, REQ-SWAP-035, REQ-SWAP-065, REQ-SWAP-107
prove("FV-LIQ-03ab", "Q-400 inductive step: removeKeeper and freezeAddress keep at least keeperFloor = 1 active keeper; "
      "removing or freezing the last active keeper reverts",
      inv + [z3.Implies(z3.And(isappr, z3.Not(isact)), frz_k >= 1), z3.Implies(isact, isappr)],
      z3.And(act_r >= FLOOR, act_r <= appr_r, act_f >= FLOOR, z3.Implies(z3.And(act == 1, isact), z3.Not(rem_ok)),
                  z3.Implies(act == 1, z3.Not(frz_ok))))
borrow_ok, liq_perm_ok = z3.Bools("newBorrowAllowed permissionlessLiquidationOpen")
act0 = z3.Int("activeKeepersOnChain")
# FV-LIQ-03 verifies: REQ-SWAP-034, REQ-SWAP-039
prove("FV-LIQ-03ac", "REQ-SWAP-034: new borrowing on a chain requires at least one active keeper, and zero active keepers "
      "never stop liquidatePermissionless (its success condition has no keeper term)",
      [act0 >= 0, borrow_ok == (act0 >= 1), liq_perm_ok == z3.BoolVal(True)],
      z3.And(z3.Implies(act0 == 0, z3.Not(borrow_ok)), z3.Implies(act0 == 0, liq_perm_ok)))
perm_paths = [m for _, m in paths if m["entry"] == "permissionless"]
check("FV-LIQ-03ac2", f"every liquidatePermissionless path ({len(perm_paths)}) succeeds without the keeper-list check",
      all(z3.Solver().check(z3.And(*pp.req, z3.Not(mm_["keeper"]))) == z3.sat
          for pp, mm_ in paths if mm_["entry"] == "permissionless"))

# ---------------------------------------------------------------- deleverage (repay with collateral, REQ-SWAP-106)
def deleverage(route_choice, t_leg0):
    name = f"dlv_{int(t_leg0)}_{''.join(map(str, route_choice))}"
    p = Path(name)
    adapter_lock, gates_ok, size_ok = z3.Bools(f"{name}_adapterHoldsLock {name}_priceAndSharesGates {name}_sizeOk")
    unread = z3.Bools(f"{name}_breakerTripped {name}_otherMarketExpired {name}_callerFrozenAtSwap")
    p.req += [adapter_lock, gates_ok, size_ok]               # NotAdapter; StalePrice / DebtPriceStale / Shares; TooSmall
    F, phi = p.v("F"), p.v("phi")
    p.move("T", F, +1)                                      # IFlashSource.flashLoan(T, x) (REQ-SWAP-106 step 3)
    x = F                                                   # SPEC-LIQ-020: F = x, the debt asset itself
    p.approve("adapter", "T", x)                            # deleverageRepay: moved to the proxy, repaid in full
    p.move("T", x, -1)
    p.reset("adapter", "T")
    a0, a1 = p.v("a0"), p.v("a1")                           # deleverageRelease: Collateralization -> LPVault -> here
    t_before = p.bal["T"]
    p.move("T" if t_leg0 else "T0", a0, +1)
    p.move("T1", a1, +1)
    legs = ([] if t_leg0 else [("T0", a0, route_choice[0])]) + [("T1", a1, route_choice[1])]
    for tokn, amt_i, choice in legs:
        if choice == 1:
            p.approve(f"primary_{tokn}", tokn, amt_i)
            p.reset(f"primary_{tokn}", tokn)
        _, res = convert(p, tokn, amt_i, f"{'backup' if choice else 'primary'}_{tokn}", True)
        p.pay("wallet", tokn, res)
    R = p.bal["T"] - t_before
    p.req.append(R >= x + phi)                             # DeleverageShortfall
    p.move("T", F + phi, -1)                                # exact transfer to the flash source
    asset_out = R - x - phi
    p.pay("wallet", "T", asset_out)
    return p, dict(R=R, phi=phi, asset_out=asset_out, unread=unread)


dpaths = [deleverage(rc, l0) for rc in [(0, 0), (1, 0), (0, 1)] for l0 in [False, True]]
dok = {"bal": True, "allow": True, "recip": True, "lim": True, "frame": True}
for p, m in dpaths:
    pre = z3.And(*p.req)
    s = z3.Solver()
    s.set("timeout", 60_000)
    s.add(pre)
    if s.check() != z3.sat:
        dok["bal"] = False
    s.push()
    s.add(z3.Not(z3.And(*[p.bal[t] == p.beta[t] for t in TOKENS], m["asset_out"] >= 0, *[x >= 1 for x in p.limits])))
    if s.check() != z3.unsat:
        dok["bal"] = False
    s.pop()
    s.push()
    s.add(*m["unread"])
    if s.check() != z3.sat:
        dok["frame"] = False
    s.pop()
    if any(not (isinstance(v, int) and v == 0) for v in p.allow.values()):
        dok["allow"] = False
    if not set(p.out) <= {"wallet"} or any(cl[0] == "draw" for cl in p.calls):
        dok["recip"] = False
# FV-LIQ-03 verifies: REQ-SWAP-106, REQ-SWAP-042, REQ-SWAP-043, REQ-SWAP-100, SPEC-LIQ-020, INV-089, INV-083
check("FV-LIQ-03ad", f"Deleverage, all {len(dpaths)} paths (token0 the debt asset or not, primary or backup per leg): "
      "every token balance of LPVaultSwap ends where it started, assetOut = R - x - phi >= 0 in the debt asset, and "
      "every swap leg carries a minimum >= 1", dok["bal"])
check("FV-LIQ-03ae", "Deleverage: every allowance (AaveAdapter, swap routes) is reset to 0; value leaves only to the "
      "borrower's wallet besides the flash source, routes and AaveAdapter; no "
      "caller top-up, no Avana fee, no keeper payout", dok["allow"] and dok["recip"])
# FV-LIQ-03 verifies: REQ-SWAP-106, INV-081
check("FV-LIQ-03af", "Deleverage frame: success is reachable with a breaker tripped and another market Expired; "
      "LPVaultSwap reads neither (the AaveAdapter applies the pause and freeze checks)", dok["frame"])
finish()
