// -*- mode: Bluespec; -*-
//
// Deterministic scenarios for topology.qnt (AMM-neutral design review). Each AMMN-SM-NN
// test replays the counterexample of one finding under PROPOSAL and the same steps under
// FIXED; the other tests show a property holding on its hardest path.
// Numbers: tokens 100 cents, LP unit = one unit of each leg (200 cents), CF 80 % (M1, M2)
// and 60 % (M3), bonus 5 %, opening HF 1.10. Loaded state: alice NFTs 1 (M1, 6 units),
// 3 (M2, 6), 5 (M3, 6) and debts 8 GHO on S1, 3 USDC (Stable) on S3; bob NFTs 2 (M1, 4),
// 6 (M3, 4) and debts 2 USDC on S1, 4 GHO (Volatile) on S3. Records 1..5 in that order.
module topology_tests {
  import topology.* from "./topology"

  pure val A1: Px = ("alice", "S1", 1)
  pure val A2: Px = ("alice", "S2", 1)
  pure val A3: Px = ("alice", "S3", 1)
  pure val B1: Px = ("bob", "S1", 1)
  pure val B3: Px = ("bob", "S3", 1)

  // Both loaded states are reachable and satisfy every property that has no finding.
  // QNT-TOPO-T00 verifies: INV-001, INV-002
  run loadedStatesTest = initFixedLoaded
    .expect(and { allFixed, topo04_hubDebtWithinCaps, topo10_shockIsolation })
    .then(initProposalLoaded)
    .expect(and { allFixed, topo04_hubDebtWithinCaps, topo10_shockIsolation })

  // ---------------------------------------------------------------- AMMN-SM-01
  // The home Hub's registry checks a Spoke's draw caps; the funding Hub's line and cross-Hub
  // cap are not enforced over all Spokes that draw from it.
  // QNT-TOPO-T01 verifies: AMMN-SM-01, AMMN-RT-11
  run ammnSm01CapsAboveLineTest = initProposal
    .then(govSetDrawCap("S1", "USDC", 13))             // STABLE checks S1 + S2 = 20 <= line 20
    .expect(and {
      capSum(s, "STABLE", "USDC") == 25,                // + S3's cross-Hub cap 5 > line 20
      not(topo05_crossHubCap),
    })
    .then(initProposal)
    .then(govSetCreditLine("STABLE", "USDC", 15))     // STABLE counts S1 + S2 = 15 only
    .expect(not(topo05_crossHubCap))

  // QNT-TOPO-T02 verifies: AMMN-SM-01, AMMN-RT-11
  run ammnSm01CrossCapIgnoredTest = initProposalLoaded
    .then(govSetCrossCap("STABLE", "USDC", 0))        // the funding Hub withdraws its cross-Hub line
    .then(borrow("alice", "S3", "USDC", 1))            // S3's cap was set in VOLATILE's scope and still allows it
    .expect(and {
      s.drawn.get(("STABLE", "USDC", "S3")) == 4, s.crossCap.get(("STABLE", "USDC")) == 0,
      s.g.crossCapDraw, not(topo05_crossHubCap),
    })

  // QNT-TOPO-T03 verifies: AMMN-SM-01, AMMN-RT-11, AMMN-FLOW-05
  run ammnSm01FixedTest = initFixedLoaded
    .expect(and {
      not(setDrawCapOk(s, "S1", "USDC", 13)),            // 13 + 7 + 5 > line 20
      not(setCrossCapOk(s, "STABLE", "USDC", 0)),        // S3's cap 5 is above it
      not(setCreditLineOk(s, "STABLE", "USDC", 15)),
    })
    .then(govSetDrawCap("S3", "USDC", 3))              // funding Hub lowers the foreign cap first
    .then(govSetCrossCap("STABLE", "USDC", 3))
    .expect(and { topo05_crossHubCap, not(borrowOk(s, "alice", "S3", "USDC", 1)), allFixed })

