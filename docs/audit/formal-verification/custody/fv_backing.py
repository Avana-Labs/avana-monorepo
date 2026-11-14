"""Backing ledger, backing gap, per-account ledger, reconcile on exit, pending settlement,
partial removal, re-credit, deleverage release and rescue units.

Model: one market with K record slots and two proxies. State variables
  open_i, own_i (proxy index), cred_i (credited units), live_i (NFPM liquidity),
  rs_i (rescue units of the record), TC (totalCredited), AC_p (accountCredited),
  AR_p (accountRescueUnits), P (pending.units), supply (vaultToken.totalSupply),
  sh_p (Spoke supplied shares of proxy p), hubA / hubS (Hub added assets / shares of
  the vault-token asset), hubBal (vault-token balance of the Hub), lpvs (vault-token
  balance of LPVaultSwap).
Proxies and the Adapter hold units only inside a call, so at rest every unit is in
the Hub or in LPVaultSwap.

Backing (SPEC-BACK-009, INV-001, INV-080): supply <= TC + P for any LPVaultSwap
implementation, with the backing gap G = TC + P - supply. Every Adapter call
(pledge, withdraw, removeLiquidity, recredit, repayWithCollateral) must leave G
unchanged and supply <= TC + P (REQ-ADAPTER-069, SPEC-PROXY-008). Conforming calls keep
G = 0; only a burnSeized that no settlement follows opens it.

Operations (each one outer call, atomic): pledge, donated liquidity, withdraw (proxy
withdraw, Adapter burn, release with reconcile), partial removal (releasePartial),
re-credit (recredit, Adapter mint and supply), deleverage release inside a repay with
collateral (releaseForDeleverage, closing the record when nothing stays credited),
zero-credit release, conforming liquidation (beginSeizure, liquidationCall,
burnSeized, settleSeizure with reconcile), conforming settlePending, and the
non-conforming LPVaultSwap behaviours the spec designs for: a seizure never burned or
settled, a transfer of held units to the Hub, a burnSeized never followed by a
settlement, and a settlePending without a burn.

Each operation returns (name, guard, post, checks, info): `guard` holds only the
modelling constraints (which record, the allocation of a debit, nondeterministic
amounts), `checks` holds every revert condition the contracts evaluate. Step cases
assume the call succeeded (all checks hold) except the Adapter's backing-gap check,
which is derived from the effects and then proved to pass. Liveness rules prove the
checks from the guard and the app's choice of amounts.

Record allocation of a debit is left nondeterministic here (any split over the
proxy's records with take_i <= cred_i that sums to the debit), which covers the
largest-first walk proved exact in fv_list.py.
"""
from z3 import (Int, Bool, And, Or, Not, If, Implies, Sum, BoolVal, IntVal)
from common import prove, satisfiable, concrete, summary, MAX_CREDITED

K = 3
NP = 2
_ctr = [0]


def fresh(name):
    _ctr[0] += 1
    return Int(f"{name}_{_ctr[0]}")


def zmin(a, b):
    return If(a <= b, a, b)


class St:
    def __init__(self, tag=None):
        if tag is None:
            return
        self.open = [Bool(f"{tag}_open{i}") for i in range(K)]
        self.own = [Int(f"{tag}_own{i}") for i in range(K)]
        self.cred = [Int(f"{tag}_cred{i}") for i in range(K)]
        self.live = [Int(f"{tag}_live{i}") for i in range(K)]
        self.rs = [Int(f"{tag}_rs{i}") for i in range(K)]
        self.AC = [Int(f"{tag}_AC{p}") for p in range(NP)]
        self.AR = [Int(f"{tag}_AR{p}") for p in range(NP)]
        self.sh = [Int(f"{tag}_sh{p}") for p in range(NP)]
        self.TC = Int(f"{tag}_TC")
        self.P = Int(f"{tag}_P")
        self.supply = Int(f"{tag}_supply")
        self.hubA = Int(f"{tag}_hubA")
        self.hubS = Int(f"{tag}_hubS")
        self.hubBal = Int(f"{tag}_hubBal")
        self.lpvs = Int(f"{tag}_lpvs")

    def copy(self):
        n = St()
        for k, v in self.__dict__.items():
            setattr(n, k, list(v) if isinstance(v, list) else v)
        return n

    def vars(self):
        out = []
        for v in self.__dict__.values():
            out += v if isinstance(v, list) else [v]
        return out


def set_at(lst, i, v):
    return [v if j == i else lst[j] for j in range(len(lst))]


# ---------------------------------------------------------------- invariants
def inv_records(s):
    c = []
    for i in range(K):
        c += [Or(s.own[i] == 0, s.own[i] == 1),
              Implies(Not(s.open[i]), And(s.cred[i] == 0, s.live[i] == 0)),
              s.cred[i] >= 0, s.cred[i] <= MAX_CREDITED,
              s.live[i] >= s.cred[i]]                                   # T-02 / INV-002 / SPEC-BACK-010
    c.append(s.TC == Sum(s.cred))                                        # SPEC-BACK-009
    for p in range(NP):
        c.append(s.AC[p] == Sum([If(s.own[i] == p, s.cred[i], 0) for i in range(K)]))
    return And(c)


def inv_rescue(s):
    """SPEC-BACK-014 / REQ-COLL-016: 0 <= rescueUnits <= credited, 0 on a closed slot,
    accountRescueUnits = sum over the proxy's open records."""
    c = []
    for i in range(K):
        c += [s.rs[i] >= 0, s.rs[i] <= s.cred[i], Implies(Not(s.open[i]), s.rs[i] == 0)]
    for p in range(NP):
        c.append(s.AR[p] == Sum([If(s.own[i] == p, s.rs[i], 0) for i in range(K)]))
    return And(c)


