# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Global invariants of the Avana model, checked after every state-machine step.
Each check names the property ID recorded in ../README.md."""
from .const import (GHO, USDC_DEBT, HUB, LPVAULT, COLL, ADAPTER, SWAP, ESCROW, COV, GHO_RID, DEBT_RIDS)
from .aave import premium_ray, curve_rate, BPS_TO_RAY
from .uniswap import position_amounts
from .mathlib import BPS, RAY, cdiv, ray_mul_up
from .tokens import DECIMALS


class InvariantViolation(AssertionError):
    pass


def check(cond, pid, msg):
    if not cond:
        raise InvariantViolation(f"{pid}: {msg}")


def realizable_gho(s, m, units):
    """INV-074 / INV-078: stressed realizable value V(1 − s) − U − floorRoundingAllowanceGho of `units` vault tokens,
    valued at the oracle (Chainlink) prices with the stable ceiling, the price a liquidation after recovery uses."""
    mk = s.markets[m]
    if units == 0:
        return 0
    from .oracle import lp_price8
    v = lambda t: 10 ** 8 if t == GHO else min(s.prices[t], 10 ** 8)
    price = lp_price8(v(mk.t0), v(mk.t1))
    V = s.vt_value_gho(m, units, price)
    U = sum(s.unit_gho(v(t), DECIMALS[t]) for t in (mk.t0, mk.t1))
    return max(0, V * (BPS - s.p.slippage_bps) // BPS - U - s.p.floor_rounding_allowance)


def solvency(s):
    """INV-074 per debt asset: Σ min(Debt, Realizable) + Pending + Coverage ≥ Σ Debt + HubDeficit, in GHO."""
    out = {}
    debt_tot = {GHO: 0, USDC_DEBT: 0}
    covered = {GHO: 0, USDC_DEBT: 0}
    for pxo in s.proxies.values():
        sp = s.spokes[pxo.spoke]
        debts = {}
        for rid in s.account_debts(pxo.addr):
            asset = DEBT_RIDS[rid]
            price = 10 ** 8 if rid == GHO_RID else s.prices["USDC"]
            debts[asset] = debts.get(asset, 0) + sp.user_debt(pxo.addr, rid) * price * 10 ** (
                18 - s.debts[rid].decimals) // 10 ** 8
        if not debts:
            continue
        real = sum(realizable_gho(s, mk.idx, sp.supplied_assets(pxo.addr, mk.rid)) for mk in s.account_markets(pxo.addr))
        tot = sum(debts.values())
        for a, dv in debts.items():
            share = real * dv // tot
            debt_tot[a] += dv
            covered[a] += min(dv, share)
    for a in (GHO, USDC_DEBT):
        price = 10 ** 8 if a == GHO else s.prices["USDC"]
        scale = lambda x: x * price * 10 ** (18 - DECIMALS[a]) // 10 ** 8
        hub_def = sum(cdiv(sd.deficit_ray, RAY) for name, sd in s.hub.assets[a].spokes.items() if name in s.spokes)
        pending_v = 0
        if a == GHO:
            for mk in s.markets:
                amts = s.pending[mk.idx]["amounts"]
                lp = {t: (10 ** 8 if t == GHO else min(s.prices[t], 10 ** 8)) for t in (mk.t0, mk.t1)}
                pending_v += sum(amts[t] * lp[t] * 10 ** 18 // (10 ** DECIMALS[t] * 10 ** 8) for t in amts)
        lhs = covered[a] + pending_v + scale(s.funded_balance(a))
        rhs = debt_tot[a] + scale(hub_def)
        out[a] = (lhs, rhs)
    return out


def check_all(s, solvency_check=False):
    led = s.ledger
    active = [r for r in s.records.values() if r.status == "active"]
    for mk in s.markets:
        credited = sum(r.credited for r in active if r.market == mk.idx)
        pend = s.pending[mk.idx]["units"]
        supply = led.supply.get(mk.vt, 0)
        supplied = sum(sp.up(px.addr, mk.rid).supplied_shares for px in s.proxies.values()
                       for sp in (s.spokes[px.spoke],))
        # HYP-01 verifies: Q-066, Q-092, Q-201, Q-224, INV-001
        # HYP-89 verifies: Q-257, INV-080, INV-066
        check(supply <= credited + pend, "HYP-01", f"market {mk.idx} supply {supply} > credited {credited} + pending {pend}")
        check(credited + pend - supply == s.orphan_burned[mk.idx], "HYP-89",
              f"market {mk.idx} backing gap {credited + pend - supply} != orphan burns {s.orphan_burned[mk.idx]}")
        # HYP-03 verifies: Q-066, Q-068, Q-103, Q-189
        asset = s.hub.assets[mk.aid]
        check(led.balance(mk.vt, HUB) == asset.liquidity == supplied, "HYP-03",
              f"market {mk.idx} hub balance {led.balance(mk.vt, HUB)} liquidity {asset.liquidity} supplied {supplied}")
        check(s.hub.shares_equal_assets(mk.aid), "HYP-03", f"market {mk.idx} Hub shares != assets")
        # HYP-04 verifies: Q-068, Q-120, Q-124, Q-165, Q-201, Q-224
        # HYP-12 verifies: Q-068, Q-116, Q-120, Q-224
        for h, v in led.holders(mk.vt).items():
            check(h in (HUB, SWAP), "HYP-04", f"{h} holds {v} {mk.vt} at rest")
        check(led.balance(mk.vt, SWAP) + supplied == supply, "HYP-04", "vault tokens outside the Hub and LPVaultSwap")
        # HYP-57 verifies: Q-201, Q-211
        if pend == 0:
            check(all(v == 0 for v in s.pending[mk.idx]["amounts"].values()), "HYP-57", "pending tokens, no units")
    for t in s.TOKENS:
        held = sum(p["amounts"].get(t, 0) for p in s.pending.values())
        check(led.balance(t, COLL) >= held, "HYP-57", f"Collateralization holds less {t} than the pending balance")
    # HYP-02 verifies: Q-066, Q-067, Q-092, Q-107, Q-225, INV-064
    for r in active:
        pos = s.nfpm.positions[r.token_id]
        check(pos.liquidity >= r.credited, "HYP-02", f"token {r.token_id} live {pos.liquidity} < credited {r.credited}")
        check(pos.owner == LPVAULT, "HYP-02", f"token {r.token_id} not in LPVault custody")
        check(s.proxies[(r.depositor, r.spoke)].addr == r.proxy, "HYP-02", "record proxy is not proxyOf[wallet][spoke]")
        check(r.rescue_units <= r.credited, "HYP-77", f"record {r.token_id} rescue units above credited")
    for (w, spn), pxo in s.proxies.items():
        check(pxo.wallet == w and pxo.spoke == spn and s.proxy_of_addr[pxo.addr] is pxo, "HYP-93", "proxy rebound")
    # HYP-05 verifies: Q-160, Q-193, Q-194, Q-201
    for px in s.proxies.values():
        sp = s.spokes[px.spoke]
        for mk in s.markets:
            sup = sp.up(px.addr, mk.rid).supplied_shares
            cred = sum(r.credited for r in active if r.proxy == px.addr and r.market == mk.idx)
            check(sup <= cred, "HYP-05", f"{px.addr} market {mk.idx} supplied {sup} > credited {cred}")
            check(sup == cred - s.unsettled.get((px.addr, mk.idx), 0), "HYP-05",
                  f"{px.addr} market {mk.idx} supplied {sup} != credited {cred} less unsettled seizures")
    # HYP-06 verifies: Q-097, Q-124
    for t in list(led.supply):
        check(led.total(t) == led.supply[t], "HYP-06", f"{t} sum of balances {led.total(t)} != supply {led.supply[t]}")
    # HYP-74 verifies: Q-063, Q-211, Q-255, Q-278, INV-079
    for t in s.TOKENS:
        for a in (SWAP, ADAPTER, LPVAULT) + tuple(p.addr for p in s.proxies.values()):
            check(led.balance(t, a) == s.dust.get((t, a), 0), "HYP-74", f"{a} holds {led.balance(t, a)} {t} at the end of a transaction")
    # HYP-07 verifies: Q-116, Q-153
    for rid, asset in DEBT_RIDS.items():
        a = s.hub.assets[asset]
        idx = s.hub.drawn_index(a)
        tot_drawn = tot_psh = tot_off = 0
        for name, sp in s.spokes.items():
            if rid not in sp.reserves:
                continue
            sd_drawn = 0
            for (user, r), up in sp.pos.items():
                if r != rid:
                    continue
                check(up.drawn_shares >= 0 and up.premium_shares >= 0, "HYP-07", f"{user} negative debt shares")
                check(premium_ray(up.premium_shares, up.premium_offset_ray, idx) >= 0, "HYP-07", "negative premium")
                sd_drawn += up.drawn_shares
                tot_psh += up.premium_shares
                tot_off += up.premium_offset_ray
            check(a.spokes[name].drawn_shares == sd_drawn, "HYP-07", f"{asset} drawn shares mismatch on {name}")
            tot_drawn += sd_drawn
        check(a.drawn_shares == tot_drawn, "HYP-07", f"{asset} Hub drawn shares mismatch")
        check(a.premium_shares == tot_psh and a.premium_offset_ray == tot_off, "HYP-07", f"{asset} premium mismatch")
        check(led.balance(asset, HUB) >= a.liquidity, "HYP-07", f"Hub {asset} balance below recorded liquidity")
        # HYP-08 verifies: Q-070, Q-101, Q-142, Q-236
        check(a.deficit_ray == sum(sd.deficit_ray for sd in a.spokes.values()) >= 0, "HYP-08", "deficit bookkeeping")
        for c in COV.values():
            if c in a.spokes:
                check(a.spokes[c].deficit_ray == 0 and a.spokes[c].drawn_shares == 0, "HYP-08", "First-Loss Reserve drew")
        # HYP-98 verifies: SPEC-HUB-007, REQ-HUB-008, Q-408
        if a.ir is not None:
            base, before, after, _ = a.ir
            check(a.drawn_rate == curve_rate(a.ir, a.liquidity, ray_mul_up(a.drawn_shares, a.rate_index)), "HYP-98",
                  f"{asset} drawn rate is not the curve's rate at the utilization of its last Hub action")
            check(base * BPS_TO_RAY <= a.drawn_rate <= (base + before + after) * BPS_TO_RAY, "HYP-98",
                  f"{asset} drawn rate outside [base, base + before + after]")
    # HYP-09 verifies: Q-061
    for mk in s.markets:
        pool = mk.pool
        need0, need1 = pool.owed0, pool.owed1
        for p in s.nfpm.positions.values():
            if p.pool is pool and p.liquidity:
                a0, a1 = position_amounts(pool.sqrt_p, p.liquidity, pool.spacing, False)
                need0 += a0
                need1 += a1
        check(led.balance(mk.t0, pool.addr) >= need0 and led.balance(mk.t1, pool.addr) >= need1, "HYP-09",
              f"pool {pool.name} insolvent")
    # HYP-10 verifies: Q-055, Q-150, Q-158, Q-174, Q-175, Q-209, Q-254
    for mk in s.markets:
        recs = [r for r in active if r.market == mk.idx]
        reg = s.counters_regular.get(mk.idx, 0)
        sl = s.counters_slice.get(mk.idx, 0)
        check(reg + sl == sum(r.charge for r in recs), "HYP-10", f"market {mk.idx} counters {reg}+{sl} != record charges")
        check(reg <= s.p.cap_market_usd and sl <= s.p.topup_slice_usd or s.p.faulty_risk_module, "HYP-10",
              "market budget exceeded")
        for r in recs:
            exp = cdiv(r.orig_charge * r.credited, r.orig_units) if r.orig_units else 0
            check(r.charge == exp, "HYP-10", f"record {r.token_id} charge {r.charge} != fixed-basis {exp}")
    for t, v in s.counters_token.items():
        check(v == sum(r.charge for r in active if t in (s.markets[r.market].t0, s.markets[r.market].t1)), "HYP-10",
              f"token counter {t}")
    # HYP-31 verifies: Q-117, Q-127, Q-167, Q-190, Q-236, Q-267, Q-397, INV-037
    # HYP-87 verifies: Q-267, Q-397, INV-038
    # Q-397 replaced the settlement budget: every settlement is funded by recovery plus the caller (top-up or own
    # funds), so R + shortfall + K ≥ D + φ_D for each recorded liquidation and no Avana balance pays a gap.
    for r in s.settlements:
        check(r["R"] + r["shortfall"] + r["K"] >= r["D"] + r["phi_d"], "HYP-31", "settlement gap not paid by caller")
        check(r["shortfall"] == r["floor_gap"] + r["gap"], "HYP-87", "caller top-up != floor gap + settlement gap")
    # HYP-65 verifies: Q-214, INV-061, REQ-ESCROW-006
    keys = set(s.escrow_credited) | set(s.escrow_claimable) | set(s.escrow_claimed)
    for k in keys:
        check(s.escrow_credited.get(k, 0) == s.escrow_claimed.get(k, 0) + s.escrow_claimable.get(k, 0), "HYP-65",
              f"escrow {k}: credited != claimed + held")
    for t in s.TOKENS:
        tot = s.escrow_total.get(t, 0)
        check(tot == sum(v for (tt, _b), v in s.escrow_claimable.items() if tt == t), "HYP-65", "totalClaimable")
        check(led.balance(t, ESCROW) >= tot, "HYP-65", f"escrow balance of {t} below totalClaimable")
    # HYP-11 verifies: Q-056, Q-128, Q-191, Q-247, Q-248, INV-055, INV-087
    now = s.now()
    for mk in s.markets:
        e = mk.oracle.evaluate(now)
        check(e["served"] >= 1, "HYP-11", "LPOracle served 0")
        if e["state"] == "Cached":
            check(e["served"] == mk.oracle.accepted, "HYP-11", "a Cached market not served at its accepted price")
        if e["fresh"] is not None:
            check(e["served"] <= e["fresh"], "HYP-11", "a market that is not failed served above its fresh price")
    de = s.debt_oracle.evaluate(now)
    check(de["served"] >= 1, "HYP-11", "DebtOracle served 0")
    if de["state"] != "Live":
        check(de["served"] >= s.debt_oracle.accepted, "HYP-11", "a non-Live debt price served below its accepted price")
    # HYP-39 verifies: Q-053, Q-139, Q-155, Q-242, Q-400
    # Q-400: only a guardian freeze can leave fewer than keeperFloor unfrozen keepers; approved keepers never drop below it.
    check(len(s.keepers) >= s.p.keeper_floor, "HYP-39", "approved keepers below the floor (keeperFloor 1)")
    check(len(s.keepers) <= s.p.max_keepers, "HYP-39", "more than MAX_KEEPERS keepers")
    # HYP-70 verifies: Q-236, Q-249, Q-278, INV-074
    if solvency_check:
        for a, (lhs, rhs) in solvency(s).items():
            check(lhs >= rhs, "HYP-70", f"{a} insolvent: reserves side {lhs} < debt side {rhs}")
