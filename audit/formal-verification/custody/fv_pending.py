"""Pending-settlement payout (SPEC-BACK-012, REQ-VAULT-139, T-08 part, F-11 rounding).

out = mulDiv(amount, x, units, Floor) for a partial settlement, the exact remainder
for the final one. Proved: no overpayment, the backing per remaining unit never
falls, the final settlement pays exactly what is left, and any sequence of
settlements that retires every unit pays exactly the stored amount.
"""
from z3 import Ints, And, Implies, If, IntVal
from common import prove, concrete, summary, floor_div

U120 = 2 ** 120
U128 = 2 ** 128


def pay(a, U, x):
    return If(x == U, a, floor_div(a * x, U))


def main():
    a, U, x, y, z = Ints("amount units x y z")
    dom = [U >= 1, U < U120, a >= 0, a < U128 * U120]
    # FV-CUS-08 verifies: SPEC-BACK-012, REQ-VAULT-139, REQ-VAULT-137, REQ-VAULT-146
    prove("FV-CUS-08-nooverpay", "T-08 a settlement of x <= units pays at most the stored amount, never negative",
          And(pay(a, U, x) >= 0, pay(a, U, x) <= a), dom + [x >= 1, x <= U])
    prove("FV-CUS-08-backing", "F-11 the pool tokens left per remaining unit never fall: (a - out) * units >= a * (units - x)",
          (a - pay(a, U, x)) * U >= a * (U - x), dom + [x >= 1, x < U])
    prove("FV-CUS-08-final", "T-08 the final settlement pays exactly the remainder (nothing stranded)",
          pay(a, U, U) == a, dom)
    # Three-step sequence x, y, rest retires every unit and pays exactly a.
    o1 = pay(a, U, x)
    a1, U1 = a - o1, U - x
    o2 = pay(a1, U1, y)
    a2, U2 = a1 - o2, U1 - y
    o3 = pay(a2, U2, U2)
    prove("FV-CUS-08-sequence", "T-08 any split x, y, rest of the pending units pays exactly the stored amount in total",
          o1 + o2 + o3 == a, dom + [x >= 1, y >= 1, x + y < U])
    prove("FV-CUS-08-zero", "REQ-VAULT-146 a zero stored amount pays zero (the transfer is skipped)",
          pay(IntVal(0), U, x) == 0, [U >= 1, x >= 1, x <= U])
    # Spec example.
    concrete("FV-CUS-08-example", "SPEC-BACK-012 example: x = 1,000,000,000 of 1,575,000,000 pays 799,999,999 / 1,249,999,999",
             1_259_999_999 * 10 ** 9 // 1_575_000_000 == 799_999_999
             and 1_968_749_999 * 10 ** 9 // 1_575_000_000 == 1_249_999_999
             and 1_259_999_999 - 799_999_999 == 460_000_000
             and 1_968_749_999 - 1_249_999_999 == 718_750_000)
    # Item 3: a fee-on-transfer pool token (excluded at listing, REQ-ARCH-014) would leave
    # Collateralization holding less than the stored pending amount, so the final
    # settlement (which pays the stored remainder) would revert and strand the balance.
    from z3 import Ints as _I
    from common import satisfiable
    fee, held = _I("feeBps held")
    satisfiable("FV-CUS-08-fot", "item 3 witness: with a fee-on-transfer token the final settlePending pays more than Collateralization holds (why REQ-ARCH-014 excludes them)",
                And(a >= 10 ** 4, fee >= 1, fee <= 100, held == a - (a * fee) / 10 ** 4, pay(a, U, U) > held, U >= 1),
                show=[a, fee, held])
    return summary("fv_pending")


if __name__ == "__main__":
    raise SystemExit(main())
