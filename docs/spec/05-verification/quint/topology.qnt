// -*- mode: Bluespec; -*-
//
// Avana multi-Hub, multi-Spoke topology (AMM-neutral design review).
//
// Two Hubs (STABLE, VOLATILE), each with a GHO and a USDC reserve. Three CDP Spokes with
// one LP market each:
//   S1  home STABLE    market M1 = USDC/USDT   GHO and USDC drawn from STABLE
//   S2  home STABLE    market M2 = DAI/USDC    GHO and USDC drawn from STABLE
//   S3  home VOLATILE  market M3 = ETH/USDC    GHO drawn from VOLATILE, USDC drawn from
//                                              STABLE through a cross-Hub credit line
// Per Spoke: LPVault custody and Collateralization ledger. Per Hub: AaveAdapter,
// LPVaultSwap, MarketRegistry, ParameterStore and pause state. Avana deploys one immutable,
// logic-free PositionProxy per wallet x CDP Spoke x market by CREATE2, which executes only
// calls from the AaveAdapter and has no version, upgrade or migration. Each modelled Spoke has
// one market, so a (wallet, Spoke) proxy here is that proxy. The model also carries proxy
// versions with an opt-in migration (releaseVersion, upgradeAdapter, migrate) to check the
// version-pinned alternative of AMMN-SM-03; with latestVersion = 1 and no releaseVersion step
// it is the deployed design.
//
// `s.design` selects how the open points of the proposal are read. PROPOSAL is the
// literal reading of the proposal; FIXED applies the fixes in
// docs/audit/design-review/amm-neutral/state-machine.md. Each field can be set alone, so a
// test can show one fix at a time.
//
// Scenario tests: topology_tests.qnt. Simulation runs: topology_run.sh.
//
// Abstractions:
//   * one vault-token unit = one unit of credited liquidity; an LP unit holds one unit of
//     each leg, so its price is the sum of its leg token prices (cents); CF is a flat
//     percentage per market; stale collateral counts as 0;
//   * debt in whole asset units; GHO = 100 cents, USDC = the USDC token price;
//   * Aave liquidation: flat 5 % bonus, no close factor; a deficit is reported when the
//     account's only collateral reaches 0 with debt left (one market per Spoke);
//   * Aave drawCap counts drawn + deficit at draw time; interest is a +1 step per debt;
//   * swaps, fees, keepers and the timelock delay are not modelled; a governance
//     action stands for an executed timelock operation.
module topology {

  // ============================================================ CONSTANTS

  type Px = (str, str, int)          // (wallet, Spoke, version); ("EOA", sp, 0) = outside liquidator

  pure val HUBS = Set("STABLE", "VOLATILE")
  pure val ASSETS = Set("GHO", "USDC")
  pure val SPOKES = Set("S1", "S2", "S3")
  pure val MARKETS = Set("M1", "M2", "M3")
  pure val TOKENS = Set("USDC", "USDT", "DAI", "ETH")
  pure val WALLETS = Set("alice", "bob")
  pure val VERSIONS = Set(1, 2)
  pure val TOKEN_IDS = 1.to(6)
  pure val PAUSE_STATES = Set("None", "Frozen", "Paused")

  pure val HOME = Map("S1" -> "STABLE", "S2" -> "STABLE", "S3" -> "VOLATILE")
  pure val MKT = Map("S1" -> "M1", "S2" -> "M2", "S3" -> "M3")
  pure val SPK = Map("M1" -> "S1", "M2" -> "S2", "M3" -> "S3")
  pure val VAULT = Map("S1" -> "VAULT_S1", "S2" -> "VAULT_S2", "S3" -> "VAULT_S3")
  pure val LEGS = Map("M1" -> Set("USDC", "USDT"), "M2" -> Set("DAI", "USDC"), "M3" -> Set("ETH", "USDC"))
  pure val CF = Map("M1" -> 80, "M2" -> 80, "M3" -> 60)
  // funding Hub of each debt reserve (Spoke, asset)
  pure val FUND = Map(
    ("S1", "GHO") -> "STABLE", ("S1", "USDC") -> "STABLE",
    ("S2", "GHO") -> "STABLE", ("S2", "USDC") -> "STABLE",
    ("S3", "GHO") -> "VOLATILE", ("S3", "USDC") -> "STABLE")
  pure val BONUS = 105                // liquidation bonus, percent
  pure val OPEN_HF = 110              // opening health factor, percent

  pure val PXS: Set[Px] = tuples(WALLETS, SPOKES, VERSIONS)
  pure val EOAS: Set[Px] = SPOKES.map(sp => ("EOA", sp, 0))
  pure val HOLDERS: Set[Px] = PXS.union(EOAS)
  pure def eoa(sp: str): Px = ("EOA", sp, 0)

  // ================================================================ TYPES

  type Design = {
    capScope: str,        // "HOME": a Spoke's draw caps are checked by its home Hub's registry
                          // "FUNDING": by the funding Hub's registry, against its line and cross-Hub cap
    pauseScope: str,      // "HOME": a borrow reads its home Hub's pause; "FUNDING": also the funding Hub's
    proxySupport: str,    // "DROPPABLE": an Adapter upgrade may stop serving older proxy versions
                          // "KEPT": it reverts while a live proxy of an older version exists
    liqVariant: str,      // "STANDARD": public liquidationCall + transfer-restricted vault token
                          // "MANAGER": only the home Hub's LPVaultSwap may call liquidationCall
    tokenCapScope: str,   // "HOME": token caps count the home Hub's Spokes only
                          // "FUNDING": every Hub a Spoke draws from counts its collateral
  }
  pure val PROPOSAL: Design = {
    capScope: "HOME", pauseScope: "HOME", proxySupport: "DROPPABLE", liqVariant: "STANDARD", tokenCapScope: "HOME",
  }
  pure val FIXED: Design = {
    capScope: "FUNDING", pauseScope: "FUNDING", proxySupport: "KEPT", liqVariant: "MANAGER", tokenCapScope: "FUNDING",
  }

  type Nft = { owner: str, liq: int, m: str }
  type BRec = { tid: int, dep: str, px: Px, sp: str, m: str, cr: int, open: bool }

  type Ghost = {
    crossRoute: bool,        // a seizure or settlement ran through another Hub's LPVaultSwap
    extSeize: bool,          // vault-token collateral seized by someone other than its Hub's LPVaultSwap
    overDraw: bool,          // a draw left drawn + deficit above that Spoke's drawCap
    crossCapDraw: bool,      // a draw by a foreign Spoke left the foreign load above the cross-Hub cap
    lossMisattributed: bool, // a deficit or coverage booked on a Hub the Spoke does not draw from
    migDup: bool,            // a migration changed an account's totals or left anything behind
    crossShock: bool,        // a token price shock in one market changed another Spoke's account values
    poolShockCross: bool,    // a pool-local shock (stale feed) changed another Spoke's account values
    tokenCapBreach: bool,    // a pledge or re-credit left a funding Hub's token exposure above its cap
    pauseBypass: bool,       // a draw of a Hub's liquidity completed while that Hub was not in None
  }
  pure val NO_GHOST: Ghost = {
    crossRoute: false, extSeize: false, overDraw: false, crossCapDraw: false, lossMisattributed: false,
    migDup: false, crossShock: false, poolShockCross: false, tokenCapBreach: false, pauseBypass: false,
  }

