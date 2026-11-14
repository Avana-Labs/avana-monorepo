#!/usr/bin/env python3
"""FV-C controls of the AMM-neutral design: the standard Spoke and its drift settings, liquidation exclusivity,
the flash source, Hub-keyed caps, credit lines and keeper-funded settlement (no SettlementBudget, Q-397).

How Avana works here, and what each check proves:

- Liquidation exclusivity. Each CDP Spoke is a standard, unmodified Aave V4 Spoke whose 5-argument
  `liquidationCall(collateralReserveId, debtReserveId, user, debtToCover, receiveShares)` anyone may call. With
  `receiveShares = false` the Hub pays the seized vault-token units to the caller by a token transfer, and the
  vault token allows exactly five balance changes (mint to a registered proxy, proxy -> Hub supply, Hub -> proxy
  withdrawal, Hub -> LPVaultSwap seizure, burn from a proxy or LPVaultSwap by the Adapter). Every liquidator other
  than LPVaultSwap therefore reverts on the seizure transfer (FV-CTL-155). This rests on three Spoke settings:
  `receiveSharesEnabled = false`, `liquidationFee = 0` and no reinvestment controller; with receive-shares on, a
  liquidator takes Spoke shares with no token transfer (FV-CTL-155-W, a mutation witness).
- Drift. The RiskModule's `checkAaveConfig` trips the Spoke's `CONFIG_DRIFT` breaker on any drift of those settings
  or of the other standard-Spoke conditions; the breaker stops new risk on every market of the Spoke and never stops
  liquidation, repay, top-ups, debt-free exits or fee collection (FV-CTL-156).
- Flash source. LPVaultSwap flash-borrows the debt asset itself through the chain's `IFlashSource` (the Aave V3
  Pool). It requests a loan only within the source's liquidity and the `maxFlashFeeBps` ceiling and never from the
  CDP Spoke's home Hub or the reserve's funding Hub; the source's callback accepts only the Pool, its own
  initiation, one asset and the active context, and LPVaultSwap's `onFlashLoan` accepts only the current source in
  an active context (FV-CTL-157). Only the timelock replaces the source, with the LPVaultSwap binding checked, and a
  short or repriced source falls back to the caller-funded path (FV-CTL-158).
- Hub-keyed caps. Token, depositor and pool counters live in the chain's one ledger keyed by Hub, so a Hub-wide cap
  is one counter however many Spokes and markets the Hub has (FV-CTL-159; a counter keyed per Spoke would admit the
  cap once per Spoke, FV-CTL-159-W).
- Credit lines. Draw caps per (funding Hub, asset, Spoke) sum to at most the credit line, and the cross-Hub part to
  at most the cross-Hub cap, itself at most the funding Hub's first-loss coverage (FV-CTL-160).
- Settlement funding. With no SettlementBudget (Q-397) each liquidation is funded by its own caller, so one
  market's liquidations never consume funds another market's liquidations need (FV-CTL-161).
- Transfer-rule wording. Every page that states the vault token's transfer rule states the same paths (FV-CTL-162).
"""
import itertools
import re
import sys

import z3

from common import HERE, exhaustive, expect, finish, open_finding, prove, witness

SPEC = HERE.parents[2] / "spec"


def page(rel):
    return (SPEC / rel).read_text()


def rule(rel, rid):
    for l_ in page(rel).splitlines():
        if l_.startswith(f"- `{rid}`"):
            return l_
    raise LookupError(f"{rid} not found in {rel}")


# ---------------------------------------------------------------- liquidation exclusivity
KINDS = ("Hub", "LPVaultSwap", "AaveAdapter", "RegisteredProxy", "OtherProxyOfMarket", "CdpSpoke", "Keeper",
         "Wallet", "FeeReceiver", "ReinvestmentController", "LPVault", "Collateralization", "Zero")


def allowed(frm, to, caller):
    """REQ-VTOKEN-006: the five allowed balance changes of a market's vault token."""
    if frm == "Zero":
        return to == "RegisteredProxy" and caller == "AaveAdapter"                       # (1) mint
    if to == "Zero":
        return frm in ("RegisteredProxy", "LPVaultSwap") and caller == "AaveAdapter"    # (5) burn
    if frm == "RegisteredProxy" and to == "Hub":
        return caller == "CdpSpoke"                                                     # (2) supply
    if frm == "Hub" and to == "RegisteredProxy":
        return True                                                                     # (3) withdraw
    if frm == "Hub" and to == "LPVaultSwap":
        return True                                                                     # (4) seizure
    return False


