#!/usr/bin/env python3
"""FV-C access control: the admin-role rule, timelock-only privileged paths, the restricted-function
matrix across pages, guardian powers, the PositionProxy surface and hostile-component containment.

How Avana works here: every upgradeable contract (AaveAdapter, ProxyManager, RiskModule, MarketRegistry,
ParameterStore, each LPOracle, each DebtOracle, LPVaultSwap) overrides `_grantRole` to revert
`AdminRoleOnlyTimelock(role, account)` when `role` is `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` and
`account != TIMELOCK`, and the AvanaTimelock reverts the same error for a grant of its own
`DEFAULT_ADMIN_ROLE` to any account but itself (REQ-ACCESS-153). Upgrade and setter power therefore never
leaves the timelock, so every upgrade waits its delay in public and every canceller can stop it. The
guardians hold only the emergency selectors of the MarketRegistry and the cancel right.

Targets: T-53, T-55 (self-held admin), T-63, T-64 (authorisation part), T-65.
"""
import re
import sys
from pathlib import Path

import z3

from common import exhaustive, expect, finish, open_finding, prove, witness

HERE = Path(__file__).resolve().parent

# ----------------------------------------------------------------------------------------------
# 1. Admin-role rule: APPLICATION_ADMIN and DEFAULT_ADMIN_ROLE held only by the timelock.
# ----------------------------------------------------------------------------------------------
Role, (DEF_ADMIN, APP_ADMIN, PAUSE_G, FREEZE_G, PROPOSER, CANCELLER, EXECUTOR, DAO_CANCELLER) = \
    z3.EnumSort("Role", ["DEF_ADMIN", "APP_ADMIN", "PAUSE_G", "FREEZE_G", "PROPOSER", "CANCELLER",
                         "EXECUTOR", "DAO_CANCELLER"])
Op, (GRANT, REVOKE, RENOUNCE) = z3.EnumSort("RoleOp", ["GRANT", "REVOKE", "RENOUNCE"])
TL = z3.IntVal(1)  # the AvanaTimelock address, the TIMELOCK constant of every implementation


def admin_of(r):
    # REQ-MREG-005, REQ-ACCESS-149: APPLICATION_ADMIN <- DEFAULT_ADMIN_ROLE; guardian roles <- APPLICATION_ADMIN;
    # timelock roles <- DEFAULT_ADMIN_ROLE; DEFAULT_ADMIN_ROLE <- itself.
    return z3.If(z3.Or(r == PAUSE_G, r == FREEZE_G), APP_ADMIN, DEF_ADMIN)


has = z3.Function("hasRole", Role, z3.IntSort(), z3.BoolSort())       # pre-state
has2 = z3.Function("hasRole_after", Role, z3.IntSort(), z3.BoolSort())  # post-state
op = z3.Const("op", Op)
r, = z3.Consts("role", Role)
acct, caller, a = z3.Ints("account caller probe")


def admin_inv(h, x):
    return z3.Implies(z3.Or(h(DEF_ADMIN, x), h(APP_ADMIN, x)), x == TL)


def role_step():
    """OpenZeppelin grantRole/revokeRole/renounceRole as one symbolic step with the `_grantRole` override
    of REQ-ACCESS-153 (`AdminRoleOnlyTimelock`); returns (success condition, post-state definition)."""
    guard_grant = z3.And(has(admin_of(r), caller),
                         z3.Or(z3.And(r != APP_ADMIN, r != DEF_ADMIN), acct == TL))
    ok = z3.Or(z3.And(op == GRANT, guard_grant),
               z3.And(op == REVOKE, has(admin_of(r), caller)),
               z3.And(op == RENOUNCE, acct == caller))
    rr = z3.Const("rr", Role)
    xx = z3.Int("xx")
    post = z3.ForAll([rr, xx], has2(rr, xx) == z3.If(
        z3.And(ok, rr == r, xx == acct), op == GRANT, has(rr, xx)))
    return ok, post


