// -*- mode: Bluespec; -*-
//
// Deterministic scenarios for avana.qnt. Each test is a QNT-T… check. Tests
// that end in `not(qnt…)` show a superseded design variant failing a property,
// or the stated scope of a property (README "Results").
// Numbers: price 2 GHO/unit, CF 80 %, bonus 5 %, opening HF 1.10, floor 1.05.
// GHO balances, fees, top-ups and payouts are in GHO cents.
module avana_tests {
  import avana.* from "./avana"

  pure val PA = "P_alice_S1"
  pure val PB = "P_bob_S1"

  // alice: NFT 42 (1000 units) and NFT 7 (800 units) in mA, borrows 1500 + 1000 GHO.
  run aliceTwoRecords = init
    .then(pledge("alice", 42, "mA"))
    .then(pledge("alice", 7, "mA"))
    .then(borrow("alice", "S1", "GHO", 1500, 0))
    .then(borrow("alice", "S1", "GHO", 1000, 1))

  // alice: NFT 42 (mA) and NFT 9 (mB) on Borrow Spoke S1, borrows 1500 + 500 GHO.
  run aliceTwoMarkets = init
    .then(pledge("alice", 42, "mA"))
    .then(pledge("alice", 9, "mB"))
    .then(borrow("alice", "S1", "GHO", 1500, 0))
    .then(borrow("alice", "S1", "GHO", 500, 1))

  pure val DISABLE_MA: OpT = { calls: Set("disableRoute"), tgt: "mA", arg: 0 }
  pure val REMOVE_K1: OpT = { calls: Set("removeKeeper"), tgt: "k1", arg: 0 }
  pure val ADD_K4: OpT = { calls: Set("addKeeper"), tgt: "k4", arg: 0 }
  pure val UPG_ADAPTER: OpT = { calls: Set("upgradeAdapter"), tgt: "ADAPTER", arg: 0 }
  pure val SHORT_UPG: OpT = { calls: Set("setShortDelaySelector"), tgt: "upgradeAdapter", arg: 1 }
  pure val DELAY3: OpT = { calls: Set("setNormalDelay"), tgt: "", arg: 3 }
  pure val DELAY4: OpT = { calls: Set("setNormalDelay"), tgt: "", arg: 4 }
  pure val GRANT_EVE: OpT = { calls: Set("grantAdmin"), tgt: "eve", arg: 0 }
  pure val RESTORE_MA: OpT = { calls: Set("restoreRoute"), tgt: "mA", arg: 0 }
  pure val MIXED_MA: OpT = { calls: Set("restoreRoute", "loosenOpenHf"), tgt: "mA", arg: 0 }
  pure val TIGHTEN: OpT = { calls: Set("tightenOpenHf"), tgt: "", arg: 0 }
  pure val UNFREEZE_EVE: OpT = { calls: Set("unfreezeAddress"), tgt: "eve", arg: 0 }

  // QNT-T01 verifies: Q-067, Q-224, Q-225, Q-258
  // NFT #42 backs one record in one account; it cannot be pledged again, by anyone, into
  // any market; the (alice, S1) proxy is bound to alice and registered in mA's vault token.
  run nft42SingleRegistrationTest = init
    .then(pledge("alice", 42, "mA"))
    .expect(and {
      s.recs.get(1).credited == 1000, s.recs.get(1).proxy == PA,
      s.bal.get(("mA", "HUB")) == 1000, s.supplied.get((PA, "mA")) == 1000,
      s.proxyWallet.get(PA) == "alice", s.validProxy == Set(("mA", PA)),
      not(pledgeOk(s, "alice", 42, "mA")), not(pledgeOk(s, "bob", 42, "mA")),
      not(pledgeOk(s, "eve", 42, "mA")), not(pledgeOk(s, "alice", 42, "mC")),
      not(pledgeOk(s, "bob", 8, "mC")),                        // pool mismatch
      honestInvariants,
    })

  // QNT-T02 verifies: Q-106, Q-212, Q-223, Q-229
  // The Adapter resolves the proxy from msg.sender: a replayed nonce, the attacker and the
  // Adapter itself cannot borrow on alice's account; any payer may repay but not withdraw.
  run borrowNonceAndCallerTest = init
    .then(pledge("alice", 42, "mA"))
    .then(borrow("alice", "S1", "GHO", 500, 0))
    .expect(and {
      not(borrowOk(s, "alice", "S1", "GHO", 500, 0)),          // replayed nonce
      borrowOk(s, "alice", "S1", "GHO", 500, 1),
      not(borrowOk(s, "eve", "S1", "GHO", 500, 1)),            // eve's own (empty) account only
      not(borrowOk(s, "ADAPTER", "S1", "GHO", 500, 1)),
      repayOk(s, "eve", PA, "GHO", 100, true),                 // any payer may repay (Q-212)
      not(withdrawOk(s, "eve", 1)),
      honestInvariants,
    })

  // QNT-T03 verifies: Q-051, Q-153, Q-227, Q-241, Q-242, Q-260
  // Partial repay of any size works under Paused(MintPathSuspect), a tripped breaker, a
  // frozen borrower, a Cached price and a hostile RiskModule.
  run repayAlwaysOpenTest = init
    .then(pledge("alice", 42, "mA"))
    .then(borrow("alice", "S1", "GHO", 1000, 0))
    .then(pauseApp("EG", "MintPathSuspect"))
    .then(tripMarket("FK", "mA"))
    .then(freezeAddress("EG", "alice"))
    .then(feedFail("mA"))
    .then(upgradeRiskHostile)
    .then(repay("alice", PA, "GHO", 300))
    .expect(and {
      s.debt.get((PA, "GHO")) == 700,
      repayOk(s, "alice", PA, "GHO", 1, true), repayOk(s, "alice", PA, "GHO", BIG, true),
      qnt14_repayAlwaysOpen, qnt17_partialRepayOpen,
    })

