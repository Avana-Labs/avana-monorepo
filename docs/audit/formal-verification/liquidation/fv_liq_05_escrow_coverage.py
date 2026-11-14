"""FV-LIQ-05: PayoutEscrow (2.18), the payout escrow, the per-asset Coverage Spokes with Aave's eliminateDeficit at the
pin (2.14, 3.9), the coverage and deficit breakers they drive (SPEC-BRK-004) and the tail coverage
ratio the Lens reports (SPEC-CAP-008, REQ-LENS-034).

PayoutEscrow keeps its contract name but has one job (Q-401): it holds a payout LPVaultSwap could not deliver
(Avana's fee, the caller's payout, a route residue, a dust leg, the borrower surplus, the settlePending residue) for
its recipient. No in-kind share or remainder exists. The model is an inductive-invariant proof: arbitrary pre-state satisfying the invariant, any
operation (deposit of a measured amount, claim, a direct token transfer, a reentrant call),
post-state satisfies it. Mappings are Z3 arrays over an unbounded borrower domain; the sum is a
hook-maintained ghost, as a prover rule would keep it. One token is modelled: tokens share no state
in the escrow, so the per-token proof is the whole proof.

Coverage arithmetic follows Hub.eliminateDeficit / SharesMath at a3ef63ea (virtual assets and shares
1e6). Share-price claims are decided over the reals with the integrality step stated in the comment.
Each Coverage Spoke is one (Hub, asset) instance; the per-asset proofs carry two assets with their own
state, so a step on one asset is checked against the other's.
"""
import z3

from _lib import BPS, RAY, VIRTUAL, WAD, ceil_div, check, expect_violation, finish, prove

# ================================================================ PayoutEscrow
Addr = z3.IntSort()
claimable = z3.Array("claimable", Addr, z3.IntSort())
credited = z3.Array("ghostCredited", Addr, z3.IntSort())
claimed = z3.Array("ghostClaimed", Addr, z3.IntSort())
total, bal, ghost_sum = z3.Ints("totalClaimable escrowBalance ghostSumClaimable")
x = z3.Int("anyBorrower")
LPVS, ZERO, ESCROW = 1, 0, 2


def slot(cl, cr, cm, y):
    return z3.And(cl[y] >= 0, cr[y] == cm[y] + cl[y])


def inv(cl, cr, cm, tot, bl, gs, ys=(x,)):
    """Scalar part plus the per-borrower part at the slots `ys`. The per-borrower part is
    universally quantified: a step proof assumes it at the slots the operation reads or
    writes and at an arbitrary slot x, and proves it at x."""
    return z3.And(tot == gs, bl >= tot, gs >= 0, *[slot(cl, cr, cm, y) for y in ys])


sender, holder, b, amt, rcpt, rcv = z3.Ints("msgSender lockHolder borrower amount recipient received")
pre = inv(claimable, credited, claimed, total, bal, ghost_sum, ys=(x, b, sender))
locked, flag, xfer_ok = z3.Bools("lockIsLocked reentrancyFlag tokenTransferSucceeds")

# deposit(token, b, amt): pulls amt, measures received = balance rise, reverts TransferMismatch unless
# 0 < received <= amount, credits received (REQ-ESCROW-003). LPVaultSwap calls it only from the payout delivery of
# REQ-SWAP-076 after a failed transfer; `kind` names the payout (0 fee, 2 route residue, 3 dust leg, 4 borrower surplus,
# 5 settlePending residue). Kind 1, the caller's payout keeperOut, is never escrowed: a failed transfer of it reverts
# the liquidation (REQ-SWAP-026, Q-404).
kind, xfer_failed = z3.Int("payoutKind"), z3.Bool("payoutTransferFailed")
PAYOUT_KINDS = 6
dep_ok = z3.And(sender == LPVS, holder == LPVS, amt > 0, b != ZERO, z3.Not(flag), rcv > 0, rcv <= amt,
                kind >= 0, kind < PAYOUT_KINDS, kind != 1, xfer_failed)
c2 = z3.Store(claimable, b, claimable[b] + rcv)
post_dep = inv(c2, z3.Store(credited, b, credited[b] + rcv), claimed, total + rcv, bal + rcv,
               ghost_sum - claimable[b] + c2[b])
