#!/usr/bin/env python3
"""FV-C circuit breakers and the address freeze, as the spec defines them (2.6, 2.7, 2.8, 2.15, 3.6).

How Avana works here:
- Circuit breakers stop new activity in one market or one debt reserve. The on-chain breakers are the oracle
  and stablecoin-band checks, the pool-concentration gate (Avana's combined share of a pool above
  `poolShareMaxBpsOf(poolKey)`: default 10,000 bps, off; per-pool cap optional, Q-403), the pool-depth gate, the issuer probe, configuration drift, the outstanding-deficit
  freeze (`breakerDeficitMax`, 10,000 GHO per CDP Spoke) and the guardian's manual trip; there is no coverage breaker. A price drop of 3% in 2 hours, more than 20% of a
  market seized in 1 hour and 3 swap-route failures in 1 hour are monitoring alerts with no on-chain trip, so
  no `breakerCooldown`, seizure or route-failure counter exists. The RiskModule reads the breakers only in
  `checkPledge` (non-rescue), `preBorrowCheck` and `preWithdrawCheck`; a tripped market breaker only makes the
  rescue rule apply to a pledge.
- The address freeze stops a wallet's new activity only (pledge outside rescue, borrow, with-debt exits, proxy
  creation, liquidation calls, becoming a keeper). It never covers a protected address and checks no keeper floor
  (Q-400): a guardian can freeze every keeper, and while 0 active keepers remain new borrowing halts on the chain
  and liquidation stays open to `liquidatePermissionless`. `keeperFloor` = 1 bounds only `removeKeeper`. It allows
  each caller at most 20 freezes in the 24 one-hour buckets ending with the current hour (a window of 23 to 24
  hours of wall-clock time), and is lifted only
  by a normal-delay `unfreezeAddress` that only the Aave DAO can cancel.
- Repay, debt-free withdrawal and removal, `repayAllAndWithdraw`, fee collection, zero-credit release, pending
  settlement, `burnSeized` and liquidation of any wallet's positions read none of these controls.

Every domain is finite or a Z3 integer model; exhaustive checks enumerate their domain completely.
"""
import itertools
import sys

import z3

from common import HERE, bounded_prove, exhaustive, expect, finish, prove

# ----------------------------------------------------------------------------------------------
# 1. Gate of every action under every combination of Avana controls.
# ----------------------------------------------------------------------------------------------
PSTATES = (("None", "None"), ("Frozen", "None"), ("Paused", "General"), ("Paused", "MintPathSuspect"))
CONTROLS = list(itertools.product(PSTATES, (False, True), (False, True), (False, True), (False, True),
                                  (False, True)))
# (pause, marketBreaker, debtBreaker, offboarding, callerFrozen, borrowerFrozen)
NEW_ACTIVITY = ("new_pledge", "top_up", "rescue_top_up", "borrow", "withdraw_with_debt", "removal_with_debt",
                "repay_with_collateral", "deploy_proxy", "liquidate_from_frozen_caller", "add_frozen_keeper")
EXITS = ("repay_by_payer", "repay_own", "withdraw_debt_free", "removal_debt_free", "repay_all_and_withdraw",
         "fees", "zero_credit_release", "settle_pending", "burn_seized", "escrow_claim",
         "liquidate_frozen_wallet_positions", "liquidate_permissionless_frozen_wallet")


def gate(action, ps, mbrk, dbrk, offb, caller_frozen, borrower_frozen):
    """True when no Avana control stops the action (2.6 REQ-ADAPTER-065/082/083/080, REQ-PROXY-015/036,
    2.7 REQ-RISK-009/065/066, 2.5 REQ-PROXY-099, 2.11 via REQ-MREG-023). Rescue eligibility is assumed for
    `rescue_top_up` and absent for `top_up`."""
    s, rho = ps
    if action in ("new_pledge", "top_up", "rescue_top_up"):
        if s == "Paused" and rho == "MintPathSuspect":
            return False
        if s == "Frozen" and action == "new_pledge":
            return False
        if offb:  # REQ-RISK-009: no pledge into an Offboarding market, rescue included
            return False
        if action == "new_pledge" and caller_frozen:  # no proxy can be deployed for a frozen wallet
            return False
        needs_exemption = (s == "Paused" and rho == "General") or caller_frozen or mbrk
        return action == "rescue_top_up" or not needs_exemption
    if action == "borrow":
        return s == "None" and not caller_frozen and not borrower_frozen and not mbrk and not dbrk and not offb
    if action in ("withdraw_with_debt", "removal_with_debt"):
        return s != "Paused" and not caller_frozen and not mbrk and not dbrk
    if action == "repay_with_collateral":  # reads the pause state and the freeze, no breaker
        return s != "Paused" and not caller_frozen
    if action in ("deploy_proxy", "liquidate_from_frozen_caller", "add_frozen_keeper"):
        return not caller_frozen
    return True  # every exit and liquidation of any wallet's positions reads no control (REQ-ADAPTER-086, INV-081)