  type St = {
    design: Design,
    nfts: int -> Nft,
    recs: int -> BRec,
    nextRec: int,
    pending: str -> int,              // market -> units reconciled into pending settlement
    pendingBack: str -> int,          // market -> liquidity removed and held for those units
    supply: str -> int,               // market -> vault-token total supply
    swapHeld: str -> int,             // market -> vault tokens held by its Hub's LPVaultSwap
    supplied: (Px, str) -> int,       // (holder, market) -> Spoke supplied units
    validPx: Set[(Px, str)],          // vault-token proxy registry
    proxies: Set[Px],                 // deployed proxies
    bound: (str, str) -> int,         // (wallet, Spoke) -> version of its current proxy (0 = none)
    debt: (Px, str) -> int,           // (proxy, asset) -> debt units
    liq: (str, str) -> int,           // (Hub, asset) -> liquidity
    added: (str, str) -> int,         // (Hub, asset) -> assets owed to suppliers (lenders + First-Loss Reserve)
    drawn: (str, str, str) -> int,    // (Hub, asset, Spoke)
    deficit: (str, str, str) -> int,  // (Hub, asset, Spoke)
    drawCap: (str, str, str) -> int,  // (Hub, asset, Spoke)
    creditLine: (str, str) -> int,    // (Hub, asset): approved line for all Spokes
    crossCap: (str, str) -> int,      // (Hub, asset): part of the line other Hubs' Spokes may draw
    coverage: (str, str) -> int,      // First-Loss Reserve balance per (funding Hub, asset)
    tokenCap: (str, str) -> int,      // (Hub, token): collateral units holding that token
    px: str -> int,                   // token USD price, cents
    stale: Set[str],                  // markets whose LP feed is stale (pool-local failure)
    pause: str -> str,                // Hub -> None | Frozen | Paused
    breaker: Set[str],                // markets with a tripped breaker
    offboarding: Set[str],            // delisted markets (Offboarding + Aave freeze)
    aaveFrozen: Set[str],             // vault-token reserves frozen on Aave
    debtFrozen: Set[(str, str)],      // (Spoke, asset) debt reserves frozen on Aave (delisting)
    receiveShares: Set[str],          // Spokes whose vault-token reserve has receiveSharesEnabled
    latestVersion: int,               // newest PositionProxy version
    minVersion: str -> int,           // Hub -> lowest proxy version its Adapter serves
    g: Ghost,
  }

  type LA = { act: str, who: str, tgt: str, n: int }

  var s: St
  var la: LA

  // ============================================================== HELPERS

  pure def openIds(st: St): Set[int] = st.recs.keys().filter(i => st.recs.get(i).open)
  pure def recsOf(st: St, p: Px, m: str): Set[int] =
    openIds(st).filter(i => st.recs.get(i).px == p and st.recs.get(i).m == m)
  pure def credOf(st: St, p: Px, m: str): int = recsOf(st, p, m).fold(0, (acc, i) => acc + st.recs.get(i).cr)
  pure def credMkt(st: St, m: str): int =
    openIds(st).filter(i => st.recs.get(i).m == m).fold(0, (acc, i) => acc + st.recs.get(i).cr)
  pure def credSpoke(st: St, sp: str): int =
    openIds(st).filter(i => st.recs.get(i).sp == sp).fold(0, (acc, i) => acc + st.recs.get(i).cr)
  pure def custodied(st: St, sp: str): Set[int] = TOKEN_IDS.filter(t => st.nfts.get(t).owner == VAULT.get(sp))
  pure def custLiq(st: St, sp: str): int = custodied(st, sp).fold(0, (acc, t) => acc + st.nfts.get(t).liq)

  pure def proxyOf(st: St, w: str, sp: str): Px = (w, sp, st.bound.get((w, sp)))
  pure def lpPrice(st: St, m: str): int = LEGS.get(m).fold(0, (acc, t) => acc + st.px.get(t))
  pure def debtPx(st: St, a: str): int = if (a == "GHO") 100 else st.px.get("USDC")
  // weighted collateral and debt; HF < 1 iff collW < debtW
  pure def collW(st: St, p: Px): int = {
    val m = MKT.get(p._2)
    if (st.stale.contains(m)) 0 else st.supplied.get((p, m)) * lpPrice(st, m) * CF.get(m)
  }
  pure def debtW(st: St, p: Px): int = ASSETS.fold(0, (acc, a) => acc + st.debt.get((p, a)) * debtPx(st, a) * 100)
  pure def vals(st: St, p: Px): (int, int) = (collW(st, p), debtW(st, p))
  pure def hasDebt(st: St, p: Px): bool = ASSETS.exists(a => st.debt.get((p, a)) > 0)
  pure def holds(st: St, p: Px): bool = or {
    hasDebt(st, p), st.supplied.get((p, MKT.get(p._2))) > 0, recsOf(st, p, MKT.get(p._2)).size() > 0,
  }
  pure def serves(st: St, p: Px): bool = p._3 >= st.minVersion.get(HOME.get(p._2))

  pure def drawnSum(st: St, h: str, a: str): int = SPOKES.fold(0, (acc, sp) => acc + st.drawn.get((h, a, sp)))
  pure def deficitSum(st: St, h: str, a: str): int = SPOKES.fold(0, (acc, sp) => acc + st.deficit.get((h, a, sp)))
  pure def capSum(st: St, h: str, a: str): int = SPOKES.fold(0, (acc, sp) => acc + st.drawCap.get((h, a, sp)))
  pure def foreignCapSum(st: St, h: str, a: str): int =
    SPOKES.filter(sp => HOME.get(sp) != h).fold(0, (acc, sp) => acc + st.drawCap.get((h, a, sp)))
  pure def foreignLoad(st: St, h: str, a: str): int =
    SPOKES.filter(sp => HOME.get(sp) != h).fold(0, (acc, sp) => acc + st.drawn.get((h, a, sp)) + st.deficit.get((h, a, sp)))
  pure def drawsFrom(sp: str, h: str): bool = ASSETS.exists(a => FUND.get((sp, a)) == h)

  // collateral units holding token t carried by Hub h: every Spoke that draws from h
  pure def exposure(st: St, h: str, t: str): int =
    openIds(st).filter(i => LEGS.get(st.recs.get(i).m).contains(t) and drawsFrom(st.recs.get(i).sp, h))
      .fold(0, (acc, i) => acc + st.recs.get(i).cr)
  // the same counter restricted to Spokes whose home is h (a per-Hub ParameterStore's view)
  pure def homeExposure(st: St, h: str, t: str): int =
    openIds(st).filter(i => LEGS.get(st.recs.get(i).m).contains(t) and HOME.get(st.recs.get(i).sp) == h)
      .fold(0, (acc, i) => acc + st.recs.get(i).cr)

  // Avana stops (application pause states and market breakers) cleared; Aave flags kept
  pure def clearStops(st: St): St = { ...st, pause: HUBS.mapBy(h => "None"), breaker: Set() }

  action go(nx: St, a: str, who: str, tgt: str, n: int): bool = all {
    s' = nx, la' = { act: a, who: who, tgt: tgt, n: n },
  }
  action stutter: bool = go(s, "stutter", "", "", 0)

  // ============================================================== LEDGER
  // Collateralization of one Spoke: debit records of (p, m), removing the matching liquidity
  // from their NFTs (largest-first order is not modelled).
  pure def debitRecs(st: St, p: Px, m: str, u: int): St = {
    val res = recsOf(st, p, m).fold((st.recs, st.nfts, u), (acc, i) => {
      val r = acc._1.get(i)
      val x = if (acc._3 < r.cr) acc._3 else r.cr
      val n = acc._2.get(r.tid)
      (acc._1.set(i, { ...r, cr: r.cr - x }), acc._2.set(r.tid, { ...n, liq: n.liq - x }), acc._3 - x)
    })
    { ...st, recs: res._1, nfts: res._2 }
  }

  // reconcile on exit (INV-058): supply below credit is debited and moved to pending settlement
  pure def reconcile(st: St, p: Px, m: str): St = {
    val short = credOf(st, p, m) - st.supplied.get((p, m))
    if (short <= 0) st
    else {
      val d = debitRecs(st, p, m, short)
      { ...d, pending: d.pending.setBy(m, x => x + short), pendingBack: d.pendingBack.setBy(m, x => x + short) }
    }
  }

  // ================================================================ CAPS

  pure def tokenCapOk(st: St, nx: St, sp: str, m: str): bool =
    if (st.design.tokenCapScope == "HOME")
      LEGS.get(m).forall(t => homeExposure(nx, HOME.get(sp), t) <= nx.tokenCap.get((HOME.get(sp), t)))
    else
      HUBS.filter(h => drawsFrom(sp, h)).forall(h => LEGS.get(m).forall(t => exposure(nx, h, t) <= nx.tokenCap.get((h, t))))