# FV-LIQ-05 verifies: REQ-ESCROW-002, REQ-ESCROW-003, REQ-ESCROW-006, REQ-ESCROW-009, REQ-ESCROW-010, REQ-ESCROW-011, INV-061
prove("FV-LIQ-05a", "T-41 base: the empty escrow satisfies the invariant (total = sum, balance >= total, credited = claimed + claimable)",
      [x >= 0], inv(z3.K(Addr, z3.IntVal(0)), z3.K(Addr, z3.IntVal(0)), z3.K(Addr, z3.IntVal(0)), 0, 0, 0))
prove("FV-LIQ-05b", "T-41 step: deposit (LPVaultSwap only, Lock held by LPVaultSwap, credit = measured balance rise "
      "0 < received <= amount, so a transfer-fee token is credited what arrived) preserves the invariant",
      [pre, dep_ok], z3.And(post_dep, rcv <= amt))
# claim(token, recipient)
amt_c = claimable[sender]
c3 = z3.Store(claimable, sender, 0)
claim_ok = z3.And(z3.Not(locked), z3.Not(flag), rcpt != ZERO, rcpt != ESCROW, amt_c > 0, xfer_ok)
# FV-LIQ-05 verifies: REQ-ESCROW-004, REQ-ESCROW-005, REQ-ESCROW-015, REQ-ESCROW-016, REQ-ESCROW-007, REQ-ESCROW-012, REQ-ESCROW-013, REQ-ESCROW-014
prove("FV-LIQ-05c", "T-41 step: claim (caller's own credit, whole amount, effects before the transfer) preserves the "
      "per-borrower part (credited = claimed + claimable) at every slot; the sum part is FV-LIQ-05p",
      [pre, claim_ok, claimable[sender] <= ghost_sum],
      z3.And(slot(c3, credited, z3.Store(claimed, sender, claimed[sender] + amt_c), x),
             total - amt_c == ghost_sum - claimable[sender], bal - amt_c >= total - amt_c))
prove("FV-LIQ-05d", "T-41: a claim whose token transfer fails reverts and leaves every credit and the balance unchanged",
      [pre, z3.Not(xfer_ok)], z3.Not(claim_ok))
prove("FV-LIQ-05e", "T-41: a claim changes only the caller's credit; no other borrower's credit moves",
      [pre, claim_ok, x != sender], c3[x] == claimable[x])
don = z3.Int("donation")
prove("FV-LIQ-05f", "T-41 step: a direct transfer to the escrow raises the balance and changes no credit",
      [pre, don >= 0], inv(claimable, credited, claimed, total, bal + don, ghost_sum))
prove("FV-LIQ-05g", "T-41: a reentrant deposit or claim during a token callback (flag set) reverts",
      [flag], z3.And(z3.Not(dep_ok), z3.Not(claim_ok)))
# FV-LIQ-05 verifies: REQ-ESCROW-002, REQ-ESCROW-011, REQ-SWAP-076, Q-401
prove("FV-LIQ-05g2", "Q-401: every credit the escrow records is a failed payout of one of the six payout kinds; a "
      "delivered payout or any other amount is never deposited",
      [pre, dep_ok], z3.And(xfer_failed, kind >= 0, kind < PAYOUT_KINDS))
# mutation: transfer before clearing the credit, with a callback re-entering claim when the flag is missing
c_twice = z3.Store(claimable, sender, 0)
mut_post = inv(c_twice, credited, z3.Store(claimed, sender, claimed[sender] + 2 * amt_c), total - 2 * amt_c,
               bal - 2 * amt_c, ghost_sum - claimable[sender])
expect_violation("FV-LIQ-05h", "mutation: no reentrancy flag and the transfer before the write (double claim); "
                 "FV-LIQ-05c's invariant catches it", [pre, amt_c > 0], mut_post, label="mutant")

# Scalar part with an exact sum over a finite borrower domain (4 borrowers; each operation
# touches one slot, so the step argument is the same for any domain size).
NB = 4
cl = [z3.Int(f"cl{i}") for i in range(NB)]
tot2, bal2, a2, r2 = z3.Ints("tot2 bal2 a2 received2")
who = z3.Int("slot")
inv2 = lambda c_, t_, b_: z3.And(t_ == z3.Sum(c_), b_ >= t_, *[ci >= 0 for ci in c_])
dep2 = [z3.If(who == i, cl[i] + r2, cl[i]) for i in range(NB)]
clm2 = [z3.If(who == i, 0, cl[i]) for i in range(NB)]
amt2 = z3.Sum([z3.If(who == i, cl[i], 0) for i in range(NB)])
# FV-LIQ-05 verifies: REQ-ESCROW-003, REQ-ESCROW-006, INV-061
prove("FV-LIQ-05p", "T-41 step (sum part): deposit of a measured amount and claim keep totalClaimable == sum of credits "
      "and balance >= totalClaimable", [inv2(cl, tot2, bal2), who >= 0, who < NB, a2 > 0, r2 > 0, r2 <= a2],
      z3.And(inv2(dep2, tot2 + r2, bal2 + r2), inv2(clm2, tot2 - amt2, bal2 - amt2)))