  // QNT-T04 verifies: Q-081, Q-203, Q-223, Q-229
  // Drifting blocks borrowing under the reviewed RiskModule. A hostile RiskModule lets it
  // through, and also a borrow against an Aave-frozen reserve (outside QNT-19's scope);
  // Aave's HF >= 1 still binds it.
  run hostilePolicyBorrowTest = init
    .then(pledge("alice", 42, "mA"))
    .then(pledge("alice", 9, "mB"))
    .then(drift("mA"))
    .expect(not(borrowOk(s, "alice", "S1", "GHO", 500, 0)))
    .then(upgradeRiskHostile)
    .then(borrow("alice", "S1", "GHO", 500, 0))
    .expect(and { not(qnt38_policyGates), qnt13_hostileBounded })
    .then(aaveFreezeVault("mB"))
    .then(borrow("alice", "S1", "GHO", 500, 1))
    .expect(and {
      not(qnt19_noBorrowWhenFrozen), qnt13_hostileBounded,
      borrowOk(s, "alice", "S1", "GHO", 1500, 2),              // HF 1.024: only Aave binds
    })
    .then(borrow("alice", "S1", "GHO", 1500, 2))
    .expect(and { not(borrowOk(s, "alice", "S1", "GHO", 300, 3)), qnt13_hostileBounded })

  // QNT-T05 verifies: Q-060, Q-061, Q-160, Q-194, Q-224, Q-256
  // Keeper liquidation: 315 units seized, debited from the larger record (42), NFT
  // liquidity reduced by exactly that, fees kept; fee 3 GHO, keeper +12 GHO.
  run keeperLiquidationTest = aliceTwoRecords
    .then(accrueFees(42))
    .then(priceMove("mA", 1))
    .then(liquidate("k1", PA, "mA", "GHO", q0(300)))
    .expect(and {
      s.recs.get(1).credited == 685, s.recs.get(2).credited == 800,
      s.nfts.get(42).liquidity == 685, s.nfts.get(42).fees == 10,
      s.supplied.get((PA, "mA")) == 1485, s.debt.get((PA, "GHO")) == 2200,
      s.feeRecipient == 300, gho(s, "k1") == 301200,
      honestInvariants,
    })

  // QNT-T06 verifies: Q-116, Q-144, Q-222
  // The liquidation-manager Spoke accepts liquidationCall only from LPVaultSwap.
  run directLiquidationBlockedTest = aliceTwoRecords
    .then(priceMove("mA", 1))
    .expect(and {
      liquidatable(s, PA),
      not(directLiqOk(s, "eve", PA, "mA", "GHO", 300)),
      not(directLiqOk(s, "k1", PA, "mA", "GHO", 300)),
      not(directLiqOk(s, ROGUE, PA, "mA", "GHO", 300)),
      not(directLiqOk(s, "ADAPTER", PA, "mA", "GHO", 300)),
      directLiqOk(s, "LPVAULTSWAP", PA, "mA", "GHO", 300),
    })

  // QNT-T07 verifies: Q-127, Q-144, Q-167, Q-222
  // At price 2 with debt 2900 a 1-GHO liquidation seizes 0 units: no third party can make
  // even that call, and LPVaultSwap refuses it (NothingSeized).
  run zeroSeizeSetup = aliceTwoRecords
    .then(accrueInterest(PA, "GHO")).then(accrueInterest(PA, "GHO"))
    .then(accrueInterest(PA, "GHO")).then(accrueInterest(PA, "GHO"))
    .then(accrueInterest(PA, "GHO")).then(accrueInterest(PA, "GHO"))
    .then(accrueInterest(PA, "GHO")).then(accrueInterest(PA, "GHO"))

  run zeroSeizeThirdPartyTest = zeroSeizeSetup
    .expect(and {
      aaveLiq(s, PA, "mA", "GHO", 1).seized == 0,
      not(directLiqOk(s, "eve", PA, "mA", "GHO", 1)), qnt09_onlySwapSeizes,
    })

  run zeroSeizeRejectedTest = zeroSeizeSetup
    .expect(and {
      liquidatable(s, PA),
      not(swapLiqOk(s, "k1", PA, "mA", "GHO", q0(1))),
      swapLiqOk(s, "k1", PA, "mA", "GHO", q0(BIG)),
    })

  // QNT-T25 verifies: Q-198, Q-250, Q-267, Q-397
  // A dust liquidation (1 GHO, 1 unit, 2 % slippage on each leg) recovers 0.98 GHO: each
  // leg meets its oracle minimum, the floor's rounding allowance lets it settle and the
  // keeper pays the 2-cent settlement gap through its top-up (no budget, Q-397).
  run dustLiquidationSettlesTest = aliceTwoRecords
    .then(priceMove("mA", 1))
    .then(liquidate("k1", PA, "mA", "GHO", { ...q0(1), s0: 2, s1: 2 }))
    .expect(and { s.g.shortfallPaid == 2, s.debt.get((PA, "GHO")) == 2499, honestInvariants })

  // QNT-T08 verifies: Q-223, Q-224, Q-226
  // A hostile Adapter stays inside its blast radius: it borrows against alice's proxy up to
  // Aave's HF, releases her NFT (which goes to alice, not to the named address), leaving
  // unbacked vault tokens, and registers a rogue proxy that still cannot liquidate.
  run hostileAdapterTest = aliceTwoRecords
    .then(upgradeAdapterHostile)
    .then(haBorrowFor(PA, "GHO", 300))
    .then(haReleaseNft(1, "eve"))
    .then(haRegister("mA", ROGUE))
    .expect(and {
      s.nfts.get(42).owner == "alice", s.debt.get((PA, "GHO")) == 2800,
      qnt13_hostileBounded, qnt35_nftOwnership, not(qnt03_supplyEqualsBacking),
      not(directLiqOk(s, ROGUE, PA, "mA", "GHO", 300)), adapterInvariants,
    })

  // QNT-T09 verifies: Q-201, Q-224, Q-257, Q-260
  // A hostile LPVaultSwap seizes 315 units and never settles. On alice's next withdrawal
  // Collateralization reconciles: 315 units are debited from NFT 42 (largest record), that
  // liquidity moves to the pending balance, and both NFTs come back. A reviewed LPVaultSwap
  // later burns the 315 units against it.
  run reconcileOnExitTest = aliceTwoRecords
    .then(priceMove("mA", 1))
    .then(upgradeSwapHostile)
    .then(hostileSwapKeep(PA, "mA", "GHO", 300))
    .expect(and {
      s.bal.get(("mA", "LPVAULTSWAP")) == 315, s.supplied.get((PA, "mA")) == 1485,
      qnt03_supplyEqualsBacking, qnt07_perProxyLedger,
    })
    .then(repay("alice", PA, "GHO", BIG))
    .then(withdraw("alice", 1))
    .expect(and {
      s.nfts.get(42).owner == "alice", s.nfts.get(42).liquidity == 685, s.pending.get("mA") == 315,
      s.supplied.get((PA, "mA")) == 800, s.recs.get(2).credited == 800,
      withdrawOk(s, "alice", 2), qnt15_debtFreeWithdrawOpen, qnt07_perProxyLedger,
      qnt03_supplyEqualsBacking, qnt37_pendingBacksTokens, qnt48_backingGap,
    })
    .then(withdraw("alice", 2))
    .then(restoreSwapHonest)
    .then(settlePending("mA"))
    .expect(and {
      s.nfts.get(7).owner == "alice", s.nfts.get(7).liquidity == 800,
      s.pending.get("mA") == 0, supplyOf(s, "mA") == 0, s.reserve.get("GHO") == 815, honestInvariants,
    })