  pure def tokenBreach(nx: St, sp: str, m: str): bool =
    HUBS.filter(h => drawsFrom(sp, h)).exists(h => LEGS.get(m).exists(t => exposure(nx, h, t) > nx.tokenCap.get((h, t))))

  // ============================================================== PLEDGE

  pure def pledgeGates(st: St, w: str, sp: str): bool = {
    val h = HOME.get(sp)
    val m = MKT.get(sp)
    val indebted = st.bound.get((w, sp)) > 0 and hasDebt(st, proxyOf(st, w, sp))
    and {
      st.pause.get(h) == "None" or (st.pause.get(h) == "Frozen" and indebted),
      not(st.offboarding.contains(m)), not(st.aaveFrozen.contains(m)),
      not(st.stale.contains(m)), not(st.breaker.contains(m)),
    }
  }

  pure def pledgeRaw(st: St, w: str, t: int): St = {
    val n = st.nfts.get(t)
    val m = n.m
    val sp = SPK.get(m)
    val v = if (st.bound.get((w, sp)) > 0) st.bound.get((w, sp)) else st.latestVersion
    val p: Px = (w, sp, v)
    { ...st,
      nfts: st.nfts.set(t, { ...n, owner: VAULT.get(sp) }),
      recs: st.recs.put(st.nextRec, { tid: t, dep: w, px: p, sp: sp, m: m, cr: n.liq, open: true }),
      nextRec: st.nextRec + 1,
      supply: st.supply.setBy(m, x => x + n.liq),
      supplied: st.supplied.setBy((p, m), x => x + n.liq),
      validPx: st.validPx.union(Set((p, m))),
      proxies: st.proxies.union(Set(p)),
      bound: st.bound.set((w, sp), v),
    }
  }

  pure def pledgeOk(st: St, w: str, t: int): bool = {
    val n = st.nfts.get(t)
    val sp = SPK.get(n.m)
    val b = st.bound.get((w, sp))
    and {
      WALLETS.contains(w), n.owner == w, n.liq > 0,
      pledgeGates(st, w, sp),
      if (b > 0) serves(st, (w, sp, b)) else st.latestVersion >= st.minVersion.get(HOME.get(sp)),
      tokenCapOk(st, pledgeRaw(st, w, t), sp, n.m),
    }
  }

  pure def pledgeNext(st: St, w: str, t: int): St = {
    val nx = pledgeRaw(st, w, t)
    val sp = SPK.get(st.nfts.get(t).m)
    { ...nx, g: { ...nx.g, tokenCapBreach: nx.g.tokenCapBreach or tokenBreach(nx, sp, st.nfts.get(t).m) } }
  }

  action pledge(w: str, t: int): bool = all { pledgeOk(s, w, t), go(pledgeNext(s, w, t), "pledge", w, "", t) }

  // ============================================================== BORROW

  pure def pauseBorrowOk(st: St, sp: str, a: str): bool = and {
    st.pause.get(HOME.get(sp)) == "None",
    st.design.pauseScope == "HOME" or st.pause.get(FUND.get((sp, a))) == "None",
  }

  pure def borrowRaw(st: St, p: Px, a: str, x: int): St = {
    val h = FUND.get((p._2, a))
    { ...st,
      debt: st.debt.setBy((p, a), d => d + x),
      drawn: st.drawn.setBy((h, a, p._2), d => d + x),
      liq: st.liq.setBy((h, a), l => l - x) }
  }

  pure def borrowOk(st: St, w: str, sp: str, a: str, x: int): bool = {
    val b = st.bound.get((w, sp))
    val p: Px = (w, sp, b)
    val m = MKT.get(sp)
    val h = FUND.get((sp, a))
    and {
      b > 0, x > 0, serves(st, p),
      pauseBorrowOk(st, sp, a),
      not(st.offboarding.contains(m)), not(st.aaveFrozen.contains(m)),
      not(st.stale.contains(m)), not(st.breaker.contains(m)),
      not(st.debtFrozen.contains((sp, a))),
      st.drawn.get((h, a, sp)) + st.deficit.get((h, a, sp)) + x <= st.drawCap.get((h, a, sp)),   // Aave drawCap
      st.liq.get((h, a)) >= x,
      { val nx = borrowRaw(st, p, a, x); collW(nx, p) * 100 >= debtW(nx, p) * OPEN_HF },
    }
  }

  pure def borrowNext(st: St, w: str, sp: str, a: str, x: int): St = {
    val p = proxyOf(st, w, sp)
    val h = FUND.get((sp, a))
    val nx = borrowRaw(st, p, a, x)
    { ...nx, g: { ...nx.g,
      overDraw: nx.g.overDraw or nx.drawn.get((h, a, sp)) + nx.deficit.get((h, a, sp)) > nx.drawCap.get((h, a, sp)),
      crossCapDraw: nx.g.crossCapDraw or (HOME.get(sp) != h and foreignLoad(nx, h, a) > nx.crossCap.get((h, a))),
      pauseBypass: nx.g.pauseBypass or st.pause.get(h) != "None" } }
  }

  action borrow(w: str, sp: str, a: str, x: int): bool = all {
    borrowOk(s, w, sp, a, x), go(borrowNext(s, w, sp, a, x), "borrow", w, sp, x),
  }

  // ======================================================= REPAY AND EXITS
  // None of these reads a pause state or breaker (INV-081); they need the Adapter to drive the proxy.

  pure def repayOk(st: St, p: Px, a: str, x: int): bool = and {
    st.proxies.contains(p), x > 0, x <= st.debt.get((p, a)), serves(st, p),
  }
  pure def repayNext(st: St, p: Px, a: str, x: int): St = {
    val h = FUND.get((p._2, a))
    { ...st,
      debt: st.debt.setBy((p, a), d => d - x),
      drawn: st.drawn.setBy((h, a, p._2), d => d - x),
      liq: st.liq.setBy((h, a), l => l + x) }
  }
  // any payer
  action repay(p: Px, a: str, x: int): bool = all { repayOk(s, p, a, x), go(repayNext(s, p, a, x), "repay", p._1, p._2, x) }

  pure def withdrawOk(st: St, w: str, i: int): bool = st.recs.keys().contains(i) and {
    val r = st.recs.get(i)
    and { r.open, r.dep == w, serves(st, r.px), not(hasDebt(st, r.px)) or r.cr == 0 }
  }
  pure def withdrawNext(st: St, i: int): St = {
    val r0 = st.recs.get(i)
    val st1 = reconcile(st, r0.px, r0.m)
    val r = st1.recs.get(i)
    { ...st1,
      recs: st1.recs.set(i, { ...r, cr: 0, open: false }),
      nfts: st1.nfts.set(r.tid, { ...st1.nfts.get(r.tid), owner: r.dep }),
      supply: st1.supply.setBy(r.m, x => x - r.cr),
      supplied: st1.supplied.setBy((r.px, r.m), x => x - r.cr) }
  }
  action withdraw(w: str, i: int): bool = all { withdrawOk(s, w, i), go(withdrawNext(s, i), "withdraw", w, "", i) }

  // partial removal: debt-free needs no gate; with debt it reads the pause state, price and HF
  pure def removeOk(st: St, w: str, i: int, x: int): bool = st.recs.keys().contains(i) and {
    val r0 = st.recs.get(i)
    val st1 = reconcile(st, r0.px, r0.m)
    val r = st1.recs.get(i)
    val nx = removeNext(st, i, x)
    and {
      r0.open, r0.dep == w, serves(st, r0.px), x > 0, x < r.cr,
      not(hasDebt(st, r0.px)) or and {
        st.pause.get(HOME.get(r0.sp)) != "Paused", not(st.stale.contains(r0.m)), not(st.breaker.contains(r0.m)),
        collW(nx, r0.px) * 100 >= debtW(nx, r0.px) * OPEN_HF,
      },
    }
  }
  pure def removeNext(st: St, i: int, x: int): St = {
    val r0 = st.recs.get(i)
    val st1 = reconcile(st, r0.px, r0.m)
    val r = st1.recs.get(i)
    { ...st1,
      recs: st1.recs.set(i, { ...r, cr: r.cr - x }),
      nfts: st1.nfts.set(r.tid, { ...st1.nfts.get(r.tid), liq: st1.nfts.get(r.tid).liq - x }),
      supply: st1.supply.setBy(r.m, y => y - x),
      supplied: st1.supplied.setBy((r.px, r.m), y => y - x) }
  }
  action removePart(w: str, i: int, x: int): bool = all { removeOk(s, w, i, x), go(removeNext(s, i, x), "removeLiquidity", w, "", i) }