expect_violation("FV-LIQ-05q", "mutation: credit the requested amount instead of the measured balance rise; a token "
                 "charging a transfer fee then leaves the balance below totalClaimable",
                 [inv2(cl, tot2, bal2), who >= 0, who < NB, a2 > 0, r2 > 0, r2 <= a2],
                 inv2([z3.If(who == i, cl[i] + a2, cl[i]) for i in range(NB)], tot2 + a2, bal2 + r2),
                 show=[a2, r2, tot2, bal2], label="mutant")

# Independence from Avana switches (REQ-ESCROW-008): the revert conditions of deposit and claim are exactly those
# of REQ-ESCROW-002/003/004/007; none reads the pause state, a breaker, the address freeze, the market status or
# the payout kind. Two states that differ only in those
# switches give the same outcome.
pause1, pause2, mkt1, mkt2 = z3.Ints("pauseState pauseState2 marketStatus marketStatus2")
brk1, brk2, frz1, frz2 = z3.Bools("breakerTripped breakerTripped2 borrowerFrozen borrowerFrozen2")
auto1, auto2 = z3.Ints("creditedPayoutKind creditedPayoutKind2")


def claim_guard(_pause, _breaker, _frozen, _market, _auto):
    return claim_ok


def deposit_guard(_pause, _breaker, _frozen, _market, _auto):
    return dep_ok


# FV-LIQ-05 verifies: REQ-ESCROW-008, REQ-ESCROW-005, REQ-ESCROW-001
prove("FV-LIQ-05r", "a claim and a deposit succeed or revert identically in every application pause state, under every "
      "breaker, for a frozen borrower, an Offboarding market and every kind of payout the credit came from",
      [z3.BoolVal(True)],
      z3.And(claim_guard(pause1, brk1, frz1, mkt1, auto1) == claim_guard(pause2, brk2, frz2, mkt2, auto2),
             deposit_guard(pause1, brk1, frz1, mkt1, auto1) == deposit_guard(pause2, brk2, frz2, mkt2, auto2)))

# ================================================================ Coverage Spoke: coverDeficit (SPEC-FLR-001)
R_ = z3.Reals
A, S, sh, dRayIn, maxA, fb, amount, dRay, dE, burn, delta = R_(
    "A S heldShares deficitRay maxAmount fundedBalance amount dRay dE sharesBurned addedAssetsDrop")
v = VIRTUAL
ceil_def = z3.Real("ceilDeficit")
cov = [A >= 0, S >= 0, sh >= 0, sh <= S, dRayIn > 0, maxA > 0,
       fb * (S + v) <= sh * (A + v), (fb + 1) * (S + v) > sh * (A + v), fb >= 0,     # floor (SPEC-FLR-002)
       ceil_def * RAY >= dRayIn, (ceil_def - 1) * RAY < dRayIn,
       amount == z3.If(z3.And(maxA <= ceil_def, maxA <= fb), maxA, z3.If(ceil_def <= fb, ceil_def, fb)),
       amount > 0,
       dRay == z3.If(amount < ceil_def, amount * RAY, dRayIn),
       dE * RAY >= dRay, (dE - 1) * RAY < dRay,
       burn * (A + v) >= dE * (S + v), (burn - 1) * (A + v) < dE * (S + v),
       delta >= 0, delta <= dE]
# integrality: amount is an integer, so amount < ceilDeficit implies amount <= ceilDeficit - 1 < deficit / RAY;
# and dE, fb, sh are integers.
cov_int = [z3.Implies(amount < ceil_def, amount * RAY < dRayIn), z3.Implies(amount < ceil_def, dE == amount),
           z3.Implies(dRay == dRayIn, dE == ceil_def)]   # both are ceil(deficitRay / RAY)