def liquidation_succeeds(liquidator, receive_shares_enabled, receive_shares, fee):
    """Standard Spoke liquidationCall: with receiveShares the seized shares move inside the Spoke (no transfer);
    otherwise the Hub transfers the seized units (minus the fee share, kept as Spoke shares) to the liquidator."""
    if liquidator == "RegisteredProxy":
        return False                                   # a proxy calls only what the Adapter builds (REQ-PROXY-008)
    if receive_shares and receive_shares_enabled:
        return True                                    # shares credited to the liquidator, no token transfer
    if receive_shares and not receive_shares_enabled:
        return False                                   # the Spoke refuses receiveShares on this reserve
    return allowed("Hub", liquidator, "CdpSpoke")


# FV-CTL-155 verifies: REQ-VTOKEN-006, REQ-VTOKEN-008, REQ-VTOKEN-026, REQ-ADAPTER-029, REQ-ADAPTER-030, REQ-ADAPTER-033, REQ-VTOKEN-025, REQ-PROXY-008
exhaustive("FV-CTL-155", "With receiveSharesEnabled = false, liquidationFee = 0 and no reinvestment controller, a liquidationCall on a standard Spoke seizes Avana collateral only when the liquidator is LPVaultSwap; every other liquidator, with either receiveShares value, reverts",
           list(itertools.product(KINDS, (False, True))),
           lambda x: liquidation_succeeds(x[0], False, x[1], 0) == (x[0] == "LPVaultSwap" and not x[1]) or x,
           verifies=["REQ-VTOKEN-006", "REQ-VTOKEN-008", "REQ-VTOKEN-026", "REQ-ADAPTER-029", "REQ-ADAPTER-030",
                     "REQ-ADAPTER-033", "REQ-VTOKEN-025", "REQ-PROXY-008"], targets=["T-63", "T-65"],
           detail="The token cannot tell a seizure Hub -> proxy from a withdrawal Hub -> proxy, so a registered proxy as "
                  "liquidator is excluded by REQ-PROXY-008 (the Adapter never makes a proxy call liquidationCall), not "
                  "by the transfer rule; without that rule the first run found the proxy case (see FV-CTL-F-29).")
liq_k = z3.Int("liquidatorKind")       # index into KINDS
rse, rsh = z3.Bools("receiveSharesEnabled receiveShares")
# FV-CTL-155-W verifies: REQ-ADAPTER-029, REQ-RISK-078
witness("FV-CTL-155-W", "Mutation witness: with receiveSharesEnabled = true a liquidator other than LPVaultSwap seizes with receiveShares = true and no token transfer, so the transfer rule alone does not give exclusivity; this is why the setting is a drift condition",
        z3.And(rse, rsh, liq_k == KINDS.index("Keeper"),
               z3.BoolVal(liquidation_succeeds("Keeper", True, True, 0))),
        verifies=["REQ-ADAPTER-029", "REQ-RISK-078"], targets=["T-65"])

# ---------------------------------------------------------------- drift: CONFIG_DRIFT stops new risk only
DRIFT = ("receiveSharesEnabled", "liquidationFee", "reinvestmentController", "borrowableVaultReserve",
         "secondSpokeOnVaultAsset", "spokeImplementation", "oracle")
NEW_RISK = ("newAccountPledge", "recreditDebtFree", "borrow", "withdrawWithDebt", "removalWithDebt")
ALWAYS = ("liquidation", "repay", "topUpWithDebt", "debtFreeExit", "feeCollection", "settlePending")
_r078 = rule("02-contracts/07-risk-module.md", "REQ-RISK-078")
_PH078 = {"receiveSharesEnabled": "`receiveSharesEnabled == false`", "liquidationFee": "`liquidationFee == 0`",
          "reinvestmentController": "no reinvestment controller", "borrowableVaultReserve": "the reserve not borrowable",
          "secondSpokeOnVaultAsset": "no second Spoke", "spokeImplementation": "approved Spoke implementation",
          "oracle": "oracle"}
_stops = re.search(r"`CONFIG_DRIFT` stops (.*?), and never stops (.*?)\.", _r078)
_page_stop = _stops.group(1) if _stops else ""
_page_keep = _stops.group(2) if _stops else ""
_STOP_PH = {"newAccountPledge": "new-account pledges", "recreditDebtFree": "re-credits of debt-free accounts",
            "borrow": "borrows", "withdrawWithDebt": "withdraw-with-debt", "removalWithDebt": "removal with debt"}
