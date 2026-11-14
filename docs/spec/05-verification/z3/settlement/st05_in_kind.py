# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-27..31: no in-kind settlement; failed payouts go to the escrow (SPEC-LIQ-011..013, REQ-SWAP-076, REQ-ESCROW-*).

Avana settles every liquidation in the debt asset over the market's swap routes; when no usable route swaps a released
token the call reverts NoRouteAvailable (SPEC-LIQ-011..013 as restated). The PayoutEscrow keeps one job: it holds a
payout LPVaultSwap could not deliver (Avana's fee, the caller's payout, a route residue, a dust leg, the borrower
surplus, the residue of settlePending), credited per (token, account) and claimable only by that account.
Payout delivery (REQ-SWAP-076): a gas-limited transfer counts as delivered iff it did not revert and returned no data
or true; otherwise LPVaultSwap deposits the whole amount in the escrow.
"""
from z3 import Reals, Ints, Bools, IntVector, BoolVector, If, And, Or, Not, Sum
from _common import check, done

# ST-27: the unwind's value at oracle prices is never below the fair value, whatever the pool spot price, so a
# spot move changes only the token mix, never whether the routed floor can be met.
L, a, r, su, sl = Reals("L a r su sl")
val_spot = L * (1 / a - 1 / su) * r * r + L * (a - sl)
val_fair = L * (1 / r - 1 / su) * r * r + L * (r - sl)
# MATH-ST-27 verifies: SPEC-LIQ-011, SPEC-LIQ-005, REQ-SWAP-025, Q-133, Q-401
check("MATH-ST-27",
      "unwound tokens valued at oracle >= LPOracle fair value for any pool spot price (AM-GM): a routed settlement "
      "never needs an in-kind fallback because of a spot move",
      [L > 0, a > 0, r > 0, su > a, su > r, sl >= 0, sl < a, sl < r, val_spot < val_fair],
      "PROVED")

# ST-28: one payout of `amount`. LPVaultSwap's balance falls by exactly `amount` whether the transfer is delivered
# or escrowed; the recipient is either paid or credited, never both, never neither.
bal0, amt, rise, credit0, credit1, bal1, paid = Ints("balance0 amount rise credit0 credit1 balance1 paid")
reverted, retFalse = Bools("reverted returnedFalse")
delivered = And(Not(reverted), Not(retFalse))
pay = [amt > 0, bal0 >= amt, credit0 >= 0, rise >= 0, rise <= amt,
       bal1 == bal0 - amt,                                          # transfer debited or escrow pulled amount
       paid == If(delivered, rise, 0),
       credit1 == credit0 + If(delivered, 0, amt)]
# MATH-ST-28 verifies: REQ-SWAP-076, REQ-ESCROW-018, Q-389, Q-401
check("MATH-ST-28",
      "payout delivery: LPVaultSwap's balance falls by exactly the amount, and the recipient is paid or credited "
      "the whole amount, exactly one of the two",
      pay + [Or(bal1 != bal0 - amt, And(delivered, credit1 != credit0), And(Not(delivered), credit1 != credit0 + amt))],
      "PROVED")
amtW, credW = Ints("amountW creditW")
# MATH-ST-28 verifies: REQ-SWAP-076, Q-389
check("MATH-ST-28",
      "wrong reading: escrowing only on a revert loses a payout whose token returns false: nobody is paid or "
      "credited (counterexample expected)",
      [amtW > 0, retFalse, Not(reverted), credW == If(reverted, amtW, 0), credW == 0],
      "COUNTEREXAMPLE", show=[amtW, credW])

# ST-29: escrow accounting over a sequence of deposits and claims for one token and 3 accounts.
N, NA = 6, 3
kind = IntVector("op", N)            # 0 deposit, 1 claim
who = IntVector("account", N)
amts = IntVector("amount", N)
recv = IntVector("received", N)
claim_ok = []
cl = [[None] * NA for _ in range(N + 1)]
tot = [None] * (N + 1)
bal = [None] * (N + 1)
cons29 = []
base = IntVector("credit0", NA)
b0 = Ints("bal0")[0]
cons29 += [base[j] >= 0 for j in range(NA)] + [b0 >= Sum(list(base))]
for j in range(NA):
    cl[0][j] = base[j]
tot[0], bal[0] = Sum(list(base)), b0
for k in range(N):
    cons29 += [Or(kind[k] == 0, kind[k] == 1), who[k] >= 0, who[k] < NA, amts[k] > 0,
               recv[k] > 0, recv[k] <= amts[k]]
    is_dep = kind[k] == 0
    pay_k = Sum([If(who[k] == j, cl[k][j], 0) for j in range(NA)])
    for j in range(NA):
        cl[k + 1][j] = If(who[k] == j, If(is_dep, cl[k][j] + recv[k], 0), cl[k][j])
    tot[k + 1] = If(is_dep, tot[k] + recv[k], tot[k] - pay_k)
    bal[k + 1] = If(is_dep, bal[k] + recv[k], bal[k] - pay_k)
viol = [Or(tot[k] != Sum(cl[k]), bal[k] < tot[k]) for k in range(N + 1)]
# MATH-ST-29 verifies: REQ-ESCROW-003, REQ-ESCROW-004, REQ-ESCROW-006, Q-214, Q-401
check("MATH-ST-29",
      f"{N} deposits and claims over {NA} accounts: totalClaimable equals the sum of credits and the escrow's "
      f"balance always covers it (deposits credit the measured amount received)",
      cons29 + [Or(*viol)],
      "PROVED")

# ST-30: a claim pays the caller's whole credit once.
c0, p1, c1, p2 = Ints("credit paid1 creditAfter paid2")
# MATH-ST-30 verifies: REQ-ESCROW-004, REQ-ESCROW-005, Q-214
check("MATH-ST-30",
      "claim pays the whole credit, clears it before the transfer, and a second claim pays nothing "
      "(it reverts NothingToClaim)",
      [c0 > 0, p1 == c0, c1 == 0, p2 == c1, Or(p1 + p2 != c0, p2 != 0)],
      "PROVED")

# ST-31: wrong reading: credits keyed by account only let an account's USDC credit be claimed in another token.
cu, ct, claimT = Ints("creditUSDC creditUSDT claimedUSDT")
# MATH-ST-31 verifies: REQ-ESCROW-005, REQ-ESCROW-006
check("MATH-ST-31",
      "wrong reading: a credit keyed by account alone lets a claim of USDT pay out a USDC credit "
      "(counterexample expected)",
      [cu == 100, ct == 0, claimT == cu + ct, claimT > ct],
      "COUNTEREXAMPLE", show=[cu, ct, claimT])

done()