# FV-LIQ-05 verifies: SPEC-FLR-001, REQ-FLR-018, REQ-FLR-019, REQ-FLR-031, REQ-FLR-027, DEF-005, DEF-006, DEF-014, DEF-F-004, DEF-POST-001, INV-041, INV-042
prove("FV-LIQ-05i", "T-46: coverage never exceeds the recorded deficit (dRay <= deficitRay), the funded balance "
      "(dE <= amount <= fundedBalance) or maxAmount; the burn fits the held shares (sharesBurned < held + 1, "
      "integer: <=, so the Hub's uint120 subtraction never reverts); a funded balance below the deficit covers "
      "part and the rest stays recorded (deficitRay - dRay > 0)",
      cov + cov_int, z3.And(dRay <= dRayIn, dE <= amount, amount <= fb, amount <= maxA, burn < sh + 1,
                            z3.Implies(amount < ceil_def, dRayIn - dRay > 0)), real=True)
# FV-LIQ-05 verifies: SPEC-FLR-001, DEF-POST-002
prove("FV-LIQ-05j", "T-46: covering a deficit never lowers other suppliers' share price: (A - drop + 1e6)/(S - burned + 1e6) "
      ">= (A + 1e6)/(S + 1e6), with drop <= dE the fall of total added assets",
      cov + cov_int + [burn <= sh], (A - delta + v) * (S + v) >= (A + v) * (S - burn + v), real=True)

# ---------------------------------------------------------------- access and per-asset isolation
# Two assets (0 and 1), each with its own Coverage Spoke instance. The instance on asset `a` reads only
# deficitRay[a][spoke]; coverDeficit succeeds only with COVERAGE_ROLE, the Spoke allowlisted on that instance,
# a non-zero deficit on its own asset and a non-zero amount (SPEC-FLR-001).
I = z3.IntSort()
deficit = z3.Array("deficitRay", I, z3.IntSort())        # per asset, for the covered Borrow Spoke
addedA = z3.Array("addedAssets", I, z3.IntSort())
addedS = z3.Array("addedShares", I, z3.IntSort())
held = z3.Array("coverageSpokeShares", I, z3.IntSort())  # each asset's Coverage Spoke shares
inst, other = z3.Ints("instanceAsset otherAsset")
role, allowed = z3.Bools("hasCoverageRole spokeAllowlisted")
amt_k, dRay_k, dE_k, burn_k = z3.Ints("coverAmount coverDRay coverDE coverBurn")
cover_ok = z3.And(role, allowed, deficit[inst] > 0, amt_k > 0)
iso = [inst >= 0, inst <= 1, other >= 0, other <= 1, inst != other, dRay_k >= 0, dRay_k <= deficit[inst],
       dE_k >= 0, burn_k >= 0, burn_k <= held[inst]]
deficit2 = z3.Store(deficit, inst, deficit[inst] - dRay_k)
addedA2 = z3.Store(addedA, inst, addedA[inst] - dE_k)
addedS2 = z3.Store(addedS, inst, addedS[inst] - burn_k)
held2 = z3.Store(held, inst, held[inst] - burn_k)
# FV-LIQ-05 verifies: REQ-FLR-016, REQ-FLR-018, REQ-FLR-029, REQ-FLR-030, REQ-FLR-032, DEF-005, DEF-F-001, DEF-F-002, DEF-F-003
prove("FV-LIQ-05k", "T-46: coverDeficit succeeds only for COVERAGE_ROLE, an allowlisted Borrow Spoke and a non-zero "
      "deficit on the instance's own asset; a call on another asset's instance, where this Spoke's deficit is 0, "
      "reverts NothingToCover even when the Spoke owes a deficit in that other asset",
      iso, z3.And(z3.Implies(cover_ok, z3.And(role, allowed, deficit[inst] > 0)),
                  z3.Implies(z3.And(deficit[inst] == 0, deficit[other] > 0), z3.Not(cover_ok))))
# FV-LIQ-05 verifies: REQ-FLR-040, REQ-FLR-004, REQ-FLR-027, DEF-008, DEF-017, INV-071, INV-042
prove("FV-LIQ-05l", "no contagion between assets: a coverage on one asset's instance leaves the other asset's deficit, "
      "added assets and shares and its Coverage Spoke's shares (so its funded balance) unchanged, and a shortfall in "
      "one asset stays recorded in that asset (deficit after >= 0)",
      iso + [cover_ok],
      z3.And(deficit2[other] == deficit[other], addedA2[other] == addedA[other], addedS2[other] == addedS[other],
             held2[other] == held[other], deficit2[inst] >= 0))