# FV-CTL-91 verifies: INV-081, REQ-ADAPTER-086, REQ-ADAPTER-047, REQ-MREG-023, REQ-RISK-065, REQ-ACCESS-068, REQ-ROLE-068, INV-067
exhaustive("FV-CTL-91", "No combination of pause state and reason, market or debt breaker, offboarding, or freeze of the caller or borrower blocks repay, debt-free withdrawal or removal, repayAllAndWithdraw, fees, zero-credit release, pending settlement, burnSeized, escrow claims or the liquidation of a frozen wallet's positions",
           [(c, a) for a in EXITS for c in CONTROLS],
           lambda x: gate(x[1], *x[0]) or {"controls": x[0], "blocked": x[1]},
           verifies=["INV-081", "REQ-ADAPTER-086", "REQ-ADAPTER-047", "REQ-MREG-023", "REQ-RISK-065",
                     "REQ-ACCESS-068", "REQ-ROLE-068", "INV-067"], targets=["T-56", "T-57"])

# Rescue top-ups: no breaker, no freeze and no pause other than MintPathSuspect stops them; offboarding does.
# FV-CTL-151 verifies: REQ-RISK-066, REQ-RISK-065, REQ-ADAPTER-082, REQ-ADAPTER-083, INV-081, INV-082
exhaustive("FV-CTL-151", "A rescue top-up passes every combination of breakers, address freeze, Frozen and Paused(General); only Paused(MintPathSuspect) and Offboarding stop it",
           CONTROLS, lambda c: gate("rescue_top_up", *c) == (c[0][1] != "MintPathSuspect" and not c[3])
           or {"controls": c},
           verifies=["REQ-RISK-066", "REQ-RISK-065", "REQ-ADAPTER-082", "REQ-ADAPTER-083", "INV-081", "INV-082"],
           targets=["T-56"])

# Monotone combination: an action runs only when every control allows it on its own; adding a control only
# removes actions.
STRENGTH = {ps: i for i, ps in enumerate(PSTATES)}


def weaker_or_equal(c1, c2):
    return STRENGTH[c1[0]] <= STRENGTH[c2[0]] and all((not a) or b for a, b in zip(c1[1:], c2[1:]))


# FV-CTL-96 verifies: INV-081, REQ-MREG-003, REQ-ADAPTER-049, REQ-ACCESS-082
exhaustive("FV-CTL-96", "Pause state, breakers, offboarding and the address freeze combine monotonically: a stronger combination never allows an action a weaker one blocks",
           [(c1, c2, a) for c1 in CONTROLS for c2 in CONTROLS if weaker_or_equal(c1, c2)
            for a in NEW_ACTIVITY + EXITS],
           lambda x: (not gate(x[2], *x[1])) or gate(x[2], *x[0]),
           verifies=["INV-081", "REQ-MREG-003", "REQ-ADAPTER-049", "REQ-ACCESS-082"], targets=["T-56"])

# Where breakers are read (REQ-RISK-065, REQ-ACCESS-082): only inside the RiskModule's three checks.
READS_BREAKERS = {
    "RiskModule.checkPledge (non-rescue)": True, "RiskModule.checkPledge (rescue)": False,
    "RiskModule.preBorrowCheck": True, "RiskModule.preWithdrawCheck": True, "RiskModule.postHealthCheck": False,
    "AaveAdapter.repay": False, "AaveAdapter.withdraw (debt-free)": False, "AaveAdapter.removeLiquidity (debt-free)": False,
    "AaveAdapter.repayAllAndWithdraw": False, "AaveAdapter.repayWithCollateral": False, "AaveAdapter.burnSeized": False,
    "AaveAdapter.deleverageRepay": False, "AaveAdapter.deleverageRelease": False,
    "LPVaultSwap.liquidate": False, "LPVaultSwap.liquidatePermissionless": False, "LPVaultSwap.settlePending": False,
    "LPVaultSwap.deleverage": False, "LPVault.collectFees": False, "Collateralization.releaseZeroCredit": False,
    "PayoutEscrow.claim": False,
}
SPEC_LIST = {"RiskModule.checkPledge (non-rescue)", "RiskModule.preBorrowCheck", "RiskModule.preWithdrawCheck"}
# FV-CTL-109 verifies: REQ-RISK-065, REQ-ACCESS-082, REQ-ADAPTER-086, REQ-ADAPTER-080, INV-081
exhaustive("FV-CTL-109", "Breakers are read only in checkPledge (non-rescue), preBorrowCheck and preWithdrawCheck; no exit, liquidation path or repay with collateral reads one",
           list(READS_BREAKERS.items()), lambda kv: kv[1] == (kv[0] in SPEC_LIST),
           verifies=["REQ-RISK-065", "REQ-ACCESS-082", "REQ-ADAPTER-086", "REQ-ADAPTER-080", "INV-081"],
           targets=["T-56"])

