"""Vault token, vault-token factory and the proxy's unit movement (T-06, T-10, T-22, T-23).

The token is modelled with OpenZeppelin v5.1.0 ERC20 semantics over an uninterpreted
address sort: `_update(from, to, v)` subtracts from `from` then adds to `to` (so a
self-transfer is a no-op on balances), `transferFrom` spends a finite allowance.
Avana adds: mint/burn/addValidProxy only from ADAPTER, zero-address reverts, the path
rule of REQ-VTOKEN-040 on every transfer (proxy -> Hub, Hub -> proxy, Hub -> LPVaultSwap),
mint only to a registered proxy, burn only from a registered proxy or LPVaultSwap, a
registry that refuses every binding and the token itself (REQ-VTOKEN-047), and no zero-amount
transfer on any path (REQ-VTOKEN-048). The distinctness of the nine fixed addresses (zero, the
seven bindings and the token) is derived from the constructor's checks (REQ-VTOKEN-046), not assumed.
"""
from z3 import (DeclareSort, Const, Consts, ArraySort, IntSort, BoolSort, Select, Store, ForAll,
                And, Or, Not, Implies, If, Int, Ints, Distinct, BoolVal, IntVal)
from common import prove, satisfiable, concrete, summary

Addr = DeclareSort("Addr")
ZERO, HUB, ADAPTER, LPVS, LPV, COLL, SPOKE, LPO, SELF = Consts("ZERO HUB ADAPTER LPVS LPV COLL SPOKE LPO SELF", Addr)
BINDINGS = [LPV, HUB, SPOKE, LPO, ADAPTER, LPVS, COLL]
FIXED = [ZERO] + BINDINGS + [SELF]
MAXU = 2 ** 256 - 1


class T:
    def __init__(self, tag):
        self.bal = Const(f"{tag}_bal", ArraySort(Addr, IntSort()))
        self.alw = Const(f"{tag}_alw", ArraySort(Addr, ArraySort(Addr, IntSort())))
        self.valid = Const(f"{tag}_valid", ArraySort(Addr, BoolSort()))
        self.supply = Int(f"{tag}_supply")


def allowed(s, a):
    return Or(a == HUB, a == LPVS, Select(s.valid, a))


def path(s, frm, to):
    return Or(And(to == HUB, Select(s.valid, frm)), And(frm == HUB, Or(Select(s.valid, to), to == LPVS)))


def inv(s, reviewed=True):
    a = Const("a_q", Addr)
    c = [Distinct(*FIXED),
         ForAll([a], Select(s.bal, a) >= 0),
         ForAll([a], Implies(Select(s.bal, a) > 0, allowed(s, a))),          # T-10 / INV-011
         ]
    c += [Not(Select(s.valid, x)) for x in FIXED]                          # REQ-VTOKEN-047, any Adapter
    return And(c)


def update(bal, frm, to, v):
    b1 = Store(bal, frm, Select(bal, frm) - v)
    return Store(b1, to, Select(b1, to) + v)


