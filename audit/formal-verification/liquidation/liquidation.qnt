// FV-LIQ-08: multi-actor state machine of the liquidation area (2.11, 2.14, 2.18, 3.5, 3.9).
//
// Actors: borrowers (borrow, repay, add and withdraw collateral), committed operators (keepers) and any
// other caller of the one entry point (liquidate, Q-404), governance (add or remove keepers), a flash-loan attacker (any
// liquidation with F > 0 whose payout must stay non-negative), the market (price shocks of
// up to 50 % on one pool token, as LP value factor 50 % .. 100 %), the coverage caller and
// recipients claiming failed payouts from the payout escrow, and the guardians (address freeze, application pause). Values are USD cents; CF and LB in bps; sizing is
// Aave V4's target-health-factor rule in value terms with the all-collateral cap and the
// deficit rule (FV-LIQ-02 proves the integer version). Two debt assets (GHO, USDC) each
// have their own Coverage Spoke reserve; three accounts in two markets.
//
// Runs (randomized simulation, quint run, 10,000 traces x 25 steps each):
//   stepLive  - every price shock is followed in the same step by keepers liquidating every
//               account below HF 1 (keeper liveness);
//   stepHalt  - shocks may also happen while liquidation is halted (an Aave pause or stale
//               price, 3.5 LIQ-053), so shortfalls can build up.
// FV-LIQ-08 verifies: REQ-SWAP-003, REQ-SWAP-105, REQ-SWAP-107, REQ-SWAP-001, REQ-SWAP-006, REQ-SWAP-018, REQ-SWAP-035, REQ-SWAP-065, SPEC-FLR-001, SPEC-FLR-004, REQ-FLR-019, REQ-FLR-040, REQ-ESCROW-006, INV-041, INV-042, INV-046, INV-061
module liquidation {
  pure val CF = 3120          // bps, listing example (2.14 SPEC-FLR-004)
  pure val LB = 10500         // max bonus 5 %
  pure val MINLB = 10200      // bonus just below HF 1
  pure val THF = 11000        // target HF 1.10 (bps of 1)
  pure val OPEN_HF = 10500    // RiskModule opening floor 1.05
  pure val KEEPER_FLOOR = 1   // keeperFloor (Q-400)
  pure val MAX_KEEPERS = 32
  pure val ACCTS = Set("a1", "a2", "a3")
  pure val ASSETS = Set("GHO", "USDC")
  pure val MARKETS = Set("m1", "m2")
  pure val KEEPER_POOL = Set("k1", "k2", "k3", "k4", "k5")

  type Acct = { market: str, asset: str, units: int, debt: int }

  var accts: str -> Acct
  var price: str -> int              // cents per collateral unit, per market
  var deficit: str -> int            // recorded Hub deficit per asset (cents)
  var reserve: str -> int            // Coverage Spoke funded balance per asset (cents)
  var covered: str -> int
  var keepers: Set[str]
  var halted: bool
  var frozen: Set[str]               // MarketRegistry address freeze (Q-242)
  var paused: bool                   // application Paused (any reason); liquidation never reads it (Q-252)
  var escrowClaimable: str -> int
  var escrowCredited: str -> int
  var escrowClaimed: str -> int
  var escrowBalance: int
  var lastLiq: { ok: bool, hfBefore: int, healthyBefore: bool, equityDrop: int, bonusPaid: int, deficitWithColl: bool,
                 seizedValue: int, repaidTimesLB: int, callerFrozen: bool,
                 acctFrozen: bool, whilePaused: bool }

  pure def imin(a: int, b: int): int = if (a < b) a else b
  pure def imax(a: int, b: int): int = if (a > b) a else b
  def collValue(a: Acct): int = a.units * price.get(a.market)
  def hfBps(a: Acct): int = if (a.debt == 0) 1000000 else (collValue(a) * CF) / a.debt
  def bonusAt(h: int): int = if (h <= 9000) LB else MINLB + ((LB - MINLB) * (10000 - h)) / 1000