  // re-credit: the depositor adds x liquidity to the NFT (NFPM) and credits it; pledge gates apply
  pure def recreditRaw(st: St, i: int, x: int): St = {
    val r0 = st.recs.get(i)
    val st1 = reconcile(st, r0.px, r0.m)
    val r = st1.recs.get(i)
    { ...st1,
      recs: st1.recs.set(i, { ...r, cr: r.cr + x }),
      nfts: st1.nfts.set(r.tid, { ...st1.nfts.get(r.tid), liq: st1.nfts.get(r.tid).liq + x }),
      supply: st1.supply.setBy(r.m, y => y + x),
      supplied: st1.supplied.setBy((r.px, r.m), y => y + x) }
  }
  pure def recreditOk(st: St, w: str, i: int, x: int): bool = st.recs.keys().contains(i) and {
    val r = st.recs.get(i)
    and { r.open, r.dep == w, serves(st, r.px), x > 0, pledgeGates(st, w, r.sp), tokenCapOk(st, recreditRaw(st, i, x), r.sp, r.m) }
  }
  pure def recreditNext(st: St, i: int, x: int): St = {
    val r = st.recs.get(i)
    val nx = recreditRaw(st, i, x)
    { ...nx, g: { ...nx.g, tokenCapBreach: nx.g.tokenCapBreach or tokenBreach(nx, r.sp, r.m) } }
  }
  action recredit(w: str, i: int, x: int): bool = all { recreditOk(s, w, i, x), go(recreditNext(s, i, x), "recredit", w, "", i) }

  // anyone can increaseLiquidity on a custodied NFT (donation, never credited)
  action donate(t: int): bool = all {
    s.nfts.get(t).owner != "alice", s.nfts.get(t).owner != "bob",
    go({ ...s, nfts: s.nfts.set(t, { ...s.nfts.get(t), liq: s.nfts.get(t).liq + 1 }) }, "donate", "anyone", "", t),
  }

  // ============================================================ MIGRATION
  // Opt-in move of the bound proxy (w, sp, b) to the latest version. Aave V4 cannot move a
  // position between users, so the Adapter repays the old debt (flash), withdraws the old
  // supply, re-supplies it to the new proxy and re-borrows the same debt, in one call.
  // Aave-side conditions apply in every design (supply into a frozen reserve, a borrow from a
  // frozen reserve or past drawCap, a borrow at HF < 1 revert). Under PROPOSAL the re-supply and
  // re-borrow also pass the Adapter's pledge and borrow gates.
  pure def migrateOk(st: St, w: str, sp: str): bool = {
    val b = st.bound.get((w, sp))
    val p: Px = (w, sp, b)
    val m = MKT.get(sp)
    val hasColl = st.supplied.get((p, m)) > 0
    val debts = ASSETS.filter(a => st.debt.get((p, a)) > 0)
    and {
      b > 0, b < st.latestVersion, st.latestVersion >= st.minVersion.get(HOME.get(sp)),
      // Aave
      hasColl implies not(st.aaveFrozen.contains(m)),
      debts.forall(a => and {
        not(st.debtFrozen.contains((sp, a))),
        st.drawn.get((FUND.get((sp, a)), a, sp)) + st.deficit.get((FUND.get((sp, a)), a, sp)) <= st.drawCap.get((FUND.get((sp, a)), a, sp)),
      }),
      debts.size() > 0 implies (not(st.stale.contains(m)) and collW(st, p) >= debtW(st, p)),
      // Avana gates on the re-supply and re-borrow (PROPOSAL)
      st.design.proxySupport == "KEPT" or and {
        hasColl implies pledgeGates(st, w, sp),
        debts.forall(a => pauseBorrowOk(st, sp, a)),
        debts.size() > 0 implies not(st.offboarding.contains(m)),
      },
    }
  }
  pure def migrateOkPx(st: St, p: Px): bool = p._1 != "EOA" and p._3 == st.bound.get((p._1, p._2)) and migrateOk(st, p._1, p._2)

  pure def migrateNext(st: St, w: str, sp: str): St = {
    val b = st.bound.get((w, sp))
    val o: Px = (w, sp, b)
    val n: Px = (w, sp, st.latestVersion)
    val m = MKT.get(sp)
    val st1 = reconcile(st, o, m)
    val ids = recsOf(st1, o, m)
    val nx = { ...st1,
      recs: ids.fold(st1.recs, (acc, i) => acc.set(i, { ...acc.get(i), px: n })),
      supplied: st1.supplied.set((n, m), st1.supplied.get((n, m)) + st1.supplied.get((o, m))).set((o, m), 0),
      debt: ASSETS.fold(st1.debt, (acc, a) => acc.set((n, a), acc.get((n, a)) + acc.get((o, a))).set((o, a), 0)),
      validPx: st1.validPx.union(Set((n, m))),
      proxies: st1.proxies.union(Set(n)),
      bound: st1.bound.set((w, sp), st.latestVersion) }
    val same = and {
      credOf(nx, n, m) == credOf(st1, o, m) + credOf(st1, n, m),
      nx.supplied.get((n, m)) == st1.supplied.get((o, m)) + st1.supplied.get((n, m)),
      ASSETS.forall(a => nx.debt.get((n, a)) == st1.debt.get((o, a)) + st1.debt.get((n, a))),
      not(holds(nx, o)),
      nx.supply == st1.supply,
      SPOKES.forall(x => ASSETS.forall(a => HUBS.forall(h => nx.drawn.get((h, a, x)) == st1.drawn.get((h, a, x))))),
    }
    { ...nx, g: { ...nx.g, migDup: nx.g.migDup or not(same) } }
  }
  action migrate(w: str, sp: str): bool = all { migrateOk(s, w, sp), go(migrateNext(s, w, sp), "migrateProxy", w, sp, s.latestVersion) }

  // ========================================================== LIQUIDATION
  // LPVaultSwap of Hub h calls Spoke.liquidationCall on proxy p, repaying d of asset a.
  // mode "honest": the reviewed LPVaultSwap burns the seized tokens and the ledger debits the
  //   records in the same call; "faulty": an LPVaultSwap implementation that keeps the tokens
  //   and never calls the ledger; "external": a liquidator other than LPVaultSwap with
  //   receiveShares, credited Spoke shares without any token transfer.

  // Aave sizing: (units seized, debt repaid); when the collateral cannot cover d plus the
  // bonus, all of it is seized and the debt repaid falls to what it covers
  pure def liqSize(st: St, p: Px, a: str, d: int): (int, int) = {
    val m = MKT.get(p._2)
    val lp = lpPrice(st, m)
    val dp = debtPx(st, a)
    val want = (d * dp * BONUS + 100 * lp - 1) / (100 * lp)
    val have = st.supplied.get((p, m))
    if (want <= have) (want, d) else (have, (have * 100 * lp) / (dp * BONUS))
  }

  pure def liqOk(st: St, p: Px, a: str, d: int): bool = {
    val m = MKT.get(p._2)
    and {
      st.proxies.contains(p), d > 0, d <= st.debt.get((p, a)),
      not(st.stale.contains(m)), st.supplied.get((p, m)) > 0, collW(st, p) < debtW(st, p),
    }
  }

  // who may complete liquidationCall and receive the seized collateral
  pure def liqCallerOk(st: St, h: str, sp: str, mode: str): bool =
    if (mode == "external")
      // Aave: receiveShares needs receiveSharesEnabled and an unfrozen reserve; no token moves
      st.design.liqVariant == "STANDARD" and st.receiveShares.contains(sp) and not(st.aaveFrozen.contains(MKT.get(sp)))
    else
      // MANAGER: the Spoke's LIQUIDATION_MANAGER; STANDARD: the vault token accepts only its own Hub's LPVaultSwap
      h == HOME.get(sp)