  // QNT-T26 verifies: Q-201, INV-058
  // Reconciliation also runs on the next reviewed settlement of that account.
  run reconcileOnSettlementTest = aliceTwoRecords
    .then(priceMove("mA", 1))
    .then(upgradeSwapHostile)
    .then(hostileSwapKeep(PA, "mA", "GHO", 300))
    .then(restoreSwapHonest)
    .then(liquidate("k1", PA, "mA", "GHO", q0(300)))
    .expect(and {
      s.supplied.get((PA, "mA")) == 1170, creditedOf(s, PA, "mA") == 1170,
      s.pending.get("mA") == 315, qnt07_perProxyLedger, qnt03_supplyEqualsBacking,
    })

  // QNT-T24 verifies: Q-128, Q-227, Q-247
  // Scope of QNT-22: the reviewed LPVaultSwap seizes the fresh market mA while mB is
  // Expired, and never mB. A hostile implementation can seize the Expired mB, which Aave
  // values at the minimum price, in full for one unit of debt (finding QNT-F1).
  run hostileSwapStaleTest = aliceTwoMarkets
    .then(priceMove("mA", 1))
    .then(feedFail("mB"))
    .then(tick).then(tick)
    .expect(and {
      ps(s, "mB") == Expired,
      swapLiqOk(s, "k1", PA, "mA", "GHO", q0(BIG)),
      LIQ_AMTS.forall(d => not(swapLiqOk(s, "k1", PA, "mB", "GHO", q0(d)))),
    })
    .then(upgradeSwapHostile)
    .then(hostileSwapKeep(PA, "mB", "GHO", BIG))
    .expect(and {
      s.supplied.get((PA, "mB")) == 0, s.debt.get((PA, "GHO")) == 1999,
      s.bal.get(("mB", "LPVAULTSWAP")) == 600, not(qnt22_noLiquidationOnStale), qnt23_noHealthySeizure,
    })

  // QNT-T10 verifies: Q-160, Q-224
  // Collateralization refuses to debit another proxy than the one seized, and refuses a
  // settlement whose vault tokens were not burned.
  run hostileSwapWrongRecordTest = aliceTwoRecords
    .then(pledge("bob", 8, "mA"))
    .then(priceMove("mA", 1))
    .then(upgradeSwapHostile)
    .expect(and {
      hostileSeizeOk(s, PA, "mA", "GHO", 300),
      not(hostileReleaseOk(s, PA, PB, "mA", "GHO", 300, true)),
      not(hostileReleaseOk(s, PA, PA, "mA", "GHO", 300, false)),
      hostileReleaseOk(s, PA, PA, "mA", "GHO", 300, true),
    })

  // QNT-T11 verifies: Q-160
  // With a LEDGER-style check (Σ credited == supply) one hostile seize-and-keep makes every
  // later reviewed liquidation of that account revert; the snapshot check does not.
  run ledgerCheckBricksTest = initLedger
    .then(pledge("alice", 42, "mA")).then(pledge("alice", 7, "mA"))
    .then(borrow("alice", "S1", "GHO", 1500, 0)).then(borrow("alice", "S1", "GHO", 1000, 1))
    .then(priceMove("mA", 1))
    .then(upgradeSwapHostile)
    .then(hostileSwapKeep(PA, "mA", "GHO", 300))
    .then(restoreSwapHonest)
    .expect(and {
      liquidatable(s, PA),
      LIQ_AMTS.forall(d => not(swapLiqOk(s, "k1", PA, "mA", "GHO", q0(d)))),
      not(qnt36_liquidationLive),
    })

  run deltaCheckSurvivesTest = aliceTwoRecords
    .then(priceMove("mA", 1))
    .then(upgradeSwapHostile)
    .then(hostileSwapKeep(PA, "mA", "GHO", 300))
    .then(restoreSwapHonest)
    .then(liquidate("k1", PA, "mA", "GHO", q0(300)))
    .expect(and { s.supplied.get((PA, "mA")) == 1170, s.recs.get(1).credited == 685, s.recs.get(2).credited == 485,
                  s.pending.get("mA") == 315, qnt36_liquidationLive })

  // QNT-T12 verifies: Q-088, Q-129, Q-154
  // Outage reaches Expired with no read in between, then recovers at a lower price;
  // HF 0.977 (not below the 0.90 grace bound).
  run graceTail = pledge("alice", 42, "mA").then(pledge("alice", 9, "mB"))
    .then(borrow("alice", "S1", "GHO", 1500, 0))
    .then(accrueInterest(PA, "GHO")).then(accrueInterest(PA, "GHO"))
    .then(accrueInterest(PA, "GHO")).then(accrueInterest(PA, "GHO"))
    .then(accrueInterest(PA, "GHO")).then(accrueInterest(PA, "GHO"))
    .then(feedFail("mA"))
    .then(tick).then(tick)
    .then(recover("mA", 1))

  run graceTimestampLatchTest = init.then(graceTail)
    .expect(and {
      s.debt.get((PA, "GHO")) == 1800, liquidatable(s, PA), s.recoveredAt.get("mA") == 2,
      not(swapLiqOk(s, "k1", PA, "mA", "GHO", q0(BIG))),
    })
    .then(tick).then(tick).then(tick)
    .then(liquidate("k1", PA, "mA", "GHO", q0(BIG)))
    .expect(qnt24_graceRespected)

  run graceReadLatchMissTest = initReadLatch.then(graceTail)
    .then(liquidate("k1", PA, "mA", "GHO", q0(BIG)))
    .expect(not(qnt24_graceRespected))

