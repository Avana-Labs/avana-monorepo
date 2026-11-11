"""Withdrawals and solvency (coordinator item 2).

Abstract account model on reals: collateral units C at price v per unit with LP
collateral factor CF, debt value D. A withdrawal with debt is accepted only if the
health factor read AFTER the Spoke withdrawal is >= hmin = max(1.00, the market's optional hard
floor (off by default), minHealthFactor) >= 1.00 (Q-398: no on-chain opening floor; T-58, owned by
the control area; used here as the Adapter's guard). Debt-free withdrawals need D == 0 on every reserve.
"""
from z3 import Reals, Ints, And, Or, Not, Implies
from common import prove, satisfiable, summary


def main():
    C, u, v, CF, D, hmin, Cq, Dq, b = Reals("C u v CF D hmin Cq Dq borrowOther")
    base = [C >= 0, u > 0, u <= C, v > 0, CF > 0, CF < 1, D >= 0, hmin >= 1]
    # FV-CUS-29 verifies: INV-045, REQ-VAULT-070, SPEC-CF-001
    prove("FV-CUS-29-post", "item 2: a withdrawal with debt that passes the post-withdrawal health check leaves the account solvent (CF-weighted collateral >= debt)",
          (C - u) * v * CF >= D,
          base + [D > 0, (C - u) * v * CF >= hmin * D])
    prove("FV-CUS-29-debtfree", "item 2: a debt-free withdrawal leaves the account with no debt to cover",
          (C - u) * v * CF >= D, base + [D == 0])
    satisfiable("FV-CUS-29-order", "item 2 witness: a health check read BEFORE the withdrawal would accept an insolvent result (why the spec reads it after)",
                And(base + [D > 0, C * v * CF >= hmin * D, (C - u) * v * CF < D]), show=[C, u, v, CF, D])
    # Liquidity for one's own units: the vault-token asset has no drawn liquidity (drawCap 0),
    # so Hub liquidity equals the sum of supplied shares and covers every proxy's own units.
    sh0, sh1, hubLiq, units = Ints("sh0 sh1 hubLiquidity units")
    prove("FV-CUS-29-liquidity", "item 2: Hub.remove never fails InsufficientLiquidity for a proxy withdrawing at most its own units (no draw on the vault-token asset)",
          units <= hubLiq, [sh0 >= 0, sh1 >= 0, hubLiq == sh0 + sh1, units >= 1, units <= sh0])
    return summary("fv_solvency")


if __name__ == "__main__":
    raise SystemExit(main())