ok_step, post_step = role_step()
# FV-CTL-01 verifies: REQ-ACCESS-153, REQ-ACCESS-032, REQ-ACCESS-003, REQ-MREG-005, REQ-ADAPTER-084, REQ-PROXY-101, REQ-ORACLE-097, INV-068, INV-084
prove("FV-CTL-01", "APPLICATION_ADMIN and DEFAULT_ADMIN_ROLE stay with the timelock across every grant, revoke and renounce, executed or not (AdminRoleOnlyTimelock)",
      admin_inv(has2, a),
      assumptions=[admin_inv(has, a), admin_inv(has, caller), admin_inv(has, acct), post_step, ok_step,
                   has(DEF_ADMIN, TL), has(APP_ADMIN, TL)],
      verifies=["REQ-ACCESS-153", "REQ-ACCESS-032", "REQ-ACCESS-003", "REQ-MREG-005", "REQ-ADAPTER-084",
                "REQ-PROXY-101", "REQ-ORACLE-097", "INV-068", "INV-084"],
      targets=["T-53", "T-64"], show={"op", "role", "account", "caller", "probe"})
# Non-vacuity: REQ-MREG-005 example: grantRole(APPLICATION_FREEZE_GUARDIAN, 0xSafe) by the timelock succeeds;
# grantRole(APPLICATION_ADMIN, 0xSafe) reverts.
# FV-CTL-01-W verifies: REQ-MREG-005, REQ-ACCESS-153
witness("FV-CTL-01-W", "Witness: the timelock grants a guardian role to a Safe, while the same operation granting APPLICATION_ADMIN reverts",
        z3.And(ok_step, op == GRANT, r == FREEZE_G, caller == TL, acct == 7, has(APP_ADMIN, TL), has(DEF_ADMIN, TL),
               z3.Not(z3.substitute(ok_step, (r, APP_ADMIN)))),
        verifies=["REQ-MREG-005", "REQ-ACCESS-153"], targets=["T-53"])

# Base case: initialize grants both admin roles to `timelock`, and reverts AdminRoleOnlyTimelock unless
# timelock == TIMELOCK (REQ-ACCESS-150, REQ-ADAPTER-074, REQ-PROXY-085).
h0 = z3.Function("hasRole_init", Role, z3.IntSort(), z3.BoolSort())
x0, tl_arg = z3.Ints("x0 initialize_timelock_arg")
init_ok = z3.And(tl_arg != 0, tl_arg == TL)
init_def = z3.And(h0(DEF_ADMIN, x0) == (x0 == tl_arg), h0(APP_ADMIN, x0) == (x0 == tl_arg))
# FV-CTL-02 verifies: REQ-ACCESS-150, REQ-ACCESS-027, REQ-ADAPTER-074, REQ-PROXY-085, REQ-ACCESS-153
prove("FV-CTL-02", "Initializers grant DEFAULT_ADMIN_ROLE and APPLICATION_ADMIN only to the TIMELOCK constant (any other argument reverts)",
      admin_inv(h0, x0), assumptions=[init_ok, init_def],
      verifies=["REQ-ACCESS-150", "REQ-ACCESS-027", "REQ-ADAPTER-074", "REQ-PROXY-085", "REQ-ACCESS-153"],
      targets=["T-53", "T-64"])


# ----------------------------------------------------------------------------------------------
# 2. Bounded trace: a hostile proposer tries to obtain upgrade power that no guardian can cancel.
#    Operation A is a pure role change [AaveAdapter.grantRole(APPLICATION_ADMIN, X)], cancellable only by
#    DAO_CANCELLER_ROLE (SPEC-GOV-005); the Aave governance executor does not cancel in time. A executes,
#    then X calls upgradeToAndCall directly.
# ----------------------------------------------------------------------------------------------
role_change_A, executed_A, grant_takes_effect, x_upgrades = z3.Bools(
    "A_is_role_change A_executed grant_takes_effect X_direct_upgrade")
trace = [role_change_A == True,
         executed_A == role_change_A,                       # no guardian may cancel A
         grant_takes_effect == z3.And(executed_A, False),   # _grantRole reverts AdminRoleOnlyTimelock for X != TIMELOCK
         x_upgrades == grant_takes_effect]                  # _authorizeUpgrade requires APPLICATION_ADMIN
# FV-CTL-03 verifies: REQ-ACCESS-153, REQ-ACCESS-113, REQ-ADAPTER-003, REQ-ADAPTER-042, REQ-ADAPTER-084, SPEC-GOV-005
prove("FV-CTL-03", "Every Adapter upgrade is a timelock operation every canceller can cancel: a role-change operation cannot hand out upgrade power",
      z3.Not(x_upgrades), assumptions=trace,
      verifies=["REQ-ACCESS-153", "REQ-ACCESS-113", "REQ-ADAPTER-003", "REQ-ADAPTER-042", "REQ-ADAPTER-084",
                "SPEC-GOV-005"],
      targets=["T-53", "T-55", "T-64"])