  // QNT-T13 verifies: Q-202, Q-227, Q-241, Q-242
  // No Avana stop reaches liquidation: Paused(MintPathSuspect), a tripped breaker and a
  // frozen borrower leave it open. An Aave-side pauseReserve has no Avana expiry and no
  // Avana action lifts it; it lasts until the DAO unpauses (accepted, C-QNT-2).
  run pauseNeverStopsLiquidationTest = aliceTwoRecords
    .then(priceMove("mA", 1))
    .then(pauseApp("EG", "MintPathSuspect"))
    .then(tripMarket("FK", "mA"))
    .then(tripDebt("FK", "S1", "GHO"))
    .then(freezeAddress("EG", "alice"))
    .expect(and { swapLiqOk(s, "k1", PA, "mA", "GHO", q0(BIG)), qnt32_avanaHaltBounded, qnt36_liquidationLive })

  run aavePauseTest = aliceTwoRecords
    .then(priceMove("mA", 1))
    .then(aavePauseVault("mA"))
    .then(tick).then(tick).then(tick).then(tick)
    .expect(and { s.vaultPaused.contains("mA"), not(liftOk(s, "EG", "Paused")), not(swapLiqOk(s, "k1", PA, "mA", "GHO", q0(BIG))) })
    .then(daoUnpauseAll)
    .expect(swapLiqOk(s, "k1", PA, "mA", "GHO", q0(BIG)))

  // QNT-T14 verifies: Q-104, Q-134, Q-258
  run strayRescueTest = init
    .then(strayTransfer("eve", 66))
    .then(pledge("alice", 42, "mA"))
    .expect(and { rescueOk(s, 66), not(rescueOk(s, 42)), not(pledgeOk(s, "eve", 66, "mA")) })
    .then(govRescue(66))
    .expect(and { s.nfts.get(66).owner == "eve", qnt12_rescueOnlyUncredited })

  // QNT-T15 verifies: Q-098, Q-101, Q-134, Q-236
  // Sequential liquidation of a two-market account until Aave records the deficit; the
  // GHO Coverage Spoke covers it; the zero-credit record is released to alice only.
  run sequentialLiquidationTest = aliceTwoMarkets
    .then(priceMove("mA", 1)).then(priceMove("mB", 1))
    .then(liquidate("k1", PA, "mA", "GHO", q0(BIG)))
    .expect(and { s.debt.get((PA, "GHO")) == 1047, s.deficit.get("GHO") == 0, s.recs.get(1).credited == 0 })
    .then(liquidate("k1", PA, "mB", "GHO", q0(BIG)))
    .expect(and { s.debt.get((PA, "GHO")) == 0, s.deficit.get("GHO") == 475, s.g.deficitReporters == Set("LPVAULTSWAP") })
    .then(coverDeficit("GHO", BIG))
    .expect(and {
      s.deficit.get("GHO") == 0, s.reserve.get("GHO") == 25, s.reserve.get("USDT") == 500, qnt30_deficitCoverage,
      withdrawZeroOk(s, "alice", 1), not(withdrawZeroOk(s, "eve", 1)), not(rescueOk(s, 42)),
      honestInvariants,
    })

  // QNT-T16 verifies: Q-067
  // Donated liquidity stays with the NFT and is not credited unless the depositor re-credits.
  run donationTest = init
    .then(pledge("alice", 42, "mA"))
    .then(donate("eve", 42, 100))
    .then(withdraw("alice", 1))
    .expect(and { s.nfts.get(42).owner == "alice", s.nfts.get(42).liquidity == 1100, qnt03_supplyEqualsBacking })

  // QNT-T17 verifies: Q-061
  // Without the principal cap the liquidation collect takes the depositor's fees.
  run uncappedCollectTest = initUncapped
    .then(pledge("alice", 42, "mA")).then(pledge("alice", 7, "mA"))
    .then(borrow("alice", "S1", "GHO", 1500, 0)).then(borrow("alice", "S1", "GHO", 1000, 1))
    .then(accrueFees(42))
    .then(priceMove("mA", 1))
    .then(liquidate("k1", PA, "mA", "GHO", q0(300)))
    .expect(not(qnt11_feesToDepositor))

  // QNT-T18 verifies: Q-162, Q-199, Q-208, Q-247
  // Disagreeing routes stop seizure of the market from the first stored observation; after
  // disagreementPauseMax it stays blocked as Expired until the routes agree; Aave values
  // the market at the lower route meanwhile.
  run disagreementPauseTest = init
    .then(pledge("alice", 42, "mA"))
    .then(borrow("alice", "S1", "GHO", 1000, 0))
    .then(priceMove("mA", 1))
    .then(disagree("mA"))
    .then(poke("mA"))
    .expect(and { s.disagreeSeen.get("mA") == 0, aavePx(s, "mA") <= s.price.get("mA"),
                  not(swapLiqOk(s, "k1", PA, "mA", "GHO", q0(BIG))),
                  not(borrowOk(s, "alice", "S1", "GHO", 500, 1)), repayOk(s, "alice", PA, "GHO", 1, true) })
    .then(tick).then(tick)
    .expect(and { disagreeExpiredForLiq(s, "mA"), not(swapLiqOk(s, "k1", PA, "mA", "GHO", q0(BIG))) })
    .then(undrift("mA"))
    .then(liquidate("k1", PA, "mA", "GHO", q0(BIG)))
    .expect(and { s.deficit.get("GHO") == 47, honestInvariants })

  // QNT-T19 verifies: Q-161, Q-229, Q-398
  // Withdraw-with-debt needs HF >= 1.00 (no opening floor; the optional hard floor is off);
  // a hostile RiskModule is held only by Aave's HF >= 1.
  run withdrawFloorTest = init
    .then(pledge("alice", 42, "mA")).then(pledge("alice", 9, "mB"))
    .then(borrow("alice", "S1", "GHO", 1500, 0))
    .expect(withdrawOk(s, "alice", 2))                         // HF after 1.067 >= 1.00
    .then(upgradeRiskHostile)
    .expect(withdrawOk(s, "alice", 2))
    .then(accrueInterest(PA, "GHO")).then(accrueInterest(PA, "GHO"))
    .expect(withdrawOk(s, "alice", 2))                         // HF after exactly 1.00
    .then(accrueInterest(PA, "GHO"))
    .expect(not(withdrawOk(s, "alice", 2)))

