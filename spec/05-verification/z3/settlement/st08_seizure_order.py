# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-42..45: allocating seized units over a proxy's records (SPEC-BACK-006, INV-015).

Records r_0..r_{N-1} of one account-market: credited c_i (<= 2^120), live liquidity l_i >= c_i,
distinct record IDs id_i. SPEC-BACK-006 keeps them in a linked list ordered largest-first at insertion,
ties by lowest record ID; within one debit that is the order "credited descending, ties lowest ID".
Greedy debit from the head: d_k = min(rem_k, c_k); rem_{k+1} = rem_k - d_k; rem_0 = u.
The call reverts unless rem_N == 0.
"""
from z3 import Int, IntVector, If, And, Or, Not, Distinct, Sum, Implies
from _common import check, done

CMAX = 2**120


def greedy(c, u):
    rem, ds = u, []
    for ci in c:
        di = If(rem < ci, rem, ci)
        ds.append(di)
        rem = rem - di
    return ds, rem


for N in (1, 2, 3, 5, 8):
    c = IntVector(f"c{N}", N)          # credited, already in debit order
    l = IntVector(f"l{N}", N)          # live NFT liquidity
    u = Int(f"u{N}")
    base = [And(ci >= 0, ci <= CMAX) for ci in c] + [l[i] >= c[i] for i in range(N)] \
        + [c[i] >= c[i + 1] for i in range(N - 1)] + [u >= 0, u <= Sum(c)]
    ds, rem = greedy(c, u)
    # MATH-ST-42 verifies: SPEC-BACK-006, INV-015, LIQ-022, Q-108, Q-165
    check("MATH-ST-42",
          f"N={N}: u <= sum(credited) => all u debited, every credited and live liquidity stays >= 0",
          base + [Or(rem != 0, Sum(ds) != u,
                     Or(*[c[i] - ds[i] < 0 for i in range(N)]),
                     Or(*[l[i] - ds[i] < 0 for i in range(N)]),
                     Sum([c[i] - ds[i] for i in range(N)]) != Sum(c) - u)],
          "PROVED")
    if N >= 2:
        # MATH-ST-43 verifies: SPEC-BACK-006, INV-015, Q-108
        check("MATH-ST-43",
              f"N={N}: at most one record is partially debited, and it is the last one touched",
              base + [Or(*[And(ds[i] > 0, ds[i] < c[i], ds[j] > 0)
                           for i in range(N) for j in range(i + 1, N)])],
              "PROVED")

# MATH-ST-44: the Q-170 comparator gives one deterministic order. Two permutations p, q that
# both sort N=5 records by (credited desc, id asc) with distinct IDs are identical.
N = 5
cr = IntVector("cr", N)
rid = IntVector("rid", N)
p = IntVector("p", N)
q = IntVector("q", N)

def before(i, j):          # record i strictly precedes record j
    return Or(cr[i] > cr[j], And(cr[i] == cr[j], rid[i] < rid[j]))

def perm(x):
    return [Distinct(*x)] + [And(xi >= 0, xi < N) for xi in x]

def sorted_by(x):
    cons = []
    for k in range(N - 1):
        for i in range(N):
            for j in range(N):
                cons.append(Implies(And(x[k] == i, x[k + 1] == j), before(i, j)))
    return cons

# MATH-ST-44 verifies: SPEC-BACK-006, INV-015, Q-170
check("MATH-ST-44",
      "Q-170 order (credited desc, lowest ID first) is unique for distinct record IDs",
      [Distinct(*rid)] + perm(p) + perm(q) + sorted_by(p) + sorted_by(q)
      + [Or(*[p[k] != q[k] for k in range(N)])],
      "PROVED")

# MATH-ST-45: if u > sum(credited) (only reachable when Hub shares != assets, see MATH-ST-40)
# the greedy leaves rem > 0; the LPVault must revert rather than under-debit.
c = IntVector("cx", 3)
u = Int("ux")
ds, rem = greedy(c, u)
# MATH-ST-45 verifies: SPEC-BACK-006, REQ-VAULT-055, Q-108, Q-160
check("MATH-ST-45",
      "u > sum(credited) leaves an undebited remainder (counterexample expected; must revert)",
      [And(ci >= 0, ci <= CMAX) for ci in c] + [u > Sum(c), rem > 0],
      "COUNTEREXAMPLE", show=[c[0], c[1], c[2], u])

done()