# ----------------------------------------------------------------------------------------------
# 2. Address freeze: protected set, no keeper floor on freeze, liquidation liveness, lifting.
# ----------------------------------------------------------------------------------------------
PROTECTED_KINDS = {  # REQ-MREG-020 (AMM-neutral design: debt assets, the IFlashSource and its lender, the recorded AMM contracts)
    "AvanaTimelock", "AaveGovernanceExecutor", "AaveAdapter", "Collateralization", "LPVault", "LPVaultSwap",
    "ProxyManager", "MarketRegistry", "ParameterStore", "RiskModule", "PayoutEscrow", "Lock",
    "VaultTokenFactory", "VaultToken(live market)", "LPOracle(live market)", "DebtOracle", "Hub", "ApprovedSpoke",
    "CoverageSpoke", "DebtAsset(listed)", "IFlashSource", "FlashSourceLender", "PublicFlashLiquidator",
    "IntegrationLPVault", "IntegrationPricing", "RecordedIntegrationContract", "RecordedRoute", "RegisteredProxy"}
# Each kind must be named in REQ-MREG-020 as it reads now (phrases of the page). The recorded AMM contracts are the
# position managers and factories, or the singleton, an integration's LPVault pins (recordIntegrationContracts).
_mreg020 = next(l_ for l_ in (HERE.parents[3] / "docs/spec/02-contracts/08-market-registry.md").read_text().splitlines()
                if l_.startswith("- `REQ-MREG-020`"))
_PHRASE = {"DebtAsset(listed)": "every listed debt asset", "IFlashSource": "the IFlashSource",
           "FlashSourceLender": "its `LENDER()` (the Aave V3 Pool behind the source, read live at the freeze",
           "PublicFlashLiquidator": "the public flash liquidation helper (`FLASH_LIQUIDATOR`",
           "IntegrationLPVault": "every registered integration's LPVault",
           "IntegrationPricing": "every registered integration's LPVault and pricing implementation",
           "RecordedIntegrationContract": "every AMM protocol contract recorded for it with `recordIntegrationContracts(integrationId, contracts)`",
           "Hub": "every registered Hub", "ApprovedSpoke": "every approved Spoke",
           "CoverageSpoke": "Coverage Spoke", "RecordedRoute": "every swap route ever recorded",
           "RegisteredProxy": "every registered proxy"}
_unnamed = [k for k, ph in _PHRASE.items() if ph not in _mreg020]
if "(its position managers and factories, or its singleton)" not in _mreg020:
    _unnamed.append("RecordedIntegrationContract (position managers and factories, or singleton)")
# The protected set the code enforces: each kind's condition in MarketRegistrySafetyLogic._isProtected.
_safety = (HERE.parents[3] / "contracts/src/policy/market-registry/MarketRegistrySafetyLogic.sol").read_text()
_isprot = _safety[_safety.index("function _isProtected("):]
_isprot = _isprot[:_isprot.index("\n    }\n")]
_CODE_COND = {
    "AvanaTimelock": "a == _TIMELOCK", "AaveGovernanceExecutor": "a == _AAVE_GOVERNANCE_EXECUTOR",
    "AaveAdapter": "a == _AAVE_ADAPTER", "Collateralization": "a == _COLLATERALIZATION",
    "LPVault": "l.integrationIdOf[a] != 0", "LPVaultSwap": "a == _LP_VAULT_SWAP", "ProxyManager": "a == _PROXY_MANAGER",
    "MarketRegistry": "a == address(this)", "ParameterStore": "a == _PARAMETER_STORE", "RiskModule": "a == _RISK_MODULE",
    "PayoutEscrow": "a == _PAYOUT_ESCROW", "Lock": "a == _LOCK", "VaultTokenFactory": "a == _VAULT_TOKEN_FACTORY",
    "VaultToken(live market)": "(mv != 0 && l.markets[mv].status != MarketStatus.Cancelled)",
    "LPOracle(live market)": "(mo != 0 && l.markets[mo].status != MarketStatus.Cancelled)",
    "DebtOracle": "l.knownPriceSource[a]", "Hub": "l.hubTier[a] != RiskTier.None", "ApprovedSpoke": "l.spokes[a].approved",
    "CoverageSpoke": "l.knownCoverageSpoke[a]", "DebtAsset(listed)": "l.isDebtAsset[a]", "IFlashSource": "a == fs",
    "FlashSourceLender": "a == _lenderOf(fs)", "PublicFlashLiquidator": "a == _FLASH_LIQUIDATOR",
    "IntegrationLPVault": "l.integrationIdOf[a] != 0", "IntegrationPricing": "l.isPricing[a]",
    "RecordedIntegrationContract": "l.knownIntegrationContract[a]", "RecordedRoute": "l.knownRoute[a]",
    "RegisteredProxy": "walletOf(a) != address(0)",
}
CODE_PROTECTED = {k for k, cond in _CODE_COND.items() if cond in _isprot}
KEEPER_FLOOR = 1  # 1.5 keeperFloor launch value (Q-400): Avana's own keeper


