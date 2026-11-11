"""Seizure list of one account-market (SPEC-BACK-006, INV-015, T-12).

The list is modelled as N slots in list order; a slot with credited 0 is a record
that is not linked (unlinked or never used), which the walk skips exactly as an
unlinked record is skipped. Credited values and record IDs are symbolic.
"""
from z3 import Int, Ints, And, Or, Not, If, Implies, Sum, BoolVal
from common import prove, satisfiable, summary, MAX_CREDITED

N = 5


def zmin(a, b):
    return If(a <= b, a, b)


def debit(c, u):
    """Greedy walk from the head. Returns (new credited list, takes, remainder)."""
    rem = u
    out, takes = [], []
    for j in range(N):
        t = zmin(rem, c[j])
        takes.append(t)
        out.append(c[j] - t)
        rem = rem - t
    return out, takes, rem


def sorted_desc(c, ids):
    """Largest first, ties by lowest record ID, over linked entries in order."""
    conds = []
    for j in range(N):
        for k in range(j + 1, N):
            conds.append(Implies(And(c[j] > 0, c[k] > 0),
                                 Or(c[j] > c[k], And(c[j] == c[k], ids[j] < ids[k]))))
    return And(conds)


def main():
    c = [Int(f"c{j}") for j in range(N)]
    ids = [Int(f"id{j}") for j in range(N)]
    u, a, b = Ints("u a b")
    dom = [And(x >= 0, x <= MAX_CREDITED) for x in c] + [u >= 0, a >= 0, b >= 0]
    total = Sum(c)

    out, takes, rem = debit(c, u)
    ok = rem == 0
    # FV-CUS-12 verifies: SPEC-BACK-006, INV-015, REQ-VAULT-054, REQ-VAULT-055, REQ-VAULT-117, REQ-VAULT-134
    prove("FV-CUS-12-exact", "T-12 a debit succeeds iff u <= sum credited, and then debits exactly u",
          And(ok == (u <= total), Implies(ok, And(Sum(takes) == u, Sum(out) == total - u))), dom)
    prove("FV-CUS-12-bounds", "T-12 each take is within [0, credited] and credited never goes negative",
          And([And(takes[j] >= 0, takes[j] <= c[j], out[j] >= 0) for j in range(N)]), dom)
    prove("FV-CUS-12-prefix", "T-12 every record before the last one touched is drained to 0 (only the last is partial)",
          And([Implies(takes[k] > 0, out[j] == 0) for k in range(N) for j in range(k)]), dom + [ok])
    prove("FV-CUS-12-stop", "T-12 the walk stops once covered: no record after the covering prefix is touched",
          And([Implies(Sum(c[:j + 1]) >= u, And([takes[k] == 0 for k in range(j + 1, N)]))
               for j in range(N)]), dom)
    prove("FV-CUS-12-onepartial", "T-12 at most one record is partially debited",
          Sum([If(And(out[j] > 0, out[j] < c[j]), 1, 0) for j in range(N)]) <= 1, dom + [ok])
    prove("FV-CUS-12-revert", "T-12 a debit above sum credited fails (InsufficientCredit) - the call reverts with no change",
          Not(ok), dom + [u > total])

    # Additivity: debit a then b == debit a + b.
    o1, t1, r1 = debit(c, a)
    o2, t2, r2 = debit(o1, b)
    o3, t3, r3 = debit(c, a + b)
    prove("FV-CUS-12-split", "T-12 splitting: debit(a) then debit(b) leaves the same records and takes as debit(a+b)",
          And(And([o2[j] == o3[j] for j in range(N)]),
              And([t1[j] + t2[j] == t3[j] for j in range(N)]),
              (And(r1 == 0, r2 == 0)) == (r3 == 0)),
          dom + [a + b <= total])
    prove("FV-CUS-12-splitfail", "T-12 splitting cannot debit more: if a+b > sum the split also fails somewhere",
          Or(r1 > 0, r2 > 0), dom + [a + b > total])

    # Insertion keeps largest-first order with ties by lowest ID.
    cn, idn = Ints("cnew idnew")
    ins_dom = [cn >= 1, cn <= MAX_CREDITED] + [idn > i for i in ids] + \
              [And(x >= 1, x <= MAX_CREDITED) for x in c[:N - 1]] + [c[N - 1] == 0]
    # list of N-1 linked records (slots 0..N-2), insert into an N-slot list
    # position k = first j with c[j] < cn, else N-1 (tail)
    pos = N - 1
    for j in reversed(range(N - 1)):
        pos = If(c[j] < cn, j, pos)
    newc, newid = [], []
    for j in range(N):
        prev_c = c[j - 1] if j > 0 else c[0]
        prev_id = ids[j - 1] if j > 0 else ids[0]
        newc.append(If(pos > j, c[j], If(pos == j, cn, prev_c)))
        newid.append(If(pos > j, ids[j], If(pos == j, idn, prev_id)))
    prove("FV-CUS-12-insert", "T-12 insertion before the first smaller record keeps the list largest-first, ties by lowest ID",
          sorted_desc(newc, newid),
          ins_dom + [sorted_desc(c, ids)] + [ids[j] != ids[k] for j in range(N) for k in range(j + 1, N)])
    prove("FV-CUS-12-insertsum", "T-12 insertion adds exactly the new record's credited units",
          Sum(newc) == Sum(c) + cn, ins_dom)

    # On a list sorted at debit time the walk follows the Q-170 order.
    prove("FV-CUS-12-order", "T-12 on a sorted list a debit never takes from a smaller record while a larger one keeps credit",
          And([Implies(And(takes[k] > 0, c[j] > c[k]), out[j] == 0) for k in range(N) for j in range(N) if j != k]),
          dom + [sorted_desc(c, ids), ok] + [ids[j] < ids[j + 1] for j in range(N - 1)])
    # After a partial debit the head may be smaller than the next record: order
    # is only largest-first at insertion (the spec states this; units are fungible).
    satisfiable("FV-CUS-12-unsorted", "T-12 witness: after a partial head debit the list is no longer sorted (allowed by SPEC-BACK-006)",
                And(dom + [sorted_desc(c, ids), ok, Not(sorted_desc(out, ids))] +
                    [ids[j] < ids[j + 1] for j in range(N - 1)]),
                show=c + [u])
    # Partial removal and re-credit change one record in place (REQ-COLL-014, REQ-COLL-015):
    # the record stays linked (credit stays > 0) and every other slot is unchanged, so a
    # later debit walks the same records and stays exact (FV-CUS-12-exact holds for any list).
    j0, du, da = Ints("slot_changed partial_units recredit_added")
    after_rm = [If(j0 == j, c[j] - du, c[j]) for j in range(N)]
    after_rc = [If(j0 == j, c[j] + da, c[j]) for j in range(N)]
    # FV-CUS-12 verifies: SPEC-BACK-006, REQ-COLL-014, REQ-COLL-015, INV-015
    prove("FV-CUS-12-keepplace", "T-12 a partial removal (0 < units < credited) or a re-credit (credited > 0) keeps every record's linked status and touches only that record",
          And([And((after_rm[j] > 0) == (c[j] > 0), (after_rc[j] > 0) == (c[j] > 0)) for j in range(N)]),
          dom + [j0 >= 0, j0 < N, du >= 1, da >= 1] +
          [Implies(j0 == j, And(du < c[j], c[j] > 0)) for j in range(N)])
    # Worked example of SPEC-BACK-006.
    ex_c = [5_000_000_000, 4_000_000_000, 4_000_000_000, 0, 0]
    from z3 import IntVal, simplify
    o, t, r = debit([IntVal(x) for x in ex_c], IntVal(6_000_000_000))
    vals = [simplify(x).as_long() for x in o]
    from common import concrete
    concrete("FV-CUS-12-example", "SPEC-BACK-006 example: debit 6,000,000,000 leaves [0, 3,000,000,000, 4,000,000,000]",
             vals[:3] == [0, 3_000_000_000, 4_000_000_000] and simplify(r).as_long() == 0, str(vals))
    return summary("fv_list")


if __name__ == "__main__":
    raise SystemExit(main())
