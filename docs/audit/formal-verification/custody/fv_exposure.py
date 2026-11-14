"""Exposure counters, exit release, the re-credit rebase, rescue units, Hub addCap
headroom and the minimum pledge value.

SPEC-BACK-003/004/005/013/014, SPEC-CAP-001/002/004, INV-027, INV-028, INV-069 (T-13,
T-14, the cap-counter part of T-77, and minPledgeUsd = $10).

Nonlinear lemmas over the ceiling charge are proved once with Z3's nonlinear
integer/real engine and then used as hypotheses of the linear inductive step.
"""
from z3 import (Int, Ints, Real, Reals, And, Or, Not, If, Implies, Sum, IntVal, BoolVal,
                ToReal, simplify)
from common import prove, satisfiable, concrete, summary, ceil_div, U128

U120 = 2 ** 120


def charge(V0, U0, c):
    """remainingCharge = mulDiv(V0, c, U0, Ceil)."""
    return ceil_div(V0 * c, U0)


def zmax0(x):
    return If(x > 0, x, 0)


def zmin(a, b):
    return If(a <= b, a, b)


def lemmas():
    V0, U0, c1, c2, x1, x2, c = Ints("V0 U0 c1 c2 x1 x2 c")
    dom = [U0 >= 1, U0 < U120, V0 >= 1, V0 < U128]
    # FV-CUS-13 verifies: SPEC-BACK-005, SPEC-CAP-004, REQ-VAULT-036, Q-174
    prove("FV-CUS-13-mono", "T-13 remainingCharge is monotone in remaining units, so capReleased >= 0",
          charge(V0, U0, c1) >= charge(V0, U0, c2),
          dom + [c2 >= 0, c1 >= c2, c1 <= U0])
    prove("FV-CUS-13-ends", "T-13 charge(originalUnits) == originalUsdCharge and charge(0) == 0",
          And(charge(V0, U0, U0) == V0, charge(V0, U0, IntVal(0)) == 0), dom)
    prove("FV-CUS-13-bounded", "T-13 remainingCharge <= originalUsdCharge for remaining <= originalUnits",
          charge(V0, U0, c1) <= V0, dom + [c1 >= 0, c1 <= U0])
    rel = lambda a, b: charge(V0, U0, a) - charge(V0, U0, b)
    prove("FV-CUS-13-split", "T-13 splitting an exit x1 + x2 releases exactly what one exit of x1 + x2 releases",
          rel(c, c - x1) + rel(c - x1, c - x1 - x2) == rel(c, c - x1 - x2),
          dom + [c >= 0, c <= U0, x1 >= 0, x2 >= 0, x1 + x2 <= c])
    prove("FV-CUS-13-noexcess", "T-13 an exit never releases more than the record's current charge",
          rel(c, c - x1) <= charge(V0, U0, c), dom + [c >= 0, c <= U0, x1 >= 0, x1 <= c])

    # addCap headroom lemma over the reals (implied by the integer ceilings).
    U0r, V0r, Dr, Fr, Mr, cr, curr = Reals("U0r V0r Dr Fr Mr cr curr")
    prove("FV-CUS-14-floorbook", "T-14 a record's remaining charge covers its credited units at the stress floor: cur*10^d >= credited*F",
          curr * Dr >= cr * Fr,
          [U0r >= 1, Dr >= 1, Fr >= 1, Mr >= Fr, V0r * Dr >= U0r * Mr, cr >= 0, cr <= U0r,
           curr * U0r >= V0r * cr])


