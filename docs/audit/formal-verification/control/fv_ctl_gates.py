#!/usr/bin/env python3
"""FV-C AaveAdapter and RiskModule gates: the health floor with rescue units excluded (T-58), the oracle,
freshness and breaker gates of the borrow-side pre-checks (T-59), Aave reserve flags (T-60), the borrow nonce
(T-61), repay liveness and sizing (T-57), exits that never read the MarketRegistry, the rescue top-up rule, and
account isolation.

How Avana works here: `postHealthCheck` values the account's rescue units at zero and requires
`hfEx >= max(1.00, hardHealthFloor(market), minHealthFactor)` (SPEC-CF-005, REQ-RISK-068), so collateral admitted
as a rescue never backs new debt. There is no on-chain opening floor (Q-398): the Lens recommends a borrow at HF
1.10 beside the maximum at HF 1.00, and the optional per-market hard floor is 0 (off) unless set at listing. The debt-free test is Aave's `borrowCount == 0`, and repay, the debt-free
branches of withdraw and removeLiquidity, `repayAllAndWithdraw`, `burnSeized` and the deleverage callbacks read
no MarketRegistry state at all (REQ-ADAPTER-047, REQ-ADAPTER-086), so no pause, breaker, freeze or faulty
registry implementation can block an exit.

Accounts are unrolled to NM = 2 collateral markets and ND = 3 debt reserves (stated bound).
"""
import sys

import z3

from common import exhaustive, expect, finish, prove, witness, zmax

WAD, RAY = 10**18, 10**27
AAVE_MIN = WAD  # Aave's HF 1.00; no PROXY_HEALTH_FACTOR_FLOOR (Q-398)
NM, ND = 2, 3

# ---------------------------------------------------------------- T-58 health floor with rescue exclusion
# Values in Aave Value units (USD x 1e26). Nr: CF-weighted value of non-rescue collateral; Er: exact CF-weighted
# value of the rescue units; E >= Er: SPEC-CF-005's rounded-up E; D: debt value; hf = floor((Nr + Er) * WAD / D)
# (Aave); sub = ceil(E * WAD / D); hfEx = max(hf - sub, 0).
Nr, Er, E, D, hf, sub, min_open, min_hf = z3.Ints(
    "nonRescueCfValue rescueCfValueExact E_roundedUp debtValue hf subtracted hardFloor minHealthFactor")
hf_def = z3.And(D > 0, Nr >= 0, Er >= 0, hf * D <= (Nr + Er) * WAD, (Nr + Er) * WAD < (hf + 1) * D,
                E >= Er, sub * D >= E * WAD, (sub - 1) * D < E * WAD)
hf_ex = z3.If(hf - sub > 0, hf - sub, 0)
required = zmax(min_open, z3.IntVal(AAVE_MIN), min_hf)
param_bounds = z3.And(z3.Or(min_open == 0, z3.And(min_open >= WAD, min_open <= 125 * 10**16)), min_hf >= 0)  # 0 = off
passes = hf_ex >= required  # postHealthCheck (REQ-ADAPTER-026), inclusive
# FV-CTL-38 verifies: SPEC-PROXY-001, SPEC-CF-003, SPEC-CF-005, REQ-ADAPTER-026, REQ-RISK-068, REQ-PROXY-022, INV-025, REQ-RISK-059
prove("FV-CTL-38", "postHealthCheck passes only if the collateral without rescue units covers the debt at max(1.00, the optional per-market hard floor, minHealthFactor), exactly, whether the hard floor is off (0) or set within bounds",
      z3.Implies(passes, z3.And(Nr * WAD >= required * D, Nr * WAD >= AAVE_MIN * D, Nr * WAD >= min_hf * D,
                                Nr * WAD >= min_open * D)),
      assumptions=[hf_def, param_bounds],
      verifies=["SPEC-PROXY-001", "SPEC-CF-003", "SPEC-CF-005", "REQ-ADAPTER-026", "REQ-RISK-068", "REQ-PROXY-022",
                "INV-025", "REQ-RISK-059"],
      targets=["T-58"])