  pure def liquidateNext(st: St, h: str, p: Px, a: str, d: int, mode: str): St = {
    val sp = p._2
    val m = MKT.get(sp)
    val sz = liqSize(st, p, a, d)
    val u = sz._1
    val rep = sz._2
    val fh = FUND.get((sp, a))
    val st1 = { ...st,
      debt: st.debt.setBy((p, a), x => x - rep),
      drawn: st.drawn.setBy((fh, a, sp), x => x - rep),
      liq: st.liq.setBy((fh, a), x => x + rep),
      supplied: st.supplied.setBy((p, m), x => x - u) }
    val st2 =
      if (mode == "honest") { ...debitRecs(st1, p, m, u), supply: st1.supply.setBy(m, x => x - u) }
      else if (mode == "faulty") { ...st1, swapHeld: st1.swapHeld.setBy(m, x => x + u) }
      else { ...st1, supplied: st1.supplied.setBy((eoa(sp), m), x => x + u) }
    // Aave deficit report: the account's only collateral is empty and debt remains
    val st3 =
      if (st2.supplied.get((p, m)) == 0 and hasDebt(st2, p))
        ASSETS.fold(st2, (acc, b) => {
          val fb = FUND.get((sp, b))
          val left = acc.debt.get((p, b))
          { ...acc,
            debt: acc.debt.set((p, b), 0),
            drawn: acc.drawn.setBy((fb, b, sp), x => x - left),
            deficit: acc.deficit.setBy((fb, b, sp), x => x + left) }
        })
      else st2
    { ...st3, g: { ...st3.g,
      crossRoute: st3.g.crossRoute or (mode != "external" and h != HOME.get(sp)),
      extSeize: st3.g.extSeize or mode == "external" } }
  }

  action liquidate(h: str, p: Px, a: str, d: int): bool = all {
    liqOk(s, p, a, d), liqCallerOk(s, h, p._2, "honest"),
    go(liquidateNext(s, h, p, a, d, "honest"), "LPVaultSwap.liquidate", h, p._2, d),
  }
  action liquidateExternal(p: Px, a: str, d: int): bool = all {
    liqOk(s, p, a, d), liqCallerOk(s, "", p._2, "external"),
    go(liquidateNext(s, "", p, a, d, "external"), "Spoke.liquidationCall(receiveShares, outside liquidator)", "EOA", p._2, d),
  }
  action liquidateFaulty(h: str, p: Px, a: str, d: int): bool = all {
    liqOk(s, p, a, d), liqCallerOk(s, h, p._2, "faulty"),
    go(liquidateNext(s, h, p, a, d, "faulty"), "LPVaultSwap(faulty).liquidate", h, p._2, d),
  }

  // settlePending: the market's Hub LPVaultSwap burns tokens it holds against pending units
  pure def settleOk(st: St, h: str, m: str): bool = and {
    st.pending.get(m) > 0, st.swapHeld.get(m) > 0, h == HOME.get(SPK.get(m)),
  }
  pure def settleNext(st: St, h: str, m: str): St = {
    val x = if (st.swapHeld.get(m) < st.pending.get(m)) st.swapHeld.get(m) else st.pending.get(m)
    { ...st,
      supply: st.supply.setBy(m, y => y - x), swapHeld: st.swapHeld.setBy(m, y => y - x),
      pending: st.pending.setBy(m, y => y - x), pendingBack: st.pendingBack.setBy(m, y => y - x),
      g: { ...st.g, crossRoute: st.g.crossRoute or h != HOME.get(SPK.get(m)) } }
  }
  action settlePending(h: str, m: str): bool = all { settleOk(s, h, m), go(settleNext(s, h, m), "settlePending", h, m, 0) }

  // ============================================================ COVERAGE
  // The First-Loss Reserve of (h, a) eliminates deficit of a Spoke on its allowlist (Spokes drawing a from h).
  pure def coverOk(st: St, h: str, a: str, sp: str, x: int): bool = and {
    x > 0, FUND.get((sp, a)) == h, x <= st.deficit.get((h, a, sp)), x <= st.coverage.get((h, a)),
  }
  pure def coverNext(st: St, h: str, a: str, sp: str, x: int): St = { ...st,
    deficit: st.deficit.setBy((h, a, sp), y => y - x),
    coverage: st.coverage.setBy((h, a), y => y - x),
    added: st.added.setBy((h, a), y => y - x),
    g: { ...st.g, lossMisattributed: st.g.lossMisattributed or FUND.get((sp, a)) != h } }
  action cover(h: str, a: str, sp: str, x: int): bool = all { coverOk(s, h, a, sp, x), go(coverNext(s, h, a, sp, x), "AvanaFirstLossReserve.coverDeficit", h, sp, x) }

  // interest: every open debt in (h, a) grows by one unit
  pure def accrueNext(st: St, h: str, a: str): St = {
    val ps = st.proxies.filter(p => st.debt.get((p, a)) > 0 and FUND.get((p._2, a)) == h)
    ps.fold(st, (acc, p) => { ...acc,
      debt: acc.debt.setBy((p, a), x => x + 1),
      drawn: acc.drawn.setBy((h, a, p._2), x => x + 1),
      added: acc.added.setBy((h, a), x => x + 1) })
  }
  action accrue(h: str, a: str): bool = go(accrueNext(s, h, a), "accrue", h, a, 0)

  // ============================================================== PRICES
  // A price shock in market m moves one of its leg tokens; every market and debt priced in
  // that token moves with it. A pool-local shock (feed stale, disagreement, drained pool)
  // affects market m only.
  pure def othersUnchanged(st: St, nx: St, m: str): bool =
    st.proxies.filter(p => p._2 != SPK.get(m)).forall(p => vals(st, p) == vals(nx, p))

  action shockToken(m: str, t: str, v: int): bool = {
    val nx = { ...s, px: s.px.set(t, v) }
    all {
      LEGS.get(m).contains(t), v != s.px.get(t),
      go({ ...nx, g: { ...nx.g, crossShock: nx.g.crossShock or not(othersUnchanged(s, nx, m)) } }, "priceShock", m, t, v),
    }
  }
  action poolShock(m: str): bool = {
    val nx = { ...s, stale: if (s.stale.contains(m)) s.stale.exclude(Set(m)) else s.stale.union(Set(m)) }
    go({ ...nx, g: { ...nx.g, poolShockCross: nx.g.poolShockCross or not(othersUnchanged(s, nx, m)) } }, "poolShock(feed stale/recovered)", m, "", 0)
  }

  // ============================================================ CONTROLS

  action setPause(h: str, ps: str): bool = all { s.pause.get(h) != ps, go({ ...s, pause: s.pause.set(h, ps) }, "setPause", h, ps, 0) }
  action tripBreaker(m: str): bool = all { not(s.breaker.contains(m)), go({ ...s, breaker: s.breaker.union(Set(m)) }, "tripBreaker", m, "", 0) }
  action resetBreaker(m: str): bool = all { s.breaker.contains(m), go({ ...s, breaker: s.breaker.exclude(Set(m)) }, "resetBreaker", m, "", 0) }

  // market delisting: Offboarding status plus the Aave freeze of its vault-token reserve (MKT-038)
  action offboard(m: str): bool = all {
    not(s.offboarding.contains(m)),
    go({ ...s, offboarding: s.offboarding.union(Set(m)), aaveFrozen: s.aaveFrozen.union(Set(m)) }, "offboardMarket", m, "", 0),
  }
  // debt-reserve delisting: drawCap 0 and Aave freeze; repay and liquidation stay open (MKT-045)
  action delistDebt(sp: str, a: str): bool = all {
    not(s.debtFrozen.contains((sp, a))),
    go({ ...s, debtFrozen: s.debtFrozen.union(Set((sp, a))), drawCap: s.drawCap.set((FUND.get((sp, a)), a, sp), 0) },
       "delistDebtReserve", sp, a, 0),
  }