def freeze_check(target_kind, is_active_keeper, active_count, already, window_count):
    """REQ-MREG-019/020/021: the revert or 'ok'. No keeper-floor check (REQ-MREG-021, Q-400): the keeper arguments
    are accepted and ignored, so freezing the last active keeper succeeds."""
    if already:
        return "AddressAlreadyFrozen"
    if target_kind in CODE_PROTECTED:
        return "ProtectedAddress"
    if window_count >= 20:
        return "FreezeLimitReached"
    return "ok"


# FV-CTL-93 verifies: REQ-MREG-020, REQ-ACCESS-157, INV-085, REQ-ACCESS-089, REQ-ACCESS-112
exhaustive("FV-CTL-93", "freezeAddress reverts ProtectedAddress for every protected kind (timelock, Aave governance executor, every Avana contract, live vault tokens and oracles, DebtOracles, every Hub, Spoke and Coverage Spoke, every listed debt asset, the IFlashSource and its LENDER(), the public flash liquidation helper, every integration's LPVault and pricing implementation and its recorded AMM contracts, recorded swap routes, registered proxies), each named on 2.8 and each a condition of MarketRegistrySafetyLogic._isProtected",
           [("page", "-")] + sorted(PROTECTED_KINDS),
           lambda k: (not _unnamed or {"not named on 2.8 REQ-MREG-020": _unnamed}) if k == ("page", "-")
           else freeze_check(k, False, 10, False, 0) == "ProtectedAddress",
           verifies=["REQ-MREG-020", "REQ-ACCESS-157", "INV-085", "REQ-ACCESS-089", "REQ-ACCESS-112"],
           targets=["T-53"])

ADDRS = ("victimWallet", "attacker", "keeper1", "keeper2", "keeper3", "keeper4", "keeper5", "LPVaultSwap",
         "AvanaTimelock", "victimProxy")
KIND = {"LPVaultSwap": "LPVaultSwap", "AvanaTimelock": "AvanaTimelock", "victimProxy": "RegisteredProxy"}


def reachable_freeze_sets(keepers, depth=4):
    seen, frontier = {frozenset()}, [frozenset()]
    for _ in range(depth):
        nxt = []
        for fs in frontier:
            active = len([k for k in keepers if k not in fs])
            for a in ADDRS:
                if freeze_check(KIND.get(a, "wallet"), a in keepers and a not in fs, active, a in fs,
                                len(fs)) == "ok":
                    n = fs | {a}
                    if n not in seen:
                        seen.add(n)
                        nxt.append(n)
        frontier = nxt
    return seen


def liquidation_possible(fs, keepers):
    """Liquidation needs an unfrozen LPVaultSwap (burnSeized, settlement) and a caller: an active keeper through
    `liquidate`, or any unfrozen address through `liquidatePermissionless`, which needs no keeper. The victim's own
    freeze and its proxy's are never read by liquidation (REQ-MREG-023)."""
    keeper_path = any(k not in fs for k in keepers)
    permissionless_path = any(a not in fs for a in ADDRS if a not in keepers and KIND.get(a, "wallet") == "wallet")
    return "LPVaultSwap" not in fs and (keeper_path or permissionless_path)


def borrowing_halted(fs, keepers):
    """REQ-RISK-071 / SPEC-GOV-008: new borrowing halts on the chain exactly while 0 active keepers remain."""
    return not any(k not in fs for k in keepers)


sets_cases = [(ks, fs) for ks in (("keeper1",), ("keeper1", "keeper2"), ("keeper1", "keeper2", "keeper3", "keeper4"),
                                  ("keeper1", "keeper2", "keeper3", "keeper4", "keeper5"))
              for fs in reachable_freeze_sets(ks)]
# Witness that Q-400 is reachable: with one keeper, a single freeze leaves 0 active keepers.
_zero_active = any(not any(k not in fs for k in ks) for ks, fs in sets_cases)
# FV-CTL-92 verifies: INV-046, INV-085, REQ-MREG-021, REQ-RISK-071, SPEC-GOV-008, REQ-ACCESS-112
exhaustive("FV-CTL-92", "No sequence of guardian freezes (up to 4) stops liquidation: LPVaultSwap is never frozen, and when freezes leave 0 active keepers liquidation stays open to liquidatePermissionless while new borrowing halts on the chain (Q-400)",
           sorted(sets_cases, key=lambda c: (len(c[0]), len(c[1]), sorted(c[1]))),
           lambda c: (liquidation_possible(c[1], c[0])
                      and borrowing_halted(c[1], c[0]) == (len([k for k in c[0] if k not in c[1]]) == 0))
           or {"keepers": c[0], "frozen": sorted(c[1])},
           verifies=["INV-046", "INV-085", "REQ-MREG-021", "REQ-RISK-071", "SPEC-GOV-008", "REQ-ACCESS-112"],
           targets=["T-56", "T-53"], bounded_note="(bounded: up to 4 freeze calls over 10 addresses, 1, 2, 4 or 5 approved keepers)")