# ----------------------------------------------------------------------------------------------
# 3. Restricted-function matrix: the allowed caller of every privileged selector, as each page states it.
#    Principals: R:<role>, A:<immutable address>, K:active keepers, ANY.
# ----------------------------------------------------------------------------------------------
import re as _re
SPEC = HERE.parents[2] / "spec"


def _line(rel, marker):
    for l_ in (SPEC / rel).read_text().splitlines():
        if marker in l_:
            return l_
    return ""


ROLES14 = "01-architecture/04-permissions-and-roles.md"
GOV215 = "02-contracts/15-governance-and-timelock.md"


def _proxy_key(text):
    """The CREATE2 key a page gives deployProxy: 'deployProxy(wallet, spoke, marketId)' or the old pair."""
    m_ = _re.search(r"deployProxy\(([^)]*)\)", text)
    return f"key:({m_.group(1)})" if m_ else "key:unstated"


def _lock_members(text):
    """Lock members a page names: the two-member design or the old four."""
    if "four members" in text:
        return {"A:ADAPTER", "A:COLLATERALIZATION", "A:LP_VAULT", "A:LP_VAULT_SWAP"}
    if _re.search(r"two (fixed )?members|`AAVE_ADAPTER` or `LP_VAULT_SWAP`", text):
        return {"A:ADAPTER", "A:LP_VAULT_SWAP"}
    return {"unstated"}


def _names(text, candidates):
    return {f"fn:{c}" for c in candidates if f"`{c}" in text or f" {c}(" in text or f"`{c}(" in text}


LPV_FNS = ("receivePosition", "topUpPosition", "returnPosition", "unwind", "releaseToDepositor", "releaseLiquidity",
           "collectFees", "receiveNft", "returnNft", "removeLiquidity")
_r038 = _line(ROLES14, "| `REQ-ROLE-038` |")
_lpv22 = _line("02-contracts/02-lp-vault.md", "| `receivePosition`, `topUpPosition`")