# fund (REQ-FLR-010, REQ-FLR-038): shares minted round down; the funder cannot dilute others
fa, minted = R_("fundAmount minted")
# FV-LIQ-05 verifies: REQ-FLR-010, REQ-FLR-038, REQ-FLR-015
prove("FV-LIQ-05m", "fund: minted = floor(amount (S+1e6)/(A+1e6)) never lowers the share price for existing holders",
      [A >= 0, S >= 0, fa > 0, minted >= 0, minted * (A + v) <= fa * (S + v)],
      (A + fa + v) * (S + v) >= (A + v) * (S + minted + v), real=True)

# ================================================================ withdrawal lifecycle (SPEC-FLR-003, T-47)
PENDING, CANCELLED, EXECUTED = 1, 2, 3
st, st2, now, ready, req_amt, wd, fb2 = z3.Ints("status statusAfter now executableAt requestAmount withdrawn fundedBal")
is_admin = z3.Bool("hasReserveAdminRole")
exec_ok = z3.And(is_admin, st == PENDING, now >= ready)
# FV-LIQ-05 verifies: SPEC-FLR-003, REQ-FLR-023, REQ-FLR-024, REQ-FLR-025, REQ-FLR-033, DEF-009
prove("FV-LIQ-05n", "T-47: executeWithdrawal succeeds only for RESERVE_ADMIN_ROLE, a Pending request and now >= executableAt; "
      "it sets Executed and withdraws min(request, fundedBalance)",
      [exec_ok, st2 == EXECUTED, wd == z3.If(req_amt <= fb2, req_amt, fb2), req_amt > 0, fb2 >= 0],
      z3.And(now >= ready, st2 != PENDING, wd <= req_amt, wd <= fb2))
prove("FV-LIQ-05o", "T-47: a request executes at most once (Executed and Cancelled are terminal: no transition returns to Pending)",
      [z3.Or(st == EXECUTED, st == CANCELLED)], z3.Not(exec_ok))
t_req, delay, liq, st3 = z3.Ints("requestTime delay hubLiquidity statusAfterCall")
remove_ok = liq >= wd
# executeWithdrawal is atomic: the status write before HUB.remove is undone when remove reverts.
st_after = z3.If(z3.And(exec_ok, remove_ok), EXECUTED, st)
# FV-LIQ-05 verifies: SPEC-FLR-003, REQ-FLR-023, REQ-FLR-034, REQ-FLR-033
prove("FV-LIQ-05s", "T-47: a request recorded at t executes no earlier than t + RESERVE_WITHDRAWAL_DELAY, and a call "
      "reverted by the Hub's InsufficientLiquidity leaves the request Pending for a later execution",
      [ready == t_req + delay, delay > 0, st == PENDING, wd >= 0, st3 == st_after],
      z3.And(z3.Implies(now < t_req + delay, z3.Not(exec_ok)), z3.Implies(z3.Not(remove_ok), st3 == PENDING)))

# ================================================================ coverage and deficit breakers (SPEC-BRK-004)
# COVERAGE of debt reserve r <=> its coverageSpoke's isBelowMinimum() returns true or reverts;
# DEFICIT <=> getSpokeDeficitRay(asset, spoke) > breakerDeficitMax(asset) * RAY. preBorrowCheck and
# preWithdrawCheck (with debt in r) refuse while either holds; repay, liquidation, coverage, fund and
# settlePending never take the breaker as an input.
fbA, minA, fbB, minB, defA, maxDefA, defB, maxDefB = z3.Ints(
    "fundedA minimumA fundedB minimumB deficitRayA breakerDeficitMaxA deficitRayB breakerDeficitMaxB")