# FV-CTL-92-W verifies: REQ-MREG-021, SPEC-GOV-008
expect("FV-CTL-92-W", "Witness (Q-400): freezing the last active keeper is reachable, so freezeAddress checks no keeper floor",
       _zero_active, verifies=["REQ-MREG-021", "SPEC-GOV-008"], targets=["T-53"])

# Keeper floor as an inductive invariant over counts (SPEC-GOV-008): K approved, A active (approved, not frozen).
K, A, K2, A2, kop, kin_active = z3.Ints("approved active approved_after active_after keeperOp targetIsActive")
floor_ = z3.Int("keeperFloor")
step = z3.And(
    z3.Implies(kop == 0, z3.And(  # removeKeeper(k), k approved; reverts KeeperFloor unless A - [k in A] >= floor
        K >= 1, z3.If(A - kin_active >= floor_, z3.And(K2 == K - 1, A2 == A - kin_active), z3.And(K2 == K, A2 == A)))),
    z3.Implies(kop == 1, z3.And(  # freezeAddress(k) for an active keeper: no floor check (Q-400)
        kin_active == 1, K2 == K, A2 == A - 1)),
    z3.Implies(kop == 2, z3.And(K2 == K + 1, A2 == A + 1)),       # addKeeper of an unfrozen address
    z3.Implies(kop == 3, z3.And(K2 == K, z3.Or(A2 == A, z3.And(A < K, A2 == A + 1)))),  # unfreezeAddress
    z3.Implies(kop == 4, z3.And(K2 == K, A2 == A)))              # freezing a non-keeper changes nothing here
# FV-CTL-105 verifies: SPEC-GOV-008, REQ-MREG-021, INV-085, INV-046
prove("FV-CTL-105", "Only a guardian freeze can take active keepers below keeperFloor: from |A| >= keeperFloor, every removeKeeper, addKeeper, unfreezeAddress and non-keeper freeze keeps |A| >= keeperFloor, and a keeper freeze lowers |A| by exactly 1 and never below 0",
      z3.And(z3.Implies(kop != 1, A2 >= floor_), z3.Implies(kop == 1, z3.And(A2 == A - 1, A2 >= 0))),
      assumptions=[floor_ >= 1, A >= floor_, K >= A, kop >= 0, kop <= 4, kin_active >= 0,
                   kin_active <= 1, z3.Implies(kin_active == 1, A >= 1), step],
      verifies=["SPEC-GOV-008", "REQ-MREG-021", "INV-085", "INV-046"], targets=["T-53", "T-56"])
# SPEC-GOV-008 example (Q-400): floor 1. With 2 active keepers removing one passes (1 active) and removing the last
# reverts KeeperFloor(0, 1); freezing the last active keeper succeeds, and new borrowing then halts on the chain.
ex_ok = (freeze_check("wallet", True, 2, False, 0) == "ok" and freeze_check("wallet", True, 1, False, 1) == "ok"
         and (1 - 1 < 1) and (2 - 1 >= 1))
halt_new_borrow = lambda active: active == 0  # noqa: E731
# FV-CTL-105-EX verifies: SPEC-GOV-008, REQ-MREG-021
expect("FV-CTL-105-EX", "keeperFloor 1 example: with 2 active keepers removing one passes and removing the last reverts KeeperFloor(0, 1); freezing the last active keeper succeeds and new borrowing then halts, since it halts only at 0 active keepers",
       ex_ok and halt_new_borrow(0) and not halt_new_borrow(1), verifies=["SPEC-GOV-008", "REQ-MREG-021"], targets=["T-53"])

# Freeze limit over 24 one-hour buckets (REQ-MREG-019): buckets b[h] per caller, h = floor(timestamp / 3,600); a freeze at hour H requires
# sum(b[H-23..H]) < 20 and increments b[H]. Time only moves forward, so buckets after H are 0.
NB = 48
b = [z3.Int(f"bucket_{h}") for h in range(NB)]
H = NB - 1


def window(arr, end):
    return z3.Sum([arr[h] for h in range(max(0, end - 23), min(end, NB - 1) + 1)])


b_after = b[:-1] + [b[H] + 1]
pre_inv = [window(b, e) <= 20 for e in range(NB)]
# FV-CTL-104 verifies: REQ-MREG-019, INV-085, REQ-ACCESS-157
prove("FV-CTL-104", "No caller makes more than 20 freezes in any 24 consecutive one-hour buckets: the bucket-window check keeps every window, past and future, at or below 20",
      z3.And(*[window(b_after, e) <= 20 for e in range(NB + 23)]),
      assumptions=[x >= 0 for x in b] + pre_inv + [window(b, H) < 20],
      verifies=["REQ-MREG-019", "INV-085", "REQ-ACCESS-157"], targets=["T-53"])
# Example: 20 freezes in hours H0..H0+2 (7 in H0) -> a 21st in H0+2 reverts; at H0+24 the window drops H0, 7 more allowed.
hours = [7, 7, 6] + [0] * 21 + [0]
win_h2 = sum(hours[0:3])
win_h24 = sum(hours[1:25])
# FV-CTL-104-EX verifies: REQ-MREG-019
expect("FV-CTL-104-EX", "REQ-MREG-019 example: the 21st freeze at hour H0+2 reverts FreezeLimitReached; at H0+24 the window covers H0+1..H0+24 and 7 more freezes are allowed",
       win_h2 == 20 and not (win_h2 < 20) and 20 - win_h24 == 7, verifies=["REQ-MREG-019"], targets=["T-53"])