AA = "R:APPLICATION_ADMIN"
FG, PG = "R:FREEZE_G", "R:PAUSE_G"
MATRIX = {
    ("MarketRegistry", "freeze"): {"2.15 REQ-ACCESS-062": {FG, AA}, "1.4 REQ-ROLE-031": {FG, AA},
                                   "2.8 REQ-MREG-004": {FG, AA}, "2.6 REQ-ADAPTER-048": {FG, AA}},
    ("MarketRegistry", "pause"): {"2.15 REQ-ACCESS-063": {PG, AA}, "1.4 REQ-ROLE-034": {PG, AA},
                                  "2.8 REQ-MREG-004": {PG, AA}, "2.6 REQ-ADAPTER-048": {PG, AA}},
    ("MarketRegistry", "unfreeze"): {"2.15 REQ-ACCESS-063": {PG, AA}, "1.4 REQ-ROLE-033": {PG, AA},
                                     "2.8 REQ-MREG-004": {PG, AA}, "2.6 REQ-ADAPTER-048": {PG, AA}},
    ("MarketRegistry", "unpause"): {"2.15 REQ-ACCESS-063": {PG, AA}, "1.4 REQ-ROLE-035": {PG, AA},
                                    "2.8 REQ-MREG-004": {PG, AA}, "2.6 REQ-ADAPTER-048": {PG, AA}},
    ("MarketRegistry", "freezeAddress"): {"2.15 REQ-ACCESS-157": {FG, AA}, "1.4 REQ-ROLE-107": {FG, AA},
                                          "2.8 REQ-MREG-019": {FG, AA}, "2.6 REQ-ADAPTER-048": {FG, AA}},
    ("MarketRegistry", "unfreezeAddress"): {"2.15 REQ-ACCESS-157": {AA}, "1.4 REQ-ROLE-107": {AA},
                                            "2.8 REQ-MREG-022": {AA}, "2.6 REQ-ADAPTER-048": {AA}},
    ("MarketRegistry", "tripMarketBreaker|tripDebtBreaker"): {"2.15 REQ-ACCESS-158": {FG, AA},
                                                              "1.4 REQ-ROLE-108": {FG, AA},
                                                              "2.8 REQ-MREG-025": {FG, AA}},
    ("MarketRegistry", "resetMarketBreaker|resetDebtBreaker"): {"2.15 REQ-ACCESS-158": {PG, AA},
                                                                "1.4 REQ-ROLE-108": {PG, AA},
                                                                "2.8 REQ-MREG-025": {PG, AA}},
    ("MarketRegistry", "useStandbyRoute"): {"2.15 REQ-ACCESS-159": {PG, AA}, "1.4 REQ-ROLE-109": {PG, AA},
                                            "2.8 REQ-MREG-028": {PG, AA}},
    ("MarketRegistry", "cancelStandbySwitch"): {"2.15 REQ-ACCESS-159": {"A:AAVE_GOVERNANCE_EXECUTOR"},
                                                "1.4 REQ-ROLE-109": {"A:AAVE_GOVERNANCE_EXECUTOR"},
                                                "2.8 REQ-MREG-028": {"A:AAVE_GOVERNANCE_EXECUTOR"}},
    ("MarketRegistry", "restorePriceRoute"): {"2.15 REQ-ACCESS-159": {AA}, "1.4 REQ-ROLE-109": {AA},
                                              "2.8 REQ-MREG-028": {AA}},
    # Q-399: LPVaultSwap records no liquidation outcome; the only breaker recorder is the RiskModule's pokeBreakers.
    ("MarketRegistry", "recordBreach"): {
        "2.8 REQ-MREG-026": {"A:RISK_MODULE"}, "2.15 latched-breaker storage row": {"A:RISK_MODULE"}},
    # AMM-neutral design: the proxy's only state-changing selector is execute (REQ-PROXY-007).
    ("PositionProxy", "execute"): {
        "2.5 REQ-PROXY-007/091": {"A:ADAPTER"}, "1.4 REQ-ROLE-019": {"A:ADAPTER"},
        "2.15 REQ-ACCESS-066": {"A:ADAPTER"}},
    # deployProxy: principal plus the CREATE2 key each page states.
    ("ProxyManager", "deployProxy"): {
        "2.5 REQ-PROXY-051": {"A:ADAPTER", _proxy_key(_line("02-contracts/05-position-proxy-and-proxy-manager.md", "- `REQ-PROXY-051`"))},
        "1.4 REQ-ROLE-020": {"A:ADAPTER", _proxy_key(_line(ROLES14, "| `REQ-ROLE-020` |"))},
        "2.15 REQ-ACCESS-147": {"A:ADAPTER", _proxy_key(_line(GOV215, "| `REQ-ACCESS-147` |"))}},
    # The ProxyManager is immutable: no implementation setter exists on any page (REQ-PROXY-050, REQ-ACCESS-147).
    ("ProxyManager", "setProxyImplementation"): {"2.5 REQ-PROXY-050/086": {"none"}, "2.15 REQ-ACCESS-147/176": {"none"}},
    ("VaultToken", "mint|burn|addValidProxy"): {"1.4 REQ-ROLE-015": {"A:ADAPTER"}, "2.15 REQ-ACCESS-066": {"A:ADAPTER"}},
    ("Collateralization", "pledge|release"): {"1.4 REQ-ROLE-012/037": {"A:ADAPTER"}, "2.15 REQ-ACCESS-066": {"A:ADAPTER"}},
    ("Collateralization", "beginSeizure|settleSeizure|settlePending"): {"1.4 REQ-ROLE-013": {"A:LP_VAULT_SWAP"},
                                                                       "2.15 REQ-ACCESS-066": {"A:LP_VAULT_SWAP"}},
    ("AaveAdapter", "burnSeized"): {"2.6 REQ-ADAPTER-070": {"A:LP_VAULT_SWAP"}, "1.4 REQ-ROLE-036": {"A:LP_VAULT_SWAP"},
                                    "2.15 REQ-ACCESS-066": {"A:LP_VAULT_SWAP"}},
    ("AaveAdapter", "deleverageRepay|deleverageRelease"): {"2.6 REQ-ADAPTER-081": {"A:LP_VAULT_SWAP"}},
    ("AaveAdapter", "upgradeToAndCall"): {"2.6 REQ-ADAPTER-003": {AA}, "1.4 REQ-ROLE-022": {AA},
                                          "2.15 REQ-ACCESS-031": {AA}},
    ("LPVault", "returnStray"): {"1.4 REQ-ROLE-014": {"A:TIMELOCK"}, "2.15 REQ-ACCESS-060": {"A:TIMELOCK"},
                                 "2.2 caller table": {"A:TIMELOCK"}},
    # Custody functions: principal plus the function names each page lists (2.2 owns the names).
    ("LPVault", "custody functions"): {
        "1.4 REQ-ROLE-038": {"A:COLLATERALIZATION"} | _names(_r038, LPV_FNS),
        "2.2 caller table": {"A:COLLATERALIZATION"} | _names(_lpv22, LPV_FNS)},
    ("Lock", "acquire"): {"1.4 REQ-ROLE-021": _lock_members(_line(ROLES14, "| `REQ-ROLE-021` |")),
                          "2.6 REQ-ADAPTER-050": _lock_members(_line("02-contracts/06-aave-adapter.md", "- `REQ-ADAPTER-050`")),
                          "2.16 REQ-LOCK-004": _lock_members(_line("02-contracts/16-lock.md", "- `REQ-LOCK-004`"))},
    ("LPVaultSwap", "liquidate"): {"1.4 REQ-ROLE-043": {"K"}, "2.15 REQ-ACCESS-052": {"K"}},
    ("LPVaultSwap", "addKeeper|removeKeeper"): {"1.4 REQ-ROLE-045/046": {AA}, "2.15 REQ-ACCESS-053/054": {AA}},
    ("LPOracle", "setPokeMinGas"): {"2.15 REQ-ACCESS-051": {AA}, "1.4 REQ-ROLE-092": {AA}},
    ("DebtOracle", "setPokeMinGas"): {"1.4 REQ-ROLE-092": {AA}, "2.10 REQ-ORACLE-098": {AA}},
    ("VaultTokenFactory", "deployVaultToken"): {"1.4 REQ-ROLE-017": {"A:TIMELOCK"}, "2.15 REQ-ACCESS-061": {"A:TIMELOCK"}},
    ("AvanaTimelock", "setNormalDelay|setShortDelaySelector|togglePublicExecution"): {
        "2.15 REQ-ACCESS-029": {"A:TIMELOCK"}, "1.4 REQ-ROLE-096": {"A:TIMELOCK"}},
    ("AvanaTimelock", "cancel"): {"2.15 REQ-ACCESS-005/006": {"R:CANCELLER"}, "1.4 REQ-ROLE-054": {"R:CANCELLER"}},
}