revA, revB = z3.Bools("isBelowMinimumCallFailsA isBelowMinimumCallFailsB")
covA = z3.Or(revA, fbA < minA)
covB = z3.Or(revB, fbB < minB)
defTripA = defA > maxDefA * RAY
defTripB = defB > maxDefB * RAY
borrow_ok_A = z3.Not(z3.Or(covA, defTripA))       # other conditions of the debt breaker only make it stricter
borrow_ok_B = z3.Not(z3.Or(covB, defTripB))
# FV-LIQ-05 verifies: REQ-FLR-014, SPEC-BRK-004, DEF-018, DEF-F-007, REQ-FLR-013, REQ-FLR-021
prove("FV-LIQ-05t", "coverage breaker: a borrow (or withdraw-with-debt) of asset A succeeds only while A's Coverage Spoke "
      "holds at least its minimum, its isBelowMinimum() does not revert (fail closed) and A's deficit on the Spoke is "
      "within breakerDeficitMax; A's breakers never change whether asset B can be borrowed",
      [minA >= 0, minB >= 0, maxDefA >= 0, maxDefB >= 0],
      z3.And(z3.Implies(borrow_ok_A, z3.And(fbA >= minA, z3.Not(revA), defA <= maxDefA * RAY)),
             z3.Implies(revA, z3.Not(borrow_ok_A)),
             borrow_ok_B == z3.Not(z3.Or(revB, fbB < minB, defB > maxDefB * RAY))))

# Funding clears COVERAGE: fund(x) mints m = floor(x(S+1e6)/(A+1e6)); the instance's balance becomes
# floor((sh+m)(A+x+1e6)/(S+m+1e6)) > fb + x - p' - 1, p' = (A+x+1e6)/(S+m+1e6), so x >= (min - fb) + p' + 1 clears it.
xf, m_, fbn, minR = R_("fundX mintedShares fundedAfter minimumR")
fund_cov = [A >= 0, S >= 0, sh >= 0, sh <= S, xf > 0, m_ >= 0,
            m_ * (A + v) <= xf * (S + v), (m_ + 1) * (A + v) > xf * (S + v),
            fb * (S + v) <= sh * (A + v), (fb + 1) * (S + v) > sh * (A + v),
            fbn * (S + m_ + v) <= (sh + m_) * (A + xf + v), (fbn + 1) * (S + m_ + v) > (sh + m_) * (A + xf + v)]
# FV-LIQ-05 verifies: REQ-FLR-014, REQ-FLR-010, SPEC-FLR-002, DEF-018
prove("FV-LIQ-05u", "the coverage breaker clears with funding: fund(x) raises fundedBalance by more than x - p' - 1, "
      "p' the share price after the add, so x >= (minimum - fundedBalance) + p' + 1 brings it back to the minimum "
      "(the 'few wei' of REQ-FLR-014 are this rounding)",
      fund_cov, (fbn - fb - xf + 1) * (S + m_ + v) > -(A + xf + v), real=True)

# Coverage clears DEFICIT: with amount >= ceil(deficitRay/RAY) - breakerDeficitMax, the deficit left is within the limit.
dmax = z3.Real("breakerDeficitMaxR")
# FV-LIQ-05 verifies: REQ-FLR-021, SPEC-BRK-004, DEF-018
prove("FV-LIQ-05v", "the deficit breaker clears with coverage: a coverDeficit whose amount reaches ceil(deficitRay/RAY) - "
      "breakerDeficitMax leaves deficitRay - dRay <= breakerDeficitMax x RAY; a whole coverage leaves 0",
      cov + cov_int + [dmax >= 0, amount >= ceil_def - dmax],
      z3.And(dRayIn - dRay <= dmax * RAY, z3.Implies(amount >= ceil_def, dRayIn - dRay == 0)), real=True)

# Exact-integer replay of the REQ-FLR-014 and DEF-018 examples on the Hub share math.
def fb_of(shares, a, s):
    return shares * (a + VIRTUAL) // (s + VIRTUAL)


def cover(shares, a, s, dE_):
    burned = ceil_div(dE_ * (s + VIRTUAL), a + VIRTUAL)
    return shares - burned, a - dE_, s - burned


def fund(shares, a, s, amount_):
    m = amount_ * (s + VIRTUAL) // (a + VIRTUAL)
    return shares + m, a + amount_, s + m


E18 = 10**18
MIN = 100_000 * E18
Ah, Sh = 2_100_000 * E18, 2_000_000 * E18
sh0 = ceil_div(MIN * (Sh + VIRTUAL), Ah + VIRTUAL)            # least shares with fundedBalance >= 100,000 GHO
assert fb_of(sh0, Ah, Sh) >= MIN
results = {}
for deficit_gho in (5_200, 1_250):
    s1, a1, S1 = cover(sh0, Ah, Sh, deficit_gho * E18)
    left = fb_of(s1, a1, S1)
    extra = 0
    while fb_of(*fund(s1, a1, S1, deficit_gho * E18 + extra)) < MIN:
        extra += 1
    results[deficit_gho] = (left, extra)