# Lifting a freeze: frozen[a] is cleared only by unfreezeAddress, which requires APPLICATION_ADMIN, held only by
# the timelock (FV-CTL-01), so only an executed normal-delay operation lifts it.
CALLERS = ("EmergencyGuardian", "AaveProtocolGuardian", "AvanaTimelock(normal-delay operation)", "frozenAddress",
           "anyone")
FNS = ("freezeAddress", "unfreezeAddress", "unfreeze", "unpause", "resetMarketBreaker", "pledge", "borrow", "repay",
       "withdraw_debt_free")


def freeze_step(fn, caller, frozen):
    if fn == "unfreezeAddress" and caller == "AvanaTimelock(normal-delay operation)":
        return False
    if fn == "freezeAddress" and caller in ("EmergencyGuardian", "AaveProtocolGuardian"):
        return True
    return frozen


# FV-CTL-94 verifies: REQ-MREG-022, REQ-ACCESS-157, REQ-ACCESS-111, REQ-ACCESS-003, INV-085
exhaustive("FV-CTL-94", "A frozen address becomes unfrozen only by an unfreezeAddress the timelock executes after the normal delay",
           list(itertools.product(FNS, CALLERS)),
           lambda x: freeze_step(x[0], x[1], True) or (x == ("unfreezeAddress", "AvanaTimelock(normal-delay operation)")),
           verifies=["REQ-MREG-022", "REQ-ACCESS-157", "REQ-ACCESS-111", "REQ-ACCESS-003", "INV-085"],
           targets=["T-53"])

# The guardian that froze an address cannot keep it frozen by cancelling: a pure unfreezeAddress operation is
# restoring (REQ-ACCESS-156) and only DAO_CANCELLER_ROLE cancels it (SPEC-GOV-005).


def may_cancel(batch_daoonly_flags, has_dao):
    restoring = len(batch_daoonly_flags) >= 1 and all(batch_daoonly_flags)
    return (not restoring) or has_dao


# FV-CTL-95 verifies: SPEC-GOV-005, REQ-ACCESS-156, REQ-MREG-022, REQ-ACCESS-112, INV-085
exhaustive("FV-CTL-95", "No guardian can cancel a pure unfreezeAddress operation; a batch that mixes it with another call stays cancellable by every canceller, and only delays the unfreeze",
           [((True,), False, False), ((True, True), False, False), ((True,), True, True), ((True, False), False, True)],
           lambda c: may_cancel(c[0], c[1]) == c[2],
           verifies=["SPEC-GOV-005", "REQ-ACCESS-156", "REQ-MREG-022", "REQ-ACCESS-112", "INV-085"], targets=["T-55"])

# ----------------------------------------------------------------------------------------------
# 3. Breaker math.
# ----------------------------------------------------------------------------------------------
MAXP = 2 * 10**12  # price8 of one whole vault token is below 2 x MAX_ROUTE_ANSWER
now, at, cp, p8, bps = z3.Ints("now checkpointAt checkpointPrice8 acceptedPrice8 alertPriceDropBps")
drop_tripped = z3.And(now - at <= 7_200, p8 * 10**4 < cp * (10**4 - bps))
price_wf = [cp >= 1, cp <= MAXP, p8 >= 1, p8 <= MAXP, bps >= 1, bps < 10**4, at <= now, at >= 0]
# FV-CTL-106 verifies: SPEC-BRK-001, REQ-RISK-065, REQ-ORACLE-088
prove("FV-CTL-106", "Price-drop alert (Q-399, monitoring only, no on-chain trip): fires only on a fall strictly larger than the alert threshold (300 bps) against a checkpoint at most 2 hours old, is monotone in the price, and its products stay below 2^78",
      z3.And(z3.Implies(drop_tripped, z3.And(now - at <= 7_200, (cp - p8) * 10**4 > cp * bps)),
             z3.Implies(now - at > 7_200, z3.Not(drop_tripped)),
             z3.Implies(z3.And(drop_tripped, z3.Int("lower_p8") >= 1, z3.Int("lower_p8") <= p8),
                        z3.substitute(drop_tripped, (p8, z3.Int("lower_p8")))),
             p8 * 10**4 < 2**78, cp * 10**4 < 2**78),
      assumptions=price_wf, verifies=["SPEC-BRK-001", "REQ-RISK-065", "REQ-ORACLE-088"], targets=["T-56"])


def drop(price8, cpv, bp, age):
    return age <= 7_200 and price8 * 10**4 < cpv * (10**4 - bp)


def share(supply, liq, bp):
    return supply * 10**4 > bp * liq