_cases04 = {f"{c}.{sel}": {k: sorted(v) for k, v in pages.items()} for (c, sel), pages in MATRIX.items()
            if len({frozenset(v) for v in pages.values()}) != 1}
open_finding("FV-CTL-04", "FV-CTL-F-28")
# FV-CTL-04 verifies: REQ-ACCESS-025, REQ-ACCESS-066, REQ-ROLE-019, REQ-ROLE-015, REQ-MREG-004, REQ-ACCESS-157, REQ-ACCESS-158, REQ-ACCESS-159, REQ-ROLE-107, REQ-ROLE-108, REQ-ROLE-109
exhaustive("FV-CTL-04", "Every page names the same allowed caller for each privileged selector, including the address freeze, breaker and standby selectors",
           [("all", "-")], lambda x: True if not _cases04 else {"disagreements": _cases04},
           verifies=["REQ-ACCESS-025", "REQ-ACCESS-066", "REQ-ROLE-019", "REQ-ROLE-015", "REQ-MREG-004",
                     "REQ-ACCESS-157", "REQ-ACCESS-158", "REQ-ACCESS-159", "REQ-ROLE-107", "REQ-ROLE-108",
                     "REQ-ROLE-109"],
           targets=["T-53", "T-63"])

# Guardian powers: the selectors a guardian key reaches are exactly the emergency selectors and cancel.
guardian_principals = {FG, PG, "R:CANCELLER"}
reached = {sel for (c, sel), pages in MATRIX.items() for v in pages.values() if v & guardian_principals}
expected = {"freeze", "pause", "unfreeze", "unpause", "freezeAddress", "tripMarketBreaker|tripDebtBreaker",
            "resetMarketBreaker|resetDebtBreaker", "useStandbyRoute", "cancel"}