  // a new PositionProxy implementation; new proxies use it, existing ones stay pinned
  action releaseVersion: bool = all {
    s.latestVersion < 2, go({ ...s, latestVersion: s.latestVersion + 1 }, "ProxyManager.releaseVersion", "", "", s.latestVersion + 1),
  }
  // an AaveAdapter upgrade of Hub h that serves proxies from the latest version on
  pure def upgradeAdapterOk(st: St, h: str): bool = and {
    st.minVersion.get(h) < st.latestVersion,
    st.design.proxySupport == "DROPPABLE" or
      st.proxies.forall(p => (HOME.get(p._2) == h and p._3 < st.latestVersion) implies not(holds(st, p))),
  }
  action upgradeAdapter(h: str): bool = all {
    upgradeAdapterOk(s, h),
    go({ ...s, minVersion: s.minVersion.set(h, s.latestVersion) }, "AaveAdapter.upgrade(min proxy version)", h, "", s.latestVersion),
  }

  action aaveSetReceiveShares(sp: str): bool = all {
    not(s.receiveShares.contains(sp)),
    go({ ...s, receiveShares: s.receiveShares.union(Set(sp)) }, "Aave.setReceiveSharesEnabled", sp, "", 1),
  }

  // governance cap changes (executed timelock operations)
  pure def setDrawCapOk(st: St, sp: str, a: str, v: int): bool = {
    val h = FUND.get((sp, a))
    val nx = { ...st, drawCap: st.drawCap.set((h, a, sp), v) }
    if (st.design.capScope == "HOME") {
      // checked by the home Hub's registry, over the home Hub's Spokes only
      val hh = HOME.get(sp)
      val mine = SPOKES.filter(x => HOME.get(x) == hh).fold(0, (acc, x) => acc + nx.drawCap.get((h, a, x)))
      mine <= (if (h == hh) st.creditLine.get((h, a)) else st.crossCap.get((h, a)))
    } else and {
      capSum(nx, h, a) <= st.creditLine.get((h, a)),
      foreignCapSum(nx, h, a) <= st.crossCap.get((h, a)),
    }
  }
  action govSetDrawCap(sp: str, a: str, v: int): bool = all {
    not(s.debtFrozen.contains((sp, a))), s.drawCap.get((FUND.get((sp, a)), a, sp)) != v, setDrawCapOk(s, sp, a, v),
    go({ ...s, drawCap: s.drawCap.set((FUND.get((sp, a)), a, sp), v) }, "gov.setDrawCap", sp, a, v),
  }
  // the funding Hub's ParameterStore holds its credit line and its cross-Hub cap
  pure def setCrossCapOk(st: St, h: str, a: str, v: int): bool = and {
    v <= st.creditLine.get((h, a)),
    st.design.capScope == "HOME" or foreignCapSum(st, h, a) <= v,
  }
  action govSetCrossCap(h: str, a: str, v: int): bool = all {
    s.crossCap.get((h, a)) != v, setCrossCapOk(s, h, a, v),
    go({ ...s, crossCap: s.crossCap.set((h, a), v) }, "gov.setCrossHubCap", h, a, v),
  }
  pure def setCreditLineOk(st: St, h: str, a: str, v: int): bool =
    if (st.design.capScope == "HOME")
      SPOKES.filter(x => HOME.get(x) == h).fold(0, (acc, x) => acc + st.drawCap.get((h, a, x))) <= v
    else
      capSum(st, h, a) <= v and st.crossCap.get((h, a)) <= v
  action govSetCreditLine(h: str, a: str, v: int): bool = all {
    s.creditLine.get((h, a)) != v, setCreditLineOk(s, h, a, v),
    go({ ...s, creditLine: s.creditLine.set((h, a), v) }, "gov.setCreditLine", h, a, v),
  }
  action govSetTokenCap(h: str, t: str, v: int): bool = all {
    s.tokenCap.get((h, t)) != v,
    go({ ...s, tokenCap: s.tokenCap.set((h, t), v) }, "gov.setTokenCap", h, t, v),
  }

  // ================================================================ INIT

  pure val NFTS0: int -> Nft = Map(
    1 -> { owner: "alice", liq: 6, m: "M1" }, 2 -> { owner: "bob", liq: 4, m: "M1" },
    3 -> { owner: "alice", liq: 6, m: "M2" }, 4 -> { owner: "bob", liq: 4, m: "M2" },
    5 -> { owner: "alice", liq: 6, m: "M3" }, 6 -> { owner: "bob", liq: 4, m: "M3" })

  pure def initState(d: Design): St = {
    design: d,
    nfts: NFTS0,
    recs: Map(),
    nextRec: 1,
    pending: MARKETS.mapBy(m => 0),
    pendingBack: MARKETS.mapBy(m => 0),
    supply: MARKETS.mapBy(m => 0),
    swapHeld: MARKETS.mapBy(m => 0),
    supplied: tuples(HOLDERS, MARKETS).mapBy(k => 0),
    validPx: Set(),
    proxies: Set(),
    bound: tuples(WALLETS, SPOKES).mapBy(k => 0),
    debt: tuples(HOLDERS, ASSETS).mapBy(k => 0),
    liq: tuples(HUBS, ASSETS).mapBy(k => 40),
    added: tuples(HUBS, ASSETS).mapBy(k => 40),
    drawn: tuples(HUBS, ASSETS, SPOKES).mapBy(k => 0),
    deficit: tuples(HUBS, ASSETS, SPOKES).mapBy(k => 0),
    // Stable USDC: 8 + 7 + 5 (cross-Hub, S3) = 20 = line; Stable GHO: 10 + 10 = 20 = line
    drawCap: tuples(HUBS, ASSETS, SPOKES).mapBy(k =>
      if (FUND.get((k._3, k._2)) != k._1) 0
      else if (k == ("STABLE", "USDC", "S1")) 8
      else if (k == ("STABLE", "USDC", "S2")) 7
      else if (k == ("STABLE", "USDC", "S3")) 5
      else 10),
    creditLine: Map(("STABLE", "GHO") -> 20, ("STABLE", "USDC") -> 20, ("VOLATILE", "GHO") -> 10, ("VOLATILE", "USDC") -> 10),
    crossCap: Map(("STABLE", "GHO") -> 0, ("STABLE", "USDC") -> 5, ("VOLATILE", "GHO") -> 0, ("VOLATILE", "USDC") -> 0),
    coverage: tuples(HUBS, ASSETS).mapBy(k => 5),
    tokenCap: Map(
      ("STABLE", "USDC") -> 26, ("STABLE", "USDT") -> 20, ("STABLE", "DAI") -> 20, ("STABLE", "ETH") -> 12,
      ("VOLATILE", "USDC") -> 12, ("VOLATILE", "USDT") -> 0, ("VOLATILE", "DAI") -> 0, ("VOLATILE", "ETH") -> 20),
    px: TOKENS.mapBy(t => 100),
    stale: Set(),
    pause: HUBS.mapBy(h => "None"),
    breaker: Set(),
    offboarding: Set(),
    aaveFrozen: Set(),
    debtFrozen: Set(),
    receiveShares: Set(),
    latestVersion: 1,
    minVersion: HUBS.mapBy(h => 1),
    g: NO_GHOST,
  }

  // open positions, built with the normal transitions: alice NFTs 1 (M1), 3 (M2), 5 (M3);
  // bob NFTs 2 (M1), 6 (M3); alice owes 8 GHO on S1 and 3 USDC (Stable) on S3; bob owes
  // 2 USDC on S1 and 4 GHO (Volatile) on S3.
  pure def loaded(d: Design): St = {
    val s1 = pledgeNext(initState(d), "alice", 1)
    val s2 = pledgeNext(s1, "alice", 3)
    val s3 = pledgeNext(s2, "alice", 5)
    val s4 = pledgeNext(s3, "bob", 2)
    val s5 = pledgeNext(s4, "bob", 6)
    val s6 = borrowNext(s5, "alice", "S1", "GHO", 8)
    val s7 = borrowNext(s6, "alice", "S3", "USDC", 3)
    val s8 = borrowNext(s7, "bob", "S1", "USDC", 2)
    borrowNext(s8, "bob", "S3", "GHO", 4)
  }