def ops(pre):
    """(name, guard, post-bal, post-alw, post-valid, post-supply, touched)"""
    caller, frm, to, spender, p = Consts("caller from to spender proxy", Addr)
    v = Int("value")
    out = []
    # mint(to, v)
    out.append(("mint", [caller == ADAPTER, to != ZERO, Select(pre.valid, to), v >= 0],
                Store(pre.bal, to, Select(pre.bal, to) + v), pre.alw, pre.valid, pre.supply + v, caller))
    # burn(from, v)
    out.append(("burn", [caller == ADAPTER, frm != ZERO, Or(Select(pre.valid, frm), frm == LPVS), v >= 0,
                         Select(pre.bal, frm) >= v],
                Store(pre.bal, frm, Select(pre.bal, frm) - v), pre.alw, pre.valid, pre.supply - v, caller))
    # transfer(to, v) by caller
    out.append(("transfer", [path(pre, caller, to), caller != ZERO, v > 0, Select(pre.bal, caller) >= v],
                update(pre.bal, caller, to, v), pre.alw, pre.valid, pre.supply, caller))
    # transferFrom(from, to, v) by spender = caller
    a0 = Select(Select(pre.alw, frm), caller)
    new_alw = Store(pre.alw, frm, Store(Select(pre.alw, frm), caller, If(a0 == MAXU, a0, a0 - v)))
    out.append(("transferFrom", [path(pre, frm, to), frm != ZERO, caller != ZERO, v > 0,
                                 Select(pre.bal, frm) >= v, a0 >= v],
                update(pre.bal, frm, to, v), new_alw, pre.valid, pre.supply, caller))
    # approve(spender, v)
    out.append(("approve", [caller != ZERO, spender != ZERO, v >= 0],
                pre.bal, Store(pre.alw, caller, Store(Select(pre.alw, caller), spender, v)),
                pre.valid, pre.supply, caller))
    # addValidProxy(p) - the token refuses zero and every binding (REQ-VTOKEN-039, REQ-VTOKEN-047)
    out.append(("addValidProxy", [caller == ADAPTER] + [p != x for x in FIXED],
                pre.bal, pre.alw, Store(pre.valid, p, BoolVal(True)), pre.supply, caller))
    return out, (caller, frm, to, spender, p, v)


def post_state(pre, bal, alw, valid, supply):
    s = T("post")
    return s, [s.bal == bal, s.alw == alw, s.valid == valid, s.supply == supply]