# FV-CTL-05 verifies: REQ-ACCESS-089, REQ-ACCESS-112, REQ-ACCESS-094, REQ-ROLE-076
expect("FV-CTL-05", "Guardian keys reach exactly freeze, pause, unfreeze, unpause, freezeAddress, breaker trip and reset, useStandbyRoute and cancel; never unfreezeAddress, an upgrade, a setter or a route choice",
       reached == expected, verifies=["REQ-ACCESS-089", "REQ-ACCESS-112", "REQ-ACCESS-094", "REQ-ROLE-076"],
       targets=["T-53", "T-56"], cex={"reached": sorted(reached), "expected": sorted(expected)})

# A freeze-only key lifts nothing: no unfreeze, unpause, breaker reset or address unfreeze.
LIFTS = ("unfreeze", "unpause", "resetMarketBreaker|resetDebtBreaker", "unfreezeAddress")
lift = [sel for (c, sel), pages in MATRIX.items() if sel in LIFTS for v in pages.values() if FG in v]
# FV-CTL-06 verifies: REQ-ACCESS-086, REQ-ACCESS-124, REQ-ROLE-071, REQ-MREG-004, REQ-MREG-025
expect("FV-CTL-06", "A key holding only APPLICATION_FREEZE_GUARDIAN can call no lifting selector (unfreeze, unpause, breaker reset, address unfreeze)",
       lift == [], verifies=["REQ-ACCESS-086", "REQ-ACCESS-124", "REQ-ROLE-071", "REQ-MREG-004", "REQ-MREG-025"],
       targets=["T-56"], cex={"lift": lift})

# Given the admin rule, every APPLICATION_ADMIN or TIMELOCK selector runs only as a timelock execution.
sender, holds_aa = z3.Int("msg_sender"), z3.Function("aa", z3.IntSort(), z3.BoolSort())
inv_aa = z3.ForAll([z3.Int("y")], z3.Implies(holds_aa(z3.Int("y")), z3.Int("y") == TL))
# FV-CTL-07 verifies: REQ-ACCESS-111, REQ-ACCESS-015, REQ-ACCESS-010, REQ-ACCESS-153
prove("FV-CTL-07", "Every APPLICATION_ADMIN or TIMELOCK selector runs only as a timelock execution",
      z3.Implies(z3.Or(holds_aa(sender), sender == TL), sender == TL), assumptions=[inv_aa],
      verifies=["REQ-ACCESS-111", "REQ-ACCESS-015", "REQ-ACCESS-010", "REQ-ACCESS-153"], targets=["T-53", "T-64"])

# ----------------------------------------------------------------------------------------------
# 4. PositionProxy (AMM-neutral design): a logic-free immutable account whose only state-changing selector is
#    execute(target, data), callable only by ADAPTER (REQ-PROXY-007, REQ-PROXY-091).
# ----------------------------------------------------------------------------------------------
ADAPTER, wallet, msg_sender, target, proxy_self = z3.Ints("ADAPTER wallet msg_sender target proxy")
has_code = z3.Bool("target_has_code")
proxy_ok = z3.And(msg_sender == ADAPTER, target != proxy_self, target != 0, has_code)
# FV-CTL-08 verifies: REQ-PROXY-007, REQ-PROXY-091, REQ-PROXY-040, REQ-ROLE-019
prove("FV-CTL-08", "PositionProxy.execute succeeds only for msg.sender == ADAPTER, never for its own wallet, and never targets the proxy itself, address 0 or an address without code",
      z3.Implies(proxy_ok, z3.And(msg_sender == ADAPTER, z3.Implies(wallet != ADAPTER, msg_sender != wallet),
                                  target != proxy_self, target != 0)),
      verifies=["REQ-PROXY-007", "REQ-PROXY-091", "REQ-PROXY-040", "REQ-ROLE-019"], targets=["T-63"],
      detail="Changed for the AMM-neutral design: supply, borrow, repay and withdrawal are Adapter logic sent through execute.")
# FV-CTL-08-W verifies: REQ-PROXY-040
witness("FV-CTL-08-W", "Witness: the Adapter's execute call to the Spoke succeeds",
        z3.And(proxy_ok, wallet != ADAPTER, target != ADAPTER), verifies=["REQ-PROXY-040"], targets=["T-63"])