  action initWith(st: St, label: str): bool = all { s' = st, la' = { act: label, who: "", tgt: "", n: 0 } }
  action initProposal = initWith(initState(PROPOSAL), "init(PROPOSAL)")
  action initFixed = initWith(initState(FIXED), "init(FIXED)")
  action initProposalLoaded = initWith(loaded(PROPOSAL), "init(PROPOSAL, open positions)")
  action initFixedLoaded = initWith(loaded(FIXED), "init(FIXED, open positions)")
  // the loaded state after reachable steps: alice borrows 2 more Stable USDC on S3, two
  // interest steps, ETH falls to 1 cent (an M3 price shock): S3 accounts end in deficit
  pure def crashed(d: Design): St = {
    val c1 = borrowNext(loaded(d), "alice", "S3", "USDC", 2)
    val c2 = accrueNext(accrueNext(c1, "STABLE", "USDC"), "STABLE", "USDC")
    { ...c2, px: c2.px.set("ETH", 1) }
  }
  action initFixedCrash = initWith(crashed(FIXED), "init(FIXED, open positions, M3 crash)")
  action init = initProposal

  // ================================================================ STEPS

  pure val AMTS = Set(1, 2, 3)
  pure val PRICES = Set(40, 70, 100, 130)
  pure val CAPS = Set(0, 3, 8, 13)

  action doUser = {
    nondet w = WALLETS.oneOf()
    nondet t = TOKEN_IDS.oneOf()
    nondet sp = SPOKES.oneOf()
    nondet a = ASSETS.oneOf()
    nondet x = AMTS.oneOf()
    nondet i = (if (openIds(s).size() > 0) openIds(s) else Set(1)).oneOf()
    val dep = if (s.recs.keys().contains(i)) s.recs.get(i).dep else w
    any {
      pledge(s.nfts.get(t).owner, t),
      borrow(w, sp, a, x),
      repay(proxyOf(s, w, sp), a, x),
      withdraw(dep, i),
      removePart(dep, i, 1),
      recredit(dep, i, 1),
      donate(t),
      migrate(w, sp),
      stutter,
    }
  }

  action doLiquidation = {
    nondet p = (if (s.proxies.size() > 0) s.proxies else Set(("alice", "S1", 1))).oneOf()
    nondet a = ASSETS.oneOf()
    nondet d = Set(1, 2, 4).oneOf()
    nondet h = HUBS.oneOf()
    nondet m = MARKETS.oneOf()
    nondet sp = SPOKES.oneOf()
    nondet x = AMTS.oneOf()
    val dd = if (s.debt.get((p, a)) < d) s.debt.get((p, a)) else d
    any {
      liquidate(HOME.get(p._2), p, a, dd),
      liquidate(h, p, a, dd),                       // any Hub's LPVaultSwap (another Hub's is refused)
      liquidateExternal(p, a, dd),
      settlePending(HOME.get(SPK.get(m)), m),
      cover(FUND.get((sp, a)), a, sp, x),
      cover(h, a, sp, x),                           // any First-Loss Reserve (a wrong pair is refused)
      accrue(h, a),
      stutter,
    }
  }

  action doMarket = {
    nondet m = MARKETS.oneOf()
    nondet t = TOKENS.oneOf()
    nondet v = PRICES.oneOf()
    any { shockToken(m, t, v), poolShock(m), stutter }
  }

  action doControl = {
    nondet h = HUBS.oneOf()
    nondet ps = PAUSE_STATES.oneOf()
    nondet m = MARKETS.oneOf()
    nondet sp = SPOKES.oneOf()
    nondet a = ASSETS.oneOf()
    any {
      setPause(h, ps), tripBreaker(m), resetBreaker(m),
      offboard(m), delistDebt(sp, a),
      releaseVersion, upgradeAdapter(h),
      aaveSetReceiveShares(sp),
      stutter,
    }
  }

  action doGov = {
    nondet h = HUBS.oneOf()
    nondet sp = SPOKES.oneOf()
    nondet a = ASSETS.oneOf()
    nondet t = TOKENS.oneOf()
    nondet v = CAPS.oneOf()
    any {
      govSetDrawCap(sp, a, v), govSetCrossCap(h, a, v), govSetCreditLine(h, a, v),
      govSetTokenCap(h, t, v + 10),
      stutter,
    }
  }

  action doFaulty = {
    nondet p = (if (s.proxies.size() > 0) s.proxies else Set(("alice", "S1", 1))).oneOf()
    nondet a = ASSETS.oneOf()
    val dd = if (s.debt.get((p, a)) < 2) s.debt.get((p, a)) else 2
    any { liquidateFaulty(HOME.get(p._2), p, a, dd), stutter }
  }