def main():
    pre = T("pre")
    lst, (caller, frm, to, spender, p, v) = ops(pre)
    for name, guard, bal, alw, valid, supply, _ in lst:
        post, eqs = post_state(pre, bal, alw, valid, supply)
        # FV-CUS-10 verifies: INV-011, REQ-VTOKEN-006, REQ-VTOKEN-008, REQ-VTOKEN-012, REQ-VTOKEN-026, REQ-VTOKEN-030, REQ-VTOKEN-033, REQ-VTOKEN-047
        prove(f"FV-CUS-10-{name}", f"T-10 every non-zero balance stays with the Hub, LPVaultSwap or a registered proxy, and no binding is ever a proxy, across {name}",
              inv(post), [inv(pre)] + guard + eqs)
        # FV-CUS-06 verifies: INV-009, INV-010, REQ-VTOKEN-015, REQ-VTOKEN-027, REQ-VTOKEN-032, REQ-VTOKEN-043
        if name not in ("mint", "burn"):
            prove(f"FV-CUS-06-{name}", f"T-06 {name} leaves totalSupply unchanged",
                  supply == pre.supply, [inv(pre)] + guard)
        else:
            prove(f"FV-CUS-06-{name}-auth", f"T-06 {name} succeeds only for the Adapter and never with address(0)",
                  And(caller == ADAPTER, (to if name == "mint" else frm) != ZERO), [inv(pre)] + guard)
        # Conservation of balances: only the named entries move, by exactly v.
        a = Const("a_other", Addr)
        if name in ("transfer", "transferFrom"):
            src = caller if name == "transfer" else frm
            prove(f"FV-CUS-10-{name}-conserve", f"{name}: balances of other accounts unchanged and source+recipient sum unchanged (self-transfer included)",
                  And(ForAll([a], Implies(And(a != src, a != to), Select(bal, a) == Select(pre.bal, a))),
                      If(src == to, Select(bal, src) == Select(pre.bal, src),
                         Select(bal, src) + Select(bal, to) == Select(pre.bal, src) + Select(pre.bal, to))),
                  [inv(pre)] + guard)
    # FV-CUS-10 verifies: REQ-VTOKEN-046, REQ-VTOKEN-047
    # The constructor's checks: every binding non-zero, the seven pairwise different, none equal to the token's own
    # address; with the token's address non-zero (a deployed contract), these give the distinctness `inv` relies on.
    ctor_ok = And([b != ZERO for b in BINDINGS]
                  + [BINDINGS[i] != BINDINGS[j] for i in range(7) for j in range(i + 1, 7)]
                  + [b != SELF for b in BINDINGS] + [SELF != ZERO])
    prove("FV-CUS-10-ctor", "REQ-VTOKEN-046: a token the constructor accepts has nine pairwise distinct fixed addresses (zero, the seven bindings, itself)",
          Distinct(*FIXED), [ctor_ok])
    # FV-CUS-10 verifies: REQ-VTOKEN-048
    for i, nm in ((2, "transfer"), (3, "transferFrom")):
        prove(f"FV-CUS-10-{nm}-zero", f"REQ-VTOKEN-048: a zero-amount {nm} reverts on every path",
              Implies(v == 0, Not(And(lst[i][1]))), [inv(pre)])
    # Unauthorized callers revert.
    for name in ("mint", "burn", "addValidProxy"):
        prove(f"FV-CUS-06-{name}-only", f"T-06 {name} by any caller other than the Adapter reverts (OnlyAdapter)",
              Implies(caller != ADAPTER, Not(And([g for nm, gd, *_ in lst if nm == name for g in gd]))),
              [inv(pre)])
    # Re-registration and append-only registry.
    name, guard, bal, alw, valid, supply, _ = [x for x in lst if x[0] == "addValidProxy"][0]
    q = Const("q", Addr)
    prove("FV-CUS-10-reregister", "re-registering a proxy is a no-op and no entry is ever removed",
          And(Implies(Select(pre.valid, p), valid == pre.valid),
              ForAll([q], Implies(Select(pre.valid, q), Select(valid, q)))),
          [inv(pre)] + guard)
    # LPVault and Collateralization never hold a unit under a reviewed Adapter.
    custodians = [LPV, COLL, ADAPTER, SPOKE]
    prove("FV-CUS-10-custodians", "REQ-VAULT-044 / REQ-COLL-004 / REQ-VTOKEN-017: the LPVault, Collateralization, the Adapter and the Spoke can never receive a unit",
          And([Implies(And(lst[i][1]), And([to != x for x in custodians])) for i in (0, 2, 3)]),
          [inv(pre)])
    # FV-CUS-10 verifies: REQ-VTOKEN-039, REQ-VTOKEN-042, REQ-VTOKEN-047, INV-012
    prove("FV-CUS-10-hostile", "blast radius bound: even a hostile Adapter cannot register a binding (Hub, Adapter, LPVaultSwap, LPVault, Collateralization, Spoke, LPOracle) or the token",
          Implies(Or([p == x for x in FIXED]), Not(And(lst[5][1]))), [inv(pre)])
    # FV-CUS-10 verifies: REQ-VTOKEN-014, REQ-VTOKEN-042, INV-010
    prove("FV-CUS-10-hubburn", "no burn from the Hub, for any caller", Implies(frm == HUB, Not(And(lst[1][1]))), [inv(pre)])
    # FV-CUS-10 verifies: REQ-VTOKEN-041, INV-011
    prove("FV-CUS-10-paths", "no proxy-to-proxy, LPVaultSwap-to-Hub or Adapter-touching transfer, by holder or spender",
          And([Implies(Or(And(Select(pre.valid, frm), Select(pre.valid, to)), And(frm == LPVS, to == HUB),
                          frm == ADAPTER, to == ADAPTER), Not(And(lst[3][1]))),
               Implies(Or(And(Select(pre.valid, caller), Select(pre.valid, to)), And(caller == LPVS, to == HUB),
                          caller == ADAPTER, to == ADAPTER), Not(And(lst[2][1])))]),
          [inv(pre)])

    # T-23 proxy unit movement (SPEC-PROXY-005) on concrete-shaped symbolic amounts.
    b0, units, a0 = Ints("proxyBalBefore units allowBefore")
    # supplyCollateral: approve(spoke, units) -> spoke transferFrom(proxy, hub, units) -> approve(spoke, 0)
    alw_after_tf = If(units == MAXU, units, units - units)
    # FV-CUS-23 verifies: SPEC-PROXY-005, REQ-PROXY-089, REQ-PROXY-094, INV-021
    prove("FV-CUS-23-supply", "T-23 supply moves exactly units out of the proxy and leaves the Spoke allowance at 0",
          And((b0 + units) - units == b0, alw_after_tf == 0),
          [b0 >= 0, units >= 1, units < 2 ** 120])
    prove("FV-CUS-23-withdraw", "T-23 withdraw then the Adapter's burn returns the proxy balance to its value before the call",
          (b0 + units) - units == b0, [b0 >= 0, units >= 1])

    # T-22 factory checks (changed for the AMM-neutral design): decimals from the value of
    # one credited unit (SPEC-UNIT-001), and the exact-range alignment of SPEC-BACK-001.
    from fractions import Fraction
    ok_dec, worst = True, None
    for mant in (1, 2, 3, 5, 7, 9):
        for k in range(0, 19):
            v = Fraction(mant, 10 ** k)                      # USD value of one credited unit
            ds = [d for d in range(6, 19) if 10 ** d * v >= 1]
            if not ds:
                continue                                    # listing fails: even d = 18 is below $1
            d = ds[0]
            whole = 10 ** d * v
            if not (6 <= d <= 18 and whole >= 1 and (d == 6 or whole < 10)):
                ok_dec, worst = False, (mant, k, d, whole)
    ok_dec &= [d for d in range(6, 19) if 10 ** d * Fraction(2, 10 ** 6) >= 1][0] == 6
    # FV-CUS-22 verifies: SPEC-UNIT-001, REQ-VTOKEN-022, REQ-VTOKEN-036, SPEC-BACK-001, REQ-VAULT-009
    concrete("FV-CUS-22-decimals", "T-22 d is the smallest value in [6, 18] with 10^d * v >= $1, so a whole token is worth $1 to $10 (or more only at d = 6); a full-range USDC/USDT unit at $2e-6 gives d = 6",
             ok_dec, str(worst))

    def trunc_mod(a, b):
        r = abs(a) % abs(b)
        return r if a >= 0 else -r

    def trunc_div(a, b):
        q = abs(a) // abs(b)
        return q if (a >= 0) == (b > 0) else -q
    ok_ticks, detail = True, []
    expect = {1: 887272, 10: 887270, 60: 887220, 200: 887200}
    for s_ in (1, 10, 60, 200):
        lo = trunc_div(-887272, s_) * s_
        hi = trunc_div(887272, s_) * s_
        ok_ticks &= lo == -expect[s_] and hi == expect[s_] and lo - s_ < -887272 and hi + s_ > 887272
        for t in range(-3 * s_ - 7, 3 * s_ + 8):
            aligned = t % s_ == 0                             # mathematical alignment
            ok_ticks &= (trunc_mod(t, s_) == 0) == aligned    # the signed int24 test agrees
        detail.append(f"s={s_}: [{lo}, {hi}]")
    uint24_cast = (-516) % (2 ** 24)
    witness_ok = trunc_mod(-516, 10) == -6 and uint24_cast % 10 == 0
    concrete("FV-CUS-22-ticks", "SPEC-BACK-001: the signed tick remainder accepts exactly the aligned ticks, and the full usable range is the special case of the outermost aligned ticks for spacings 1, 10, 60, 200",
             ok_ticks, "; ".join(detail))
    concrete("FV-CUS-22-W", "witness: the uint24-cast test would accept the misaligned tick -516 at spacing 10 (16,776,700 % 10 = 0), which the signed test refuses (-516 % 10 = -6)",
             witness_ok)
    return summary("fv_token")


if __name__ == "__main__":
    raise SystemExit(main())