def inv_aave(s, reviewed=False):
    c = [s.hubA == s.hubS,                                              # T-16
         s.hubA == Sum(s.sh),
         s.hubBal >= s.hubA,
         s.supply == s.hubBal + s.lpvs,                                 # units rest in Hub or LPVaultSwap
         s.lpvs >= 0, s.P >= 0]
    for p in range(NP):
        c += [s.sh[p] >= 0, s.sh[p] <= s.AC[p]]                         # T-04 / INV-008
    if reviewed:
        c.append(s.hubBal == s.hubA)                                    # T-03 / INV-003
    return And(c)


def gap(s):
    return s.TC + s.P - s.supply                                         # SPEC-BACK-009 backing gap


def backing_le(s):
    return s.supply <= s.TC + s.P                                       # T-01 / INV-001 / INV-080


def backing_eq(s):
    return s.supply == s.TC + s.P


def INV(s, reviewed=False):
    return And(inv_records(s), inv_aave(s, reviewed), backing_le(s))


def INV_EQ(s, reviewed=False):
    return And(INV(s, reviewed), backing_eq(s))


def gap_check(pre, post):
    """REQ-ADAPTER-069 / SPEC-PROXY-008: supply <= credited + pending after, gap unchanged."""
    return And(post.supply <= post.TC + post.P, gap(post) == gap(pre))


# ---------------------------------------------------------------- building blocks
def debit(s, p, D, tag, t=None):
    """Debit D units from proxy p's records (any allocation), capping rescue units at
    the new credited units (SPEC-BACK-014). Returns (cons, takes)."""
    t = t if t is not None else [fresh(f"{tag}_take{i}") for i in range(K)]
    cons = []
    for i in range(K):
        cons += [t[i] >= 0, t[i] <= s.cred[i],
                 Implies(Or(Not(s.open[i]), s.own[i] != p), t[i] == 0)]
    cons.append(Sum(t) == D)
    s.cred = [s.cred[i] - t[i] for i in range(K)]
    s.live = [s.live[i] - t[i] for i in range(K)]
    cap_record(s)
    s.AC = [s.AC[q] - D if q == p else s.AC[q] for q in range(NP)]
    s.TC = s.TC - D
    return cons, t


def cap_record(s, only=None):
    """rescueUnits = min(rescueUnits, credited) on every record (only=i: on record i)."""
    new_rs = [zmin(s.rs[i], s.cred[i]) if (only is None or only == i) else s.rs[i] for i in range(K)]
    s.AR = [s.AR[q] - Sum([If(s.own[i] == q, s.rs[i] - new_rs[i], 0) for i in range(K)])
            for q in range(NP)]
    s.rs = new_rs


def reconcile(s, p, S, tag, t=None):
    """SPEC-BACK-011: shortfall = max(0, AC_p - S); runs only while hubA == hubS."""
    sf = If(And(s.hubA == s.hubS, s.AC[p] > S), s.AC[p] - S, 0)
    cons, t = debit(s, p, sf, tag, t)
    s.P = s.P + sf
    return cons, sf, t


def aave_move(s, p, u, to_lpvs):
    """Hub remove of u units from proxy p's supply (shares == assets)."""
    s.sh = [s.sh[q] - u if q == p else s.sh[q] for q in range(NP)]
    s.hubA, s.hubS, s.hubBal = s.hubA - u, s.hubS - u, s.hubBal - u
    if to_lpvs:
        s.lpvs = s.lpvs + u


def aave_supply(s, p, u):
    """Proxy supplyCollateral of u freshly minted units (shares == assets)."""
    s.sh = [s.sh[q] + u if q == p else s.sh[q] for q in range(NP)]
    s.hubA, s.hubS, s.hubBal = s.hubA + u, s.hubS + u, s.hubBal + u


def debit_record(s, p, i, u):
    """Debit u units from record i of proxy p (partial removal, deleverage release)."""
    s.cred = set_at(s.cred, i, s.cred[i] - u)
    s.live = set_at(s.live, i, s.live[i] - u)
    cap_record(s, only=i)
    s.TC = s.TC - u
    s.AC = [s.AC[q] - u if q == p else s.AC[q] for q in range(NP)]


def close_record(s, p, i, when=BoolVal(True)):
    """Close record i (when `when` holds): drop its credit, rescue units and liquidity
    (the NFT returns to its depositor with whatever liquidity it still has)."""
    s.TC = s.TC - If(when, s.cred[i], 0)
    s.AC = [s.AC[q] - If(when, s.cred[i], 0) if q == p else s.AC[q] for q in range(NP)]
    s.AR = [s.AR[q] - If(when, s.rs[i], 0) if q == p else s.AR[q] for q in range(NP)]
    s.cred = set_at(s.cred, i, If(when, IntVal(0), s.cred[i]))
    s.rs = set_at(s.rs, i, If(when, IntVal(0), s.rs[i]))
    s.live = set_at(s.live, i, If(when, IntVal(0), s.live[i]))
    s.open = set_at(s.open, i, If(when, BoolVal(False), s.open[i]))


# ---------------------------------------------------------------- operations
def op_pledge(pre, p, i, mint_extra=None):
    L, ru = fresh("L"), fresh("ru")
    s = pre.copy()
    guard = [Not(pre.open[i]), ru >= 0, ru <= L]                 # SPEC-BACK-014: rescueUnits <= L
    s.open = set_at(s.open, i, BoolVal(True))
    s.own = set_at(s.own, i, IntVal(p))
    s.cred = set_at(s.cred, i, L)
    s.live = set_at(s.live, i, L)
    s.rs = set_at(s.rs, i, ru)
    s.AR = [s.AR[q] + ru if q == p else s.AR[q] for q in range(NP)]
    s.TC = s.TC + L
    s.AC = [s.AC[q] + L if q == p else s.AC[q] for q in range(NP)]
    m = L if mint_extra is None else L + mint_extra
    s.supply = s.supply + m                                   # Adapter mint(proxy, credited)
    aave_supply(s, p, m)                                      # proxy supply, shares == assets
    checks = {"ZeroLiquidity": And(L >= 1, L <= MAX_CREDITED),
              "SupplyIncomplete": s.sh[p] - pre.sh[p] == L,
              "BackingMismatch": gap_check(pre, s)}
    return f"pledge(p{p},slot{i})", guard, s, checks, dict(L=L, minted=m)


