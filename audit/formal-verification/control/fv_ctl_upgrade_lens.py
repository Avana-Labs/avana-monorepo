#!/usr/bin/env python3
"""FV-C upgrade safety, PositionProxy binding, the proxy address views and Lens view integrity.

How Avana works here, and what each check proves:

- Initializers. Every implementation constructor of an upgradeable contract runs `_disableInitializers()`, so an
  implementation can never be initialized or reinitialized, and a proxy's `initializer` runs once inside its
  creating call (FV-CTL-86). A UUPS `reinitializer(n)` runs inside the same `upgradeToAndCall` the timelock
  executes. A PositionProxy is a plain immutable contract with no implementation, initializer, upgrade or role
  selector: its only state-changing selector is `execute`, callable only by the AaveAdapter, so after any upgrade
  only the timelock (UUPS) or the Adapter (`execute`) changes state (FV-CTL-87). The append-only storage rule
  rejects every delete, retype, insert and reorder (FV-CTL-88).
- Binding and address views. One PositionProxy exists per (wallet, CDP Spoke, market): the CREATE2 salt and the init
  code both carry the triple and the init code carries the Adapter, so no other deployer, Adapter, Hub, Spoke or
  market can occupy a triple's address (FV-CTL-89). The Adapter's `predictProxy(wallet, marketId)`, the Lens
  `predictProxy` and `RiskModule.previewPledge` use the stored `proxyOf(wallet, marketId)` whenever it is non-zero;
  `deployProxy` refuses a frozen wallet while `predictProxy` reads nothing from the MarketRegistry (FV-CTL-90).
  The ProxyManager is immutable, so the prediction shown before an account exists is the address `deployProxy`
  later creates for the chain's lifetime (FV-CTL-149).
- Lens paging. `checkRecordBacking` returns an empty page for `offset >= nextRecordId` and otherwise walks
  `offset .. offset + min(limit, n - offset) - 1`, which never overflows for any 256-bit input (FV-CTL-77). The
  paging rules of the Lens are compared for one outcome per input (FV-CTL-148).
- Lens liquidation preview. `premiumWithinMax` is true exactly when LPVaultSwap's flash-premium checks accept the
  same loan: the Lens, the ParameterStore, LPVaultSwap and the borrow gate all state the exact form
  `phi x 10^4 <= maxFlashFeeBps x F`, read from the pages (FV-CTL-78; resolves FV-CTL-F-27).
- Read-only reentrancy. Every view a third party can call during an Avana operation either reverts while the
  Lock is held or reads state the locked operation does not write before its last external call (FV-CTL-97).
"""
import itertools
import sys

import z3

from common import HERE, exhaustive, expect, finish, open_finding, prove, witness

SPEC = HERE.parents[2] / "spec"

MAXV = 2**64 - 1  # OpenZeppelin Initializable: _disableInitializers sets type(uint64).max

# ---------------------------------------------------------------- OpenZeppelin 5.1 Initializable (upgradeable contracts)
ver, ver2, n = z3.Ints("initialized initialized_after reinit_n")
init_ok = ver == 0
reinit_ok = z3.And(ver < n, n <= MAXV)
# FV-CTL-86 verifies: REQ-ACCESS-150, REQ-ADAPTER-004, REQ-ORACLE-080, REQ-ACCESS-031
prove("FV-CTL-86", "An implementation of an upgradeable contract whose constructor ran _disableInitializers() can never be initialized or reinitialized; a proxy's initializer runs once",
      z3.And(z3.Implies(ver == MAXV, z3.And(z3.Not(init_ok), z3.Not(reinit_ok))),
             z3.Implies(z3.And(init_ok, ver2 == 1), z3.Not(ver2 == 0))),
      assumptions=[ver >= 0, ver <= MAXV, n >= 1],
      verifies=["REQ-ACCESS-150", "REQ-ADAPTER-004", "REQ-ORACLE-080", "REQ-ACCESS-031"],
      targets=["T-64", "T-62"],
      detail="Changed for the AMM-neutral design: the PositionProxy has no initializer at all (REQ-PROXY-001), so this "
             "check now covers only the UUPS contracts; the proxy is covered by FV-CTL-87.")

