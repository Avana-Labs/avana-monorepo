"""LPVault custody of one position and its record (T-02, T-05, T-11, T-18, REQ-COLL-006).

Changed for the AMM-neutral design: the generic custody functions are
receivePosition / returnPosition / unwind / releaseToDepositor / collectFees, keyed by
positionKey, and the record is keyed by (integrationId, positionKey) (FV-CUS-35). This
model is the Uniswap v3 and Aerodrome Slipstream LPVault, whose position is an ERC-721
NFT of the pinned NFPM; the old names below map as receiveNft -> receivePosition,
returnNft -> returnPosition, removeLiquidity -> unwind, releaseLiquidity ->
releaseToDepositor. Every custody call is reachable only inside a call tree of the two
Lock members (FV-CUS-42); fee collection and the stray return enter through the Adapter.

Per-token state: NFPM owner, per-token approval, LPVault depositorOf, Collateralization
record (open, depositor, credited), live liquidity and amounts owed to the NFT (fees
and pre-pledge principal). Addresses are an enum; the Avana contracts are distinct.
NFPM semantics (Uniswap v3 periphery, OpenZeppelin ERC721 3.4): transferFrom needs
the caller to be the owner, the approved address or an operator, clears the per-token
approval; increaseLiquidity is open to anyone; decreaseLiquidity and collect need the
owner or an approved address; collect pays min(cap, owed).
Calls on custody (final 2.2/2.3): receiveNft refuses the LPVault itself as owner and
pledge refuses the LPVault or Collateralization as depositor (Q-258); removeLiquidity
pays principal to LPVaultSwap or Collateralization (seizure, reconciliation, deleverage
release); releaseLiquidity pays a partial removal's principal to the depositor of
record; recredit credits the live liquidity above credited.
"""
from z3 import Int, Ints, Bool, And, Or, Not, If, Implies, BoolVal, IntVal
from common import prove, satisfiable, summary

ZERO, W1, W2, LPV, COLL, LPVS, TL, ADAPTER, OTHER = range(9)
AVANA = [LPV, COLL, LPVS, TL, ADAPTER]
ADDRS = [ZERO, W1, W2, LPV, COLL, LPVS, TL, ADAPTER, OTHER]


class N:
    def __init__(self, tag=None):
        if tag is None:
            return
        self.owner, self.appr, self.dep, self.recDep = Ints(f"{tag}_owner {tag}_appr {tag}_dep {tag}_recDep")
        self.rec = Bool(f"{tag}_rec")
        self.cred, self.live, self.owed = Ints(f"{tag}_cred {tag}_live {tag}_owed")

    def copy(self):
        n = N()
        n.__dict__.update(self.__dict__)
        return n


def is_addr(x):
    return Or([x == a for a in ADDRS])


def inv(s, strict_depositor=True):
    c = [is_addr(s.owner), is_addr(s.appr), is_addr(s.dep), is_addr(s.recDep), s.owner != ZERO,
         s.rec == (s.dep != ZERO),                                                   # REQ-COLL-006
         Implies(s.rec, And(s.owner == LPV, s.dep == s.recDep)),                     # INV-005 (b)
         Implies(Not(s.rec), And(s.cred == 0, s.recDep == ZERO)),
         Implies(s.rec, And(s.cred >= 0, s.live >= s.cred)),                         # T-02 / INV-002
         s.live >= 0, s.owed >= 0,
         Implies(s.owner == LPV, s.appr == ZERO),                                    # LPVault grants no approval
         Implies(s.owner == COLL, s.appr == ZERO)]                                   # Collateralization has no NFPM call (REQ-VAULT-090)
    if strict_depositor:
        c.append(Implies(s.rec, And(s.dep != LPV, s.dep != COLL)))                 # REQ-VAULT-094, REQ-VAULT-093
    return And(c)


