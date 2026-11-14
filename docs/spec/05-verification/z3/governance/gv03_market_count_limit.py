# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-GOV-25..28: the MarketRegistry's market-count limit ([2.8] REQ-MREG-034, REQ-MREG-030) and the length of the
ParameterStore's chain-wide re-check walk it bounds (REQ-PSTORE-009).

State: c = marketCount, N = MAX_MARKET_COUNT >= 1. A new market takes id = c + 1 and is accepted only when id <= N
(then c' = c + 1); a relisting takes a Cancelled id with 1 <= id <= c and leaves c' = c; every other call leaves c.
The re-check walks ids 1..c. Gas model of the walk: g(c) = a + b * c with a >= 0 the fixed part and b > 0 the per-market
part; integers, no rounding except the floor in N_max = floor((cap - a) / b).
"""
from z3 import Int, Ints, Bool, If, And, Or, Not, Implies
from _common import check, done

TX_CAP = 2**24  # EIP-7825 per-transaction gas cap on Ethereum
STEPS = 6

N = Int("N")
c0 = Int("c0")
new = [Bool(f"new_{i}") for i in range(STEPS)]
rel = [Bool(f"relist_{i}") for i in range(STEPS)]
rid = [Int(f"relistId_{i}") for i in range(STEPS)]


def run(with_check):
    cs = [c0]
    accepted = []
    for i in range(STEPS):
        c = cs[-1]
        ok_new = And(new[i], Not(rel[i]), (c + 1 <= N) if with_check else True)
        ok_rel = And(rel[i], Not(new[i]), rid[i] >= 1, rid[i] <= c)
        accepted.append(Or(ok_new, ok_rel))
        cs.append(If(ok_new, c + 1, c))
    return cs, accepted


cs, _ = run(True)
# MATH-GOV-25 verifies: REQ-MREG-034, REQ-MREG-030
check("MATH-GOV-25",
      f"over {STEPS} listing calls (new or relisting) from any c0 <= N, marketCount never exceeds MAX_MARKET_COUNT",
      [N >= 1, c0 >= 0, c0 <= N, Or([x > N for x in cs])],
      "PROVED")

cs_nc, _ = run(False)
# MATH-GOV-26 verifies: REQ-MREG-034
check("MATH-GOV-26",
      "wrong reading: without the check at registration the count passes the limit (deliberate counterexample)",
      [N == 1, c0 == 1, new[0], Not(rel[0]), cs_nc[1] > N],
      "COUNTEREXAMPLE", show=[N, c0])

cs2, acc2 = run(True)
# MATH-GOV-27 verifies: REQ-MREG-034, REQ-MREG-030
check("MATH-GOV-27",
      "at the limit (c0 = N) a relisting of any cancelled id <= N is still accepted and leaves the count at N",
      [N >= 1, c0 == N, rel[0], Not(new[0]), rid[0] >= 1, rid[0] <= N, Or(Not(acc2[0]), cs2[1] != N)],
      "PROVED")

a, b, cap, nmax, n = Ints("a b cap N_max n")
# MATH-GOV-28 verifies: REQ-MREG-034, REQ-PSTORE-009
check("MATH-GOV-28",
      "with g(c) = a + b*c, every walk of c <= N_max = floor((cap - a) / b) markets fits the cap, and N_max + 1 markets do not",
      [a >= 0, b >= 1, cap > a, nmax == (cap - a) / b, n >= 0,
       Or(And(n <= nmax, a + b * n > cap), a + b * (nmax + 1) <= cap)],
      "PROVED")

# MATH-GOV-28b verifies: REQ-MREG-034
# Fixture figures of the REQ-MREG-034 example: 302,539 gas at 1 market, 9,515,531 at 64.
g1, g64 = 302_539, 9_515_531
b_fix = (g64 - g1) // 63
a_fix = g1 - b_fix
check("MATH-GOV-28b",
      f"fixture example: per-market gas floor((g64 - g1) / 63) = {b_fix}, and the mock-LPOracle walk alone would bound N at "
      f"{(TX_CAP - a_fix) // b_fix} under 2^24 gas (an upper bound only; the real LPOracle costs more per market)",
      [b == b_fix, a == a_fix, cap == TX_CAP, nmax == (cap - a) / b,
       Or(b != 146_237, nmax != 113, a + b * 64 > cap)],
      "PROVED")

done()