  // QNT-T20 verifies: Q-193, Q-194, Q-225, Q-234
  // Avana sets no cap on markets or records per account; a pledge on another Borrow Spoke
  // creates a second proxy for the same wallet.
  run noAvanaAccountCapsTest = init
    .then(pledge("alice", 42, "mA")).then(pledge("alice", 7, "mA"))
    .then(pledge("alice", 9, "mB")).then(pledge("alice", 21, "mC"))
    .expect(and {
      acctMarkets(s, PA) == Set("mA", "mB"), recsOf(s, PA, "mA").size() == 2,
      acctMarkets(s, "P_alice_S2") == Set("mC"), s.proxyWallet.get("P_alice_S2") == "alice", honestInvariants,
    })

  // QNT-T21 verifies: Q-118, Q-140
  // Hub halts the Spoke: only fee collection continues.
  run hubHaltTest = init
    .then(pledge("alice", 42, "mA"))
    .then(borrow("alice", "S1", "GHO", 1000, 0))
    .then(daoHalt("S1", true))
    .expect(and {
      not(repayOk(s, "alice", PA, "GHO", BIG, true)), not(withdrawOk(s, "alice", 1)),
      not(pledgeOk(s, "alice", 7, "mA")), not(borrowOk(s, "alice", "S1", "GHO", 100, 1)),
      collectOk(s, "alice", 1), qnt14_repayAlwaysOpen, qnt15_debtFreeWithdrawOpen,
    })

  // QNT-T22 verifies: Q-132, Q-227
  // A new account needs Live; a top-up may go into Drifting, not Cached; Frozen admits a
  // top-up of an indebted account and refuses a new account.
  run topUpRulesTest = init
    .then(drift("mA"))
    .expect(not(pledgeOk(s, "alice", 42, "mA")))
    .then(undrift("mA"))
    .then(pledge("alice", 42, "mA"))
    .then(borrow("alice", "S1", "GHO", 1000, 0))
    .then(drift("mA"))
    .then(freezeApp("FK"))
    .expect(and { pledgeOk(s, "alice", 7, "mA"), not(pledgeOk(s, "bob", 8, "mA")) })
    .then(feedFail("mA"))
    .expect(not(pledgeOk(s, "alice", 7, "mA")))
    .then(recover("mA", 2))
    .then(pauseApp("EG", "General"))
    .expect(not(pledgeOk(s, "alice", 7, "mA")))               // HF 1.6: not a rescue top-up

  // QNT-T23 verifies: Q-139, Q-228, Q-242, Q-263, Q-400
  // keeperFloor 1: removal may go down to one active keeper and stops there; an address freeze
  // checks no floor (Q-400), so freezing the last active keeper succeeds and halts new borrowing;
  // adding a keeper waits the normal delay and only the DAO can cancel it.
  run keeperFloorTest = init
    .then(schedule("MULTISIG", REMOVE_K1, true))
    .then(tick)
    .expect(executeOk(s, 1))
    .then(execute(1))
    .then(freezeAddress("EG", "k2"))
    .expect(and { activeKeepers(s) == Set("kS"), freezeTargetOk(s, "kS"), qnt34_keeperFloor })
    .then(freezeAddress("EG", "kS"))
    .expect(and { activeKeepers(s) == Set(), MARKETS.forall(m => liqHaltedMkt(s, m)), qnt34_keeperFloor })
    .then(schedule("MULTISIG", ADD_K4, false))
    .expect(and { not(cancelOk(s, "EG", 2)), not(cancelOk(s, "MULTISIG", 2)), cancelOk(s, "AAVE_EXEC", 2), not(executeOk(s, 2)) })
    .then(waitDelay)
    .then(execute(2))
    .expect(and { activeKeepers(s) == Set("k4"), qnt34_keeperFloor })

  // QNT-T27 verifies: Q-189, Q-206, Q-227, Q-229
  // Withdraw-with-debt is blocked while liquidation of a market the account holds is halted
  // (both route records disabled) and while Hub shares != assets, which also
  // stops liquidation of that market; repay stays open.
  run haltBlocksRiskyExitsTest = init
    .then(pledge("alice", 42, "mA")).then(pledge("alice", 9, "mB"))
    .then(borrow("alice", "S1", "GHO", 500, 0))
    .expect(withdrawOk(s, "alice", 2))
    .then(schedule("MULTISIG", DISABLE_MA, true)).then(tick).then(execute(1))
    .expect(and { liqHaltedMkt(s, "mA"), not(withdrawOk(s, "alice", 2)), repayOk(s, "alice", PA, "GHO", BIG, true) })
    .then(schedule("MULTISIG", RESTORE_MA, true)).then(tick).then(execute(2))
    .expect(withdrawOk(s, "alice", 2))
    .then(sharesFlag("mA", true))
    .expect(and {
      not(withdrawOk(s, "alice", 2)),
      not(liqGate(s, "k1", PA, "mA", "GHO")), liqGate(s, "k1", PA, "mB", "GHO"),
      repayOk(s, "alice", PA, "GHO", BIG, true),
    })

  // QNT-T28 verifies: Q-180, Q-212, Q-269
  // bob repays alice's whole debt first; alice's later repay-all spends 0.
  run repayRaceTest = init
    .then(pledge("alice", 42, "mA"))
    .then(borrow("alice", "S1", "GHO", 1000, 0))
    .then(repayAll("bob", PA, "GHO", BIG))
    .expect(and { s.debt.get((PA, "GHO")) == 0, gho(s, "bob") == 200000 })
    .then(repayAll("alice", PA, "GHO", BIG))
    .expect(and { gho(s, "alice") == 400000, s.debt.get((PA, "GHO")) == 0,
                  not(withdrawOk(s, "bob", 1)), withdrawOk(s, "alice", 1), qnt39_repayNeverOverspends })

  // QNT-T29 verifies: Q-213, Q-216, Q-242, Q-404
  // Any address that is not frozen, registered as a committed operator or not, may call the
  // one entry point `liquidate`; it funds its own settlement gap (Q-397), a frozen caller
  // cannot call it, and the deadline and minimum payout only make the call revert.
  run anyCallerLiquidationTest = aliceTwoRecords
    .then(priceMove("mA", 1))
    .then(freezeAddress("EG", "eve"))
    .expect(and {
      swapLiqOk(s, "bob", PA, "mA", "GHO", { ...q0(300), dl: s.now + 1, minPay: 1200 }),
      not(swapLiqOk(s, "bob", PA, "mA", "GHO", { ...q0(300), dl: s.now - 1 })),
      not(swapLiqOk(s, "bob", PA, "mA", "GHO", { ...q0(300), minPay: 1201 })),
      swapLiqOk(s, "bob", PA, "mA", "GHO", { ...q0(1), s0: 2, s1: 2 }),       // bob pays the 2-cent gap
      swapLiqOk(s, "k1", PA, "mA", "GHO", { ...q0(1), s0: 2, s1: 2 }),          // a committed operator, the same call
      not(swapLiqOk(s, "eve", PA, "mA", "GHO", q0(300))),                    // frozen caller
      qnt42_paramsOnlyRevert,
    })
    .then(liquidate("bob", PA, "mA", "GHO", { ...q0(300), dl: s.now + 1, minPay: 1200 }))
    .expect(and { gho(s, "bob") == 301200, s.g.seizers == Set("LPVAULTSWAP"), honestInvariants })