  // ---------------------------------------------------------------- AMMN-SM-02
  // drawn <= drawCap is a gate on new draws, not a state invariant: a cap cut (delisting) or
  // interest leaves drawn above the caps in every design.
  // QNT-TOPO-T04 verifies: INV-057, AMMN-SM-02
  run ammnSm02CapCutTest = initFixedLoaded
    .then(govSetDrawCap("S2", "GHO", 0))
    .then(delistDebt("S1", "GHO"))                     // MKT-045: drawCap 0 and freeze while 8 GHO is drawn
    .expect(and {
      drawnSum(s, "STABLE", "GHO") == 8, capSum(s, "STABLE", "GHO") == 0,
      not(topo04_hubDebtWithinCaps), topo04g_drawGate, allFixed,
    })

  // QNT-TOPO-T05 verifies: INV-057, AMMN-SM-02
  run ammnSm02InterestTest = initFixedLoaded
    .then(govSetDrawCap("S1", "GHO", 8))
    .then(govSetDrawCap("S2", "GHO", 0))
    .then(accrue("STABLE", "GHO"))
    .expect(and {
      s.drawn.get(("STABLE", "GHO", "S1")) == 9, capSum(s, "STABLE", "GHO") == 8,
      not(topo04_hubDebtWithinCaps), topo04g_drawGate,
      not(borrowOk(s, "alice", "S1", "GHO", 1)),
    })

  // ---------------------------------------------------------------- AMMN-SM-03
  // Pinned proxies: an Adapter upgrade may stop serving older versions, and migration is a
  // re-supply plus re-borrow that the pause, the Aave freeze and the drawCap can refuse.
  // QNT-TOPO-T06 verifies: INV-067, AMMN-SM-03
  run ammnSm03PauseBlocksExitTest = initProposalLoaded
    .then(releaseVersion)
    .then(upgradeAdapter("STABLE"))                    // STABLE's Adapter serves version 2 only
    .expect(and { topo07_stopsNeverReachExits, canRepay(s, A1, "GHO"), canWithdraw(s, 2) })
    .then(setPause("STABLE", "Paused"))
    .expect(and {
      not(canRepay(s, A1, "GHO")), canRepay(clearStops(s), A1, "GHO"),    // repay needs migration, migration needs None
      not(canWithdraw(s, 2)), canWithdraw(clearStops(s), 2),              // alice's debt-free M2 record
      not(topo07_stopsNeverReachExits),
    })

  // QNT-TOPO-T07 verifies: AMMN-SM-03
  run ammnSm03CapCutOrphansTest = initProposalLoaded
    .then(releaseVersion)
    .then(upgradeAdapter("STABLE"))
    .then(govSetDrawCap("S1", "GHO", 3))               // de-risking cut below alice's 8 GHO
    .expect(and {
      not(serves(s, A1)), not(migrateOk(clearStops(s), "alice", "S1")),  // re-borrow of 8 fails Aave's drawCap
      not(canRepay(clearStops(s), A1, "GHO")),
      not(topo08_migration),
    })

  // QNT-TOPO-T08 verifies: MKT-045, AMMN-SM-03
  run ammnSm03DelistStrandsTest = initProposalLoaded
    .then(releaseVersion)
    .then(upgradeAdapter("STABLE"))
    .then(offboard("M2"))                              // Offboarding + Aave freeze of M2's reserve
    .expect(and {
      not(hasDebt(s, A2)), not(canWithdraw(clearStops(s), 2)),             // debt-free and still stuck
      not(topo09_delistingNeverStrands), not(topo08_migration),
    })
    .then(initProposalLoaded)
    .then(releaseVersion)
    .then(upgradeAdapter("STABLE"))
    .then(delistDebt("S1", "GHO"))
    .expect(and { not(canRepay(clearStops(s), A1, "GHO")), not(topo09_delistingNeverStrands) })

  // QNT-TOPO-T09 verifies: INV-067, AMMN-SM-03
  run ammnSm03FixedTest = initFixedLoaded
    .then(releaseVersion)
    .expect(and { not(upgradeAdapterOk(s, "STABLE")), not(upgradeAdapterOk(s, "VOLATILE")) })
    .then(setPause("STABLE", "Paused"))
    .then(offboard("M2"))
    .then(govSetDrawCap("S1", "GHO", 3))
    .expect(and { canRepay(s, A1, "GHO"), canWithdraw(s, 2), allFixed })
    .then(migrate("bob", "S1"))                         // opt-in migration stays available under a pause
    .expect(and {
      s.bound.get(("bob", "S1")) == 2, credOf(s, ("bob", "S1", 2), "M1") == 4,
      s.debt.get((("bob", "S1", 2), "USDC")) == 2, not(holds(s, B1)), allFixed,
    })