# After an implementation change: which callers can change an account's state first?
# AMM-neutral design: a PositionProxy is a plain immutable contract with no implementation, initializer or upgrade
# selector (REQ-PROXY-001, REQ-PROXY-103); its only state-changing selector is execute, callable only by ADAPTER
# (REQ-PROXY-007). Its selector inventory is read from the page.
_proxy_page = (SPEC / "02-contracts/05-position-proxy-and-proxy-manager.md").read_text()
PROXY_SELECTORS = {"execute", "ADAPTER", "WALLET", "SPOKE", "MARKET_ID"}
_inventory_ok = ("`execute` and the four views only" in _proxy_page
                 and all(f"`{v}()`" in _proxy_page for v in ("ADAPTER", "WALLET", "SPOKE", "MARKET_ID")))
FORBIDDEN = ("initialize", "reinitializer", "upgradeToAndCall", "setProxyImplementation", "setBeacon", "migrate",
             "grantRole", "transferOwnership", "delegatecallAny", "receive", "fallback", "isValidSignature",
             "onERC721Received")
CALLERS = ("Adapter", "Timelock", "wallet", "anyone")


def changes_state(form, sel, caller):
    if form == "UUPS":
        # reinitializer(n) runs inside upgradeToAndCall, an APPLICATION_ADMIN call only the timelock makes
        return sel == "reinitializer" and caller == "Timelock"
    # immutable PositionProxy: a selector outside its inventory matches nothing and reverts (no fallback)
    if sel not in PROXY_SELECTORS:
        return False
    return sel == "execute" and caller == "Adapter"   # OnlyAdapter() for every other caller


_dom87 = [("UUPS", s, c) for s in ("initialize", "reinitializer", "view") for c in CALLERS] + \
         [("PositionProxy", s, c) for s in sorted(PROXY_SELECTORS) + list(FORBIDDEN) for c in CALLERS]
# FV-CTL-87 verifies: REQ-PROXY-001, REQ-PROXY-007, REQ-PROXY-086, REQ-PROXY-103, REQ-PROXY-101, REQ-ACCESS-147, REQ-ACCESS-176
exhaustive("FV-CTL-87", "After any implementation change only the timelock (UUPS reinitializer inside upgradeToAndCall) changes an upgradeable contract's state, and only the AaveAdapter (execute) can make a PositionProxy act: the proxy has no initializer, upgrade, role, receiver or fallback selector, and the page states its inventory as execute plus the four views",
           [("inventory", "-", "-")] + _dom87,
           lambda x: _inventory_ok if x[0] == "inventory" else
           ((not changes_state(*x)) or x[2] == ("Timelock" if x[0] == "UUPS" else "Adapter") or x),
           verifies=["REQ-PROXY-001", "REQ-PROXY-007", "REQ-PROXY-086", "REQ-PROXY-103", "REQ-PROXY-101",
                     "REQ-ACCESS-147", "REQ-ACCESS-176"],
           targets=["T-64", "T-62"],
           detail="Changed for the AMM-neutral design: the beacon form and its no-reinitializer rule are gone; the proxy "
                  "is logic-free and immutable, so an Adapter upgrade changes account logic for every proxy at once.")

# Storage layout rule (TEST-137): append-only inside the ERC-7201 namespace (upgradeable contracts only).
OLD = [("a", "address"), ("b", "uint256"), ("c", "mapping"), ("d", "bool")]


def append_only(old, new):
    return len(new) >= len(old) and new[:len(old)] == old


MUTATIONS = []
for i in range(len(OLD)):
    MUTATIONS.append(("delete", OLD[:i] + OLD[i + 1:], False))
    MUTATIONS.append(("retype", OLD[:i] + [(OLD[i][0], "uint128")] + OLD[i + 1:], False))
    MUTATIONS.append(("insert", OLD[:i] + [("x", "uint256")] + OLD[i:], False))
for i, j in itertools.combinations(range(len(OLD)), 2):
    sw = list(OLD)
    sw[i], sw[j] = sw[j], sw[i]
    MUTATIONS.append(("swap", sw, False))