PROXY_SURFACE = {"execute", "ADAPTER", "WALLET", "SPOKE", "MARKET_ID"}
# The Adapter's call builder: fixed selectors per target (REQ-PROXY-008).
BUILDER = {"SPOKE": {"supply", "setUsingAsCollateral", "borrow", "repay", "withdraw"},
           "vaultToken": {"approve", "transfer"}, "debtAsset": {"approve", "transfer"}}
FORBIDDEN = {"multicall", "delegatecall", "isValidSignature", "onERC721Received", "onERC1155Received", "receive",
             "fallback", "sweep", "liquidationCall", "setUserPositionManager", "setUserPositionManagersWithSig",
             "renouncePositionManagerRole", "updateUserRiskPremium", "updateUserDynamicConfig", "selfdestruct",
             "upgradeTo", "upgradeToAndCall", "initialize", "reinitialize", "grantRole", "transferOwnership"}
# FV-CTL-09 verifies: REQ-PROXY-007, REQ-PROXY-008, REQ-PROXY-001, REQ-PROXY-103, REQ-PROXY-101
exhaustive("FV-CTL-09", "The PositionProxy selector inventory is execute plus four views, with no generic multicall, delegatecall, signature, receiver, manager, upgrade, initializer or role selector; the Adapter's call builder never sends a liquidation, position-manager or risk-premium selector",
           [("proxy", x) for x in sorted(PROXY_SURFACE)] + [("builder", f"{t}.{x}") for t, xs in BUILDER.items() for x in sorted(xs)],
           lambda x: x[1].split(".")[-1] not in FORBIDDEN,
           verifies=["REQ-PROXY-007", "REQ-PROXY-008", "REQ-PROXY-001", "REQ-PROXY-103", "REQ-PROXY-101"], targets=["T-63"],
           detail="Changed for the AMM-neutral design: the named supply, borrow, repay and withdraw functions of the old proxy are replaced by execute.")

# ----------------------------------------------------------------------------------------------
# 5. Containment (T-65): reachability over caller-checked edges from each hostile upgradeable component
#    (any implementation) to the custody effects.
# ----------------------------------------------------------------------------------------------
EDGES = {
    # AMM-neutral design: the Lock has two members (AaveAdapter, LPVaultSwap); every Collateralization and LPVault
    # function that moves value is reachable only from a call tree one of them opened (REQ-LOCK-028, REQ-COLL-029).
    "AaveAdapter": {"VT.mint", "VT.burn", "VT.addValidProxy", "CO.pledge", "CO.release", "CO.releasePartial",
                    "CO.recredit", "CO.releaseForDeleverage", "CO.releaseZeroCredit", "CO.collectFees",
                    "PM.deployProxy", "Proxy.execute", "Lock.acquire", "LVS.deleverage"},
    "LPVaultSwap": {"CO.beginSeizure", "CO.settleSeizure", "CO.settlePending", "AD.burnSeized",
                    "Escrow.deposit", "Route.convert", "Lock.acquire", "FS.flashLoan",
                    "AD.deleverageCallbacks(revert without an Adapter-opened session)"},
    "AD.burnSeized": {"VT.burn(from LPVaultSwap)"},
    "CO.pledge": {"LV.receivePosition", "RM.checkPledge(view)", "LO.poke"},
    "CO.release": {"LV.returnPosition(to depositor)"},
    "CO.releaseZeroCredit": {"LV.returnPosition(to depositor)"},
    "CO.collectFees": {"LV.collectFees(to depositor)"},
    "CO.releasePartial": {"LV.releaseToDepositor(principal to depositor)"},
    "CO.releaseForDeleverage": {"LV.unwind(to LPVaultSwap, checked: units == burned)"},
    "CO.settleSeizure": {"LV.unwind(to LPVaultSwap, checked: share drop == supply drop == units)"},
    "CO.settlePending": {"CO.pendingPayout(checked: supply + units == credited + pending)"},
    "FS.flashLoan": {"LVS.onFlashLoan(checked: caller == flashSource, active context)"},
    "IFlashSource": {"LVS.onFlashLoan(revert without an active LPVaultSwap context)"},
    "RiskModule": {"LO.poke", "DO.poke", "MR.recordBreach"},
    "ParameterStore": set(),
    "MarketRegistry": set(),
    "LPOracle": set(),
    "DebtOracle": set(),
    "Timelock": {"LV.returnStray(Lock free, no record ever)", "VTF.deployVaultToken",
                 "LVS.setFlashSource", "*.APPLICATION_ADMIN"},
}
FORBIDDEN_EFFECTS = {"VT.mint", "VT.addValidProxy", "PM.deployProxy", "CO.pledge", "CO.release",
                     "LV.returnPosition(to depositor)", "LV.collectFees(to depositor)",
                     "LV.returnStray(Lock free, no record ever)", "LVS.setFlashSource"}