def op_donate_liquidity(pre, i):
    d = fresh("donation")
    s = pre.copy()
    guard = [pre.open[i], d >= 1]
    s.live = set_at(s.live, i, s.live[i] + d)
    return f"increaseLiquidity(slot{i})", guard, s, {}, {}


def op_withdraw(pre, p, i, takes=None, units=None):
    """Debt-free withdraw of slot i by proxy p: proxy withdraw, burn, release."""
    s = pre.copy()
    units = units if units is not None else fresh("units")
    guard = [pre.open[i], pre.own[i] == p]
    checks = {"AaveWithdraw": And(units >= 1, units <= pre.sh[p])}
    aave_move(s, p, units, to_lpvs=False)          # proxy.withdrawCollateral: units land in the proxy
    s.supply = s.supply - units                    # Adapter burn(proxy, units)
    S = s.sh[p] + units                            # REQ-VAULT-131
    cons, sf, t = reconcile(s, p, S, "wd_rec", takes)
    guard += cons
    rc = s.cred[i]                                 # previewRelease(i)
    checks["UnitsMismatch"] = And(units == rc, units > 0)
    close_record(s, p, i)
    checks["BackingMismatch"] = gap_check(pre, s)
    return f"withdraw(p{p},slot{i})", guard, s, checks, dict(units=units, preview=rc, S=S, sf=sf)


def op_release_partial(pre, p, i, takes=None, units=None):
    """Adapter.removeLiquidity: proxy withdraw, burn, Collateralization.releasePartial."""
    s = pre.copy()
    u = units if units is not None else fresh("pr_units")
    guard = [pre.open[i], pre.own[i] == p]
    checks = {"AaveWithdraw": And(u >= 1, u <= pre.sh[p])}
    aave_move(s, p, u, to_lpvs=False)
    s.supply = s.supply - u
    cons, sf, t = reconcile(s, p, s.sh[p] + u, "pr_rec", takes)     # REQ-VAULT-131
    guard += cons
    rc = s.cred[i]
    checks["UnitsMismatch"] = u != 0
    checks["PartialRemovalTooLarge"] = u < rc
    debit_record(s, p, i, u)
    checks["BackingMismatch"] = gap_check(pre, s)
    return f"releasePartial(p{p},slot{i})", guard, s, checks, dict(units=u, preview=rc, sf=sf)


def op_recredit(pre, p, i, takes=None, mint_extra=None):
    """Adapter.recredit: Collateralization.recredit (reconcile, credit live - credited),
    then mint `added` to the proxy and supply it."""
    s = pre.copy()
    ru = fresh("rc_ru")
    guard = [pre.open[i], pre.own[i] == p]
    cons, sf, t = reconcile(s, p, pre.sh[p], "rc_rec", takes)        # REQ-VAULT-131 (current shares)
    guard += cons
    rc = s.cred[i]                                                    # credited after reconcile
    added = s.live[i] - s.cred[i]                                     # REQ-COLL-015
    guard += [ru >= 0, ru <= added]                                   # SPEC-BACK-014
    checks = {"NothingToRecredit": And(s.cred[i] > 0, added > 0),
              "LiquidityAboveBound": s.cred[i] + added <= MAX_CREDITED}
    s.cred = set_at(s.cred, i, s.live[i])
    s.TC = s.TC + added
    s.AC = [s.AC[q] + added if q == p else s.AC[q] for q in range(NP)]
    s.rs = set_at(s.rs, i, s.rs[i] + ru)
    s.AR = [s.AR[q] + ru if q == p else s.AR[q] for q in range(NP)]
    m = added if mint_extra is None else added + mint_extra
    s.supply = s.supply + m                                           # Adapter mint(proxy, added)
    aave_supply(s, p, m)
    checks["SupplyIncomplete"] = s.sh[p] - pre.sh[p] == added
    checks["BackingMismatch"] = gap_check(pre, s)
    return f"recredit(p{p},slot{i})", guard, s, checks, dict(added=added, minted=m, sf=sf, rc=rc)


def op_deleverage(pre, p, i, takes=None, units=None):
    """Adapter.deleverageRelease inside repayWithCollateral: proxy withdraw, burn,
    Collateralization.releaseForDeleverage (close when nothing stays credited)."""
    s = pre.copy()
    u = units if units is not None else fresh("dl_units")
    guard = [pre.open[i], pre.own[i] == p]
    checks = {"AaveWithdraw": And(u >= 1, u <= pre.sh[p])}
    aave_move(s, p, u, to_lpvs=False)
    s.supply = s.supply - u
    cons, sf, t = reconcile(s, p, s.sh[p] + u, "dl_rec", takes)
    guard += cons
    rc = s.cred[i]
    checks["UnitsMismatch"] = And(u > 0, u <= rc)
    debit_record(s, p, i, u)
    closed = s.cred[i] == 0
    close_record(s, p, i, when=closed)
    checks["SharesDrop"] = pre.sh[p] - s.sh[p] == u                   # Adapter: UnitsMismatch(p.units, drop)
    checks["BackingMismatch"] = gap_check(pre, s)
    return f"releaseForDeleverage(p{p},slot{i})", guard, s, checks, dict(units=u, preview=rc, closed=closed, sf=sf)