def ops(pre, hostile_adapter=True, final_checks=True):
    out = []
    # pledge: Collateralization.pledge -> LPVault.receiveNft(depositorArg, tokenId)
    d = Int("depositorArg")
    g = [Not(pre.rec), is_addr(d), d != ZERO, pre.owner == d,                     # NotTokenOwner
         Or(pre.appr == LPV, pre.owner == LPV),                                    # NFPM transferFrom auth (caller LPVault)
         pre.live >= 1]                                                            # ZeroLiquidity
    if not hostile_adapter:
        g.append(And([d != a for a in AVANA]))                                     # reviewed Adapter: depositor = msg.sender wallet
    if final_checks:
        g += [d != COLL, d != LPV,                                                 # pledge: InvalidDepositor (REQ-COLL-005)
              d != LPV]                                                            # receiveNft: NotTokenOwner if owner == this
    s = pre.copy()
    s.owner, s.appr, s.dep, s.rec, s.recDep, s.cred = IntVal(LPV), IntVal(ZERO), d, BoolVal(True), d, pre.live
    out.append(("pledge", g, s, dict(to=None)))
    # close: release / releaseZeroCredit -> returnNft
    s = pre.copy()
    s.owner, s.dep, s.rec, s.recDep, s.cred = pre.dep, IntVal(ZERO), BoolVal(False), IntVal(ZERO), IntVal(0)
    out.append(("returnNft", [pre.rec], s, dict(to=pre.dep)))
    # removeLiquidity(take, recipient): decreaseLiquidity then collect capped at the principal
    take, a0, rcp = Ints("take principal recipient")
    s = pre.copy()
    s.cred, s.live = pre.cred - take, pre.live - take
    owed_mid = pre.owed + a0                       # tokensOwed after decreaseLiquidity
    collected = If(a0 <= owed_mid, a0, owed_mid)   # collect(min(cap = a0, owed))
    s.owed = owed_mid - collected
    out.append(("removeLiquidity", [pre.rec, take >= 1, take <= pre.cred, a0 >= 0, is_addr(rcp),
                                    rcp != ZERO, rcp != LPV], s, dict(to=None, collected=collected, a0=a0)))
    # releaseLiquidity(take, min): partial removal, principal collected to depositorOf only
    ptake, pa0 = Ints("partialTake partialPrincipal")
    s = pre.copy()
    s.cred, s.live = pre.cred - ptake, pre.live - ptake
    owed_mid = pre.owed + pa0
    pcollected = If(pa0 <= owed_mid, pa0, owed_mid)
    s.owed = owed_mid - pcollected
    out.append(("releaseLiquidity", [pre.rec, ptake >= 1, ptake < pre.cred, pa0 >= 0], s,
                dict(to=None, collected=pcollected, a0=pa0, paid_to=pre.dep)))
    # recredit: credited rises to the live liquidity (REQ-COLL-015), custody unchanged
    s = pre.copy()
    s.cred = pre.live
    out.append(("recredit", [pre.rec, pre.cred >= 1, pre.live > pre.cred], s, dict(to=None)))
    # collectFees(caller)
    caller = Int("caller")
    s = pre.copy()
    s.owed = IntVal(0)
    out.append(("collectFees", [pre.dep != ZERO, caller == pre.dep], s, dict(to=None, paid_to=pre.dep)))
    # returnStrayNft(recipient) by caller
    r2, c2 = Ints("strayRecipient strayCaller")
    s = pre.copy()
    s.owner, s.appr = r2, IntVal(ZERO)
    out.append(("returnStrayNft", [c2 == TL, pre.owner == LPV, pre.dep == ZERO, is_addr(r2), r2 != ZERO, r2 != LPV],
                s, dict(to=r2)))
    # third parties: increaseLiquidity, fee accrual
    dl, fa = Ints("donation feeAccrued")
    s = pre.copy()
    s.live = pre.live + dl
    out.append(("increaseLiquidity", [dl >= 1], s, dict(to=None)))
    s = pre.copy()
    s.owed = pre.owed + fa
    out.append(("feeAccrual", [fa >= 0], s, dict(to=None)))
    # owner actions while the NFT is outside the LPVault: transfer (incl. safeTransfer to the LPVault: stray), approve, decrease
    nt, na, dd = Ints("newOwner newApproved decrease")
    s = pre.copy()
    s.owner, s.appr = nt, IntVal(ZERO)
    out.append(("ownerTransfer", [pre.owner != LPV, is_addr(nt), nt != ZERO], s, dict(to=nt)))
    s = pre.copy()
    s.appr = na
    out.append(("ownerApprove", [pre.owner != LPV, pre.owner != COLL, is_addr(na)], s, dict(to=None)))
    s = pre.copy()
    s.live = pre.live - dd
    out.append(("ownerDecrease", [pre.owner != LPV, dd >= 0, dd <= pre.live], s, dict(to=None)))
    return out