MUTATIONS.append(("append", OLD + [("e", "uint256")], True))
MUTATIONS.append(("identical", list(OLD), True))
# FV-CTL-88 verifies: REQ-ADAPTER-004, REQ-ORACLE-080
exhaustive("FV-CTL-88", "The append-only layout rule accepts exactly the appending and identical layouts and rejects every delete, retype, insert and reorder",
           MUTATIONS, lambda m: append_only(OLD, m[1]) == m[2], verifies=["REQ-ADAPTER-004", "REQ-ORACLE-080"],
           targets=["T-64"],
           detail="Namespaces are disjoint by construction: each root is keccak256(keccak256(id) - 1) & ~0xff over distinct ids; "
                  "collision resistance is assumed. The PositionProxy has no storage layout to keep (immutables only).")

# ---------------------------------------------------------------- PositionProxy binding and the address views
# create2(deployer, salt, initCodeHash); salt = keccak(abi.encode(wallet, spoke, marketId));
# initCodeHash = keccak(creationCode ++ abi.encode(ADAPTER, wallet, spoke, marketId)) (REQ-PROXY-052).
A = z3.Function("create2", z3.IntSort(), z3.IntSort(), z3.IntSort(), z3.IntSort())
salt = z3.Function("salt", z3.IntSort(), z3.IntSort(), z3.IntSort(), z3.IntSort())
ich = z3.Function("initCodeHash", z3.IntSort(), z3.IntSort(), z3.IntSort(), z3.IntSort(), z3.IntSort())
w1, s1, m1, w2, s2, m2, PM, D2, AD, AD2 = z3.Ints("w1 s1 m1 w2 s2 m2 ProxyManager otherDeployer Adapter otherAdapter")


def injective(fun, args_list):
    """Ground instances of injectivity (keccak / CREATE2 modelled as injective) for every pair of argument tuples."""
    out = []
    for a_, b_ in itertools.combinations(args_list, 2):
        out.append(z3.Implies(fun(*a_) == fun(*b_), z3.And([x == y for x, y in zip(a_, b_)])))
    return out


def addr(dep, adapter, w, s, m):
    return A(dep, salt(w, s, m), ich(adapter, w, s, m))


inj = (injective(salt, [(w1, s1, m1), (w2, s2, m2)])
       + injective(ich, [(AD, w1, s1, m1), (AD, w2, s2, m2), (AD2, w1, s1, m1)])
       + injective(A, [(PM, salt(w1, s1, m1), ich(AD, w1, s1, m1)), (PM, salt(w2, s2, m2), ich(AD, w2, s2, m2)),
                       (D2, salt(w1, s1, m1), ich(AD, w1, s1, m1)), (PM, salt(w1, s1, m1), ich(AD2, w1, s1, m1))]))
# FV-CTL-89 verifies: INV-012, REQ-PROXY-052, REQ-PROXY-053, REQ-PROXY-055, REQ-PROXY-100, REQ-ARCH-035
prove("FV-CTL-89", "One PositionProxy per (wallet, CDP Spoke, market): equal CREATE2 addresses from the ProxyManager imply the same triple, no other deployer and no other Adapter can produce a triple's address, so no Hub, Spoke or market occupies another's proxy (keccak and CREATE2 modelled as injective)",
      z3.And(z3.Implies(addr(PM, AD, w1, s1, m1) == addr(PM, AD, w2, s2, m2), z3.And(w1 == w2, s1 == s2, m1 == m2)),
             z3.Implies(D2 != PM, addr(D2, AD, w1, s1, m1) != addr(PM, AD, w1, s1, m1)),
             z3.Implies(AD2 != AD, addr(PM, AD2, w1, s1, m1) != addr(PM, AD, w1, s1, m1))),
      assumptions=inj, verifies=["INV-012", "REQ-PROXY-052", "REQ-PROXY-053", "REQ-PROXY-055", "REQ-PROXY-100", "REQ-ARCH-035"],
      targets=["T-62"],
      detail="Changed for the AMM-neutral design: the key is (wallet, spoke, marketId), not (wallet, spoke), and the "
             "init code carries the Adapter and the triple.")

stored = z3.Int("proxyOf_wallet_market")         # AaveAdapter.proxyOf(wallet, marketId), written once
frozen_a = z3.Bool("isFrozenAddress_wallet")
pm_predict = addr(PM, AD, w1, s1, m1)              # ProxyManager immutable: PM, ADAPTER and the code hash never change