def op_release_zero(pre, p, i):
    s = pre.copy()
    guard = [pre.open[i], pre.own[i] == p]
    cons, sf, t = reconcile(s, p, pre.sh[p], "rz_rec")
    guard += cons
    checks = {"RecordHasCredit": s.cred[i] == 0}
    close_record(s, p, i)
    return f"releaseZeroCredit(p{p},slot{i})", guard, s, checks, dict(sf=sf)


def op_seize(pre, p, core_only=False):
    """Conforming liquidation of proxy p seizing u units."""
    s = pre.copy()
    u = fresh("u")
    guard = [u >= 1, u <= pre.sh[p]]
    checks = {"SharesNotEqualAssets": pre.hubA == pre.hubS}
    shB, supB = pre.sh[p], pre.supply                            # Collateralization's own snapshot
    aave_move(s, p, u, to_lpvs=True)                             # liquidationCall, liquidationFee = 0
    s.lpvs = s.lpvs - u                                          # Adapter.burnSeized(u)
    s.supply = s.supply - u
    checks["DebitMismatch"] = shB - s.sh[p] == u
    checks["SupplyDropMismatch"] = supB - s.supply == u
    cons, sf, t1 = reconcile(s, p, shB, "sz_rec")                # REQ-VAULT-133: S = sharesBefore
    guard += cons
    checks["InsufficientCredit"] = u <= s.AC[p]
    if core_only:
        return f"liquidate(p{p})", guard, s, checks, {}
    cons2, t2 = debit(s, p, u, "sz_debit")
    guard += cons2
    return f"liquidate(p{p})", guard, s, checks, {}


def op_seize_unsettled(pre, p):
    s = pre.copy()
    u = fresh("u_unsettled")
    guard = [u >= 1, u <= pre.sh[p]]
    aave_move(s, p, u, to_lpvs=True)
    return f"unsettledSeizure(p{p})", guard, s, {}, {}


def op_settle_pending(pre):
    s = pre.copy()
    x = fresh("x")
    guard = [x <= pre.lpvs]
    checks = {"PendingExceeded": And(x >= 1, x <= pre.P)}
    s.lpvs, s.supply = s.lpvs - x, s.supply - x                  # burnSeized(x)
    checks["SupplyDropMismatch"] = s.supply + x <= pre.TC + pre.P   # SPEC-BACK-012 (one-sided)
    s.P = s.P - x
    return "settlePending", guard, s, checks, dict(x=x)


def op_settle_pending_noburn(pre):
    """Non-conforming: settlePending(x) with no burn."""
    s = pre.copy()
    x = fresh("x_noburn")
    guard = []
    checks = {"PendingExceeded": And(x >= 1, x <= pre.P),
              "SupplyDropMismatch": s.supply + x <= pre.TC + pre.P}
    s.P = s.P - x
    return "settlePending-without-burn", guard, s, checks, dict(x=x)


def op_donate_hub(pre):
    s = pre.copy()
    z = fresh("z")
    guard = [z >= 1, z <= pre.lpvs]
    s.lpvs, s.hubBal = s.lpvs - z, s.hubBal + z
    return "LPVaultSwap-transfer-to-Hub", guard, s, {}, {}


def op_orphan_burn(pre):
    """Non-conforming: burnSeized(y) with no settleSeizure / settlePending after it."""
    s = pre.copy()
    y = fresh("y")
    guard = [y >= 1, y <= pre.lpvs]
    s.lpvs, s.supply = s.lpvs - y, s.supply - y
    return "burnSeized-without-settlement", guard, s, {}, dict(y=y)


ADAPTER_OPS = ("pledge", "withdraw", "releasePartial", "recredit", "releaseForDeleverage")


def honest_ops(pre):
    ops = []
    for p in range(NP):
        for i in range(K):
            ops += [op_pledge(pre, p, i), op_withdraw(pre, p, i), op_release_partial(pre, p, i),
                    op_recredit(pre, p, i), op_deleverage(pre, p, i), op_release_zero(pre, p, i)]
        ops.append(op_seize(pre, p))
    for i in range(K):
        ops.append(op_donate_liquidity(pre, i))
    ops.append(op_settle_pending(pre))
    return ops


def nonconforming_ops(pre):
    ops = [op_seize_unsettled(pre, p) for p in range(NP)]
    ops += [op_donate_hub(pre), op_settle_pending_noburn(pre), op_orphan_burn(pre)]
    return ops


def holds(checks, skip=()):
    return And([v for k, v in checks.items() if k not in skip] or [BoolVal(True)])


def is_adapter(name):
    return name.split("(")[0] in ADAPTER_OPS