  // QNT-T30 verifies: Q-133, Q-214, Q-228, Q-401
  // In-kind settlement is removed. bob's GHO payout is refused by the token: bob's
  // liquidation still completes, the 12 GHO payout is credited to bob in the
  // PayoutEscrow (payout escrow) and bob claims it to alice.
  run payoutEscrowTest = aliceTwoRecords
    .then(priceMove("mA", 1))
    .then(payoutBlockToggle("bob"))
    .then(liquidate("bob", PA, "mA", "GHO", q0(300)))
    .expect(and {
      gho(s, "bob") == 300000, s.escrowHeld.get("bob") == 1200, s.escrowBal == 1200,
      qnt41_escrowSolvent, qnt43_payoutEscrowed, qnt07_perProxyLedger, qnt56_reportsAlertOnly,
    })
    .then(claimEscrow("bob", "bob", "alice"))
    .expect(and { s.escrowHeld.get("bob") == 0, s.escrowBal == 0, qnt41_escrowSolvent })

  // ------------------------------------------------ features of Q-222 … Q-278

  // QNT-T31 verifies: Q-227, Q-252, Q-253
  // alice (HF 1.00 after interest) under Paused(General): a new account is refused; NFT 5
  // (100 units, below minPledgeUsd) passes as a rescue top-up within the restore amount and
  // NFT 7 (above it) is refused; MintPathSuspect refuses even the rescue; the rescue units
  // are excluded from new borrowing; a freeze-only key cannot unpause.
  run rescueTopUpTest = init
    .then(pledge("alice", 42, "mA"))
    .then(borrow("alice", "S1", "GHO", 1450, 0))
    .then(accrueInterest(PA, "GHO")).then(accrueInterest(PA, "GHO")).then(accrueInterest(PA, "GHO"))
    .then(pauseApp("EG", "General"))
    .expect(and {
      pledgeOk(s, "alice", 5, "mA"), not(pledgeOk(s, "alice", 7, "mA")), not(pledgeOk(s, "bob", 8, "mA")),
      not(liftOk(s, "FK", "Paused")),
    })
    .then(setPauseReason("EG", "MintPathSuspect"))
    .expect(not(pledgeOk(s, "alice", 5, "mA")))
    .then(setPauseReason("APG", "General"))
    .then(pledge("alice", 5, "mA"))
    .expect(and { s.recs.get(2).rescue == 100, qnt47_rescue, qnt25_topUpStates })
    .then(liftApp("EG", "Paused"))
    .then(priceMove("mA", 3))
    .expect(and { borrowOk(s, "alice", "S1", "GHO", 300, 1), not(borrowOk(s, "alice", "S1", "GHO", 1500, 1)),
                  qnt47_rescue, qnt44_pauseState })

  // QNT-T32 verifies: Q-241
  // A manual market breaker stops borrowing and withdraw-with-debt, not repay; a debt
  // breaker stops borrowing that asset only; a seizure surge is an alert only (Q-399) and
  // leaves the market open to new accounts.
  run breakersTest = init
    .then(pledge("alice", 42, "mA")).then(pledge("alice", 9, "mB"))
    .then(borrow("alice", "S1", "GHO", 500, 0))
    .then(tripMarket("FK", "mA"))
    .expect(and { not(borrowOk(s, "alice", "S1", "GHO", 300, 1)), not(withdrawOk(s, "alice", 2)),
                  repayOk(s, "alice", PA, "GHO", 100, true), qnt45_breakers })
    .then(resetMarket("EG", "mA"))
    .expect(borrowOk(s, "alice", "S1", "GHO", 300, 1))
    .then(issuerAssetToggle("GHO"))
    .expect(and { not(borrowOk(s, "alice", "S1", "GHO", 300, 1)), borrowOk(s, "alice", "S1", "USDT", 300, 1) })

  run seizureSurgeTest = aliceTwoRecords
    .then(priceMove("mA", 1))
    .then(liquidate("k1", PA, "mA", "GHO", q0(BIG)))
    .expect(and { s.seizeWin.get("mA") > 0, not(marketBreaker(s, "mA")), qnt45_breakers })

  // QNT-T33 verifies: Q-242
  // A frozen borrower keeps repay, fee collection and debt-free withdrawal, loses borrowing
  // and withdraw-with-debt; protected addresses cannot be frozen; each guardian is limited
  // per window; unfreezing waits the normal delay and only the DAO can cancel it.
  run addressFreezeTest = init
    .then(pledge("alice", 42, "mA")).then(pledge("alice", 9, "mB"))
    .then(borrow("alice", "S1", "GHO", 500, 0))
    .then(freezeAddress("EG", "alice"))
    .expect(and {
      not(borrowOk(s, "alice", "S1", "GHO", 300, 1)), not(withdrawOk(s, "alice", 2)),
      repayOk(s, "alice", PA, "GHO", 100, true), collectOk(s, "alice", 1),
      not(freezeTargetOk(s, "LPVAULTSWAP")), not(freezeTargetOk(s, PA)), not(freezeTargetOk(s, "TIMELOCK")),
    })
    .then(repayAll("alice", PA, "GHO", BIG))
    .expect(withdrawOk(s, "alice", 2))
    .then(freezeAddress("EG", "bob"))
    .expect(and { s.freezeWinCount.get("EG") == FREEZE_LIMIT, s.freezeWinStart.get("EG") + DAY > s.now })  // a third freeze by EG reverts
    .then(freezeAddress("APG", "eve"))
    .then(schedule("MULTISIG", UNFREEZE_EVE, false))
    .expect(and { not(cancelOk(s, "EG", 1)), cancelOk(s, "AAVE_EXEC", 1), qnt46_addressFreeze })
    .then(waitDelay).then(execute(1))
    .expect(and { not(s.frozen.contains("eve")), qnt46_addressFreeze })

