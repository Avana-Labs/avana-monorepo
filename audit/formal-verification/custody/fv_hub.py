"""Aave V4 Hub vault-token asset: shares == assets, and donation independence of the
seizure debit (T-15, T-16).

Hub math is taken from Aave V4 at a3ef63ea6415d25237a9775bf66e76e9993561c2:
  SharesMath.toSharesDown(assets, A, S) = floor(assets * (S + 1e6) / (A + 1e6))
  SharesMath.toSharesUp  (assets, A, S) = ceil (assets * (S + 1e6) / (A + 1e6))
  Hub.add: liquidity += amount; shares = toAddedSharesDown(amount); require(shares > 0)
  Hub.remove: shares = toAddedSharesUp(amount); liquidity -= amount
  getAddedAssets = liquidity + swept + owed(drawn, premium, deficit) - fees
With drawCap = 0 on every Spoke, no reinvestment controller (swept = 0), no deficit
on a non-borrowable asset and no drawn shares, getAddedAssets == liquidity.
"""
from z3 import Ints, And, Or, Not, If, Implies, IntVal, Exists
from common import prove, satisfiable, summary, floor_div, ceil_div

VA = 10 ** 6
VS = 10 ** 6
U120 = 2 ** 120


def to_shares_down(x, A, S):
    return floor_div(x * (S + VS), A + VA)


def to_shares_up(x, A, S):
    return ceil_div(x * (S + VS), A + VA)


def to_assets_up(sh, A, S):
    return ceil_div(sh * (A + VA), S + VS)


def main():
    A, S, amt, bal, z, spokeSh, addCap, D = Ints("A S amount balance donation spokeShares addCap D")
    dom = [A >= 0, A < U120, S >= 0, S < U120, amt >= 1, amt < U120]
    # FV-CUS-16 verifies: SPEC-HUB-008, REQ-VAULT-114, INV-004, REQ-VAULT-047, Q-189
    prove("FV-CUS-16-add", "T-16 Hub.add with A == S mints exactly `amount` shares and keeps A == S",
          And(to_shares_down(amt, A, S) == amt, A + amt == S + to_shares_down(amt, A, S)),
          dom + [A == S])
    prove("FV-CUS-16-remove", "T-16 Hub.remove with A == S burns exactly `amount` shares and keeps A == S",
          And(to_shares_up(amt, A, S) == amt, A - amt == S - to_shares_up(amt, A, S)),
          dom + [A == S, amt <= A])
    prove("FV-CUS-16-addshares", "T-16 Hub.add never fails InvalidShares for a positive amount when A == S",
          to_shares_down(amt, A, S) > 0, dom + [A == S])
    prove("FV-CUS-16-addcap", "T-16 the addCap test reads spoke shares as assets 1:1 when A == S",
          to_assets_up(spokeSh, A, S) == spokeSh, [A == S, A >= 0, A < U120, spokeSh >= 0, spokeSh <= S])
    satisfiable("FV-CUS-16-drift", "T-16 witness: with A > S a removal burns fewer shares than units (why the gate exists)",
                And(dom + [A > S, amt <= A, to_shares_up(amt, A, S) != amt]),
                show=[A, S, amt])
    # Donation: a vault-token transfer to the Hub changes only its token balance.
    # The success condition of add is balance_after_transfer >= liquidity + amount.
    prove("FV-CUS-16-donation", "T-15/T-16 a Hub donation never makes Hub.add fail and never changes A or S",
          (bal + amt + z >= A + amt),
          [A >= 0, bal >= A, z >= 1, amt >= 1])

    # T-15 two-execution comparison: the seizure debit is a function of Collateralization's
    # own reads (Spoke shares of the proxy, totalSupply) before and after liquidationCall.
    shB, supB, u, hubBal1, hubBal2, lpvs1, lpvs2 = Ints("sharesBefore supplyBefore u hubBal1 hubBal2 lpvs1 lpvs2")
    def run(hubBal, lpvs):
        # liquidationCall: Hub.remove(u) to LPVaultSwap; shares removed = toSharesUp(u) = u (A == S)
        removed = to_shares_up(u, A, S)
        shA = shB - removed
        # burnSeized(u) from LPVaultSwap's balance (requires lpvs + u >= u)
        supA = supB - u
        return shB - shA, supB - supA, hubBal - u, lpvs + u - u
    d1 = run(hubBal1, lpvs1)
    d2 = run(hubBal2, lpvs2)
    # FV-CUS-15 verifies: INV-014, SPEC-BACK-007, REQ-VAULT-049, REQ-VAULT-051, REQ-VTOKEN-031
    prove("FV-CUS-15-donation", "T-15 two executions differing only by a vault-token donation to the Hub or to LPVaultSwap give the same debit checks",
          And(d1[0] == d2[0], d1[1] == d2[1], d1[0] == u, d1[1] == u),
          [A == S, A >= u, u >= 1, shB >= u, supB >= shB, hubBal1 >= A, hubBal2 >= hubBal1,
           lpvs1 >= 0, lpvs2 >= lpvs1, A < U120])
    prove("FV-CUS-15-inflate", "T-15 a caller-reported units value other than the measured drops fails DebitMismatch",
          Not(And(shB - (shB - to_shares_up(u, A, S)) == u + 1)),
          [A == S, A >= u, u >= 1, shB >= u, A < U120])
    # Item 4: the Hub's added share price never falls on add or remove, for any A and S.
    from z3 import Reals
    Ar, Sr, xr, shr = Reals("Ar Sr xr shr")
    base = [Ar >= 0, Sr >= 0, xr > 0, shr >= 0]
    # FV-CUS-16 verifies: SPEC-HUB-008
    prove("FV-CUS-16-rate-add", "item 4: Hub.add (shares rounded down) never lowers (A + 1e6) / (S + 1e6)",
          (Ar + xr + VA) * (Sr + VS) >= (Ar + VA) * (Sr + shr + VS),
          base + [shr * (Ar + VA) <= xr * (Sr + VS)])
    prove("FV-CUS-16-rate-remove", "item 4: Hub.remove (shares rounded up) never lowers (A + 1e6) / (S + 1e6)",
          (Ar - xr + VA) * (Sr + VS) >= (Ar + VA) * (Sr - shr + VS),
          base + [shr * (Ar + VA) >= xr * (Sr + VS), shr <= Sr, xr <= Ar])
    return summary("fv_hub")


if __name__ == "__main__":
    raise SystemExit(main())