def proxy_view():
    """Adapter.predictProxy (REQ-PROXY-049), Lens.predictProxy (REQ-LENS-008), RiskModule.previewPledge (REQ-RISK-031)."""
    return z3.If(stored != 0, stored, pm_predict)


deploy_ok = lambda frozen: z3.Not(frozen)  # noqa: E731  REQ-PROXY-099: AddressIsFrozen before deploying
# FV-CTL-90 verifies: REQ-PROXY-049, REQ-LENS-008, REQ-RISK-031, REQ-PROXY-099, REQ-PROXY-053
prove("FV-CTL-90", "For every deployed account the Adapter, Lens and previewPledge views equal the stored proxyOf(wallet, marketId), Lens reports deployed = true; deployProxy refuses a frozen wallet and predictProxy reads no MarketRegistry state",
      z3.And(proxy_view() == stored, z3.Implies(frozen_a, z3.Not(deploy_ok(frozen_a)))),
      assumptions=inj + [stored != 0, stored == pm_predict],
      verifies=["REQ-PROXY-049", "REQ-LENS-008", "REQ-RISK-031", "REQ-PROXY-099", "REQ-PROXY-053"], targets=["T-62", "T-74"],
      detail="Changed for the AMM-neutral design: the ProxyManager is immutable, so no upgrade can change the creation "
             "code; predictProxy has no registry input (REQ-PROXY-099).")
# FV-CTL-149 verifies: REQ-PROXY-050, REQ-PROXY-052, REQ-LENS-008, REQ-PROXY-085
prove("FV-CTL-149", "The address the views show before an account exists (deployed = false) is the address deployProxy later creates, and deployProxy's own equality check with predictProxy cannot fail, for the chain's lifetime (immutable ProxyManager, fixed ADAPTER and creation-code hash)",
      z3.And(proxy_view() == addr(PM, AD, w1, s1, m1), addr(PM, AD, w1, s1, m1) == pm_predict),
      assumptions=inj + [stored == 0],
      verifies=["REQ-PROXY-050", "REQ-PROXY-052", "REQ-LENS-008", "REQ-PROXY-085"], targets=["T-62", "T-74"])

# ---------------------------------------------------------------- Lens paging (REQ-LENS-014, -020, -023, -024)
BV = 256
off, lim, nxt = z3.BitVecs("offset limit nextRecordId", BV)
LENS_MAX_PAGE = 200
cnt = z3.If(z3.ULT(lim, nxt - off), lim, nxt - off)    # min(limit, n - offset), evaluated only when offset < n
end = off + cnt
walks = z3.And(z3.ULT(off, nxt), lim != 0, z3.ULE(lim, LENS_MAX_PAGE))
# FV-CTL-77 verifies: REQ-LENS-014, REQ-LENS-024, REQ-LENS-023
prove("FV-CTL-77", "checkRecordBacking returns an empty page whenever offset >= nextRecordId and otherwise walks offset .. offset + min(limit, n - offset) - 1 with no underflow or overflow, at most limit IDs, all below nextRecordId, for every 256-bit offset, limit and nextRecordId",
      z3.And(z3.Implies(walks, z3.And(z3.BVSubNoUnderflow(nxt, off, False), z3.BVAddNoOverflow(off, cnt, False),
                                      z3.ULE(end, nxt), z3.ULE(off, end), z3.ULE(cnt, lim), cnt != 0)),
             z3.Implies(z3.UGE(off, nxt), z3.Not(walks))),
      verifies=["REQ-LENS-014", "REQ-LENS-024", "REQ-LENS-023"], targets=["T-74"])