  // migration itself preserves the account (PROPOSAL, no Adapter upgrade)
  // QNT-TOPO-T10 verifies: AMMN-RT-04
  run migrationPreservesTest = initProposalLoaded
    .then(releaseVersion)
    .then(migrate("alice", "S1"))
    .expect(and {
      not(holds(s, A1)), credOf(s, ("alice", "S1", 2), "M1") == 6, s.debt.get((("alice", "S1", 2), "GHO")) == 8,
      s.validPx.contains((("alice", "S1", 2), "M1")), s.recs.get(1).px == ("alice", "S1", 2),
      topo08_migration, topo02b_perProxy, topo01_custody, topo02_supplyEqualsCredit, topo03_noCrossRouting,
    })
    .then(migrate("alice", "S3"))
    .then(pledge("bob", 4))                             // bob's first S2 proxy is created at version 2
    .expect(and { s.bound.get(("bob", "S2")) == 2, topo08_migration })

  // ---------------------------------------------------------------- AMMN-SM-04
  // Standard Spoke: with receiveSharesEnabled (an Aave setting) any liquidator takes Spoke
  // shares of the vault token without a token transfer, past LPVaultSwap and the ledger.
  // QNT-TOPO-T11 verifies: AMMN-SM-04, AMMN-RT-03, AMMN-INT-07
  run ammnSm04ReceiveSharesTest = initProposalLoaded
    .then(aaveSetReceiveShares("S3"))
    .then(shockToken("M3", "ETH", 40))
    .then(liquidateExternal(B3, "GHO", 4))
    .expect(and {
      s.supplied.get((eoa("S3"), "M3")) == 3, s.supplied.get((B3, "M3")) == 1, credOf(s, B3, "M3") == 4,
      not(topo03_noCrossRouting), not(topo02b_perProxy), topo02_supplyEqualsCredit,
    })
    .then(withdraw("bob", 5))                          // reconcile moves 3 units to pending
    .expect(and {
      s.pending.get("M3") == 3, not(canSettle(s, "M3")), not(canSettle(clearStops(s), "M3")),
      topo02_supplyEqualsCredit, topo01_custody,
    })

  // QNT-TOPO-T12 verifies: AMMN-SM-04, AMMN-RT-03, AMMN-INT-07
  run ammnSm04FixedTest = initFixedLoaded
    .then(aaveSetReceiveShares("S3"))
    .then(shockToken("M3", "ETH", 40))
    .expect(and { not(liqCallerOk(s, "", "S3", "external")), liqOk(s, B3, "GHO", 4) })
    .then(liquidate("VOLATILE", B3, "GHO", 4))
    .expect(and { s.debt.get((B3, "GHO")) == 0, credOf(s, B3, "M3") == 1, topo03_noCrossRouting, topo02b_perProxy })

  // another Hub's LPVaultSwap cannot liquidate a Spoke (both designs)
  // QNT-TOPO-T13 verifies: AMMN-SM-04, AMMN-RT-03
  run crossHubLiquidationRefusedTest = initProposalLoaded
    .then(shockToken("M3", "ETH", 40))
    .expect(and { liqOk(s, B3, "GHO", 4), not(liqCallerOk(s, "STABLE", "S3", "honest")) })
    .then(liquidate("VOLATILE", B3, "GHO", 4))
    .expect(and { topo03_noCrossRouting, topo02b_perProxy, topo01_custody, topo02_supplyEqualsCredit })

  // ---------------------------------------------------------------- AMMN-SM-05
  // A token price shock in one market moves every Spoke whose market or debt uses the token;
  // per-Hub token caps miss collateral of other Hubs' Spokes that draw from the Hub.
  // QNT-TOPO-T14 verifies: INV-075, AMMN-SM-05
  run ammnSm05TokenShockTest = initFixedLoaded
    .then(shockToken("M1", "USDC", 70))
    .expect(and {
      s.g.crossShock, not(topo10_shockIsolation),
      collW(s, A3) == 6 * 170 * 60, debtW(s, A3) == 3 * 70 * 100,          // S3 collateral and debt both moved
      collW(s, A2) == 6 * 170 * 80,
    })