def main():
    pre = N("pre")
    for name, g, post, info in ops(pre, hostile_adapter=True):
        # FV-CUS-02 verifies: INV-002, INV-005, SPEC-BACK-010, REQ-VAULT-032, REQ-VAULT-077, REQ-COLL-006, REQ-VAULT-152
        prove(f"FV-CUS-02-{name}", f"T-02/T-05 custody iff open record, owner LPVault, live >= credited across {name} (any Adapter)",
              inv(post), [inv(pre)] + g)
        # FV-CUS-11 verifies: INV-007, REQ-VAULT-072, REQ-VAULT-094, REQ-VAULT-122, REQ-VAULT-123, REQ-VAULT-079, REQ-VAULT-083
        leaves = And(pre.owner == LPV, post.owner != LPV)
        prove(f"FV-CUS-11-{name}", f"T-11 an NFT leaves the LPVault only to its depositor of record (closing the record) or as a stray via the timelock, in {name}",
              Implies(leaves, Or(And(Not(post.rec), pre.rec, post.owner == pre.dep, name == "returnNft"),
                                 And(Not(pre.rec), name == "returnStrayNft"))),
              [inv(pre)] + g)
        # FV-CUS-18 verifies: INV-033, INV-044, SPEC-BACK-008, REQ-VAULT-065, REQ-VAULT-067, REQ-VAULT-059, REQ-VAULT-076
        if name == "collectFees":
            prove("FV-CUS-18-collect", "T-18 collectFees pays only the depositor of record and changes no liquidity or credit",
                  And(info["paid_to"] == pre.dep, post.live == pre.live, post.cred == pre.cred, post.rec == pre.rec),
                  [inv(pre)] + g)
        if name == "removeLiquidity":
            prove("FV-CUS-18-capped", "T-18 a removal's collect takes exactly the removed principal; owed fees are unchanged",
                  And(info["collected"] == info["a0"], post.owed == pre.owed), [inv(pre)] + g)
        if name == "releaseLiquidity":
            # FV-CUS-18 verifies: REQ-VAULT-161, REQ-COLL-014, SPEC-BACK-008, INV-088, REQ-VAULT-061
            prove("FV-CUS-18-partial", "a partial removal pays exactly the removed principal, only to the depositor of record, keeps owed fees and leaves the NFT in custody with credit >= 1",
                  And(info["collected"] == info["a0"], info["paid_to"] == pre.dep, post.owed == pre.owed,
                      post.rec, post.owner == LPV, post.cred >= 1, post.live - post.cred == pre.live - pre.cred),
                  [inv(pre)] + g)
        if name == "recredit":
            # FV-CUS-31 verifies: REQ-COLL-015, REQ-VAULT-162, REQ-VAULT-077, SPEC-BACK-010, INV-088
            prove("FV-CUS-31-custody", "a re-credit raises credited to exactly the live liquidity and moves no NFT, liquidity or fee",
                  And(post.cred == pre.live, post.live == pre.live, post.owner == pre.owner, post.owed == pre.owed, post.rec),
                  [inv(pre)] + g)
        if name == "pledge":
            prove("FV-CUS-05-dup", "T-05 pledging a tokenId with an open record is outside the success guard (AlreadyPledged)",
                  Not(And(g)), [inv(pre), pre.rec])
    # Stray NFTs are never pledged (REQ-VAULT-147, REQ-COLL-005, REQ-VAULT-007, Q-258).
    # FV-CUS-11 verifies: REQ-VAULT-147, REQ-VAULT-007, REQ-COLL-005, REQ-COLL-019, REQ-VAULT-093, REQ-VAULT-094, REQ-VAULT-079
    name, g, post, info = ops(pre, hostile_adapter=True)[0]
    prove("FV-CUS-11-depositor",
          "REQ-VAULT-147/REQ-COLL-005: under any Adapter, a pledge never records the LPVault or Collateralization as depositor, so a stray NFT is never pledged",
          inv(post), [inv(pre)] + g, show=[pre.owner, pre.appr, pre.dep, Int("depositorArg"), post.dep])
    name, g, post, info = ops(pre, hostile_adapter=True, final_checks=False)[0]
    satisfiable("FV-CUS-11-depositor-mut",
                "mutation witness: without the self-owner and InvalidDepositor checks a hostile Adapter pledges a stray NFT with the LPVault as depositor",
                And([inv(pre), pre.owner == LPV, pre.dep == ZERO] + g + [post.dep == LPV]),
                show=[pre.owner, Int("depositorArg"), post.dep])

    # Item 5: the LP journey (pledge -> fees accrue -> collectFees -> donation -> withdraw)
    # with no liquidation: the NFT returns to its depositor with all its liquidity, and
    # every fee owed is either paid to the depositor or still owed to the NFT.
    O = ops(pre, hostile_adapter=False)
    byname = {n: (g, s_) for n, g, s_, _ in O}
    W = Int("lpWallet")
    g1, s1 = byname["pledge"]
    f1 = Int("fee1")
    j = [inv(pre), Not(pre.rec), pre.owner == W, Or(W == W1, W == W2), Int("depositorArg") == W] + g1
    s2 = s1.copy(); s2.owed = s1.owed + f1                                 # swap fees accrue
    paid = s2.owed; s3 = s2.copy(); s3.owed = IntVal(0)                    # collectFees by the depositor
    f2, dn = Ints("fee2 donation2")
    s4 = s3.copy(); s4.owed = s3.owed + f2; s4.live = s3.live + dn         # more fees, a donation
    s5 = s4.copy(); s5.owner, s5.dep, s5.rec, s5.recDep, s5.cred = s4.dep, IntVal(ZERO), BoolVal(False), IntVal(ZERO), IntVal(0)
    # FV-CUS-28 verifies: REQ-VAULT-072, REQ-VAULT-065, REQ-VAULT-077, REQ-VAULT-059, INV-033, INV-044
    prove("FV-CUS-28-journey", "item 5: without a liquidation the depositor gets back the NFT with all its liquidity and every fee (paid or still owed)",
          And(s5.owner == W, s5.live == pre.live + dn, paid + s5.owed == pre.owed + f1 + f2),
          j + [f1 >= 0, f2 >= 0, dn >= 0])
    # Across every operation, while the NFT is in custody its liquidity falls only by a
    # removal Collateralization debited, and owed fees fall only when paid to the depositor.
    for name, g, post, info in ops(pre, hostile_adapter=True):
        prove(f"FV-CUS-28-{name}", f"item 5: in {name}, custodied liquidity falls only in a debited removal (removeLiquidity, releaseLiquidity) and owed fees fall only in collectFees",
              And(Implies(And(pre.rec, post.rec, post.live < pre.live), BoolVal(name in ("removeLiquidity", "releaseLiquidity"))),
                  Implies(And(pre.rec, post.owed < pre.owed), BoolVal(name == "collectFees"))),
              [inv(pre)] + g)
    # Item 3: a hook in a pool token paid during collect cannot re-enter Avana: the
    # LPVault holds the Lock for collectFees and removeLiquidity runs under its caller's Lock.
    h, hookCaller, named = Ints("lockHolderDuringCollect hookCaller namedCaller")
    members = [ADAPTER, COLL, LPV, LPVS]
    outer_ok = h == ZERO                                     # Lock.acquire succeeds only when free
    inner_ok = And(hookCaller == named, h == named, Or([named == m for m in members]))
    # FV-CUS-28 verifies: REQ-LOCK-005, REQ-LOCK-010, REQ-VAULT-150, REQ-ARCH-014
    prove("FV-CUS-28-reentry", "item 3: a pool-token hook running inside NFPM collect/decreaseLiquidity cannot enter any Avana outer or inner entry point",
          And(Not(outer_ok), Not(inner_ok)),
          [Or([h == m for m in members]), And([hookCaller != m for m in members])])

    # Read-only reentrancy: views under the lock (REQ-VAULT-091, REQ-VAULT-151, REQ-COLL-018, REQ-LOCK-016).
    holder, caller = Ints("lockHolder viewCaller")
    members = [ADAPTER, COLL, LPV, LPVS]
    coll_view_ok = Or(holder == ZERO, caller == holder)                 # record, total, pending, counter, preview views
    rescue_view_ok = Or(holder == ZERO, holder == ADAPTER)              # getAccountRescueUnits
    lpv_view_ok = holder == ZERO                                        # depositorOf, isInCustody
    liq_view_ok = Or(holder == ZERO, caller == COLL)                    # liquidityOf
    # FV-CUS-24 verifies: REQ-VAULT-091, REQ-VAULT-125, REQ-VAULT-151, REQ-VAULT-160, REQ-VAULT-162, REQ-COLL-018, REQ-LOCK-016
    prove("FV-CUS-24-views", "read-only reentrancy: while any member holds the Lock, a non-member (pool, token, oracle, keeper) reads no Collateralization record, total, pending or preview and no LPVault custody or liquidity view",
          And(Not(coll_view_ok), Not(lpv_view_ok), Not(liq_view_ok)),
          [Or([holder == m for m in members]), And([caller != m for m in members])])
    prove("FV-CUS-24-rescue", "getAccountRescueUnits answers under the Lock only while the AaveAdapter holds it; under LPVaultSwap, Collateralization or the LPVault it reverts Locked",
          Implies(Or([holder == m for m in members]), rescue_view_ok == (holder == ADAPTER)),
          [is_addr(holder), is_addr(caller)])
    return summary("fv_lpvault")


if __name__ == "__main__":
    raise SystemExit(main())