def main():
    pre = St("pre")
    init = St()
    init.open = [BoolVal(False)] * K
    init.own = [IntVal(0)] * K
    for f in ("cred", "live", "rs"):
        setattr(init, f, [IntVal(0)] * K)
    for f in ("AC", "AR", "sh"):
        setattr(init, f, [IntVal(0)] * NP)
    for f in ("TC", "P", "supply", "hubA", "hubS", "hubBal", "lpvs"):
        setattr(init, f, IntVal(0))
    # FV-CUS-01 verifies: INV-001, INV-080, SPEC-BACK-009, REQ-VAULT-029, REQ-VTOKEN-016, REQ-ADAPTER-069, REQ-ADAPTER-075, SPEC-PROXY-008, REQ-COLL-007
    prove("FV-CUS-01-base", "T-01/T-02/T-04 invariants hold in the empty market with a backing gap of 0",
          And(INV_EQ(init, reviewed=True), inv_rescue(init)))

    allops = honest_ops(pre) + nonconforming_ops(pre)
    # ---- T-01 one-sided backing over every successful call, conforming or not. The
    # Adapter's backing-gap check is NOT assumed: the bound is derived from the effects.
    for name, guard, post, checks, info in allops:
        g = [INV(pre)] + guard + [holds(checks, {"BackingMismatch"})]
        prove(f"FV-CUS-01-{name}", f"T-01 supply <= totalCredited + pending and the record sums kept by {name}",
              INV(post), g, show=[pre.supply, pre.TC, pre.P, post.supply, post.TC, post.P])

    # ---- Backing gap accounting: every call keeps the gap except the two non-conforming
    # LPVaultSwap calls that change supply or pending without the matching other side.
    for name, guard, post, checks, info in allops:
        g = [INV(pre)] + guard + [holds(checks, {"BackingMismatch"})]
        if name == "burnSeized-without-settlement":
            claim, what = gap(post) == gap(pre) + info["y"], "raises the gap by exactly the orphan units"
        elif name == "settlePending-without-burn":
            claim, what = And(gap(post) == gap(pre) - info["x"], gap(post) >= 0), "lowers the gap by x and leaves it >= 0"
        else:
            claim, what = gap(post) == gap(pre), "leaves the backing gap unchanged"
        prove(f"FV-CUS-01-gap-{name}", f"INV-080 {name} {what}", claim, g)

    # PROP-065 as restated for FV-CUS-F-07: only a burnSeized not followed by its debit
    # raises the gap, and only a settlePending(x) called without a matching burn lowers it,
    # by the x units not burned in that call and never below 0 (SPEC-BACK-012). Checked
    # over every call at once: each successful call either keeps or raises the gap, or is
    # the unburned settlePending and lowers it by exactly x to a value >= 0.
    # FV-CUS-01 verifies: PROP-065, SPEC-BACK-012, INV-080, REQ-VAULT-139
    parts = []
    for name, guard, post, checks, info in allops:
        ok = And(guard + [holds(checks, {"BackingMismatch"})])
        if name == "settlePending-without-burn":
            cl = And(gap(post) == gap(pre) - info["x"], gap(post) >= 0)
        else:
            cl = gap(post) >= gap(pre)
        parts.append(Implies(ok, cl))
    prove("FV-CUS-01-gapmono", "PROP-065: only an unburned settlePending lowers the backing gap, by x and never below 0; no other call lowers it",
          And(parts), [INV(pre)])

    # ---- Equality while no orphan burn happened: every conforming call (and an
    # unsettled seizure or a Hub transfer) keeps supply == totalCredited + pending.
    for name, guard, post, checks, info in honest_ops(pre) + nonconforming_ops(pre)[:3]:
        g = [INV_EQ(pre)] + guard + [holds(checks, {"BackingMismatch"})]
        prove(f"FV-CUS-01-eq-{name}", f"INV-001 equality kept by {name} when every burnSeized was settled",
              backing_eq(post), g)
    # The orphan burn is the only call that opens a gap; the Adapter calls then keep it.
    name, guard, post, checks, info = op_orphan_burn(pre)
    prove("FV-CUS-01-orphanBurn", "T-01 a burnSeized with no settlement keeps every unit backed (supply < credited + pending)",
          And(backing_le(post), post.supply < post.TC + post.P), [INV(pre)] + guard)

    # ---- Rescue units (SPEC-BACK-014, REQ-COLL-016) over every call.
    # FV-CUS-33 verifies: SPEC-BACK-014, REQ-COLL-016, REQ-COLL-014, REQ-COLL-015, REQ-COLL-017, INV-001
    for name, guard, post, checks, info in allops:
        g = [INV(pre), inv_rescue(pre)] + guard + [holds(checks, {"BackingMismatch"})]
        prove(f"FV-CUS-33-{name}", f"rescue units stay within credited units and sum to accountRescueUnits across {name}",
              inv_rescue(post), g)

    # ---- T-03: with a reviewed LPVaultSwap the Hub balance equals its recorded
    # liquidity and every unit at rest sits in the Hub or in LPVaultSwap.
    # FV-CUS-03 verifies: INV-003, REQ-VTOKEN-017, REQ-VTOKEN-018
    for name, guard, post, checks, info in honest_ops(pre) + nonconforming_ops(pre)[:2]:
        g = [INV(pre, reviewed=True)] + guard + [holds(checks, {"BackingMismatch"})]
        prove(f"FV-CUS-03-{name}", f"T-03 Hub balance == added assets == added shares == sum of proxy shares across {name}",
              INV(post, reviewed=True), g)

    # ---- Liveness of the Adapter calls: from every reachable state (a positive gap
    # left by an orphan burn included) the call passes every check when the app sizes
    # its amounts from the previews.
    # FV-CUS-07 verifies: SPEC-BACK-002, REQ-VAULT-018, REQ-VAULT-020, REQ-ADAPTER-068, REQ-ADAPTER-069, INV-080
    for p in range(NP):
        name, guard, post, checks, info = op_pledge(pre, p, 0)
        prove(f"FV-CUS-07-p{p}", "T-07 pledge: proxy shares rise by credited and the backing-gap check passes",
              holds(checks), [INV(pre)] + guard + [checks["ZeroLiquidity"]])
    # FV-CUS-20 verifies: INV-058, SPEC-BACK-011, REQ-VAULT-131, REQ-VAULT-134, REQ-VAULT-140, REQ-VAULT-143, REQ-ADAPTER-069
    for p in range(NP):
        name, guard, post, checks, info = op_withdraw(pre, p, 1)
        prove(f"FV-CUS-20-p{p}", "T-20/T-19 debt-free withdraw with previewRelease units passes every check and leaves shares == accountCredited",
              And(holds(checks), post.sh[p] == post.AC[p]),
              [INV(pre)] + guard + [info["units"] == info["preview"], info["preview"] >= 1])
    name, guard, post, checks, info = op_release_zero(pre, 0, 2)
    prove("FV-CUS-20-zero", "T-20 releaseZeroCredit leaves shares == accountCredited and moves exactly the shortfall to pending",
          And(post.sh[0] == post.AC[0], post.P - pre.P == pre.AC[0] - post.AC[0]),
          [INV(pre)] + guard + [holds(checks)])

    # Partial removal (REQ-COLL-014, REQ-ADAPTER-078).
    # FV-CUS-30 verifies: REQ-COLL-014, REQ-ADAPTER-078, INV-088, WDR-POST-010, WDR-039, SPEC-BACK-009, SPEC-BACK-010, SPEC-BACK-011, REQ-VAULT-131, REQ-VAULT-140, REQ-VAULT-043, REQ-COLL-020
    for p in range(NP):
        name, guard, post, checks, info = op_release_partial(pre, p, 1)
        prove(f"FV-CUS-30-live-p{p}", "partial removal of 0 < units < previewRelease passes every check (backing gap included) in every reachable state",
              holds(checks), [INV(pre)] + guard + [info["units"] >= 1, info["units"] < info["preview"]])
        g = [INV(pre), inv_rescue(pre)] + guard + [holds(checks, {"BackingMismatch"})]
        prove(f"FV-CUS-30-record-p{p}", "partial removal leaves the record open with credited = previewRelease - units >= 1, live - credited unchanged, and shares == accountCredited",
              And(post.open[1], post.cred[1] == info["preview"] - info["units"], post.cred[1] >= 1,
                  post.live[1] - post.cred[1] == pre.live[1] - pre.cred[1],
                  post.sh[p] == post.AC[p], pre.supply - post.supply == info["units"]), g)
        q = 1 - p
        prove(f"FV-CUS-30-other-p{p}", "partial removal changes no record, credit or share of another proxy",
              And(post.AC[q] == pre.AC[q], post.sh[q] == pre.sh[q], post.AR[q] == pre.AR[q],
                  And([Implies(pre.own[i] == q, And(post.cred[i] == pre.cred[i], post.open[i] == pre.open[i]))
                       for i in range(K)])), g)
        prove(f"FV-CUS-30-toolarge-p{p}", "a partial removal of every credited unit (units >= previewRelease) reverts PartialRemovalTooLarge",
              Not(checks["PartialRemovalTooLarge"]), [INV(pre)] + guard + [info["units"] >= info["preview"]])

    # Re-credit (REQ-COLL-015, REQ-ADAPTER-079).
    # FV-CUS-31 verifies: REQ-COLL-015, REQ-ADAPTER-079, INV-088, DEP-021, DEP-023, DEP-024, DEP-025, REQ-VAULT-024, REQ-VAULT-042, SPEC-BACK-009, SPEC-BACK-010, REQ-VAULT-131, REQ-VAULT-140, REQ-COLL-021
    for p in range(NP):
        name, guard, post, checks, info = op_recredit(pre, p, 1)
        prove(f"FV-CUS-31-live-p{p}", "re-credit of a record with live liquidity above credited passes every check (backing gap included) in every reachable state",
              holds(checks, {"NothingToRecredit"}),
              [INV(pre)] + guard + [checks["NothingToRecredit"], checks["LiquidityAboveBound"]])
        g = [INV(pre), inv_rescue(pre)] + guard + [holds(checks, {"BackingMismatch"})]
        prove(f"FV-CUS-31-record-p{p}", "re-credit mints exactly live - credited, leaves credited == live, and shares == accountCredited",
              And(info["minted"] == info["added"], info["added"] == pre.live[1] - pre.cred[1], post.cred[1] == post.live[1],
                  post.supply - pre.supply == info["added"], post.sh[p] == post.AC[p]), g)
        q = 1 - p
        prove(f"FV-CUS-31-other-p{p}", "re-credit changes no record, credit or share of another proxy",
              And(post.AC[q] == pre.AC[q], post.sh[q] == pre.sh[q], post.AR[q] == pre.AR[q],
                  And([Implies(pre.own[i] == q, post.cred[i] == pre.cred[i]) for i in range(K)])), g)
        prove(f"FV-CUS-31-nothing-p{p}", "re-credit with no live liquidity above credited, or of a record at 0 credited units, reverts NothingToRecredit",
              Not(checks["NothingToRecredit"]),
              [INV(pre)] + guard + [Or(pre.live[1] == pre.cred[1], info["rc"] == 0)])

    # Deleverage release (REQ-COLL-017, REQ-ADAPTER-081).
    # FV-CUS-32 verifies: REQ-COLL-017, REQ-ADAPTER-080, REQ-ADAPTER-081, SPEC-BACK-009, SPEC-BACK-010, REQ-VAULT-131, REQ-VAULT-140, REQ-VAULT-074, REQ-VAULT-033
    for p in range(NP):
        name, guard, post, checks, info = op_deleverage(pre, p, 1)
        prove(f"FV-CUS-32-live-p{p}", "deleverage release of 0 < units <= previewRelease passes every check (backing gap included) in every reachable state",
              holds(checks), [INV(pre)] + guard + [info["units"] >= 1, info["units"] <= info["preview"]])
        g = [INV(pre), inv_rescue(pre)] + guard + [holds(checks, {"BackingMismatch"})]
        prove(f"FV-CUS-32-close-p{p}", "deleverage release closes the record exactly when every credited unit leaves; otherwise it stays open with credit >= 1",
              And(Implies(info["units"] == info["preview"], Not(post.open[1])),
                  Implies(info["units"] < info["preview"], And(post.open[1], post.cred[1] >= 1)),
                  post.sh[p] == post.AC[p], pre.supply - post.supply == info["units"]), g)

    # ---- T-15 seizure checks and the settlePending checks.
    # FV-CUS-15 verifies: SPEC-BACK-007, REQ-VAULT-051, REQ-VAULT-055, INV-014, REQ-VAULT-133
    name, guard, post, checks, info = op_seize(pre, 0, core_only=True)
    prove("FV-CUS-15-checks", "T-15 conforming liquidation passes SharesNotEqualAssets, DebitMismatch, SupplyDropMismatch, InsufficientCredit",
          holds(checks), [INV(pre)] + guard)
    name, guard, post, checks, info = op_seize(pre, 0)
    prove("FV-CUS-15-ledger", "T-15 after settleSeizure the proxy's shares equal accountCredited (REQ-VAULT-140)",
          post.sh[0] == post.AC[0], [INV(pre)] + guard + [holds(checks)])
    prove("FV-CUS-15-other", "T-15/T-48 a liquidation of p0 changes no record, credit or share of p1",
          And(post.AC[1] == pre.AC[1], post.sh[1] == pre.sh[1],
              And([Implies(pre.own[i] == 1, And(post.cred[i] == pre.cred[i], post.open[i] == pre.open[i]))
                   for i in range(K)])),
          [INV(pre)] + guard + [holds(checks)])
    # FV-CUS-08 verifies: SPEC-BACK-012, REQ-VAULT-139, REQ-COLL-012, REQ-VAULT-141, REQ-VAULT-137, INV-080
    name, guard, post, checks, info = op_settle_pending(pre)
    prove("FV-CUS-08-pending", "T-08 a conforming settlePending (burn of x <= pending, held by LPVaultSwap) passes its one-sided burn check",
          holds(checks), [INV(pre)] + guard + [info["x"] >= 1, info["x"] <= pre.P])
    name, guard, post, checks, info = op_settle_pending_noburn(pre)
    prove("FV-CUS-08-noburn", "T-08 with a gap of 0, settlePending without a burn always reverts SupplyDropMismatch",
          Not(holds(checks)), [INV_EQ(pre)] + guard)
    prove("FV-CUS-08-noburn-gap", "T-08 after an orphan burn, settlePending without a burn passes only for x <= the gap, and every remaining unit stays backed",
          Implies(holds(checks), And(info["x"] <= gap(pre), backing_le(post))), [INV(pre)] + guard)

    # ---- T-19: liveness of every Adapter exit after an orphan burn (gap >= 1).
    # FV-CUS-19 verifies: INV-045, INV-080, WDR-018, REQ-ADAPTER-069, REQ-ADAPTER-070, REQ-COLL-007, REQ-VAULT-029
    mid = St("mid")
    broken = [INV(mid), gap(mid) >= 1]
    name, guard, post, checks, info = op_withdraw(mid, 0, 0)
    prove("FV-CUS-19-orphan", "T-19 debt-free withdraw with previewRelease units passes every check after a burnSeized without settlement",
          holds(checks), broken + guard + [info["units"] == info["preview"], info["preview"] >= 1],
          show=[mid.supply, mid.TC, mid.P, mid.AC[0], mid.sh[0], mid.cred[0]])
    name, guard, post, checks, info = op_release_partial(mid, 0, 0)
    prove("FV-CUS-19-orphan-partial", "T-19 debt-free partial removal passes every check after a burnSeized without settlement",
          holds(checks), broken + guard + [info["units"] >= 1, info["units"] < info["preview"]])
    name, guard, post, checks, info = op_pledge(mid, 0, 0)
    prove("FV-CUS-19-orphan-pledge", "T-19 a pledge passes the backing-gap check after a burnSeized without settlement",
          holds(checks), broken + guard + [checks["ZeroLiquidity"]])
    prove("FV-CUS-19-orphan-gapkept", "T-19 that pledge keeps the gap at its value before the call",
          gap(post) == gap(mid), broken + guard + [holds(checks)])

    # ---- Exactness of the backing-gap check: a mint that differs from the record
    # change by any d != 0 fails BackingMismatch in every reachable state.
    # FV-CUS-34 verifies: REQ-ADAPTER-069, REQ-ADAPTER-075, SPEC-PROXY-008, INV-066, INV-080
    for kind in ("pledge", "recredit"):
        d = fresh(f"extra_{kind}")
        if kind == "pledge":
            name, guard, post, checks, info = op_pledge(pre, 0, 0, mint_extra=d)
        else:
            name, guard, post, checks, info = op_recredit(pre, 0, 0, mint_extra=d)
        prove(f"FV-CUS-34-{kind}", f"the backing-gap check rejects a {kind} whose mint differs from the record change by any d != 0",
              Not(checks["BackingMismatch"]), [INV(pre)] + guard + [d != 0])
    for kind, mk in (("withdraw", op_withdraw), ("releasePartial", op_release_partial),
                     ("releaseForDeleverage", op_deleverage)):
        name, guard, post, checks, info = mk(pre, 0, 0)
        d = fresh(f"burn_extra_{kind}")
        bad = post.copy()
        bad.supply = post.supply - d                     # burns units + d instead of units
        prove(f"FV-CUS-34-{kind}", f"the backing-gap check rejects a {kind} whose burn differs from the record debit by any d != 0",
              Not(gap_check(pre, bad)), [INV(pre)] + guard + [holds(checks, {"BackingMismatch"}), d != 0])
    # Spec examples: SPEC-PROXY-008 and SPEC-BACK-009.
    g0 = 1_575_000_000
    concrete("FV-CUS-34-example", "SPEC-PROXY-008 example: with a gap of 1,575,000,000 a pledge of 50,000,000,000 keeps the gap; a mint of 50,000,000,001 leaves 1,574,999,999",
             (g0 + 50_000_000_000) - 50_000_000_000 == g0 and (g0 + 50_000_000_000) - 50_000_000_001 == 1_574_999_999)
    tc, pnd, sup = 9_000_000_000, 0, 7_425_000_000
    gb = tc + pnd - sup
    sup2 = sup - 4_000_000_000                           # withdraw NFT 7, burn 4,000,000,000
    S = (7_425_000_000 - 4_000_000_000) + 4_000_000_000
    sf = max(0, 9_000_000_000 - S)
    tc2, pnd2 = tc - sf - 4_000_000_000, pnd + sf
    concrete("FV-CUS-01-example", "SPEC-BACK-009 example: after an orphan burn of 1,575,000,000 the withdrawal of NFT 7 reads gapBefore = gapAfter = 1,575,000,000",
             gb == 1_575_000_000 and tc2 + pnd2 - sup2 == 1_575_000_000 and sup2 <= tc2 + pnd2)

    # ---- T-09 credited never rises on an open record, except a re-credit, which
    # raises it to exactly the live liquidity; the proxy of a record never changes.
    # FV-CUS-09 verifies: INV-006, REQ-VAULT-031, REQ-VAULT-024, REQ-VAULT-030, REQ-VAULT-077, REQ-VAULT-042
    for name, guard, post, checks, info in allops:
        g = [INV(pre)] + guard + [holds(checks, {"BackingMismatch"})]
        rc_slot = int(name.split("slot")[1][0]) if name.startswith("recredit") else None
        claim = And([Implies(And(pre.open[i], post.open[i]),
                             And(post.own[i] == pre.own[i],
                                 post.cred[i] == post.live[i] if i == rc_slot else post.cred[i] <= pre.cred[i]))
                     for i in range(K)])
        prove(f"FV-CUS-09-{name}", f"T-09 credited never rises (a re-credit raises it to exactly live) and the proxy never changes in {name}", claim, g)

    # ---- Item 2: withdrawals of different accounts commute and do not interfere.
    # FV-CUS-26 verifies: REQ-VAULT-043, REQ-LOCK-011, INV-001, INV-008
    tA = [fresh(f"cA_take{i}") for i in range(K)]
    tB = [fresh(f"cB_take{i}") for i in range(K)]
    uA, uB = fresh("cA_units"), fresh("cB_units")
    nA, gA, sA, cA, iA = op_withdraw(pre, 0, 0, takes=tA, units=uA)
    nB, gB, sB, cB, iB = op_withdraw(sA, 1, 1, takes=tB, units=uB)
    nB2, gB2, sB2, cB2, iB2 = op_withdraw(pre, 1, 1, takes=tB, units=uB)
    nA2, gA2, sA2, cA2, iA2 = op_withdraw(sB2, 0, 0, takes=tA, units=uA)
    same = And([a == b for a, b in zip(sB.vars(), sA2.vars())])
    prove("FV-CUS-26-commute", "item 2: debt-free withdrawals by two accounts succeed in either order and give the same state (same per-account allocation)",
          And(same, And(gB2), And(gA2), holds(cB2), holds(cA2)),
          [INV(pre)] + gA + gB + [holds(cA), holds(cB)])
    prove("FV-CUS-26-other", "item 2: a withdrawal by p0 changes no record, credit or share of p1 and keeps the backing gap",
          And(sA.AC[1] == pre.AC[1], sA.sh[1] == pre.sh[1], gap(sA) == gap(pre),
              And([Implies(pre.own[i] == 1, sA.cred[i] == pre.cred[i]) for i in range(K)])),
          [INV(pre)] + gA + [holds(cA, {"BackingMismatch"})])
    # ---- Item 4: closing a record reduces credited + pending by exactly its units.
    # FV-CUS-27 verifies: SPEC-BACK-009, REQ-VAULT-129, REQ-VAULT-071
    units_closed = pre.supply - sA.supply
    prove("FV-CUS-27-close", "item 4: a withdrawal reduces totalCredited + pending and the supply by exactly the released units, and totalCredited by units + shortfall",
          And((pre.TC + pre.P) - (sA.TC + sA.P) == units_closed,
              pre.TC - sA.TC == units_closed + (sA.P - pre.P),
              sA.P - pre.P >= 0),
          [INV(pre)] + gA + [holds(cA, {"BackingMismatch"})])

    # ---- T-17 nothing for zero.
    # FV-CUS-17 verifies: REQ-VAULT-052, REQ-VAULT-141, REQ-VAULT-107, REQ-COLL-011, REQ-COLL-014, REQ-COLL-017, REQ-COLL-021
    v, b = fresh("seized"), fresh("burned")
    prove("FV-CUS-17-zeroSeize", "T-17 settleSeizure(0) passes only if Aave moved no unit and none was burned",
          And(v == 0, b == 0),
          [INV(pre), v >= 0, v <= pre.sh[0], b >= 0, b <= pre.lpvs + v,
           (pre.sh[0]) - (pre.sh[0] - v) == 0, pre.supply - (pre.supply - b) == 0])
    name, guard, post, checks, info = op_settle_pending(pre)
    prove("FV-CUS-17-pending0", "T-17 settlePending with x == 0 reverts PendingExceeded",
          Not(checks["PendingExceeded"]), [INV(pre), info["x"] == 0])
    name, guard, post, checks, info = op_pledge(pre, 0, 0)
    prove("FV-CUS-17-pledge0", "T-17 a pledge that credits 0 units reverts ZeroLiquidity",
          Not(checks["ZeroLiquidity"]), [INV(pre), info["L"] == 0])
    name, guard, post, checks, info = op_release_partial(pre, 0, 0, units=IntVal(0))
    prove("FV-CUS-17-partial0", "T-17 a partial removal of 0 units reverts",
          Not(holds(checks)), [INV(pre)] + guard)
    name, guard, post, checks, info = op_deleverage(pre, 0, 0, units=IntVal(0))
    prove("FV-CUS-17-deleverage0", "T-17 a deleverage release of 0 units reverts",
          Not(holds(checks)), [INV(pre)] + guard)
    name, guard, post, checks, info = op_recredit(pre, 0, 0)
    prove("FV-CUS-17-recredit0", "T-17 a re-credit that would add 0 units reverts NothingToRecredit and mints nothing",
          Not(checks["NothingToRecredit"]), [INV(pre)] + guard + [info["added"] == 0])
    return summary("fv_backing")


if __name__ == "__main__":
    raise SystemExit(main())