def counters():
    """Inductive counter invariant: 3 records, 2 markets sharing token B, 2 depositors."""
    R = 3
    MK = 2
    pool = {0: (0, 1), 1: (1, 2)}   # market -> (token0, token1)
    NT, ND = 3, 2

    class C:
        pass

    def mk(tag):
        s = C()
        s.open = [Int(f"{tag}_open{r}") for r in range(R)]       # 0/1
        s.mkt = [Int(f"{tag}_mkt{r}") for r in range(R)]
        s.dep = [Int(f"{tag}_dep{r}") for r in range(R)]
        s.cur = [Int(f"{tag}_cur{r}") for r in range(R)]
        s.reg = [Int(f"{tag}_reg{m}") for m in range(MK)]
        s.sl = [Int(f"{tag}_sl{m}") for m in range(MK)]
        s.tok = [Int(f"{tag}_tok{t}") for t in range(NT)]
        s.dpc = [Int(f"{tag}_dpc{x}") for x in range(ND)]
        return s

    def cp(s):
        n = C()
        for k, v in s.__dict__.items():
            setattr(n, k, list(v))
        return n

    Kc = [Int(f"Kcap{m}") for m in range(MK)]
    Zc = [Int(f"Zcap{m}") for m in range(MK)]
    caps = [x >= 0 for x in Kc + Zc]

    def in_pool(r, t, s):
        return Or([And(s.mkt[r] == m, BoolVal(t in pool[m])) for m in range(MK)])

    def inv(s):
        c = []
        for r in range(R):
            c += [Or(s.open[r] == 0, s.open[r] == 1), Or(s.mkt[r] == 0, s.mkt[r] == 1),
                  Or(s.dep[r] == 0, s.dep[r] == 1), s.cur[r] >= 0,
                  Implies(s.open[r] == 0, s.cur[r] == 0)]
        for m in range(MK):
            c += [s.reg[m] >= 0, s.sl[m] >= 0, s.reg[m] <= Kc[m], s.sl[m] <= Zc[m],
                  s.reg[m] + s.sl[m] == Sum([If(And(s.open[r] == 1, s.mkt[r] == m), s.cur[r], 0)
                                             for r in range(R)])]
        for t in range(NT):
            c.append(s.tok[t] == Sum([If(And(s.open[r] == 1, in_pool(r, t, s)), s.cur[r], 0)
                                      for r in range(R)]))
        for x in range(ND):
            c.append(s.dpc[x] == Sum([If(And(s.open[r] == 1, s.dep[r] == x), s.cur[r], 0)
                                      for r in range(R)]))
        return And(c)

    pre = mk("pre")
    results_ok = True

    # Pledge of record r into market m by depositor x (SPEC-CAP-002 tests + SPEC-BACK-004 booking).
    for r in range(R):
        for m in range(MK):
            for topup in (False, True):
                ch, s_ = Ints(f"chg_{r}_{m}_{int(topup)} sl_{r}_{m}_{int(topup)}")
                x = Int(f"depx_{r}_{m}_{int(topup)}")
                room = zmax0(Kc[m] - pre.reg[m])
                g = [inv(pre), pre.open[r] == 0, ch >= 1, ch < U128, Or(x == 0, x == 1)] + caps
                if topup:
                    g += [s_ == zmax0(ch - room), pre.sl[m] + s_ <= Zc[m]]
                else:
                    g += [s_ == 0, ch <= room]
                post = cp(pre)
                post.open[r], post.mkt[r], post.dep[r], post.cur[r] = IntVal(1), IntVal(m), x, ch
                post.reg[m] = pre.reg[m] + ch - s_
                post.sl[m] = pre.sl[m] + s_
                for t in pool[m]:
                    post.tok[t] = pre.tok[t] + ch
                post.dpc = [If(x == k, pre.dpc[k] + ch, pre.dpc[k]) for k in range(ND)]
                # FV-CUS-14 verifies: INV-027, SPEC-BACK-004, SPEC-CAP-002, REQ-VAULT-015, REQ-VAULT-017, INV-028
                prove(f"FV-CUS-14-pledge-r{r}m{m}{'t' if topup else 'n'}",
                      f"T-14 counters equal the open records' charges and stay within marketUsdCap / topUpSliceUsd after a {'top-up' if topup else 'new-account'} pledge",
                      inv(post), g)

    # Exit of x units from record r: new charge nc with 0 <= nc <= cur (FV-CUS-13-mono),
    # nc == 0 when the exit is total (FV-CUS-13-ends).
    for r in range(R):
        nc = Int(f"nc_{r}")
        total_exit = Int(f"total_{r}")
        g = [inv(pre), pre.open[r] == 1, nc >= 0, nc <= pre.cur[r], Or(total_exit == 0, total_exit == 1),
             Implies(total_exit == 1, nc == 0)] + caps
        rel = pre.cur[r] - nc
        post = cp(pre)
        post.cur[r] = nc
        m_r = pre.mkt[r]
        sat_flags = []
        for m in range(MK):
            from_slice = zmin(rel, pre.sl[m])
            here = m_r == m
            post.sl[m] = If(here, pre.sl[m] - from_slice, pre.sl[m])
            post.reg[m] = If(here, zmax0(pre.reg[m] - (rel - from_slice)), pre.reg[m])
            sat_flags.append(Implies(here, pre.reg[m] - (rel - from_slice) >= 0))
        for t in range(NT):
            post.tok[t] = If(in_pool(r, t, pre), zmax0(pre.tok[t] - rel), pre.tok[t])
            sat_flags.append(Implies(in_pool(r, t, pre), pre.tok[t] - rel >= 0))
        for k in range(ND):
            post.dpc[k] = If(pre.dep[r] == k, zmax0(pre.dpc[k] - rel), pre.dpc[k])
            sat_flags.append(Implies(pre.dep[r] == k, pre.dpc[k] - rel >= 0))
        prove(f"FV-CUS-14-exit-r{r}", "T-14 an exit keeps every counter equal to the open records' remaining charges",
              inv(post), g)
        prove(f"FV-CUS-14-nosat-r{r}", "T-14 no exit subtraction ever saturates (CounterSaturated is unreachable)",
              And(sat_flags), g)
        # Closing: a record at charge 0 leaves (release after a total exit, zero-credit release).
        g2 = [inv(pre), pre.open[r] == 1, pre.cur[r] == 0] + caps
        post2 = cp(pre)
        post2.open[r] = IntVal(0)
        prove(f"FV-CUS-14-close-r{r}", "T-14 closing a record at charge 0 keeps every counter equal",
              inv(post2), g2)

    # Re-credit of open record r (REQ-COLL-015): the added units are checked and booked
    # exactly as a top-up of that size into the same account, and the record's current
    # charge becomes its remaining charge plus the new charge (SPEC-BACK-013).
    for r in range(R):
        ch, s_ = Ints(f"rchg_{r} rsl_{r}")
        g = [inv(pre), pre.open[r] == 1, ch >= 1, ch < U128] + caps
        post = cp(pre)
        post.cur[r] = pre.cur[r] + ch
        conds = []
        for m in range(MK):
            here = pre.mkt[r] == m
            room = zmax0(Kc[m] - pre.reg[m])
            conds.append(Implies(here, And(s_ == zmax0(ch - room), pre.sl[m] + s_ <= Zc[m])))
            post.reg[m] = If(here, pre.reg[m] + ch - s_, pre.reg[m])
            post.sl[m] = If(here, pre.sl[m] + s_, pre.sl[m])
        for t in range(NT):
            post.tok[t] = If(in_pool(r, t, pre), pre.tok[t] + ch, pre.tok[t])
        for k in range(ND):
            post.dpc[k] = If(pre.dep[r] == k, pre.dpc[k] + ch, pre.dpc[k])
        # FV-CUS-14 verifies: INV-027, SPEC-BACK-004, SPEC-BACK-013, REQ-COLL-015, REQ-ADAPTER-079
        prove(f"FV-CUS-14-recredit-r{r}",
              "T-14 a re-credit keeps every counter equal to the open records' charges and within marketUsdCap / topUpSliceUsd",
              inv(post), g + conds)