  pure val GROUPS = Set(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
  action stepWith(faulty: bool): bool = {
    nondet k = GROUPS.oneOf()
    if (k <= 4) doUser
    else if (k <= 6) doLiquidation
    else if (k == 7) doMarket
    else if (k == 8) doControl
    else if (k == 9) doGov
    else if (faulty) doFaulty
    else doUser
  }
  action step = stepWith(false)
  action stepFaulty = stepWith(true)

  // ========================================================== EXIT GATES
  // What a borrower or keeper can still do, without assuming who has funds.

  pure def canRepay(st: St, p: Px, a: str): bool =
    st.debt.get((p, a)) > 0 and (serves(st, p) or migrateOkPx(st, p))
  pure def canWithdraw(st: St, i: int): bool = {
    val r = st.recs.get(i)
    and { r.open, not(hasDebt(st, r.px)) or r.cr == 0, serves(st, r.px) or migrateOkPx(st, r.px) }
  }
  pure def canRemoveFree(st: St, i: int): bool = {
    val r = st.recs.get(i)
    and { r.open, r.cr > 1, not(hasDebt(st, r.px)), serves(st, r.px) or migrateOkPx(st, r.px) }
  }
  pure def canLiquidate(st: St, p: Px, a: str): bool =
    liqOk(st, p, a, 1) and liqCallerOk(st, HOME.get(p._2), p._2, "honest")
  pure def canSettle(st: St, m: str): bool = settleOk(st, HOME.get(SPK.get(m)), m)

  // ============================================================ INVARIANTS
  // TOPO-01 … TOPO-10 are the properties requested for the design review; TOPO-X1, TOPO-X2
  // are extra checks the review added. Results: docs/audit/design-review/amm-neutral/state-machine.md.

  // TOPO-01 (INV-002, INV-005): per Spoke, the NFTs its vault custodies are exactly those of
  // its ledger's open records, each holds at least its credited units, and pending units equal
  // the liquidity the ledger holds for them.
  // QNT-TOPO-01 verifies: INV-002, INV-005
  val topo01_custody = and {
    SPOKES.forall(sp =>
      custodied(s, sp) == openIds(s).filter(i => s.recs.get(i).sp == sp).map(i => s.recs.get(i).tid)),
    openIds(s).map(i => s.recs.get(i).tid).size() == openIds(s).size(),
    openIds(s).forall(i => s.nfts.get(s.recs.get(i).tid).liq >= s.recs.get(i).cr),
    SPOKES.forall(sp => credSpoke(s, sp) <= custLiq(s, sp)),
    MARKETS.forall(m => s.pending.get(m) == s.pendingBack.get(m)),
  }

  // TOPO-02 (INV-001, INV-080): per market, vault-token supply == Σ credited + pending, and
  // the supply is exactly the Spoke shares plus what LPVaultSwap holds.
  // QNT-TOPO-02 verifies: INV-001, INV-080
  val topo02_supplyEqualsCredit = MARKETS.forall(m => and {
    s.supply.get(m) == credMkt(s, m) + s.pending.get(m),
    s.supply.get(m) == HOLDERS.fold(0, (acc, p) => acc + s.supplied.get((p, m))) + s.swapHeld.get(m),
  })
  // TOPO-02b (INV-008): per proxy and market, Spoke supply == Σ credited (reviewed components)
  // QNT-TOPO-02B verifies: INV-008
  val topo02b_perProxy = PXS.forall(p => s.supplied.get((p, MKT.get(p._2))) == credOf(s, p, MKT.get(p._2)))

  // TOPO-03 (INV-005, INV-012, INV-041, INV-071): records, supply, debt and deficits stay on
  // their own Spoke and funding Hub, and no seizure or settlement runs through another Hub's
  // LPVaultSwap or bypasses the market's own LPVaultSwap and ledger.
  // QNT-TOPO-03 verifies: INV-005, INV-012, INV-041, INV-071, AMMN-SM-04, AMMN-RT-03
  val topo03_noCrossRouting = and {
    not(s.g.crossRoute), not(s.g.extSeize),
    openIds(s).forall(i => {
      val r = s.recs.get(i)
      and { r.px._2 == r.sp, SPK.get(r.m) == r.sp, s.validPx.contains((r.px, r.m)), r.px._1 == r.dep }
    }),
    tuples(HOLDERS, MARKETS).forall(k => s.supplied.get(k) > 0 implies k._1._2 == SPK.get(k._2)),
    tuples(HUBS, ASSETS, SPOKES).forall(k =>
      (s.drawn.get(k) != 0 or s.deficit.get(k) != 0 or s.drawCap.get(k) != 0) implies FUND.get((k._3, k._2)) == k._1),
    SPOKES.forall(sp => ASSETS.forall(a =>
      HOLDERS.filter(p => p._2 == sp).fold(0, (acc, p) => acc + s.debt.get((p, a))) == s.drawn.get((FUND.get((sp, a)), a, sp)))),
    HOLDERS.forall(p => ASSETS.forall(a => s.debt.get((p, a)) > 0 implies s.proxies.contains(p))),
  }

  // TOPO-04 (INV-057), state form: each Hub's drawn total is within the sum of its draw caps
  // QNT-TOPO-04 verifies: INV-057, AMMN-SM-02
  val topo04_hubDebtWithinCaps = HUBS.forall(h => ASSETS.forall(a => drawnSum(s, h, a) <= capSum(s, h, a)))
  // TOPO-04g, gate form: no draw leaves drawn + deficit above the drawing Spoke's cap
  // QNT-TOPO-04G verifies: INV-057, AMMN-SM-02
  val topo04g_drawGate = not(s.g.overDraw)

  // TOPO-05: a funding Hub's draw caps sum to at most its credit line, other Hubs' Spokes'
  // caps to at most its cross-Hub cap, and no foreign draw exceeds the cross-Hub cap.
  // QNT-TOPO-05 verifies: AMMN-SM-01, AMMN-RT-11, AMMN-FLOW-05
  val topo05_crossHubCap = and {
    HUBS.forall(h => ASSETS.forall(a => and {
      capSum(s, h, a) <= s.creditLine.get((h, a)),
      foreignCapSum(s, h, a) <= s.crossCap.get((h, a)),
    })),
    not(s.g.crossCapDraw),
  }

  // TOPO-06 (INV-041, INV-042, INV-071): a Hub's suppliers lose only through deficits of
  // Spokes that draw from that Hub; coverage pays only its own (Hub, asset); Hub books balance.
  // QNT-TOPO-06 verifies: INV-041, INV-042, INV-071
  val topo06_lossAttribution = and {
    not(s.g.lossMisattributed),
    tuples(HUBS, ASSETS, SPOKES).forall(k => s.deficit.get(k) > 0 implies FUND.get((k._3, k._2)) == k._1),
    HUBS.forall(h => ASSETS.forall(a =>
      s.liq.get((h, a)) + drawnSum(s, h, a) + deficitSum(s, h, a) == s.added.get((h, a)))),
    tuples(HUBS, ASSETS, SPOKES).forall(k => s.drawn.get(k) >= 0 and s.deficit.get(k) >= 0),
  }

  // TOPO-07 (INV-067, INV-081): repay, debt-free withdrawal and removal, liquidation and
  // pending settlement are available in exactly the same cases with every Avana stop cleared.
  // QNT-TOPO-07 verifies: INV-067, INV-081, AMMN-SM-03
  val topo07_stopsNeverReachExits = {
    val c = clearStops(s)
    and {
      s.proxies.forall(p => ASSETS.forall(a => canRepay(s, p, a) == canRepay(c, p, a) and canLiquidate(s, p, a) == canLiquidate(c, p, a))),
      openIds(s).forall(i => canWithdraw(s, i) == canWithdraw(c, i) and canRemoveFree(s, i) == canRemoveFree(c, i)),
      MARKETS.forall(m => canSettle(s, m) == canSettle(c, m)),
    }
  }

  // TOPO-08: migration never duplicates or orphans collateral or debt: it preserves the
  // account's totals and empties the old proxy; one live proxy per (wallet, Spoke), the bound
  // one; every live proxy is served by its Adapter or can be migrated (Avana stops cleared).
  // QNT-TOPO-08 verifies: AMMN-SM-03, AMMN-RT-04, AMMN-RT-16, AMMN-FLOW-04
  val topo08_migration = and {
    not(s.g.migDup),
    tuples(WALLETS, SPOKES).forall(ws => VERSIONS.filter(v => holds(s, (ws._1, ws._2, v))).size() <= 1),
    PXS.forall(p => holds(s, p) implies p._3 == s.bound.get((p._1, p._2))),
    PXS.forall(p => holds(s, p) implies (serves(s, p) or migrateOkPx(clearStops(s), p))),
  }

  // TOPO-09 (MKT-038, MKT-040, MKT-045): in a delisted market or a Spoke with a delisted debt
  // reserve, every borrower can still repay each debt and, once debt-free, withdraw.
  // QNT-TOPO-09 verifies: MKT-038, MKT-040, MKT-045
  val topo09_delistingNeverStrands = openIds(s).forall(i => {
    val r = s.recs.get(i)
    val p = r.px
    val c = clearStops(s)
    val delisted = s.offboarding.contains(r.m) or ASSETS.exists(a => s.debtFrozen.contains((r.sp, a)))
    delisted implies and {
      not(hasDebt(s, p)) implies canWithdraw(c, i),
      ASSETS.forall(a => s.debt.get((p, a)) > 0 implies canRepay(c, p, a)),
    }
  })

  // TOPO-10 (INV-075): a price shock in one market never changes the account values on another Spoke
  // QNT-TOPO-10 verifies: INV-075, AMMN-SM-05
  val topo10_shockIsolation = not(s.g.crossShock) and not(s.g.poolShockCross)
  // TOPO-10p: the same for pool-local shocks only (feed stale, disagreement, drained pool)
  // QNT-TOPO-10P verifies: INV-075
  val topo10p_poolShockIsolation = not(s.g.poolShockCross)

  // TOPO-X1: a Hub's pause stops every new draw of its liquidity, including cross-Hub draws
  // QNT-TOPO-X1 verifies: AMMN-SM-06, AMMN-FLOW-19
  val topoX1_fundingPause = not(s.g.pauseBypass)
  // TOPO-X2: collateral holding a token, on every Spoke that draws from a Hub, stays within
  // that Hub's token cap after every pledge and re-credit
  // QNT-TOPO-X2 verifies: AMMN-SM-05, AMMN-RT-05
  val topoX2_tokenCap = not(s.g.tokenCapBreach)

  val allHolding = and {
    topo01_custody, topo02_supplyEqualsCredit, topo06_lossAttribution, topo04g_drawGate, topo10p_poolShockIsolation,
  }
  // every FIXED property that holds for any LPVaultSwap implementation (TOPO-02b is the
  // documented exception of INV-008 while a faulty LPVaultSwap leaves a seizure unsettled)
  val allFixedAnySwap = and {
    topo01_custody, topo02_supplyEqualsCredit, topo03_noCrossRouting, topo04g_drawGate,
    topo05_crossHubCap, topo06_lossAttribution, topo07_stopsNeverReachExits, topo08_migration,
    topo09_delistingNeverStrands, topo10p_poolShockIsolation, topoX1_fundingPause, topoX2_tokenCap,
  }
  val allFixed = and {
    topo01_custody, topo02_supplyEqualsCredit, topo02b_perProxy, topo03_noCrossRouting, topo04g_drawGate,
    topo05_crossHubCap, topo06_lossAttribution, topo07_stopsNeverReachExits, topo08_migration,
    topo09_delistingNeverStrands, topo10p_poolShockIsolation, topoX1_fundingPause, topoX2_tokenCap,
  }
}