dmax_gho = 1_000 * E18
# FV-LIQ-05 verifies: REQ-FLR-014, DEF-018, SPEC-BRK-004
check("FV-LIQ-05w", "REQ-FLR-014 / DEF-018 examples at A = 2,100,000, S = 2,000,000: a 1,250 GHO deficit trips DEFICIT "
      "(> 1,000 GHO); covering 5,200 or 1,250 GHO leaves the reserve 5,200 or 1,250 GHO lower (below the 100,000 "
      "minimum, COVERAGE trips); funding the same amount plus at most 2 wei clears it",
      1_250 * E18 * RAY > dmax_gho * RAY and all(MIN - left <= d * E18 + 2 and MIN - left >= d * E18 - 2 and e <= 2
                                                 for d, (left, e) in results.items()),
      f"{ {d: dict(fundedAfterCover=l, extraWei=e) for d, (l, e) in results.items()} }")

# ================================================================ tail coverage ratio (SPEC-CAP-008, REQ-LENS-034)
# Two tokens. tail_t = min(ceil(capSl_t * CF_t / 1e4), drawCapUsd) (final text, no opening health factor); fundedUsd = floor(funded * Pa / 10^da);
# ratio = floor(fundedUsd * 1e4 / max_t tail_t). Exact values (no rounding) are the real-valued terms of SPEC-CAP-007 (ii).
capA, capB, cfA, cfB, hmin, drawUsd, fundedExact, fundedUsd, tA, tB, tailUsd, ratio = R_(
    "capPlusSlicesA capPlusSlicesB cfA cfB minOpeningHF drawCapUsd fundedUsdExact fundedUsd tailA tailB tailUsd ratioBps")
eA, eB = R_("exactTailA exactTailB")
tail_model = [capA >= 0, capB >= 0, cfA > 0, cfA <= BPS, cfB > 0, cfB <= BPS, hmin >= WAD, drawUsd >= 0,
              fundedExact >= 0,
              eA == z3.If(capA * cfA / BPS <= drawUsd, capA * cfA / BPS, drawUsd),
              eB == z3.If(capB * cfB / BPS <= drawUsd, capB * cfB / BPS, drawUsd),
              # tail rounds up: tail >= exact (ceil of the token term, min with the integer draw-cap total)
              tA >= eA, tA < eA + 1, tB >= eB, tB < eB + 1,
              tailUsd == z3.If(tA >= tB, tA, tB), tailUsd > 0,
              fundedUsd <= fundedExact, fundedUsd > fundedExact - 1,
              ratio * tailUsd <= fundedUsd * BPS, (ratio + 1) * tailUsd > fundedUsd * BPS]
# FV-LIQ-05 verifies: SPEC-CAP-008, REQ-LENS-034, SPEC-FLR-005, SPEC-CAP-007, REQ-FLR-041
prove("FV-LIQ-05x", "the tail coverage ratio never overstates coverage: ratioBps x exactTail_t <= fundedUsd x 10^4 for "
      "every token, so ratioBps >= 10,000 implies the funded reserve covers every token's tail term of SPEC-CAP-007 (ii)",
      tail_model, z3.And(ratio * eA <= fundedExact * BPS, ratio * eB <= fundedExact * BPS,
                         z3.Implies(ratio >= BPS, z3.And(fundedExact >= eA, fundedExact >= eB))), real=True)


def tail_usd8(cap_plus_slices_usd, cf_bps, draw_cap_usd8):
    return min(ceil_div(cap_plus_slices_usd * 10**8 * cf_bps, BPS), draw_cap_usd8)


def ratio_bps(funded_usd8, tail):
    return 2**256 - 1 if tail == 0 else funded_usd8 * BPS // tail


