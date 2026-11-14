# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""MATH-ST-37..41: received / burned / Spoke share drop / debit equality (SPEC-BACK-007, INV-004, INV-014).

Aave V4 (pinned a3ef63e): Hub SharesMath with VIRTUAL_ASSETS = VIRTUAL_SHARES = 1e6.
  A = totalAddedAssets, S = addedShares of the vault-token asset; Su = proxy suppliedShares;
  s = collateral shares liquidated (Aave liquidation fee 0 -> all to LPVaultSwap).
  Spoke: proxy suppliedShares -= s                                    (share drop, exact)
  received u = previewRemoveByShares(s) = floor(s (A+1e6) / (S+1e6))   tokens to LPVaultSwap
  hub.remove(u): Hub shares removed hs = ceil(u (S+1e6) / (A+1e6)); A' = A - u; S' = S - hs
  Spoke asset view = floor(shares (A+1e6) / (S+1e6))
SPEC-BACK-007: the AaveAdapter burns the u units LPVaultSwap received; Collateralization requires
  sharesBefore - sharesAfter == u (DebitMismatch) and supplyBefore - supplyAfter == u (SupplyDropMismatch),
  and the gate Hub.getAddedAssets == Hub.getAddedShares holds at beginSeizure (INV-004, REQ-ADAPTER-037).
Wrong reading checked in ST-38: comparing the proxy's asset-view drop with u instead of its share drop.
"""
from z3 import Ints, And, Or, Not
from _common import check, floor_div, ceil_div, done

VV = 10**6
A, S, Su, s, u, hs, before, after, C, a, sh_add, sh_rem = Ints(
    "A S Su s u hs before after C a sh_add sh_rem")


def model(extra):
    return extra + [S >= 0, A >= 0, Su >= 1, Su <= S, s >= 1, s <= Su] \
        + floor_div(u, s * (A + VV), S + VV) \
        + ceil_div(hs, u * (S + VV), A + VV) \
        + floor_div(before, Su * (A + VV), S + VV) \
        + floor_div(after, (Su - s) * (A - u + VV), S - hs + VV)


# concrete drifted Hub state (ratio 1.001, e.g. interest after a config drift) keeps the search linear
near_one_up = [S == 10**12, A == 10**12 + 10**9, s >= 1000]

# MATH-ST-37 verifies: SPEC-BACK-007, INV-014, LIQ-POST-002, Q-160, Q-165
check("MATH-ST-37",
      "Hub shares == assets: share drop s == Hub shares removed == received == burned == debited, asset drop == u",
      model([A == S, S <= 2**120]) + [Or(u != s, hs != s, before - after != u)],
      "PROVED")

# MATH-ST-38 verifies: SPEC-BACK-007, Q-160
check("MATH-ST-38",
      "wrong reading: with shares != assets the asset-view drop differs from the units received (counterexample expected)",
      model(near_one_up) + [before - after != u],
      "COUNTEREXAMPLE", show=[A, S, Su, s, u, before, after])

# MATH-ST-39 verifies: SPEC-BACK-007, Q-160
check("MATH-ST-39",
      "ratio 1.001 (A > S): proxy share drop s == Hub shares removed hs, so the share-drop check holds",
      model(near_one_up) + [hs != s],
      "PROVED")
# MATH-ST-39 verifies: SPEC-BACK-007, Q-160
check("MATH-ST-39",
      "ratio 0.999 (A < S, a loss): share drop s != Hub shares removed hs (counterexample expected)",
      model([S == 10**12, A == 10**12 - 10**9, s >= 1000]) + [hs != s],
      "COUNTEREXAMPLE", show=[A, S, s, u, hs])

# MATH-ST-40 verifies: SPEC-BACK-007, INV-004, Q-160, Q-108
check("MATH-ST-40",
      "A > S: units received for all of a proxy's shares exceed its credited backing (counterexample expected)",
      model(near_one_up) + [C == Su, s == Su, u > C],
      "COUNTEREXAMPLE", show=[A, S, Su, u, C])

# MATH-ST-41: the Q-172 drift checks (vault-token drawCap 0, single Spoke, no reinvestment
# controller, liquidation fee 0) leave only add/remove on the asset; both preserve A == S.
# MATH-ST-41 verifies: INV-004, REQ-ADAPTER-037, SPEC-BACK-007, Q-172
check("MATH-ST-41",
      "A == S is preserved by Hub.add (shares floor) and Hub.remove (shares ceil) of any amount",
      [A == S, S >= 0, S <= 2**120, a >= 1, a <= 2**120]
      + floor_div(sh_add, a * (S + VV), A + VV) + ceil_div(sh_rem, a * (S + VV), A + VV)
      + [Or(sh_add != a, sh_rem != a)],
      "PROVED")

done()