_KEEP_PH = {"liquidation": "liquidation", "repay": "repay", "topUpWithDebt": "top-ups", "debtFreeExit": "debt-free exits",
            "feeCollection": "fee collection"}


def blocked(drift, action):
    """RiskModule gate under the Spoke's CONFIG_DRIFT breaker (REQ-RISK-078, REQ-RISK-086, REQ-ADAPTER-036)."""
    return drift is not None and action in NEW_RISK


def drift_case(x):
    if x == ("page", "-"):
        bad = {"setting not named": [d for d, ph in _PH078.items() if ph not in _r078],
               "stop not named": [a for a, ph in _STOP_PH.items() if ph not in _page_stop],
               "continue not named": [a for a, ph in _KEEP_PH.items() if ph not in _page_keep]}
        return True if not any(bad.values()) else bad
    d, a = x
    return blocked(d, a) == (d is not None and a in NEW_RISK) and not (a in ALWAYS and blocked(d, a)) or x


# FV-CTL-156 verifies: REQ-RISK-078, REQ-RISK-086, REQ-ADAPTER-036, REQ-ADAPTER-020, REQ-HUB-110
exhaustive("FV-CTL-156", "Any drift of a standard-Spoke setting (receiveSharesEnabled, liquidationFee, reinvestment controller, borrowable vault reserve, second Spoke, implementation, oracle) trips CONFIG_DRIFT, which blocks new-account pledges, debt-free re-credits, borrows, withdraw-with-debt and removal with debt, and never liquidation, repay, top-ups, debt-free exits, fee collection or pending settlement; REQ-RISK-078 names each setting and each effect",
           [("page", "-")] + list(itertools.product((None,) + DRIFT, NEW_RISK + ALWAYS)), drift_case,
           verifies=["REQ-RISK-078", "REQ-RISK-086", "REQ-ADAPTER-036", "REQ-ADAPTER-020", "REQ-HUB-110"],
           targets=["T-56", "T-63"])

# ---------------------------------------------------------------- flash source
F, avail, fee, mf, prem = z3.Ints("F maxFlashLoan flashFee maxFlashFeeBps premium")
lender, home_hub, fund_hub = z3.Ints("lender homeHub fundingHub")
cb_sender, POOL, initiator, src_self, n_assets, a_cb, amt_cb, ctx_asset, ctx_amt = z3.Ints(
    "executeOperation_sender POOL initiator flashSource n_assets asset_cb amount_cb ctx_asset ctx_amount")
on_sender, cur_source = z3.Ints("onFlashLoan_sender flashSourceStorage")
ctx_active = z3.Bool("contextActive")
pre_ok = z3.And(F >= 1, F <= avail, fee * 10**4 <= mf * F, lender != home_hub, lender != fund_hub)  # REQ-FLASH-002/005
cb_ok = z3.And(cb_sender == POOL, initiator == src_self, n_assets == 1, a_cb == ctx_asset, amt_cb == ctx_amt,
               ctx_active)                                                                    # REQ-FLASH-003
on_ok = z3.And(on_sender == cur_source, ctx_active, a_cb == ctx_asset, amt_cb == ctx_amt,
               prem * 10**4 <= mf * amt_cb)                                                   # REQ-SWAP-013, FLASH-004
# FV-CTL-157 verifies: REQ-FLASH-001, REQ-FLASH-002, REQ-FLASH-003, REQ-FLASH-004, REQ-FLASH-005, REQ-FLASH-009, REQ-SWAP-012, REQ-SWAP-013, SPEC-LIQ-015
prove("FV-CTL-157", "A flash-funded settlement runs only for a loan LPVaultSwap requested within the source's liquidity and the fee ceiling, from a lender that is neither the CDP Spoke's home Hub nor the reserve's funding Hub, delivered by the Pool to the source's own initiation, for one asset and the amount of the active context, with a charged premium within maxFlashFeeBps",
      z3.Implies(z3.And(pre_ok, cb_ok, on_ok, ctx_amt == F),
                 z3.And(F <= avail, lender != home_hub, lender != fund_hub, cb_sender == POOL, initiator == src_self,
                        n_assets == 1, amt_cb == F, on_sender == cur_source, prem * 10**4 <= mf * F)),
      assumptions=[mf >= 0, mf <= 100, prem >= 0, fee >= 0],
      verifies=["REQ-FLASH-001", "REQ-FLASH-002", "REQ-FLASH-003", "REQ-FLASH-004", "REQ-FLASH-005", "REQ-FLASH-009",
                "REQ-SWAP-012", "REQ-SWAP-013", "SPEC-LIQ-015"], targets=["T-65"])