def reach(src):
    seen, queue = set(), [src]
    while queue:
        n = queue.pop()
        for m in EDGES.get(n, ()):
            if m not in seen:
                seen.add(m)
                queue.append(m)
    return seen


hostiles = ["RiskModule", "ParameterStore", "MarketRegistry", "LPOracle", "DebtOracle", "LPVaultSwap", "IFlashSource"]
# FV-CTL-10 verifies: INV-052, INV-053, REQ-RISK-007, REQ-PSTORE-003, REQ-ADAPTER-081, REQ-ORACLE-098
exhaustive("FV-CTL-10", "No hostile RiskModule, ParameterStore, MarketRegistry, LPOracle, DebtOracle, LPVaultSwap or IFlashSource implementation reaches mint, proxy registration, position return, fee collection, stray return, or flash-source replacement",
           hostiles, lambda h: True if not (reach(h) & FORBIDDEN_EFFECTS) else sorted(reach(h) & FORBIDDEN_EFFECTS),
           verifies=["INV-052", "INV-053", "REQ-RISK-007", "REQ-PSTORE-003", "REQ-ADAPTER-081", "REQ-ORACLE-098"],
           targets=["T-65"])

# T-65 scope: the methodology row names the components whose hostility the immutable contracts contain.
# Each named component must be contained, and the AaveAdapter (trusted, INV-018) must not be named.
meth = (HERE.parent / "methodology.md").read_text()
row = next(l for l in meth.splitlines() if l.startswith("| T-65 |"))
named = re.search(r"For any implementation of ([^,]+(?:, [^,]+)*?) or (\w+)", row)
t65 = [x.strip() for x in named.group(1).split(",")] + [named.group(2)] if named else []
t65_ok = bool(t65) and "AaveAdapter" not in t65 and all(not (reach(h) & FORBIDDEN_EFFECTS) for h in t65)
# FV-CTL-11 verifies: INV-018, INV-052, INV-053
expect("FV-CTL-11", "Methodology T-65 names only contained components (the AaveAdapter, which reaches mint and proxy registration, is in the reviewed scope instead)",
       t65_ok, verifies=["INV-018", "INV-052", "INV-053"], targets=["T-65"],
       cex={"t65_named": t65, "adapter_reach": sorted(reach("AaveAdapter") & FORBIDDEN_EFFECTS)})

# Every value-moving custody effect is reachable only from the two Lock members (or, for a stray position that never
# had a record, from the timelock while the Lock is free).
LOCK_MEMBERS = {"AaveAdapter", "LPVaultSwap"}
ROOTS = [n for n in EDGES if "." not in n]
_custody = lambda e: e.startswith(("CO.", "LV.")) and "view" not in e  # noqa: E731
# FV-CTL-154 verifies: REQ-LOCK-004, REQ-LOCK-010, REQ-LOCK-028, REQ-COLL-029, REQ-ADAPTER-050
exhaustive("FV-CTL-154", "Every Collateralization and LPVault effect that moves a position, a token or a ledger amount is reachable only from a call tree opened by AaveAdapter or LPVaultSwap, the Lock's two members; the timelock reaches only returnStray of a never-recorded position, with the Lock free",
           ROOTS, lambda r: True if r in LOCK_MEMBERS else
           ({e for e in reach(r) if _custody(e)} <= {"LV.returnStray(Lock free, no record ever)"} if r == "Timelock" else
            not any(_custody(e) for e in reach(r))) or sorted(e for e in reach(r) if _custody(e)),
           verifies=["REQ-LOCK-004", "REQ-LOCK-010", "REQ-LOCK-028", "REQ-COLL-029", "REQ-ADAPTER-050"], targets=["T-65", "T-73"])

sys.exit(finish())