funded_usd8 = 100_000 * E18 * 10**8 // E18                     # floor(funded * Pa / 10^da), GHO at 1e8
cap8 = min(ceil_div(450_000 * 10**8 * 3120, BPS), 600_000 * 10**8)   # SPEC-CAP-008: booked x CF_t, no h_o
usdt = tail_usd8(330_000, 3120, 600_000 * 10**8)
usdc = tail_usd8(275_000, 3120, 600_000 * 10**8)
usde = tail_usd8(420_000, 3120, 2_000_000 * 10**8)
usde2 = tail_usd8(620_000, 3120, 2_000_000 * 10**8)
worst = max([("USDT", usdt), ("USDC", usdc)], key=lambda kv: kv[1])
# FV-LIQ-05 verifies: SPEC-CAP-008, REQ-LENS-034, SPEC-FLR-005, REQ-FLR-041
check("FV-LIQ-05y", "tail coverage examples: SPEC-CAP-008 tail 14,040,000,000,000 and 7,122 bps; REQ-LENS-034 tail_USDT "
      "$102,960 (worstToken USDT), tail_USDC $85,800, 9,712 bps; SPEC-FLR-005 7,631 bps; REQ-FLR-041 5,169 bps",
      cap8 == 14_040_000_000_000 and ratio_bps(funded_usd8, cap8) == 7_122
      and usdt == 10_296_000_000_000 and usdc == 8_580_000_000_000 and worst[0] == "USDT"
      and ratio_bps(funded_usd8, usdt) == 9_712 and ratio_bps(funded_usd8, usde) == 7_631
      and ratio_bps(funded_usd8, usde2) == 5_169,
      f"cap8={cap8} usdt={usdt} usdc={usdc} usde={usde} usde2={usde2}")

# The text before FV-LIQ-F-15 counted an unlimited Hub drawCap as type(uint256).max inside drawCapUsd = sum(drawCap x Pa),
# which overflows uint256 for any price above 1 (kept as a mutant). The final REQ-LENS-034 / SPEC-CAP-008 set
# drawCapUsd = type(uint256).max without computing the sum when any drawCap is MAX_ALLOWED_SPOKE_CAP (type(uint40).max),
# so every summed cap is below 2^40.
dcap, pa, nsp, sm = z3.Ints("drawCapCounted assetPrice8 spokeCount drawCapUsdSum")
# FV-LIQ-05 verifies: REQ-LENS-034, SPEC-CAP-008
expect_violation("FV-LIQ-05z", "mutation (the REQ-LENS-034 text before FV-LIQ-F-15): an unlimited drawCap counted as "
                 "type(uint256).max makes drawCapUsd = drawCap x Pa overflow uint256 for every asset price above 1",
                 [dcap == 2**256 - 1, pa >= 10**8, pa <= 10**14], dcap * pa < 2**256, show=[dcap, pa], label="mutant")
prove("FV-LIQ-05z2", "REQ-LENS-034 / SPEC-CAP-008 (final): with every summed drawCap below MAX_ALLOWED_SPOKE_CAP = 2^40 - 1, "
      "a price below 1e14 (8 decimals) and at most 2^16 Borrow Spokes, drawCapUsd = sum(drawCap x Pa) stays below 2^128",
      [dcap >= 0, dcap < 2**40 - 1, pa >= 0, pa <= 10**14, nsp >= 0, nsp <= 2**16, sm >= 0, sm <= nsp * dcap * pa],
      sm < 2**128)

# ---------------- REQ-SWAP-076 / REQ-ESCROW-018: every payout falls back to the escrow (Q-389, N2a) ----------------
# A payout of `amt` to `rcp` (fee recipient, caller or borrower): the gas-limited transfer either succeeds or not;
# on failure the escrow deposit credits rcp. The settlement outcome depends only on the escrow deposit.
amt, delivered, escrowed = z3.Ints("payout delivered escrowed")
tx_ok, dep_ok, settled = z3.Bools("transferOk depositOk settled")
rule = [amt > 0,
        delivered == z3.If(tx_ok, amt, 0),
        escrowed == z3.If(z3.Not(tx_ok), amt, 0),
        settled == z3.Or(tx_ok, dep_ok)]
# FV-LIQ-05 verifies: REQ-SWAP-076, REQ-SWAP-028, REQ-SWAP-082, REQ-ESCROW-018, Q-389
prove("FV-LIQ-05aa", "N2a: a failed payout transfer (a blocklisted feeRecipient, caller or borrower) never reverts the "
      "settlement while the escrow accepts the deposit, and the amount is either delivered or credited in full",
      rule + [dep_ok],
      z3.And(settled, delivered + escrowed == amt))
# FV-LIQ-05 verifies: REQ-SWAP-064, REQ-SWAP-076
expect_violation("FV-LIQ-05am", "mutation (the text before Q-389): an unguarded fee transfer reverts the whole "
                 "liquidation when feeRecipient is blocklisted",
                 [amt > 0, z3.Not(tx_ok), settled == tx_ok],
                 settled, show=[tx_ok, settled], label="mutant")

finish()