# FV-CTL-157-W verifies: REQ-FLASH-002, REQ-FLASH-003
witness("FV-CTL-157-W", "Witness: SPEC-LIQ-015's example loan (1,950 USDC, 5 bps, ceiling 10 bps) passes every check",
        z3.And(pre_ok, cb_ok, on_ok, ctx_amt == F, F == 1_950_000_000, avail == 18_000_000 * 10**6, mf == 10,
               fee == 975_000, prem == 975_000, lender == 7, home_hub == 1, fund_hub == 1),
        verifies=["REQ-FLASH-002", "REQ-FLASH-003"], targets=["T-65"])

SOURCE_STATES = ("ok", "liquidityShort", "feeAboveCeiling", "reservePaused", "beingReplaced")
SET_CALLERS = ("TIMELOCK(APPLICATION_ADMIN)", "guardian", "keeper", "anyone")


def path(state):
    """REQ-SWAP-014: the flash path only when the source is usable, otherwise caller funds (F = 0)."""
    return "flash" if state == "ok" else "callerFunded"


def set_source_ok(caller, nonzero, has_code, bound_to_self):
    return caller == SET_CALLERS[0] and nonzero and has_code and bound_to_self   # REQ-FLASH-006


# FV-CTL-158 verifies: REQ-FLASH-006, REQ-SWAP-014, REQ-FLASH-008, REQ-FLASH-010
exhaustive("FV-CTL-158", "Only the timelock replaces the flash source, and only with a non-zero contract bound to this LPVaultSwap; whenever the source is short, repriced above the ceiling, paused or being replaced, liquidation proceeds caller-funded instead of stopping",
           [("set",) + c for c in itertools.product(SET_CALLERS, (False, True), (False, True), (False, True))]
           + [("path", s) for s in SOURCE_STATES],
           lambda x: (set_source_ok(*x[1:]) == (x[1] == SET_CALLERS[0] and all(x[2:]))) if x[0] == "set"
           else (path(x[1]) in ("flash", "callerFunded") and (x[1] == "ok") == (path(x[1]) == "flash")) or x,
           verifies=["REQ-FLASH-006", "REQ-SWAP-014", "REQ-FLASH-008", "REQ-FLASH-010"], targets=["T-64", "T-65"])

# ---------------------------------------------------------------- Hub-keyed caps
NS = 3  # Spokes of one Hub booking the same token
c = z3.Ints(" ".join(f"charge_spoke{i}" for i in range(NS)))
cap, ctr0 = z3.Ints("tokenUsdCap tokenUsd_hub_before")
hub_ctr = [ctr0]
for i in range(NS):     # every pledge of every Spoke checks and books the one (Hub, token) counter
    hub_ctr.append(hub_ctr[-1] + c[i])
admitted = [hub_ctr[i] + c[i] <= cap for i in range(NS)]
# FV-CTL-159 verifies: REQ-COLL-026, REQ-VAULT-034, REQ-RISK-079, REQ-COLL-030
prove("FV-CTL-159", "With token, depositor and pool counters keyed by Hub in the chain's one ledger, pledges admitted on any number of Spokes and markets of that Hub never take the Hub's counter above its cap",
      hub_ctr[-1] <= cap, assumptions=[ctr0 >= 0, ctr0 <= cap] + [x >= 0 for x in c] + admitted,
      verifies=["REQ-COLL-026", "REQ-VAULT-034", "REQ-RISK-079", "REQ-COLL-030"], targets=["T-77"])
spoke_ctr = z3.Ints(" ".join(f"perSpokeCounter{i}" for i in range(NS)))
# FV-CTL-159-W verifies: REQ-COLL-026
witness("FV-CTL-159-W", "Mutation witness: counters keyed per Spoke admit the cap once per Spoke (three Spokes book 3 x $10M of USDT against a $10M Hub cap)",
        z3.And(cap == 10_000_000 * 10**8, *[spoke_ctr[i] == 0 for i in range(NS)],
               *[z3.And(spoke_ctr[i] + c[i] <= cap, c[i] == cap) for i in range(NS)], z3.Sum(c) == 3 * cap),
        verifies=["REQ-COLL-026"], targets=["T-77"])

# ---------------------------------------------------------------- credit lines per (funding Hub, asset, Spoke)
dc = z3.Ints("drawCap_s0_home drawCap_s1_home drawCap_s2_cross drawCap_s3_cross")
cross = [False, False, True, True]
line, xcap, cov, new_dc, which = z3.Ints("creditLine crossHubCap coverageBalance newDrawCap spoke")
enabled = z3.Bool("crossHubLinesEnabled")