  // QNT-T34 verifies: Q-257, INV-080
  // An orphan burn (burnSeized never settled) leaves the market with a backing gap: under
  // the one-sided check bob's debt-free withdrawal still works; under the absolute
  // equality of Q-224 as first written it reverts.
  run orphanSetup = pledge("alice", 42, "mA").then(pledge("alice", 7, "mA"))
    .then(borrow("alice", "S1", "GHO", 1500, 0)).then(borrow("alice", "S1", "GHO", 1000, 1))
    .then(pledge("bob", 8, "mA"))
    .then(priceMove("mA", 1))
    .then(upgradeSwapHostile)
    .then(hostileSwapKeep(PA, "mA", "GHO", 300))
    .then(hostileOrphanBurn("mA"))
    .then(restoreSwapHonest)

  run backingOneSidedTest = init.then(orphanSetup)
    .expect(and { gapOf(s, "mA") == 315, s.orphan.get("mA") == 315, withdrawOk(s, "bob", 3),
                  qnt03_supplyEqualsBacking, qnt15_debtFreeWithdrawOpen })
    .then(withdraw("bob", 3))
    .expect(and { gapOf(s, "mA") == 315, qnt48_backingGap })

  run backingEqualityBricksTest = initEquality.then(orphanSetup)
    .expect(and { not(withdrawOk(s, "bob", 3)), not(qnt15_debtFreeWithdrawOpen) })

  // QNT-T35 verifies: Q-254
  // Partial removal: principal to the depositor, NFT and fees stay; with debt the record
  // left must be worth minPledgeUsd and the account keep 1.10; Paused refuses it with debt
  // and allows it debt-free.
  run partialRemovalTest = init
    .then(pledge("alice", 42, "mA"))
    .then(accrueFees(42))
    .then(removeLiquidity("alice", 1, 300))
    .expect(and { s.recs.get(1).credited == 700, s.nfts.get(42).liquidity == 700, s.nfts.get(42).owner == "LPVAULT",
                  s.nfts.get(42).fees == 10, s.tokVal.get("alice") == 60000, s.supplied.get((PA, "mA")) == 700, qnt49_removalRecredit })
    .then(borrow("alice", "S1", "GHO", 500, 0))
    .expect(and { not(removeOk(s, "alice", 1, 600)), not(removeOk(s, "alice", 1, 500)), removeOk(s, "alice", 1, 100) })
    .then(pauseApp("EG", "General"))
    .expect(not(removeOk(s, "alice", 1, 100)))
    .then(repayAll("alice", PA, "GHO", BIG))
    .expect(removeOk(s, "alice", 1, 600))

  // QNT-T36 verifies: Q-254, Q-257
  // Re-credit books exactly the added liquidity, mints it and supplies it; only the depositor.
  run recreditTest = init
    .then(pledge("alice", 42, "mA"))
    .then(borrow("alice", "S1", "GHO", 1000, 0))
    .then(donate("eve", 42, 200))
    .expect(and { not(recreditOk(s, "eve", 1)), recreditOk(s, "alice", 1) })
    .then(recredit("alice", 1))
    .expect(and { s.recs.get(1).credited == 1200, s.supplied.get((PA, "mA")) == 1200, s.bal.get(("mA", "HUB")) == 1200,
                  qnt49_removalRecredit, qnt48_backingGap, honestInvariants })

  // QNT-T37 verifies: Q-255
  // Repay with collateral under Frozen and a tripped breaker: NFT 7's 800 units repay
  // 1,550 GHO with no bonus or fee; HF rises; the 50 GHO left go to alice and the
  // whole record's NFT returns. Paused and a frozen caller refuse it.
  run repayWithCollateralTest = aliceTwoRecords
    .then(freezeApp("FK"))
    .then(tripMarket("FK", "mA"))
    .then(repayWithCollateral("alice", 2, 800, "GHO", 0, 0))
    .expect(and {
      s.debt.get((PA, "GHO")) == 950, gho(s, "alice") == 555000, s.nfts.get(7).owner == "alice",
      not(s.recs.get(2).open), s.feeRecipient == 0, qnt50_repayWithCollateral, qnt48_backingGap,
    })
    .then(pauseApp("EG", "General"))
    .expect(not(rwcOk(s, "alice", 1, 100, "GHO", 0, 0, 0)))
    .then(liftApp("EG", "Paused"))
    .then(freezeAddress("EG", "alice"))
    .expect(not(rwcOk(s, "alice", 1, 100, "GHO", 0, 0, 0)))

  // QNT-T38 verifies: Q-235, Q-247, Q-248, Q-256
  // bob holds GHO and USDT debt. A USDT rally and a price drop make him liquidatable. While
  // USDT's DebtOracle is Cached only the GHO reserve can be repaid; the standby switch
  // restores USDT; the executor undoes it. The USDT liquidation buys 410 USDT (10 over),
  // sells 10 back above its floor, and Avana's fee comes from the oracle value.
  run usdtLiquidationTest = init
    .then(pledge("bob", 8, "mA"))
    .then(borrow("bob", "S1", "GHO", 600, 0))
    .then(borrow("bob", "S1", "USDT", 400, 1))
    .then(debtPriceMove(120))
    .then(priceMove("mA", 1))
    .then(debtFeedFail)
    .expect(and { not(swapLiqOk(s, "k1", PB, "mA", "USDT", q0(BIG))), swapLiqOk(s, "k1", PB, "mA", "GHO", q0(BIG)) })
    .then(useStandbyDebt("EG"))
    .expect(swapLiqOk(s, "k1", PB, "mA", "USDT", q0(BIG)))
    .then(cancelStandbyDebt("AAVE_EXEC"))
    .then(debtRecover(120))
    .expect(not(swapLiqOk(s, "k1", PB, "mA", "USDT", { ...q0(BIG), over: 10, b: 3 })))   // buy above the oracle bound
    .then(liquidate("k1", PB, "mA", "USDT", { ...q0(BIG), over: 10, b: 1 }))
    .expect(and {
      s.debt.get((PB, "USDT")) == 0, s.debt.get((PB, "GHO")) == 600, s.supplied.get((PB, "mA")) == 196,
      s.feeRecipient == 379, gho(s, "k1") == 301517, qnt57_waterfall, honestInvariants,
    })