def rebase():
    """SPEC-BACK-013: the charge basis after a re-credit, and the record's life."""
    V0, U0, c, x1, x2, a, ch = Ints("rb_V0 rb_U0 rb_c rb_x1 rb_x2 rb_added rb_charge")
    cur = charge(V0, U0, c)
    U1, V1 = c + a, cur + ch
    dom = [U0 >= 1, U0 < U120, V0 >= 1, V0 < U128, c >= 1, c <= U0, a >= 1, ch >= 1,
           U1 < U120, V1 < U128]
    # FV-CUS-13 verifies: SPEC-BACK-013, SPEC-BACK-005, REQ-COLL-015, REQ-VAULT-030, INV-027
    prove("FV-CUS-13-rebase-cur", "SPEC-BACK-013 after a re-credit the record's remaining charge at its credited units is exactly what it booked (remaining + new charge)",
          charge(V1, U1, U1) == V1, dom)
    prove("FV-CUS-13-rebase-ends", "SPEC-BACK-013 on the rebased basis the last exit leaves 0 and no exit releases a negative amount",
          And(charge(V1, U1, IntVal(0)) == 0,
              charge(V1, U1, U1 - x1) <= V1),
          dom + [x1 >= 0, x1 <= U1])
    # A whole life: pledge (V0, U0), exit to c, re-credit a for ch, exit x2, exit the rest.
    rel1 = V0 - cur
    mid = charge(V1, U1, U1 - x2)
    released = rel1 + (V1 - mid) + (mid - 0)
    prove("FV-CUS-13-rebase-life", "SPEC-BACK-013 over a record's life (pledge, exit, re-credit, exits to 0) the counters release exactly the pledge charge plus the re-credit charge",
          And(released == V0 + ch, rel1 >= 0, V1 - mid >= 0, mid >= 0),
          dom + [x2 >= 0, x2 <= U1])
    satisfiable("FV-CUS-13-oldbasis", "SPEC-BACK-013 witness: keeping the pledge basis after a re-credit makes an exit compute a remaining charge above the current one (capReleased < 0)",
                And(dom + [x1 >= 1, x1 <= U1, charge(V0, U0, U1 - x1) > V1]),
                show=[V0, U0, c, a, ch, x1])
    # Spec examples.
    cl = lambda p_, q_: -(-p_ // q_)
    after_rm = cl(10 ** 12 * 4_000_000_000, 5_000_000_000)
    V1e, U1e = after_rm + cl(1_500_000_000 * 200_000_000, 10 ** 6), 4_000_000_000 + 1_500_000_000
    mid_e = cl(V1e * 2_750_000_000, U1e)
    life = (10 ** 12 - after_rm) + (V1e - mid_e) + mid_e
    concrete("FV-CUS-13-ex-rebase", "SPEC-BACK-013 example: $8,000 + $3,000 rebased to $11,000 over 5,500,000,000 units; exits release $2,000 + $5,500 + $5,500 = $13,000",
             after_rm == 800_000_000_000 and V1e == 1_100_000_000_000 and U1e == 5_500_000_000
             and mid_e == 550_000_000_000 and life == 1_300_000_000_000)
    concrete("FV-CUS-13-ex-partial", "REQ-COLL-014 example: removing 1,000,000,000 of 5,000,000,000 units leaves a charge of $8,000 and releases $2,000",
             after_rm == 800_000_000_000 and 10 ** 12 - after_rm == 200_000_000_000)
    concrete("FV-CUS-13-ex-deleverage", "REQ-COLL-017 example: releasing 800,000,000 of NFT 7's 4,000,000,000 units leaves a charge of $6,400",
             cl(800_000_000_000 * 3_200_000_000, 4_000_000_000) == 640_000_000_000)
    concrete("FV-CUS-13-ex-inv027", "INV-027 example: $2,000 for 1,000 units releases $800 for 400 units; a re-credit of 200 units at $500 rebases to $1,700 for 800 units",
             cl(2_000 * 600, 1_000) == 1_200 and 2_000 - 1_200 == 800 and 1_200 + 500 == 1_700 and 600 + 200 == 800)
    concrete("FV-CUS-13-ex-adapter", "REQ-ADAPTER-079 example: a re-credit of 2,500,000,000 units at 199,990,000 books 499,975,000,000",
             cl(2_500_000_000 * 199_990_000, 10 ** 6) == 499_975_000_000)


def rescue():
    """SPEC-BACK-014: rescue units of a pledge or re-credit."""
    L, chg, sl = Ints("rq_L rq_charge rq_slice")
    ru = If(sl > 0, ceil_div(L * sl, chg), IntVal(0))
    dom = [L >= 1, L < U120, chg >= 1, chg < U128, sl >= 0, sl <= chg]
    # FV-CUS-33 verifies: SPEC-BACK-014, REQ-COLL-016, Q-253
    prove("FV-CUS-33-bound", "SPEC-BACK-014 rescueUnits = ceil(L * sliceUsd / usdCharge) is at most L, so Collateralization's rescueUnits <= L check never rejects the RiskModule's value",
          And(ru >= 0, ru <= L), dom)
    prove("FV-CUS-33-share", "SPEC-BACK-014 rounding up excludes at least the slice's share of the units: rescueUnits * usdCharge >= L * sliceUsd",
          ru * chg >= L * sl, dom)
    prove("FV-CUS-33-full", "SPEC-BACK-014 a pledge charged entirely to the slice books all its units as rescue units",
          ru == L, dom + [sl == chg])
    cl = lambda p_, q_: -(-p_ // q_)
    concrete("FV-CUS-33-ex", "SPEC-BACK-014 examples: 1,000,000,000 (all slice); ceil(1,500,000,000 x 2/3) = 1,000,000,000; a seizure to 300,000,000 credited leaves 300,000,000",
             cl(1_000_000_000 * 200_000_000_000, 200_000_000_000) == 1_000_000_000
             and cl(1_500_000_000 * 200_000_000_000, 300_000_000_000) == 1_000_000_000
             and min(1_000_000_000, 300_000_000) == 300_000_000)


def addcap():
    """Hub addCap is never the binding limit for a pledge the caps admitted."""
    cr = [Real(f"cred{r}") for r in range(3)]
    cu = [Real(f"cur{r}") for r in range(3)]
    D, F, Kc, Zc, addCap, L, cL = Reals("D F K Z addCap L cL")
    hyps = [D >= 1, F >= 1, Kc >= 0, Zc >= 0, addCap * F >= Kc + Zc]
    hyps += [And(cr[r] >= 0, cu[r] * D >= cr[r] * F) for r in range(3)]   # FV-CUS-14-floorbook
    hyps += [L >= 0, cL * D >= L * F, Sum(cu) + cL <= Kc + Zc]            # the new pledge fits the caps
    # FV-CUS-14 verifies: SPEC-UNIT-005, SPEC-CAP-001, REQ-VAULT-035
    prove("FV-CUS-14-addcap", "T-14 credited units after a cap-admitted pledge stay within the Hub addCap (whole tokens x 10^d)",
          Sum(cr) + L <= addCap * D, hyps)


def min_pledge():
    L, p, D, F, Mn = Reals("L p D F Mn")
    pu, chg = Reals("pledgeUsd usdCharge")
    # pledgeUsd = floor(L*p/D): pu*D <= L*p < (pu+1)*D ; usdCharge = ceil(L*max(p,F)/D): chg*D >= L*max(p,F)
    M = If(p >= F, p, F)
    hyps = [L >= 1, p >= 1, F >= 1, D >= 1, pu * D <= L * p, (pu + 1) * D > L * p,
            chg * D >= L * M, (chg - 1) * D < L * M, pu >= Mn, Mn == 10 * 10 ** 8]
    # FV-CUS-14 verifies: INV-069, SPEC-CAP-001, REQ-RISK-057, Q-230
    prove("FV-CUS-MP-value", "minPledgeUsd: an accepted pledge is worth at least $10 at the served price (exact value >= 10e8)",
          L * p >= Mn * D, hyps)
    prove("FV-CUS-MP-charge", "minPledgeUsd: the booked charge is at least the floored pledge value, so >= $10",
          chg >= pu, hyps)
    Li, pi, Di, Fi = Ints("Li pi Di Fi")
    prove("FV-CUS-MP-pos", "SPEC-BACK-003: usdCharge >= 1 for every L >= 1 and price >= 1 (no InvalidCharge for 0)",
          ceil_div(Li * If(pi >= Fi, pi, Fi), Di) >= 1,
          [Li >= 1, pi >= 1, Fi >= 1, Di >= 1, Di <= 10 ** 18])
    # Reachable upper bound: L <= maxLiquidityPerTick(200), price <= 2^33 (about $85.9 per whole token), d >= 6.
    num_ticks = (887200 // 200) * 2 + 1
    lmax = (2 ** 128 - 1) // num_ticks
    worst = -(-lmax * 2 ** 33 // 10 ** 6)
    concrete("FV-CUS-MP-ub", f"SPEC-BACK-003: usdCharge < 2^128 for L <= maxLiquidityPerTick(200) = {lmax}, price8 <= 2^33, d >= 6",
             worst < 2 ** 128, f"worst={worst}")
    # Spec examples (SPEC-CAP-001, SPEC-BACK-003, SPEC-BACK-005, $10 minimum).
    fl = lambda a, b: a // b
    cl = lambda a, b: -(-a // b)
    ex = [
        (fl(5_000_000 * 199_990_000, 10 ** 6) == 999_950_000 and 999_950_000 < 10 ** 9, "L=5,000,000 reverts BelowMinPledge"),
        (fl(5_001_000 * 199_990_000, 10 ** 6) == 1_000_149_990, "L=5,001,000 passes with 1,000,149,990"),
        (cl(5_000_000_000 * 200_000_000, 10 ** 6) == 1_000_000_000_000, "NFT 42 charge $10,000"),
        (cl(5_000_000_000 * 100_000_000, 10 ** 6) == 500_000_000_000, "NFT 42 at the floor $5,000"),
        (10 ** 12 - cl(10 ** 12 * 3_425_000_000, 5_000_000_000) == 315_000_000_000, "reconcile releases $3,150"),
        (cl(5 * 10 ** 10 * 10 ** 8, 10 ** 6) == 5_000_000_000_000, "SPEC-CAP-001 depressed price booked at floor"),
    ]
    for i, (ok, msg) in enumerate(ex):
        concrete(f"FV-CUS-MP-ex{i}", f"spec example: {msg}", ok)


def main():
    lemmas()
    counters()
    rebase()
    rescue()
    addcap()
    min_pledge()
    return summary("fv_exposure")


if __name__ == "__main__":
    raise SystemExit(main())