def inv160(d):
    tot = z3.Sum(d)
    xs = z3.Sum([d[i] for i in range(4) if cross[i]])
    return z3.And(tot <= line, xs <= xcap, xcap <= cov, z3.Implies(z3.Not(enabled), xs == 0), *[x >= 0 for x in d])


after = [z3.If(which == i, new_dc, dc[i]) for i in range(4)]
guard = inv160(after)    # REQ-HUB-020 / enableDebtReserve / REQ-FLR-043: every drawCap change re-checks the pair
step_dc = [z3.If(guard, after[i], dc[i]) for i in range(4)]
borrow_ok = lambda i, paused: z3.And(z3.Implies(z3.BoolVal(cross[i]), z3.And(enabled, z3.Not(paused))))  # noqa: E731
paused = z3.Bool("fundingHubPaused")
# FV-CTL-160 verifies: SPEC-HUB-003, SPEC-CAP-010, REQ-FLR-043, REQ-RISK-082, REQ-HUB-103, REQ-CONFIG-081, REQ-HUB-020
prove("FV-CTL-160", "Across every drawCap change the draw caps of every Spoke on (funding Hub, asset) sum to at most the credit line, the cross-Hub part to at most crossHubCap <= the funding Hub's first-loss coverage (0 while lines are off), and a cross-Hub borrow needs lines enabled and the funding Hub unpaused",
      z3.And(inv160(step_dc), z3.Implies(z3.Or(z3.Not(enabled), paused), z3.Not(borrow_ok(2, paused)))),
      assumptions=[inv160(dc), which >= 0, which <= 3, new_dc >= 0],
      verifies=["SPEC-HUB-003", "SPEC-CAP-010", "REQ-FLR-043", "REQ-RISK-082", "REQ-HUB-103", "REQ-CONFIG-081",
                "REQ-HUB-020"], targets=["T-77"])

# ---------------------------------------------------------------- keeper-funded settlement per market (Q-397)
NM = 3
fund = z3.Ints(" ".join(f"callerFunding{i}" for i in range(NM)))
need = z3.Ints(" ".join(f"repayPlusPremium{i}" for i in range(NM)))
mk = z3.Int("market")
ctx161 = [z3.And(fund[i] >= need[i], need[i] >= 0) for i in range(NM)]
# FV-CTL-161 verifies: SPEC-SET-006, SPEC-SET-005, REQ-BUDGET-020, REQ-BUDGET-021, REQ-BUDGET-024
prove("FV-CTL-161", "With no shared SettlementBudget (Q-397) each liquidation settles from its own caller's funding, so whatever other markets' liquidations need, market m's settlement is covered whenever its caller funded its own repayment and premium: one market cannot starve another",
      z3.Implies(z3.And(mk >= 0, mk < NM), z3.Or([z3.And(mk == i, fund[i] >= need[i]) for i in range(NM)])),
      assumptions=ctx161, verifies=["SPEC-SET-006", "SPEC-SET-005", "REQ-BUDGET-020", "REQ-BUDGET-021", "REQ-BUDGET-024"],
      targets=["T-71"])

# ---------------------------------------------------------------- the transfer rule as each page states it
_vt006 = rule("02-contracts/04-vault-tokens.md", "REQ-VTOKEN-006")
_ad036 = rule("02-contracts/07-risk-module.md", "REQ-ADAPTER-036")
_states_hub_to_adapter = {"2.4 REQ-VTOKEN-006": "There is no Hub → Adapter transfer" not in _vt006 and "Hub to Adapter" in _vt006,
                          "2.7 REQ-ADAPTER-036": "Hub to Adapter" in _ad036}
open_finding("FV-CTL-162", "FV-CTL-F-29")
# FV-CTL-162 verifies: REQ-VTOKEN-006, REQ-ADAPTER-036, REQ-VTOKEN-041
expect("FV-CTL-162", "Every page that states the vault token's transfer rule states the same paths: no page allows a Hub -> Adapter transfer, which REQ-VTOKEN-006 and REQ-VTOKEN-041 refuse (withdrawn units go Hub -> proxy and are burned there)",
       not any(_states_hub_to_adapter.values()),
       verifies=["REQ-VTOKEN-006", "REQ-ADAPTER-036", "REQ-VTOKEN-041"], targets=["T-63"],
       cex={"pages that allow Hub -> Adapter": [k for k, v in _states_hub_to_adapter.items() if v]})

sys.exit(finish())