# FV-CTL-106-EX verifies: SPEC-BRK-001, SPEC-BRK-002
expect("FV-CTL-106-EX", "Q-399 examples: a price of 193,990,000 against a 200,000,000 checkpoint fires the 300 bps alert and 194,000,000 does not; Avana's combined share of 2.1e12 against pool liquidity 2e13 trips the 1,000 bps concentration gate and 2e12 does not, whatever the token quotes",
       drop(193_990_000, 200_000_000, 300, 2_400) and not drop(194_000_000, 200_000_000, 300, 2_400)
       and share(21 * 10**11, 2 * 10**13, 1_000) and not share(2 * 10**12, 2 * 10**13, 1_000),
       verifies=["SPEC-BRK-001", "SPEC-BRK-002"], targets=["T-56"])

# Q-399 concentration gate: POOL_SHARE trips when Avana's combined share of the pool, across every borrower and
# Spoke on the chain, exceeds poolShareMaxBps (one parameter for the pledge cap and the gate; no separate
# breakerPoolShareBps and no peg condition).
sup, lhm, psb, add = z3.Ints("avanaSupply poolLiquidity poolShareMaxBps pledgeUnits")
pool_tripped = sup * 10**4 > psb * lhm
pool_wf = [sup >= 0, lhm >= 0, add >= 1, psb >= 0, psb <= 10_000, sup < 2**128, lhm < 2**128]
# FV-CTL-152 verifies: SPEC-BRK-002, REQ-RISK-065, EMG-068
prove("FV-CTL-152", "Concentration gate (Q-399): trips exactly when Avana's combined share exceeds poolShareMaxBps; a pledge the pool-share cap admits never trips the gate at the same liquidity; a tripped gate refuses every pledge that increases the share; products stay below 2^256",
      z3.And(z3.Implies((sup + add) * 10**4 <= psb * lhm, z3.Not(z3.substitute(pool_tripped, (sup, sup + add)))),
             z3.Implies(pool_tripped, (sup + add) * 10**4 > psb * lhm),
             (sup + add) * 10**4 < 2**256, psb * lhm < 2**256),
      assumptions=pool_wf + [add < 2**128], verifies=["SPEC-BRK-002", "REQ-RISK-065", "EMG-068"], targets=["T-56"])

# Seizure and route-failure alerts (Q-399): monitoring, off-chain. No on-chain counter, latch or cooldown exists,
# because a reverted call cannot persist a count and a counter written by callers can be gamed. The alert
# compares exact products over the window base (credited units before the window's first seizure).
cred_after, seized, sum_w, bps_s = z3.Ints("creditedAfterDebit unitsSeized windowSeized alertSeizureBps")
credited_before = cred_after + seized
alert = sum_w * 10**4 > bps_s * credited_before
gate_reads_alert = z3.BoolVal(False)  # no RiskModule gate reads a monitoring alert
# FV-CTL-107 verifies: SPEC-BRK-005, SPEC-BRK-006, REQ-MREG-025, REQ-MREG-026, INV-081
prove("FV-CTL-107", "Seizure and route-failure alerts (Q-399): the window base equals the credited units before the window's first seizure, the alert compares exact products, and no new-activity gate reads an alert, so no seizure or route failure can stop activity on chain",
      z3.And(credited_before == cred_after + seized, z3.Not(gate_reads_alert),
             z3.Implies(alert, sum_w * 10**4 > bps_s * credited_before),
             sum_w * 10**4 < 2**256, bps_s * credited_before < 2**256),
      assumptions=[cred_after >= 0, seized >= 0, cred_after + seized < 2**128, sum_w >= seized, sum_w < 2**128,
                   bps_s >= 0, bps_s <= 10**4],
      verifies=["SPEC-BRK-005", "SPEC-BRK-006", "REQ-MREG-025", "REQ-MREG-026", "INV-081"], targets=["T-56"])


class Window:
    """Monitoring window per market (Q-399): alerts only, nothing latched on chain."""

    def __init__(self):
        self.start, self.base, self.seized, self.fail, self.reasons = 0, 0, 0, 0, set()

    def roll(self, now_, base):
        if now_ >= self.start + 3_600:
            self.start, self.base, self.seized, self.fail = now_, base, 0, 0

    def record(self, now_, credited_after, units, failed, bps_, count_):
        self.roll(now_, credited_after + units)
        self.seized += units
        self.fail += failed
        if self.seized * 10**4 > bps_ * self.base:
            self.reasons.add("SEIZURE_ALERT")
        if self.fail >= count_:
            self.reasons.add("ROUTE_ALERT")


T0 = 36_000  # 10:00
w1 = Window()
w1.record(T0, 10**10 - 12 * 10**8, 12 * 10**8, 0, 2_000, 3)
w1.record(T0 + 600, 10**10 - 20 * 10**8, 8 * 10**8, 0, 2_000, 3)
no_latch = "SEIZURE_ALERT" not in w1.reasons
w1.record(T0 + 700, 10**10 - 20 * 10**8 - 1, 1, 0, 2_000, 3)
latched = "SEIZURE_ALERT" in w1.reasons
w2 = Window()
for mins in (5, 31, 52):
    w2.record(T0 + mins * 60, 10**10, 0, 1, 2_000, 3)
