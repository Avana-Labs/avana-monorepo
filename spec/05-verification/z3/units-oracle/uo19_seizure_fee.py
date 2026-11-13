# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-UO-78 — seizure under Aave's liquidation fee on a vault-token key ([2.3] SPEC-BACK-007, REQ-VAULT-176).

A liquidation moves u units to LPVaultSwap (the Hub's transfer, then the Adapter's burn) and f fee shares to Aave's
fee receiver inside the Hub (no vault token leaves the Hub). settleSeizure requires supply drop == u and share drop
>= u, reconciles the account against sharesBefore - f (debiting the shortfall into pending), then debits u.
Backing gap g = totalCredited + pending - totalSupply.
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from z3 import Ints, And, If
from _common import prove, witness, note, finish

C, P, S, A, H, u, f = Ints('C P S A H u f')
# C total credited, P pending units, S supply, A the account's credit, H its shares before (snapshot).
base = [C >= 0, P >= 0, S >= 0, A >= 0, H >= 0, u >= 1, f >= 0, A <= C, H >= u + f, C + P - S >= 0]
short = If(A > H - f, A - (H - f), 0)          # reconcile against sharesBefore - f
C2 = C - short - u
P2 = P + short
S2 = S - u
A2 = A - short - u

# MATH-UO-78 verifies: SPEC-BACK-007, REQ-VAULT-176, INV-058
prove('MATH-UO-78a', 'the backing gap is unchanged: (C - short - u) + (P + short) - (S - u) == C + P - S',
      base + [A >= H], C2 + P2 - S2 == C + P - S)
# MATH-UO-78 verifies: SPEC-BACK-007, REQ-VAULT-176
prove('MATH-UO-78b', 'with credit equal to shares at the snapshot (A == H), exactly the fee units go to pending and the '
      'credit after equals the shares after (H - u - f)',
      base + [A == H], And(P2 == P + f, A2 == H - u - f))
# MATH-UO-78 verifies: SPEC-BACK-007, REQ-VAULT-176
witness('MATH-UO-78c', 'wrong reading: debiting u + f with nothing moved to pending lowers the gap by f, below 0 '
        'when the gap was smaller than the fee',
        base + [f >= 1, C + P - S < f, (C - u - f) + P - (S - u) < 0])
# MATH-UO-78 verifies: SPEC-BACK-007, REQ-VAULT-176
witness('MATH-UO-78d', 'wrong reading: debiting only u leaves the account credited above its shares by f',
        base + [A == H, f >= 1, A - u > H - u - f])
# MATH-UO-78 verifies: REQ-VAULT-176
note('MATH-UO-78e', 'REQ-VAULT-176 example: u = 1,000, f = 100 on an account credited 10,000 = its shares',
     f'records lose {1000 + 100}, pending +{100}, supply -{1000}, gap change {(-1100) + 100 - (-1000)}')
finish()