  action init = all {
    accts' = Map(
      "a1" -> { market: "m1", asset: "GHO", units: 100, debt: 3000 },
      "a2" -> { market: "m1", asset: "USDC", units: 60, debt: 1800 },
      "a3" -> { market: "m2", asset: "GHO", units: 80, debt: 2400 }),
    price' = Map("m1" -> 100, "m2" -> 100),
    deficit' = Map("GHO" -> 0, "USDC" -> 0),
    reserve' = Map("GHO" -> 2000, "USDC" -> 1000),
    covered' = Map("GHO" -> 0, "USDC" -> 0),
    keepers' = Set("k1", "k2", "k3", "k4"),
    halted' = false,
    frozen' = Set(),
    paused' = false,
    escrowClaimable' = ACCTS.mapBy(a => 0),
    escrowCredited' = ACCTS.mapBy(a => 0),
    escrowClaimed' = ACCTS.mapBy(a => 0),
    escrowBalance' = 0,
    lastLiq' = { ok: false, hfBefore: 0, healthyBefore: false, equityDrop: 0, bonusPaid: 0, deficitWithColl: false,
                 seizedValue: 0, repaidTimesLB: 0, callerFrozen: false, acctFrozen: false, whilePaused: false },
  }

  // Aave sizing in value terms: debt to target, capped by debt and by collateral at LB.
  def liquidated(a: Acct): (Acct, int, int) =
    val C = collValue(a)
    val h = hfBps(a)
    val lb = bonusAt(h)
    val pen = (lb * CF) / 10000
    val toTarget = (a.debt * (THF - h) + (THF - pen) - 1) / (THF - pen)
    val D0 = imin(toTarget, a.debt)
    val seize0 = (D0 * lb) / 10000
    if (seize0 >= C) {
      // all-collateral branch: D = C / LB rounded up, every unit seized
      val D1 = imin((C * 10000 + lb - 1) / lb, a.debt)
      ({ ...a, units: 0, debt: a.debt - D1 }, D1, C)
    } else {
      val unitsSeized = seize0 / price.get(a.market)
      ({ ...a, units: a.units - unitsSeized, debt: a.debt - D0 }, D0, unitsSeized * price.get(a.market))
    }

  // One liquidation through the one entry point (Q-404): any caller that is not frozen, a committed
  // operator or not, with identical economics for the account.
  action liquidate(id: str, caller: str): bool = {
    val a = accts.get(id)
    val r = liquidated(a)
    val after = r._1
    val newDeficit = if (after.units == 0 and after.debt > 0) after.debt else 0
    all {
      not(halted),
      not(frozen.contains(caller)),                     // REQ-SWAP-001, REQ-SWAP-105: no registry check; only the caller's
                                                        // freeze is checked; paused is never read
      a.debt > 0,
      hfBps(a) < 10000,                                 // REQ-SWAP-006: never a healthy account
      a.units > 0,
      accts' = accts.set(id, { ...after, debt: after.debt - newDeficit }),
      deficit' = deficit.set(a.asset, deficit.get(a.asset) + newDeficit),
      lastLiq' = { ok: true, hfBefore: hfBps(a), healthyBefore: hfBps(a) >= 10000,
                   equityDrop: (collValue(a) - a.debt) - (collValue(after) - after.debt),
                   bonusPaid: (r._2 * (bonusAt(hfBps(a)) - 10000)) / 10000 + 1,
                   deficitWithColl: newDeficit > 0 and after.units > 0,
                   seizedValue: r._3, repaidTimesLB: (r._2 * bonusAt(hfBps(a))) / 10000,
                   callerFrozen: frozen.contains(caller), acctFrozen: frozen.contains(id), whilePaused: paused },
      price' = price, reserve' = reserve, covered' = covered, keepers' = keepers, halted' = halted, frozen' = frozen, paused' = paused,
      escrowClaimable' = escrowClaimable, escrowCredited' = escrowCredited, escrowClaimed' = escrowClaimed,
      escrowBalance' = escrowBalance,
    }
  }

  action shock(m: str, factorPct: int): bool = all {
    price' = price.set(m, imax(1, (price.get(m) * factorPct) / 100)),
  }

  action borrow(id: str, amt: int): bool = {
    val a = accts.get(id)
    val a2 = { ...a, debt: a.debt + amt }
    all {
      not(halted), not(paused), not(frozen.contains(id)), amt > 0, hfBps(a2) >= OPEN_HF,
      accts' = accts.set(id, a2),
      price' = price, deficit' = deficit, reserve' = reserve, covered' = covered, keepers' = keepers, halted' = halted, frozen' = frozen, paused' = paused,
      escrowClaimable' = escrowClaimable, escrowCredited' = escrowCredited, escrowClaimed' = escrowClaimed,
      escrowBalance' = escrowBalance, lastLiq' = { ...lastLiq, ok: false },
    }
  }

  action repay(id: str, amt: int): bool = {
    val a = accts.get(id)
    all {
      amt > 0, amt <= a.debt,
      accts' = accts.set(id, { ...a, debt: a.debt - amt }),
      price' = price, deficit' = deficit, reserve' = reserve, covered' = covered, keepers' = keepers, halted' = halted, frozen' = frozen, paused' = paused,
      escrowClaimable' = escrowClaimable, escrowCredited' = escrowCredited, escrowClaimed' = escrowClaimed,
      escrowBalance' = escrowBalance, lastLiq' = { ...lastLiq, ok: false },
    }
  }

  action withdraw(id: str, u: int): bool = {
    val a = accts.get(id)
    val a2 = { ...a, units: a.units - u }
    all {
      u > 0, u <= a.units, a2.debt == 0 or (not(halted) and hfBps(a2) >= OPEN_HF),
      accts' = accts.set(id, a2),
      price' = price, deficit' = deficit, reserve' = reserve, covered' = covered, keepers' = keepers, halted' = halted, frozen' = frozen, paused' = paused,
      escrowClaimable' = escrowClaimable, escrowCredited' = escrowCredited, escrowClaimed' = escrowClaimed,
      escrowBalance' = escrowBalance, lastLiq' = { ...lastLiq, ok: false },
    }
  }

  // SPEC-FLR-001: amount = min(maxAmount, deficit, funded balance), own asset only.
  action cover(s: str, maxAmount: int): bool = {
    val amt = imin(maxAmount, imin(deficit.get(s), reserve.get(s)))
    all {
      amt > 0,
      deficit' = deficit.set(s, deficit.get(s) - amt),
      reserve' = reserve.set(s, reserve.get(s) - amt),
      covered' = covered.set(s, covered.get(s) + amt),
      accts' = accts, price' = price, keepers' = keepers, halted' = halted, frozen' = frozen, paused' = paused,
      escrowClaimable' = escrowClaimable, escrowCredited' = escrowCredited, escrowClaimed' = escrowClaimed,
      escrowBalance' = escrowBalance, lastLiq' = { ...lastLiq, ok: false },
    }
  }

  def activeKeepers: Set[str] = keepers.exclude(frozen)

  action addKeeper(k: str): bool = all {
    not(keepers.contains(k)), not(frozen.contains(k)),               // REQ-SWAP-033, REQ-SWAP-107
    keepers.size() < MAX_KEEPERS,                                     // MAX_KEEPERS (Q-400)
    keepers' = keepers.union(Set(k)),
    accts' = accts, price' = price, deficit' = deficit, reserve' = reserve, covered' = covered, halted' = halted, frozen' = frozen, paused' = paused,
    escrowClaimable' = escrowClaimable, escrowCredited' = escrowCredited, escrowClaimed' = escrowClaimed,
    escrowBalance' = escrowBalance, lastLiq' = { ...lastLiq, ok: false },
  }

  action removeKeeper(k: str): bool = all {
    keepers.contains(k), activeKeepers.exclude(Set(k)).size() >= KEEPER_FLOOR,   // REQ-SWAP-035 over active keepers
    keepers' = keepers.exclude(Set(k)),
    accts' = accts, price' = price, deficit' = deficit, reserve' = reserve, covered' = covered, halted' = halted, frozen' = frozen, paused' = paused,
    escrowClaimable' = escrowClaimable, escrowCredited' = escrowCredited, escrowClaimed' = escrowClaimed,
    escrowBalance' = escrowBalance, lastLiq' = { ...lastLiq, ok: false },
  }

  // Address freeze (REQ-SWAP-107, REQ-MREG-021): no keeper floor (Q-400); freezing the last active keeper succeeds,
  // after which new borrowing halts and liquidate stays open to every caller that is not frozen.
  action freeze(x: str): bool = all {
    not(frozen.contains(x)),
    frozen' = frozen.union(Set(x)),
    accts' = accts, price' = price, deficit' = deficit, reserve' = reserve, covered' = covered, keepers' = keepers,
    halted' = halted, paused' = paused, escrowClaimable' = escrowClaimable, escrowCredited' = escrowCredited,
    escrowClaimed' = escrowClaimed, escrowBalance' = escrowBalance, lastLiq' = { ...lastLiq, ok: false },
  }

  action unfreeze(x: str): bool = all {
    frozen.contains(x),
    frozen' = frozen.exclude(Set(x)),
    accts' = accts, price' = price, deficit' = deficit, reserve' = reserve, covered' = covered, keepers' = keepers,
    halted' = halted, paused' = paused, escrowClaimable' = escrowClaimable, escrowCredited' = escrowCredited,
    escrowClaimed' = escrowClaimed, escrowBalance' = escrowBalance, lastLiq' = { ...lastLiq, ok: false },
  }

  // Application pause by a guardian: blocks new exposure (borrow), never liquidation (REQ-SWAP-003).
  action setPaused(b: bool): bool = all {
    paused' = b,
    accts' = accts, price' = price, deficit' = deficit, reserve' = reserve, covered' = covered, keepers' = keepers,
    halted' = halted, frozen' = frozen, escrowClaimable' = escrowClaimable, escrowCredited' = escrowCredited,
    escrowClaimed' = escrowClaimed, escrowBalance' = escrowBalance, lastLiq' = { ...lastLiq, ok: false },
  }

  // A payout LPVaultSwap could not deliver (Avana's fee, the caller's payout, a route residue, the borrower
  // surplus) escrowed for its recipient, then claimed (2.18, Q-401).
  action escrowDeposit(b: str, amt: int): bool = all {
    amt > 0,
    escrowClaimable' = escrowClaimable.set(b, escrowClaimable.get(b) + amt),
    escrowCredited' = escrowCredited.set(b, escrowCredited.get(b) + amt),
    escrowBalance' = escrowBalance + amt,
    escrowClaimed' = escrowClaimed,
    accts' = accts, price' = price, deficit' = deficit, reserve' = reserve, covered' = covered, keepers' = keepers,
    halted' = halted, frozen' = frozen, paused' = paused, lastLiq' = { ...lastLiq, ok: false },
  }

  action escrowClaim(b: str): bool = all {
    escrowClaimable.get(b) > 0,
    escrowClaimed' = escrowClaimed.set(b, escrowClaimed.get(b) + escrowClaimable.get(b)),
    escrowBalance' = escrowBalance - escrowClaimable.get(b),
    escrowClaimable' = escrowClaimable.set(b, 0),
    escrowCredited' = escrowCredited,
    accts' = accts, price' = price, deficit' = deficit, reserve' = reserve, covered' = covered, keepers' = keepers,
    halted' = halted, frozen' = frozen, paused' = paused, lastLiq' = { ...lastLiq, ok: false },
  }

  action unchangedExceptPriceAndLiq = all {
    reserve' = reserve, covered' = covered, keepers' = keepers, halted' = halted, frozen' = frozen, paused' = paused,
    escrowClaimable' = escrowClaimable, escrowCredited' = escrowCredited, escrowClaimed' = escrowClaimed,
    escrowBalance' = escrowBalance, lastLiq' = { ...lastLiq, ok: false },
  }

  // Market move followed by keepers liquidating every account below HF 1 (keeper liveness).
  action shockThenLiquidate: bool = all {
    not(halted),
    nondet m = MARKETS.oneOf()
    nondet f = 50.to(100).oneOf()
    val p2 = price.set(m, imax(1, (price.get(m) * f) / 100))
    all {
      price' = p2,
      accts' = accts.keys().mapBy(id => {
        val a = accts.get(id)
        val C = a.units * p2.get(a.market)
        val h = if (a.debt == 0) 1000000 else (C * CF) / a.debt
        if (a.debt > 0 and a.units > 0 and h < 10000) {
          val lb = bonusAt(h)
          val pen = (lb * CF) / 10000
          val D0 = imin((a.debt * (THF - h) + (THF - pen) - 1) / (THF - pen), a.debt)
          val s0 = (D0 * lb) / 10000
          if (s0 >= C) { ...a, units: 0, debt: 0 }
          else { ...a, units: a.units - s0 / p2.get(a.market), debt: a.debt - D0 }
        } else a
      }),
      deficit' = ASSETS.mapBy(s => deficit.get(s) + accts.keys().fold(0, (acc, id) => {
        val a = accts.get(id)
        val C = a.units * p2.get(a.market)
        val h = if (a.debt == 0) 1000000 else (C * CF) / a.debt
        if (a.asset == s and a.debt > 0 and a.units > 0 and h < 10000) {
          val lb = bonusAt(h)
          val pen = (lb * CF) / 10000
          val D0 = imin((a.debt * (THF - h) + (THF - pen) - 1) / (THF - pen), a.debt)
          if ((D0 * lb) / 10000 >= C) acc + imax(0, a.debt - (C * 10000 + lb - 1) / lb) else acc
        } else acc
      })),
      unchangedExceptPriceAndLiq,
    }
  }

  action shockOnly: bool = all {
    nondet m = MARKETS.oneOf()
    nondet f = 50.to(100).oneOf()
    all { shock(m, f), accts' = accts, deficit' = deficit, unchangedExceptPriceAndLiq }
  }

  action setHalt(h: bool): bool = all {
    halted' = h, frozen' = frozen, paused' = paused,
    accts' = accts, price' = price, deficit' = deficit, reserve' = reserve, covered' = covered, keepers' = keepers,
    escrowClaimable' = escrowClaimable, escrowCredited' = escrowCredited, escrowClaimed' = escrowClaimed,
    escrowBalance' = escrowBalance, lastLiq' = { ...lastLiq, ok: false },
  }

  action userOrGov: bool = {
    nondet id = ACCTS.oneOf()
    nondet amt = 1.to(2000).oneOf()
    nondet u = 1.to(40).oneOf()
    nondet k = KEEPER_POOL.oneOf()
    nondet s = ASSETS.oneOf()
    nondet caller = KEEPER_POOL.union(Set("anyone")).oneOf()
    any {
      borrow(id, amt), repay(id, amt), withdraw(id, u), cover(s, amt), addKeeper(k), removeKeeper(k),
      escrowDeposit(id, amt), escrowClaim(id),
      freeze(caller), freeze(id), unfreeze(caller), unfreeze(id), setPaused(true), setPaused(false),
      liquidate(id, caller),
    }
  }

  action stepLive = any { userOrGov, shockThenLiquidate }
  action stepHalt = any { userOrGov, shockOnly, setHalt(true), setHalt(false) }

  // ------------------------------------------------------------------ invariants
  def shortfall(s: str): int =
    accts.keys().fold(0, (acc, id) => {
      val a = accts.get(id)
      if (a.asset == s) acc + imax(0, a.debt - collValue(a)) else acc
    })
  // (1) solvency per debt asset: every shortfall, realized (deficit) or latent, fits in that asset's reserve.
  val solvencyPerAsset = ASSETS.forall(s => shortfall(s) + deficit.get(s) <= reserve.get(s))
  // (2) a liquidation lowers equity by at most the bonus it paid and never seizes more than D x LB.
  val noAmplification = lastLiq.ok implies (lastLiq.equityDrop <= lastLiq.bonusPaid
                                            and lastLiq.seizedValue <= lastLiq.repaidTimesLB + 1)
  // T-33 / bug class: no liquidation of a healthy account.
  val noHealthyLiquidation = lastLiq.ok implies not(lastLiq.healthyBefore)
  // T-46: a deficit is recorded only when the account has no collateral left.
  val deficitOnlyWhenEmpty = lastLiq.ok implies not(lastLiq.deficitWithColl)
  // SPEC-FLR-001, REQ-FLR-040: coverage never exceeds what was recorded or funded, per asset.
  val coverageBounded = ASSETS.forall(s => deficit.get(s) >= 0 and reserve.get(s) >= 0 and covered.get(s) >= 0)
  // REQ-SWAP-035, REQ-SWAP-107: removal never leaves fewer than KEEPER_FLOOR approved keepers; only a guardian
  // freeze can leave 0 active keepers (Q-400).
  val keeperFloor = keepers.size() >= KEEPER_FLOOR
  // REQ-SWAP-105: a frozen caller never completes a liquidation.
  val noFrozenCaller = lastLiq.ok implies not(lastLiq.callerFrozen)
  // T-41: escrow conservation.
  val escrowConservation = and {
    ACCTS.forall(b => escrowCredited.get(b) == escrowClaimed.get(b) + escrowClaimable.get(b)),
    escrowBalance == ACCTS.fold(0, (acc, b) => acc + escrowClaimable.get(b)),
  }
  val liveInvariants = and { solvencyPerAsset, noAmplification, noHealthyLiquidation, deficitOnlyWhenEmpty,
                             coverageBounded, keeperFloor, escrowConservation, noFrozenCaller }
  val safetyInvariants = and { noAmplification, noHealthyLiquidation, deficitOnlyWhenEmpty, coverageBounded,
                               keeperFloor, escrowConservation, noFrozenCaller }
}