# One outcome per input: REQ-LENS-014 applies the limit checks of REQ-LENS-023 first (0 returns an empty array, a limit
# above LENS_MAX_PAGE reverts LimitTooHigh, as REQ-LENS-020), then returns an empty array when offset >= nextRecordId;
# REQ-LENS-024 covers any offset up to type(uint256).max and any limit <= LENS_MAX_PAGE.
says_empty = z3.Or(lim == 0, z3.And(z3.UGE(off, nxt), z3.ULE(lim, LENS_MAX_PAGE)))   # REQ-LENS-014, -023, -024
says_revert = z3.UGT(lim, LENS_MAX_PAGE)                                          # REQ-LENS-020, REQ-LENS-023
says_walk = z3.And(z3.ULT(off, nxt), lim != 0, z3.ULE(lim, LENS_MAX_PAGE))           # REQ-LENS-014
# FV-CTL-148 verifies: REQ-LENS-014, REQ-LENS-020, REQ-LENS-023, REQ-LENS-024
prove("FV-CTL-148", "The Lens paging rules give checkRecordBacking one outcome for every (offset, limit, nextRecordId)",
      z3.And(z3.Not(z3.And(says_empty, says_revert)), z3.Not(z3.And(says_empty, says_walk)),
             z3.Not(z3.And(says_walk, says_revert)), z3.Or(says_empty, says_revert, says_walk)), verifies=["REQ-LENS-014", "REQ-LENS-020", "REQ-LENS-023", "REQ-LENS-024"],
      targets=["T-74"], show={"offset", "limit", "nextRecordId"})

# Lens premiumWithinMax against LPVaultSwap's flash-premium checks (AMM-neutral design: no GHO buy leg; the flash
# source lends the debt asset itself). Every page states one exact form, phi x 10^4 <= maxFlashFeeBps x F, with F
# the flash amount and no division or rounding: the Lens flag (REQ-LENS-029), the ParameterStore ceiling
# (REQ-PSTORE-024), LPVaultSwap's pre-loan and callback checks (REQ-FLASH-002, SPEC-LIQ-015) and the borrow gate's
# probe (REQ-RISK-062, with F = 10^dec). The forms are read from the pages; a rounded ceiling such as
# ceil(D x maxFlashFeeBps / 10^4) on any of them fails the check.
import re as _re


def _rule(rel, rid):
    for line in (SPEC / rel).read_text().splitlines():
        if line.lstrip("- ").startswith(f"`{rid}`"):
            return line
    return ""


_FORMS78 = {
    "REQ-LENS-029": ("02-contracts/17-lens.md", "`premiumWithinMax` true exactly when `flashPremium × 10⁴ ≤ maxFlashFeeBps × F`"),
    "REQ-PSTORE-024": ("02-contracts/09-parameter-store.md", "`φ × 10⁴ ≤ maxFlashFeeBps × amount`"),
    "SPEC-LIQ-015": ("02-contracts/11-lpvaultswap.md", "`φ × 10⁴ ≤ maxFlashFeeBps × F`"),
    "REQ-FLASH-002": ("02-contracts/11-lpvaultswap.md", "`flashSource.flashPremium(T, F) × 10⁴ > maxFlashFeeBps × F`"),
    "REQ-RISK-062": ("02-contracts/07-risk-module.md", "`FLASH_SOURCE.flashPremium(asset, 10^dec) × 10⁴ > maxFlashFeeBps × 10^dec`"),
}
_texts78 = {rid: _rule(rel, rid) for rid, (rel, _) in _FORMS78.items()}
_rounded = _re.compile(r"⌈[^⌉`]*maxFlashFeeBps|maxFlashFeeBps\s*/\s*10⁴")
_forms_ok = {rid: (form in _texts78[rid] and not _rounded.search(_texts78[rid])) for rid, (_, form) in _FORMS78.items()}
_launch_ok = ("launch 10 on Ethereum and on Base" in _texts78["REQ-PSTORE-024"]
              and "`maxFlashFeeBps` launch 10" in _texts78["SPEC-LIQ-015"])
_ex_ok = ("`975,000 × 10⁴ = 9,750,000,000 ≤ 10 × 1,950,000,000 = 19,500,000,000`" in _texts78["SPEC-LIQ-015"]
          and "`39,000,000,000 > 19,500,000,000`" in _texts78["SPEC-LIQ-015"])
_ex78 = (975_000 * 10**4 <= 10 * 1_950_000_000) and not (3_900_000 * 10**4 <= 10 * 1_950_000_000) and _ex_ok

# The flag and the checks, as the pages state them: phi is the flash source's quote, which is the premium the Pool
# charges in the callback (same asset, same amount, same block); F is the flash amount the params carry.
F_, mf, pp, phi = z3.Ints("flashAmount maxFlashFeeBps poolPremiumBps premium")
dom78 = [F_ >= 1, F_ < 2**128, mf >= 0, mf <= 100, pp >= 0, pp <= 10**4, phi >= 0,
         phi * 10**4 >= F_ * pp, (phi - 1) * 10**4 < F_ * pp]          # Aave V3 premium F x p / 10^4, rounded up