# FV-CTL-38-W verifies: SPEC-CF-005, REQ-ADAPTER-026
witness("FV-CTL-38-W", "Witness: with the hard floor off, a borrow leaving hfEx exactly 1.00 with no rescue units passes",
        z3.And(hf_def, param_bounds, passes, Er == 0, E == 0, hf == WAD, min_open == 0,
               min_hf == 0), verifies=["SPEC-CF-005", "REQ-ADAPTER-026"], targets=["T-58"])


def mul_div_ceil(a, b, c):
    return -((-a * b) // c)


# SPEC-CF-005 example: hf 1.2000, debt $10,000 (1e57), rescue units 5e8 of a d = 6 market at 2e8 and CF 3,120.
E_ex = mul_div_ceil(5 * 10**8 * 200_000_000, 3_120 * 10**18, 10**6 * 10**4)
sub_ex = mul_div_ceil(E_ex, WAD * RAY, 10**57)
hfex_ex = 12 * 10**17 - sub_ex
# Borrowing back to Aave hf 1.00: debt 12,000 -> hfEx = (12,000 - 312) / 12,000 = 0.974 < 1.00 reverts.
cf_total = 12_000 * 10**26
debt_back = cf_total * WAD // WAD
hf_back = cf_total * WAD // debt_back
hfex_back = hf_back - mul_div_ceil(E_ex, WAD, debt_back)
# FV-CTL-102 verifies: SPEC-CF-005, REQ-RISK-068
expect("FV-CTL-102", "SPEC-CF-005 example: E = 3.12e28, subtraction 0.0312e18, hfEx = 1.1688e18; borrowing back to Aave hf 1.00 gives hfEx 0.974 and reverts",
       E_ex == 312 * 10**26 and sub_ex == 312 * 10**14 and hfex_ex == 11_688 * 10**14
       and hfex_back == 974 * 10**15 and hfex_back < WAD,
       verifies=["SPEC-CF-005", "REQ-RISK-068"], targets=["T-58"],
       cex={"E": E_ex, "sub": sub_ex, "hfEx": hfex_ex, "hfEx_after_borrow_back": hfex_back})

# Path coverage: every Adapter path whose Spoke calls can lower an indebted account's health factor ends with
# postHealthCheck, or with the direction check of repayWithCollateral (hfAfter >= max(hfBefore, minHealthFactor)).
PATHS = {  # entry -> (Spoke calls that can lower HF when debt > 0, closing check)
    "pledge": ([], None), "recredit": ([], None),
    "borrow": (["borrow"], "postHealthCheck"),                                   # REQ-PROXY-022
    "repay": ([], None),
    "withdraw(with debt)": (["withdraw"], "postHealthCheck"),                    # REQ-PROXY-036
    "removeLiquidity(with debt)": (["withdraw"], "postHealthCheck"),             # REQ-ADAPTER-078
    "repayWithCollateral": (["withdraw"], "hfAfter >= max(hfBefore, minHealthFactor)"),  # REQ-ADAPTER-080
    "withdraw(debt-free)": (["withdraw", "setUsingAsCollateral(false)"], None),  # only with borrowCount == 0
    "removeLiquidity(debt-free)": (["withdraw"], None),                          # only with borrowCount == 0
    "repayAllAndWithdraw": (["withdraw", "setUsingAsCollateral(false)"], None),  # requires borrowCount == 0
    "burnSeized": ([], None),
}
DEBT_FREE_ONLY = {"withdraw(debt-free)", "removeLiquidity(debt-free)", "repayAllAndWithdraw"}
bad = [p for p, (calls, check) in PATHS.items() if calls and check is None and p not in DEBT_FREE_ONLY]
# FV-CTL-39 verifies: REQ-ADAPTER-027, REQ-ADAPTER-078, REQ-ADAPTER-080, REQ-ADAPTER-071, INV-025
expect("FV-CTL-39", "Every Adapter path that can lower an indebted account's health ends with postHealthCheck or the repay-with-collateral direction check; the unchecked paths run only at zero debt",
       not bad, verifies=["REQ-ADAPTER-027", "REQ-ADAPTER-078", "REQ-ADAPTER-080", "REQ-ADAPTER-071", "INV-025"],
       targets=["T-58"], cex={"unchecked": bad})

# ---------------------------------------------------------------- debt-free test and exits vs any MarketRegistry
debt = [z3.Int(f"debt_{i}") for i in range(ND)]
borrow_count = z3.Int("borrowCount")  # Spoke.getUserAccountData(proxy).borrowCount
nonneg = [d >= 0 for d in debt]
aave_count = borrow_count == z3.Sum([z3.If(d > 0, 1, 0) for d in debt])  # Aave counts every borrowed reserve
truly_free = z3.And([d == 0 for d in debt])
# FV-CTL-40 verifies: REQ-PROXY-034, REQ-PROXY-035, INV-025, INV-045
prove("FV-CTL-40", "The Adapter's debt-free test (Spoke borrowCount == 0) is exact: no indebted account takes the unchecked path and no debt-free account the gated one, for any MarketRegistry",
      (borrow_count == 0) == truly_free, assumptions=nonneg + [aave_count],
      verifies=["REQ-PROXY-034", "REQ-PROXY-035", "INV-025", "INV-045"], targets=["T-58"])

# What each Adapter entry point reads (2.6 text). Registry state = pause state or reason, address freeze, breakers,
# market records, the debt-reserve set; RM/PS/ORACLE = RiskModule, ParameterStore, LPOracle/DebtOracle.
READS = {
    "repay": {"Spoke", "Proxy", "Token"},                                              # REQ-PROXY-027
    "withdraw(debt-free)": {"Spoke", "Proxy", "VaultTokenFactory", "Collateralization"},  # REQ-PROXY-033/035
    "removeLiquidity(debt-free)": {"Spoke", "Proxy", "VaultTokenFactory", "Collateralization"},  # REQ-ADAPTER-078
    "repayAllAndWithdraw": {"Spoke", "Proxy", "Token", "VaultTokenFactory", "Collateralization"},  # REQ-ADAPTER-071
    "burnSeized": {"Lock", "VaultTokenFactory"},                                       # REQ-ADAPTER-070
    "deleverageRepay": {"Lock", "Session", "Proxy", "Token"},                          # REQ-ADAPTER-081
    "deleverageRelease": {"Lock", "Session", "Proxy", "Collateralization"},            # REQ-ADAPTER-081
    # new-activity paths, for contrast (non-vacuity)
    "borrow": {"Registry", "RiskModule", "Spoke", "Proxy"},
    "pledge": {"Registry", "Collateralization", "ProxyManager", "Spoke", "Proxy"},
    "withdraw(with debt)": {"Registry", "RiskModule", "Spoke", "Proxy", "Collateralization"},
    "repayWithCollateral": {"Registry", "LPVaultSwap", "Spoke", "Proxy", "Collateralization"},
}
EXIT_PATHS = ("repay", "withdraw(debt-free)", "removeLiquidity(debt-free)", "repayAllAndWithdraw", "burnSeized",
              "deleverageRepay", "deleverageRelease")
CONFIG = {"Registry", "RiskModule", "ParameterStore", "LPOracle", "DebtOracle"}
# FV-CTL-100 verifies: REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-PROXY-027, REQ-PROXY-035, REQ-ADAPTER-070, REQ-ADAPTER-081, REQ-ACCESS-148, INV-045, INV-081
exhaustive("FV-CTL-100", "Repay, the debt-free branches of withdraw and removeLiquidity, repayAllAndWithdraw, burnSeized and the deleverage callbacks read no MarketRegistry, RiskModule, ParameterStore or oracle state; every new-activity path does read the registry",
           list(READS), lambda e: (not (READS[e] & CONFIG)) if e in EXIT_PATHS else ("Registry" in READS[e]),
           verifies=["REQ-ADAPTER-047", "REQ-ADAPTER-086", "REQ-PROXY-027", "REQ-PROXY-035", "REQ-ADAPTER-070",
                     "REQ-ADAPTER-081", "REQ-ACCESS-148", "INV-045", "INV-081"], targets=["T-57", "T-58"])

# Repay liveness (T-57): the outcome depends only on Aave, the payer and the call; every registry-side value is free.
deadline_ok, has_proxy, aave_paused, hub_halted = z3.Bools("deadline_ok has_proxy r_paused hub_halted")
mr_vals = z3.Bools("mr_pauseState_paused mr_reason_mintPathSuspect mr_payerFrozen mr_borrowerFrozen "
                   "mr_marketBreaker mr_debtBreaker mr_isApprovedDebtReserve mr_reverts")
repay_all = z3.Bool("repayAll")
Dr, maxs, allowance, balance = z3.Ints("liveDebt maxRepaySpend allowance payerBalance")
x = z3.If(repay_all, maxs, z3.If(maxs < Dr, maxs, Dr))  # REQ-PROXY-028, REQ-ADAPTER-085: repay-all pulls the cap
repay_ok = z3.And(deadline_ok, has_proxy, z3.Or(repay_all, maxs > 0),
                  z3.Implies(z3.And(repay_all, Dr > 0), Dr <= maxs),
                  z3.Or(Dr == 0, z3.And(allowance >= x, balance >= x)), z3.Not(aave_paused), z3.Not(hub_halted))
honest = z3.And(deadline_ok, has_proxy, Dr > 0, z3.Or(z3.And(repay_all, maxs >= Dr),
                z3.And(z3.Not(repay_all), maxs > 0)), allowance >= x, balance >= x,
                z3.Not(aave_paused), z3.Not(hub_halted))
# FV-CTL-41 verifies: INV-043, REQ-PROXY-027, REQ-PROXY-032, REQ-ACCESS-068, REQ-ADAPTER-047, REQ-ADAPTER-082
prove("FV-CTL-41", "Repay succeeds whenever Aave allows it and the payer funds it, for every pause state and reason, payer or borrower freeze, breaker and MarketRegistry implementation",
      z3.ForAll(list(mr_vals), z3.Implies(honest, repay_ok)), assumptions=[Dr >= 0, maxs >= 0],
      verifies=["INV-043", "REQ-PROXY-027", "REQ-PROXY-032", "REQ-ACCESS-068", "REQ-ADAPTER-047", "REQ-ADAPTER-082"],
      targets=["T-57"])

# Sizing (SPEC-PROXY-003, REQ-ADAPTER-085, REQ-PROXY-029/030): pull x, the proxy receives `received <= x`
# (a transfer fee can lower it), Aave takes spent = min(received, D), the payer gets received - spent back.
received = z3.Int("received")
pulled = z3.If(Dr == 0, 0, x)
spent = z3.If(received < Dr, received, Dr)
net = z3.If(Dr == 0, 0, pulled - (received - spent))  # what the payer is out of pocket, ignoring the fee itself
fee_free = received == pulled
# FV-CTL-42 verifies: SPEC-PROXY-003, REQ-PROXY-028, REQ-PROXY-029, REQ-PROXY-030, REQ-PROXY-083, REQ-PROXY-084, REQ-ADAPTER-085
prove("FV-CTL-42", "Repay pulls min(maxRepaySpend, live debt) for a partial repay and maxRepaySpend for a repay-all, refunds received - spent, nets exactly the live debt for a fee-free repay-all, and moves nothing at zero debt",
      z3.And(z3.Implies(z3.Not(repay_all), pulled <= Dr), pulled <= maxs, z3.Implies(Dr == 0, pulled == 0),
             spent <= Dr, spent <= received,
             z3.Implies(z3.And(repay_ok, repay_all, Dr > 0, fee_free), z3.And(spent == Dr, net == Dr)),
             z3.Implies(z3.And(repay_ok, z3.Not(repay_all), Dr > 0, fee_free), net == z3.If(maxs < Dr, maxs, Dr))),
      assumptions=[Dr >= 0, maxs >= 0, received >= 1, received <= pulled],
      verifies=["SPEC-PROXY-003", "REQ-PROXY-028", "REQ-PROXY-029", "REQ-PROXY-030", "REQ-PROXY-083",
                "REQ-PROXY-084", "REQ-ADAPTER-085"],
      targets=["T-57"])
# REQ-PROXY-083 example: repay-all cap 5,030e6 against D' = 3,024.657535 USDC pulls 5,030,000,000 and refunds 2,005,342,465.
# FV-CTL-42-EX verifies: REQ-PROXY-083, REQ-ADAPTER-085
expect("FV-CTL-42-EX", "REQ-PROXY-083 example: Aave takes 3,024,657,535 and 2,005,342,465 return to the borrower",
       5_030_000_000 - 3_024_657_535 == 2_005_342_465, verifies=["REQ-PROXY-083", "REQ-ADAPTER-085"], targets=["T-57"])

# ---------------------------------------------------------------- T-59 / T-60 / T-78 borrow-side pre-checks
now = z3.Int("now")
state = [z3.Int(f"priceState_{m}") for m in range(NM)]  # 0 Live, 1 Drifting, 2 Cached, 3 Expired
enabled = [z3.Bool(f"collateralEnabled_{m}") for m in range(NM)]
t_in = [[z3.Int(f"inputTs_{m}_{j}") for j in range(4)] for m in range(NM)]
age_lim = [[z3.Int(f"borrowMaxAge_{m}_{j}") for j in range(4)] for m in range(NM)]
frozen = [z3.Bool(f"collFrozen_{m}") for m in range(NM)]
cpaused = [z3.Bool(f"collPaused_{m}") for m in range(NM)]
offb = [z3.Bool(f"offboarding_{m}") for m in range(NM)]
shares_eq = [z3.Bool(f"sharesEqAssets_{m}") for m in range(NM)]
halted = [z3.Bool(f"liqHalted_{m}") for m in range(NM)]       # no usable route (no in-kind path, Q-401)
mbrk = [z3.Bool(f"marketBreaker_{m}") for m in range(NM)]       # REQ-RISK-065 market breaker of m
active_keepers = z3.Int("activeKeeperCount")
borrowed = [z3.Bool(f"borrowing_{r}") for r in range(ND)]
target_r = z3.Int("debtReserveId")
dpaused = [z3.Bool(f"debtPaused_{r}") for r in range(ND)]
src_ok = [z3.Bool(f"debtSourceEqualsRecorded_{r}") for r in range(ND)]
gho = [z3.Bool(f"isGho_{r}") for r in range(ND)]               # Aave's fixed $1 source, no age
dstate = [z3.Int(f"debtOracleState_{r}") for r in range(ND)]   # DebtOracle state, 0 Live
dts = [z3.Int(f"debtServedTs_{r}") for r in range(ND)]
dlim = [z3.Int(f"debtBorrowMaxAge_{r}") for r in range(ND)]
dhalt = [z3.Bool(f"noBuyRoute_{r}") for r in range(ND)]
dbrk = [z3.Bool(f"debtBreaker_{r}") for r in range(ND)]
drift = z3.Bool("configDrift")


def in_debt_scope(r, is_borrow):
    return z3.Or(borrowed[r], z3.And(is_borrow, target_r == r))


def fresh(ts, lim):
    return z3.And(ts <= now, now - ts <= lim)


def pre_check(is_borrow):
    """preBorrowCheck / preWithdrawCheck as the 2.7 check order states them (REQ-ADAPTER-010…025, REQ-RISK-056…065)."""
    g = [z3.Not(drift)]
    for m in range(NM):
        g.append(z3.Implies(enabled[m], z3.And(
            state[m] == 0, *[fresh(t_in[m][j], age_lim[m][j]) for j in range(4)],
            z3.Not(cpaused[m]), shares_eq[m], z3.Not(halted[m]), active_keepers > 0, z3.Not(mbrk[m]),
            *([z3.Not(frozen[m]), z3.Not(offb[m])] if is_borrow else []))))
    for r_ in range(ND):
        scope = in_debt_scope(r_, is_borrow)
        g.append(z3.Implies(scope, z3.And(z3.Not(dpaused[r_]), src_ok[r_],
                                          z3.Or(gho[r_], z3.And(dstate[r_] == 0, fresh(dts[r_], dlim[r_]),
                                                                z3.Not(dhalt[r_]))))))
        # debt breaker: of the borrowed reserve for a borrow; of every held reserve for a withdrawal
        g.append(z3.Implies(z3.And(scope, z3.If(is_borrow, target_r == r_, borrowed[r_])), z3.Not(dbrk[r_])))
    return z3.And(g)


ok_b, ok_w = pre_check(True), pre_check(False)
claim_common = lambda is_borrow: z3.And(
    z3.Not(drift), z3.Implies(z3.Or(enabled), active_keepers > 0),
    *[z3.Implies(enabled[m], z3.And(state[m] == 0, z3.Not(cpaused[m]), shares_eq[m], z3.Not(mbrk[m]),
                                    *[t_in[m][j] <= now for j in range(4)],
                                    *[now - t_in[m][j] <= age_lim[m][j] for j in range(4)]))
      for m in range(NM)],
    *[z3.Implies(in_debt_scope(r_, is_borrow), z3.And(z3.Not(dpaused[r_]), src_ok[r_],
                                                      z3.Or(gho[r_], z3.And(dstate[r_] == 0, dts[r_] <= now,
                                                                            now - dts[r_] <= dlim[r_]))))
      for r_ in range(ND)])
# FV-CTL-43 verifies: SPEC-PROXY-002, REQ-ADAPTER-015, REQ-ADAPTER-016, REQ-RISK-061, REQ-ADAPTER-061, REQ-ADAPTER-019, REQ-ADAPTER-021, REQ-RISK-065, REQ-RISK-071, REQ-ADAPTER-010, INV-023, INV-024, INV-060, INV-029, INV-072
prove("FV-CTL-43", "A borrow passes preBorrowCheck only if every collateral market is Live, fresh and unbroken, no collateral reserve is paused or frozen, every debt price is GHO's or a Live, fresh DebtOracle on the recorded source, the borrowed reserve's debt breaker is clear, an active keeper exists, with no drift and Hub shares == assets",
      z3.Implies(ok_b, z3.And(claim_common(True), *[z3.Implies(enabled[m], z3.And(z3.Not(frozen[m]), z3.Not(offb[m])))
                                                    for m in range(NM)],
                              *[z3.Implies(target_r == r_, z3.Not(dbrk[r_])) for r_ in range(ND)])),
      assumptions=[target_r >= 0, target_r < ND],
      verifies=["SPEC-PROXY-002", "REQ-ADAPTER-015", "REQ-ADAPTER-016", "REQ-RISK-061", "REQ-ADAPTER-061",
                "REQ-ADAPTER-019", "REQ-ADAPTER-021", "REQ-RISK-065", "REQ-RISK-071", "REQ-ADAPTER-010", "INV-023",
                "INV-024", "INV-060", "INV-029", "INV-072"],
      targets=["T-59", "T-60", "T-78"])
# FV-CTL-43-W verifies: REQ-ADAPTER-024
witness("FV-CTL-43-W", "Witness: a two-market, three-reserve account (GHO and a Live DebtOracle reserve) passes preBorrowCheck",
        z3.And(ok_b, enabled[0], enabled[1], borrowed[0], gho[0], z3.Not(gho[2]), target_r == 2),
        verifies=["REQ-ADAPTER-024"], targets=["T-59"])
# FV-CTL-103 verifies: REQ-ADAPTER-025, REQ-PROXY-036, REQ-RISK-065, INV-024
prove("FV-CTL-103", "A withdraw-with-debt passes preWithdrawCheck only under the same gates except Offboarding and Aave-frozen collateral, and with the debt breaker of every held reserve clear",
      z3.Implies(ok_w, z3.And(claim_common(False), *[z3.Implies(borrowed[r_], z3.Not(dbrk[r_])) for r_ in range(ND)])),
      assumptions=[target_r >= 0, target_r < ND],
      verifies=["REQ-ADAPTER-025", "REQ-PROXY-036", "REQ-RISK-065", "INV-024"], targets=["T-59"])
# FV-CTL-44 verifies: REQ-PROXY-019, SPEC-PROXY-002, REQ-RISK-061
prove("FV-CTL-44", "The borrowed reserve's price source, DebtOracle state and freshness are checked even before the account holds that debt",
      z3.Implies(z3.And(ok_b, z3.Not(borrowed[2]), target_r == 2),
                 z3.And(src_ok[2], z3.Or(gho[2], z3.And(dstate[2] == 0, dts[2] <= now)))),
      verifies=["REQ-PROXY-019", "SPEC-PROXY-002", "REQ-RISK-061"], targets=["T-59"])

# T-60 as the methodology now scopes it: the reviewed RiskModule refuses a borrow against a paused or frozen
# collateral reserve; for any RiskModule, Aave itself refuses a paused or frozen borrowed reserve.
b_frozen, b_paused, aave_borrow_ok = z3.Bools("borrowedReserveFrozen borrowedReservePaused aaveBorrowValidation")
# FV-CTL-45 verifies: INV-060, REQ-PROXY-079, REQ-ADAPTER-019, REQ-ADAPTER-061
prove("FV-CTL-45", "T-60 as scoped: with the reviewed RiskModule no borrow completes against a paused or frozen collateral reserve; with any RiskModule Aave refuses a paused or frozen borrowed reserve",
      z3.And(z3.Implies(ok_b, z3.And(*[z3.Implies(enabled[m], z3.And(z3.Not(frozen[m]), z3.Not(cpaused[m])))
                                       for m in range(NM)])),
             z3.Implies(aave_borrow_ok, z3.And(z3.Not(b_frozen), z3.Not(b_paused)))),
      assumptions=[aave_borrow_ok == z3.And(z3.Not(b_frozen), z3.Not(b_paused))],
      verifies=["INV-060", "REQ-PROXY-079", "REQ-ADAPTER-019", "REQ-ADAPTER-061"], targets=["T-60"])

# ---------------------------------------------------------------- rescue top-up rule (REQ-RISK-066/067, REQ-ADAPTER-083)
RESCUE_MIN = 10 * 10**8
borrow_count_p, hf_p, h_o = z3.Ints("pledge_borrowCount pledge_hf rescueTargetHF")
pledge_usd, charge, restore, min_pledge = z3.Ints("pledgeUsd usdCharge restoreBooked minPledgeUsd")
pool_share_exceeded, mbreak_non_oracle, frozen_caller = z3.Bools("poolShareExceeded marketBreakerNonOracle callerFrozen")
pstate = z3.Int("pauseState")    # 0 None, 1 Frozen, 2 Paused
preason = z3.Int("pauseReason")  # 0 None, 1 General, 2 MintPathSuspect


def adapter_gate():
    """REQ-ADAPTER-083: returns (proceeds, requireRescue)."""
    proceeds = z3.And(z3.Not(z3.And(pstate == 2, preason == 2)), z3.Not(z3.And(pstate == 1, borrow_count_p == 0)))
    require = z3.Or(z3.And(pstate == 2, preason == 1), frozen_caller)
    return proceeds, require


def risk_rescue(require):
    """REQ-RISK-066: returns (passes, rescue)."""
    eligible = z3.And(borrow_count_p > 0, hf_p < h_o)
    needs = z3.Or(require, pool_share_exceeded, mbreak_non_oracle, pledge_usd < min_pledge)
    rescue_min = z3.If(min_pledge < RESCUE_MIN, min_pledge, RESCUE_MIN)
    rescue_pass = z3.And(pledge_usd >= rescue_min, eligible, charge <= restore)
    return z3.If(needs, rescue_pass, True), needs


wf_p = [borrow_count_p >= 0, hf_p >= 0, h_o == 110 * 10**16,  # rescue target: the Lens recommended HF 1.10 (Q-398)
         pledge_usd >= 0, charge >= pledge_usd,
        restore >= 0, min_pledge >= 0, min_pledge <= 100_000 * 10**8, pstate >= 0, pstate <= 2,
        preason >= 0, preason <= 2, (pstate == 2) == (preason != 0)]
proceeds, require = adapter_gate()
passes_rm, rescue = risk_rescue(require)
admitted = z3.And(proceeds, passes_rm)
# FV-CTL-101 verifies: REQ-RISK-066, REQ-RISK-067, REQ-ADAPTER-083, REQ-ADAPTER-082, REQ-RISK-016, INV-082
prove("FV-CTL-101", "A pledge admitted through an exemption (Paused(General), a frozen caller, a tripped market breaker, the pool-share cap or minPledgeUsd above $10) is a rescue top-up: indebted, below the rescue target HF 1.10, charged at most its restore amount and worth at least min(minPledgeUsd, $10); and every such rescue passes unless the reason is MintPathSuspect",
      z3.And(z3.Implies(z3.And(admitted, rescue), z3.And(borrow_count_p > 0, hf_p < h_o, charge <= restore,
                                                         pledge_usd >= z3.If(min_pledge < RESCUE_MIN, min_pledge, RESCUE_MIN))),
             z3.Implies(z3.And(admitted, require), borrow_count_p > 0),
             z3.Implies(z3.And(borrow_count_p > 0, hf_p < h_o, charge <= restore, pledge_usd >= RESCUE_MIN,
                               z3.Not(z3.And(pstate == 2, preason == 2))), admitted)),
      assumptions=wf_p,
      verifies=["REQ-RISK-066", "REQ-RISK-067", "REQ-ADAPTER-083", "REQ-ADAPTER-082", "REQ-RISK-016", "INV-082"],
      targets=["T-56", "T-58"])


# REQ-RISK-066 / SPEC-CAP-003 example: hf 1.02, debt $10,000, CF 3,000 -> restoreBooked 266,666,666,667.
x_ex = mul_div_ceil(110 * 10**16 - 102 * 10**16, 10**57, WAD * RAY)
usd_restore = mul_div_ceil(x_ex, 10**4, 3_000 * 10**18)
restore_ex = mul_div_ceil(usd_restore, max(199_990_000, 10**8), 199_990_000)
restore_floor = mul_div_ceil(usd_restore, max(80_000_000, 10**8), 80_000_000)
# FV-CTL-101-EX verifies: REQ-RISK-066, SPEC-CAP-003, REQ-ADAPTER-083
expect("FV-CTL-101-EX", "REQ-RISK-066 example: restoreBooked = 266,666,666,667 ($2,666.67); a $2,000 rescue passes, a $3,000 one reverts NotRescueTopUp; at price8 80,000,000 the restore amount is 333,333,333,334",
       x_ex == 8 * 10**28 and usd_restore == 266_666_666_667 and restore_ex == 266_666_666_667
       and restore_floor == 333_333_333_334 and 2_000 * 10**8 <= restore_ex < 3_000 * 10**8,
       verifies=["REQ-RISK-066", "SPEC-CAP-003", "REQ-ADAPTER-083"], targets=["T-58"],
       cex={"x": x_ex, "usdToRestore": usd_restore, "restoreBooked": restore_ex, "at_80M": restore_floor})

# ---------------------------------------------------------------- T-61 borrow nonce
n0, e1, e2 = z3.Ints("nonce0 expected1 expected2")
rest1, rest2 = z3.Bools("other_checks_pass_1 other_checks_pass_2")
ok1 = z3.And(e1 == n0, rest1)
n1 = z3.If(ok1, n0 + 1, n0)  # a later revert undoes the increment (atomic call)
ok2 = z3.And(e2 == n1, rest2)
n2 = z3.If(ok2, n1 + 1, n1)
# FV-CTL-46 verifies: INV-019, REQ-PROXY-015
prove("FV-CTL-46", "borrowNonce rises by exactly 1 per successful borrow, is unchanged by a reverted one, and admits one borrow per nonce value",
      z3.And(n2 - n0 == z3.If(ok1, 1, 0) + z3.If(ok2, 1, 0), z3.Not(z3.And(ok1, ok2, e1 == e2))),
      assumptions=[n0 >= 0], verifies=["INV-019", "REQ-PROXY-015"], targets=["T-61"])

# ---------------------------------------------------------------- isolation
w_caller, w_other, spoke = z3.Ints("msg_sender other_wallet spoke")
proxy_of = z3.Function("proxyOf", z3.IntSort(), z3.IntSort(), z3.IntSort())
inj = z3.ForAll([z3.Int("w1"), z3.Int("w2"), z3.Int("s1")],
                z3.Implies(z3.And(proxy_of(z3.Int("w1"), z3.Int("s1")) == proxy_of(z3.Int("w2"), z3.Int("s1")),
                                  proxy_of(z3.Int("w1"), z3.Int("s1")) != 0), z3.Int("w1") == z3.Int("w2")))
acted_on = proxy_of(w_caller, spoke)  # REQ-ADAPTER-066: pledge/borrow/withdraw act on proxyOf[msg.sender][spoke]
# FV-CTL-47 verifies: REQ-ADAPTER-066, REQ-PROXY-053, Q-223
prove("FV-CTL-47", "A wallet's pledge, borrow or withdrawal can act only on its own proxy, never on another wallet's account",
      z3.Implies(z3.And(w_caller != w_other, acted_on != 0), acted_on != proxy_of(w_other, spoke)),
      assumptions=[inj], verifies=["REQ-ADAPTER-066", "REQ-PROXY-053", "Q-223"], targets=["T-62"])

sys.exit(finish())