  // QNT-TOPO-T15 verifies: INV-075
  run poolShockIsolatedTest = initFixedLoaded
    .then(poolShock("M1"))                             // M1's feed goes stale: only S1 accounts change
    .expect(and { collW(s, A1) == 0, collW(s, A3) == 6 * 200 * 60, topo10p_poolShockIsolation })
    .then(initProposalLoaded)
    .then(poolShock("M3"))
    .expect(topo10p_poolShockIsolation)

  // QNT-TOPO-T16 verifies: AMMN-SM-05, AMMN-RT-05
  run ammnSm05TokenCapTest = initProposalLoaded
    .then(pledge("bob", 4))                            // STABLE's ParameterStore sees S1 + S2 only
    .expect(and {
      homeExposure(s, "STABLE", "USDC") == 20, exposure(s, "STABLE", "USDC") == 30,
      s.tokenCap.get(("STABLE", "USDC")) == 26, not(topoX2_tokenCap),
    })
    .then(initFixedLoaded)
    .expect(not(pledgeOk(s, "bob", 4)))

  // ---------------------------------------------------------------- AMMN-SM-06
  // A funding Hub's pause does not stop other Hubs' Spokes drawing its liquidity.
  // QNT-TOPO-T17 verifies: AMMN-SM-06, AMMN-FLOW-19
  run ammnSm06FundingPauseTest = initProposalLoaded
    .then(setPause("STABLE", "Paused"))
    .then(borrow("alice", "S3", "USDC", 1))
    .expect(and { s.g.pauseBypass, not(topoX1_fundingPause) })
    .then(initFixedLoaded)
    .then(setPause("STABLE", "Paused"))
    .expect(and {
      not(borrowOk(s, "alice", "S3", "USDC", 1)),
      borrowOk(s, "alice", "S3", "GHO", 1),          // VOLATILE's own GHO stays open
      canRepay(s, A3, "USDC"),
    })

  // ---------------------------------------------------------------- holding paths
  // A Volatile-home Spoke's USDC deficit lands on the Stable Hub (the Hub it draws from) and
  // only the Stable USDC Coverage Spoke can cover it.
  // QNT-TOPO-T18 verifies: INV-041, INV-042
  run deficitAttributionTest = initFixedLoaded
    .then(borrow("alice", "S3", "USDC", 2))
    .then(shockToken("M3", "ETH", 1))
    .then(accrue("STABLE", "USDC"))
    .then(liquidate("VOLATILE", A3, "USDC", 6))
    .expect(and {
      s.supplied.get((A3, "M3")) == 0, s.debt.get((A3, "USDC")) == 0,
      s.deficit.get(("STABLE", "USDC", "S3")) == 1, deficitSum(s, "VOLATILE", "USDC") == 0,
      not(coverOk(s, "VOLATILE", "USDC", "S3", 1)), not(coverOk(s, "STABLE", "GHO", "S3", 1)),
      topo06_lossAttribution, topo01_custody, topo02_supplyEqualsCredit,
    })
    .then(cover("STABLE", "USDC", "S3", 1))
    .expect(and { deficitSum(s, "STABLE", "USDC") == 0, s.coverage.get(("STABLE", "USDC")) == 4, topo06_lossAttribution })

  // A faulty LPVaultSwap that keeps seized tokens: supply == Σ credited + pending throughout;
  // reconcile on exit and settlePending close the gap (INV-001, INV-058).
  // QNT-TOPO-T19 verifies: INV-001, INV-058
  run faultySwapPendingTest = initFixedLoaded
    .then(shockToken("M1", "USDT", 40))
    .then(liquidateFaulty("STABLE", A1, "GHO", 4))
    .expect(and { s.swapHeld.get("M1") == 3, topo02_supplyEqualsCredit, not(topo02b_perProxy) })
    .then(repay(A1, "GHO", 4))
    .then(setPause("STABLE", "Paused"))
    .then(withdraw("alice", 1))
    .expect(and { s.pending.get("M1") == 3, canSettle(s, "M1"), topo02_supplyEqualsCredit, topo01_custody })
    .then(settlePending("STABLE", "M1"))
    .expect(and { s.pending.get("M1") == 0, s.supply.get("M1") == 4, topo02_supplyEqualsCredit, topo02b_perProxy, allFixed })
}