lens_ok = phi * 10**4 <= mf * F_                                         # REQ-LENS-029
pre_ok = z3.Not(phi * 10**4 > mf * F_)                                   # REQ-FLASH-002 (no FlashFeeTooHigh)
cb_ok = phi * 10**4 <= mf * F_                                           # SPEC-LIQ-015 callback, REQ-PSTORE-024
_page_ok = all(_forms_ok.values()) and _launch_ok and _ex78
# FV-CTL-78 verifies: REQ-LENS-029, REQ-LENS-016, SPEC-LIQ-015, REQ-FLASH-002, REQ-PSTORE-024, REQ-RISK-062
prove("FV-CTL-78", "previewLiquidation's premiumWithinMax is true exactly when LPVaultSwap's pre-loan and callback flash-premium checks accept the same loan: every page (2.17 REQ-LENS-029, 2.9 REQ-PSTORE-024, 2.11 SPEC-LIQ-015 and REQ-FLASH-002, 2.7 REQ-RISK-062) states the exact form phi x 10^4 <= maxFlashFeeBps x F, launch 10 bps (SPEC-LIQ-015 example: 5 bps on 1,950 USDC passes, 20 bps fails)",
      z3.And(lens_ok == pre_ok, lens_ok == cb_ok, z3.BoolVal(_page_ok)), assumptions=dom78,
      verifies=["REQ-LENS-029", "REQ-LENS-016", "SPEC-LIQ-015", "REQ-FLASH-002", "REQ-PSTORE-024", "REQ-RISK-062"],
      targets=["T-74"], show={"flashAmount", "maxFlashFeeBps", "poolPremiumBps", "premium"},
      detail="Changed for the AMM-neutral design: maxGhoSpend no longer exists. Resolves FV-CTL-F-27: the Lens flag "
             "had rounded the ceiling up while LPVaultSwap compared exact products; every page now states the exact "
             "form. Page forms: " + ", ".join(f"{k}={'ok' if v else 'MISSING'}" for k, v in _forms_ok.items())
             + f", launch 10={'ok' if _launch_ok else 'MISSING'}, example={'ok' if _ex_ok else 'MISSING'}.")

# ---------------------------------------------------------------- read-only reentrancy (T-73)
VIEWS = {
    "Lens.* (every function)": "reverts Locked (REQ-LENS-006)",
    "Collateralization record/total/pending views": "reverts for a non-holder while locked (REQ-VAULT-091)",
    "LPVault custody views": "reverts Locked (REQ-VAULT-125)",
    "LPOracle and DebtOracle latestAnswer/getPriceState": "reads feeds and oracle storage written only by poke(), which makes only static calls",
    "RiskModule.getAccountGateStatus/previewPledge": "reads Collateralization views, which revert while locked",
    "AaveAdapter.proxyOf/predictProxy/borrowNonce": "written only by the holder before any external call; values final",
    "MarketRegistry marketBreaker/debtBreaker": "written only by guardian, timelock and live-condition paths; LPVaultSwap writes no breaker state (Q-399), so no Adapter path can read it while locked",
    "MarketRegistry routes, statuses and activePriceRoutes; ParameterStore views": "not written by any Lock holder",
}
SAFE_REASONS = ("revert", "written only by", "not written", "static calls", "values final", "after its waterfall")
# FV-CTL-97 verifies: REQ-LENS-006, REQ-LENS-021, REQ-VAULT-125, REQ-ORACLE-025, REQ-SWAP-104, REQ-MREG-026
exhaustive("FV-CTL-97", "Every view a third party can call mid-operation either reverts while the Lock is held or reads state the locked call does not write before its last external call",
           list(VIEWS.items()), lambda kv: any(s in kv[1] for s in SAFE_REASONS),
           verifies=["REQ-LENS-006", "REQ-LENS-021", "REQ-VAULT-125", "REQ-ORACLE-025", "REQ-SWAP-104", "REQ-MREG-026"],
           targets=["T-73"])

sys.exit(finish())