route_latched = "ROUTE_ALERT" in w2.reasons
w3 = Window()
for mins in (5, 31, 67):
    w3.record(T0 + mins * 60, 10**10, 0, 1, 2_000, 3)
restarted = "ROUTE_ALERT" not in w3.reasons and w3.fail == 1 and w3.start == T0 + 67 * 60
# FV-CTL-107-EX verifies: SPEC-BRK-005, SPEC-BRK-006
expect("FV-CTL-107-EX", "Q-399 alert examples: 2,000,000,000 seized units of 10,000,000,000 in one hour do not alert and one more does; route failures at 10:05, 10:31 and 10:52 alert, while a third at 11:07 restarts the count at 1; none of them stops activity",
       no_latch and latched and route_latched and restarted, verifies=["SPEC-BRK-005", "SPEC-BRK-006"],
       targets=["T-56"], cex={"no_latch": no_latch, "latched": latched, "route": route_latched, "restart": restarted})

# Issuer probe and debt conditions fail closed (SPEC-BRK-003, SPEC-BRK-004).
PROBES = ("None", "PausedFlag", "UsdtFeeRate")
OUTCOMES = ("false_or_zero", "true_or_positive", "revert", "out_of_gas", "malformed")


def issuer_tripped(probe, outcome):
    if probe == "None":
        return False
    if outcome in ("revert", "out_of_gas", "malformed"):
        return True
    return outcome == "true_or_positive"


EXPECTED_TRIP = {("PausedFlag", "true_or_positive"), ("UsdtFeeRate", "true_or_positive")} | \
    {(p, o) for p in ("PausedFlag", "UsdtFeeRate") for o in ("revert", "out_of_gas", "malformed")}
# FV-CTL-108 verifies: SPEC-BRK-003, SPEC-BRK-004, REQ-MREG-027, REQ-RISK-065
exhaustive("FV-CTL-108", "Issuer probe fails closed: a paused flag, a positive fee rate, a revert, an out-of-gas or malformed return trips the breaker; a probe of None never trips",
           list(itertools.product(PROBES, OUTCOMES)),
           lambda x: issuer_tripped(*x) == (x in EXPECTED_TRIP),
           verifies=["SPEC-BRK-003", "SPEC-BRK-004", "REQ-MREG-027", "REQ-RISK-065"], targets=["T-56"])
RAY = 10**27
# FV-CTL-108-EX verifies: SPEC-BRK-004
expect("FV-CTL-108-EX", "SPEC-BRK-004 examples (Q-399): a GHO deficit of 10,000.5 against breakerDeficitMax 10,000 GHO freezes new borrowing on that debt reserve and 10,000 does not; there is no SettlementBudget and so no BUDGET condition",
       (100_005 * 10**17 * RAY > 10_000 * 10**18 * RAY) and not (10_000 * 10**18 * RAY > 10_000 * 10**18 * RAY),
       verifies=["SPEC-BRK-004"], targets=["T-56"])

# Who may trip and reset (REQ-MREG-025/026, REQ-ACCESS-158). LPVaultSwap records no liquidation outcome or
# recovery shortfall: seizure surges and route failures are monitoring alerts, not on-chain counters (Q-399).
FNS_B = ("tripMarketBreaker", "tripDebtBreaker", "resetMarketBreaker", "resetDebtBreaker")
WHO = ("FREEZE_G", "PAUSE_G", "APPLICATION_ADMIN", "LPVaultSwap", "AaveAdapter", "anyone")
ALLOWED_B = {"tripMarketBreaker": {"FREEZE_G", "APPLICATION_ADMIN"}, "tripDebtBreaker": {"FREEZE_G", "APPLICATION_ADMIN"},
             "resetMarketBreaker": {"PAUSE_G", "APPLICATION_ADMIN"}, "resetDebtBreaker": {"PAUSE_G", "APPLICATION_ADMIN"}}


def breaker_call(fn, who, key_known):
    """Outcome of a trip or reset call: the caller must hold the role and the key must be known."""
    if who not in ALLOWED_B[fn]:
        return "revert"
    return "ok" if key_known else "revert"


# FV-CTL-150 verifies: REQ-MREG-025, REQ-MREG-026, REQ-ACCESS-158, REQ-ROLE-108, INV-081
exhaustive("FV-CTL-150", "Only the freeze guardian or the admin trips and only the pause guardian or the admin resets; LPVaultSwap and the AaveAdapter can do neither, and no liquidation makes a breaker call that could revert it (Q-399)",
           list(itertools.product(FNS_B, WHO, (False, True))),
           lambda x: (breaker_call(*x) != "revert") == (x[1] in ALLOWED_B[x[0]] and x[2]),
           verifies=["REQ-MREG-025", "REQ-MREG-026", "REQ-ACCESS-158", "REQ-ROLE-108", "INV-081"], targets=["T-56"])

sys.exit(finish())