  // QNT-T39 verifies: Q-251, Q-228
  // Routes 10 % below the oracle: the call fails at the per-leg minimums without a
  // shortfall allowance and settles with one (the keeper pays 20.05 GHO). Floor-failure
  // reports are alerts only (Q-399, Q-401): they open no settlement mode and change no gate.
  run shortfallReportsAlertTest = aliceTwoRecords
    .then(priceMove("mA", 1))
    .expect(and {
      not(swapLiqOk(s, "k1", PA, "mA", "GHO", { ...q0(300), s0: 10, s1: 10 })),
      swapLiqOk(s, "k1", PA, "mA", "GHO", { ...q0(300), s0: 10, s1: 10, k: 5000 }),
      settleX(s, aaveLiq(s, PA, "mA", "GHO", 300), "mA", "GHO", { ...q0(300), s0: 10, s1: 10, k: 5000 }).sh == 2005,
    })
    .then(reportShortfall("k1", PA, "mA", "GHO", { ...q0(300), s0: 10, s1: 10, k: 5000 })).then(tick)
    .then(reportShortfall("k1", PA, "mA", "GHO", { ...q0(300), s0: 10, s1: 10, k: 5000 })).then(tick)
    .then(reportShortfall("k1", PA, "mA", "GHO", { ...q0(300), s0: 10, s1: 10, k: 5000 }))
    .expect(and { not(marketBreaker(s, "mA")), not(liqHaltedMkt(s, "mA")), qnt56_reportsAlertOnly })
    .then(liquidate("k1", PA, "mA", "GHO", { ...q0(300), s0: 10, s1: 10, k: 5000 }))
    .expect(and { gho(s, "k1") == 298050, qnt57_waterfall, qnt27_recoveryFloor })

  // QNT-T40 verifies: Q-228, Q-245, Q-259, Q-262, Q-263
  // An upgrade cannot be scheduled at the short delay nor moved onto the short list; the
  // normal delay cannot drop below 4; admin power cannot leave the timelock; with the
  // multisig's quorum lost the Aave executor proposes; a restoring operation is cancellable
  // only by the DAO, a mixed one by any canceller; a ready operation expires.
  run timelockTest = init
    .expect(and { not(scheduleOk(s, "MULTISIG", UPG_ADAPTER, true)), scheduleOk(s, "MULTISIG", UPG_ADAPTER, false) })
    .then(schedule("MULTISIG", SHORT_UPG, false))
    .then(schedule("MULTISIG", DELAY3, false))
    .then(schedule("MULTISIG", DELAY4, false))
    .then(schedule("MULTISIG", GRANT_EVE, false))
    .then(waitDelay)
    .expect(and { not(executeOk(s, 1)), not(executeOk(s, 2)), executeOk(s, 3), not(executeOk(s, 4)) })
    .then(execute(3))
    .expect(s.normalDelay == 4)
    .then(multisigLost)
    .expect(and { not(scheduleOk(s, "MULTISIG", RESTORE_MA, true)), scheduleOk(s, "AAVE_EXEC", RESTORE_MA, true) })
    .then(schedule("AAVE_EXEC", RESTORE_MA, true))
    .then(schedule("AAVE_EXEC", MIXED_MA, false))
    .then(schedule("AAVE_EXEC", TIGHTEN, true))
    .expect(and { not(cancelOk(s, "EG", 5)), cancelOk(s, "AAVE_EXEC", 5), cancelOk(s, "EG", 6), qnt52_timelockDelays })
    .then(cancel("EG", 6))
    .then(waitDelay).then(waitDelay).then(waitDelay)
    .expect(and { not(executeOk(s, 7)), qnt52_timelockDelays, qnt53_restrictedCancel })

  // QNT-T41 verifies: Q-248
  // The standby switch ends an outage at once but never bypasses freshness: with a stale
  // standby the market stays Cached; only the Aave executor undoes a guardian's switch.
  run standbyTest = init
    .then(pledge("alice", 42, "mA"))
    .then(feedFail("mA"))
    .expect(ps(s, "mA") == Cached)
    .then(useStandby("EG", "mA"))
    .expect(and { ps(s, "mA") == Live, qnt54_standby })
    .then(cancelStandby("AAVE_EXEC", "mA"))
    .expect(ps(s, "mA") == Cached)
    .then(standbyGoesStale("mA"))
    .then(useStandby("APG", "mA"))
    .expect(and { ps(s, "mA") == Cached, qnt54_standby })

  // QNT-T42 verifies: Q-247, Q-276, Q-277
  // A failing market no longer shields the account: with mB Expired (valued at the minimum
  // price) the reviewed LPVaultSwap seizes the fresh mA and never mB.
  run staleMarketNoShieldTest = aliceTwoMarkets
    .then(feedFail("mB"))
    .then(tick).then(tick)
    .then(priceMove("mA", 1))
    .expect(and { aavePx(s, "mB") == 0, liquidatable(s, PA), qnt55_conservativeValuation })
    .then(liquidate("k1", PA, "mA", "GHO", q0(BIG)))
    .expect(and { s.supplied.get((PA, "mB")) == 600, qnt22_noLiquidationOnStale, qnt36_liquidationLive })

  // QNT-T43 verifies: Q-225, Q-234, Q-278
  // alice's accounts on S1 and S2 are separate: liquidating S1 leaves S2 untouched.
  run accountIsolationTest = init
    .then(pledge("alice", 42, "mA")).then(pledge("alice", 21, "mC"))
    .then(borrow("alice", "S1", "GHO", 1000, 0)).then(borrow("alice", "S2", "GHO", 1000, 0))
    .then(priceMove("mA", 1))
    .expect(and { liquidatable(s, PA), not(liquidatable(s, "P_alice_S2")) })
    .then(liquidate("k1", PA, "mA", "GHO", q0(BIG)))
    .expect(and { s.supplied.get(("P_alice_S2", "mC")) == 1000, s.debt.get(("P_alice_S2", "GHO")) == 1000, qnt51_accountIsolation })

  // QNT-T44 verifies: Q-267, Q-236, Q-397
  // The budget and its sub-caps are removed: a caller's top-up is exactly the floor
  // shortfall plus the settlement gap, here the 2-cent gap of a dust liquidation.
  run callerTopUpSplitTest = aliceTwoRecords
    .then(priceMove("mA", 1))
    .expect(and {
      settleX(s, aaveLiq(s, PA, "mA", "GHO", 1), "mA", "GHO", { ...q0(1), s0: 2, s1: 2 }).gap == 2,
      settleX(s, aaveLiq(s, PA, "mA", "GHO", 1), "mA", "GHO", { ...q0(1), s0: 2, s1: 2 }).sh == 2,
    })
}
