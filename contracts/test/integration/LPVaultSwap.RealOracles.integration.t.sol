// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IDebtOracle} from "../../src/oracle/debt-oracle/IDebtOracle.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {LPOracleCL} from "../../src/oracle/lp-oracle/LPOracleCL.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {Market} from "../../src/types/Market.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {PriceStateView} from "../../src/types/PriceStateView.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";
import {AccessTrace} from "../utils/AccessTrace.sol";
import {RealClMarketBuilder, RealDebtOracleBuilder} from "../utils/fixtures/RealOracleBuilders.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LPVaultSwapRealOraclesIntegrationTest
/// @notice LPVaultSwap on the real oracles: the market's LPOracle is the real concentrated-liquidity `LPOracleCL` over
/// a real Uniswap v3 USDC/USDT pool, and the USDC debt reserve's price source is the real `DebtOracle` behind its UUPS
/// proxy, both wired into the MarketRegistry record LPVaultSwap reads (the AaveOracle keeps its own sources). Checked:
/// LPVaultSwap pokes each oracle before it reads it and the poke stores state in a successful liquidation
/// (REQ-ORACLE-109, REQ-ORACLE-110); a USD-band breach never stops liquidation (TEST-043); the disagreement pause
/// and its expiry stop seizure until the routes agree (TEST-044, TEST-157); an Expired market and an Expired debt
/// price refuse seizure and repayment (TEST-230).
/// forge-config: default.isolate = false
contract LPVaultSwapRealOraclesIntegrationTest is LPVaultSwapUnitBase {
    using AccessTrace for Vm.AccountAccess[];

    uint256 internal constant USD_BAND = 3;
    uint256 internal constant QUOTE_CHANGE_CAPPED = 18;

    RealClMarketBuilder internal cl;
    RealDebtOracleBuilder internal debtBuilder;
    LPOracleCL internal clOracle;
    IDebtOracle internal debtOracle;
    address internal proxy;

    function setUp() public override {
        cl = new RealClMarketBuilder();
        clOracle = cl.build();
        debtBuilder = new RealDebtOracleBuilder();
        debtOracle = debtBuilder.build();
        super.setUp();
        Market memory m = registry.getMarket(MARKET_ID);
        m.lpOracle = address(clOracle);
        registry.setMarket(MARKET_ID, m);
        DebtReserveDef memory d = registry.getDebtReserve(aave.cdpSpoke, usdcReserveId);
        d.priceSource = address(debtOracle);
        registry.setDebtReserve(aave.cdpSpoke, usdcReserveId, d, true);
        (proxy,) = _bobAccount();
        _refresh();
        _settleQuote();
    }

    function _refresh() internal {
        cl.refresh();
        debtBuilder.refresh();
    }

    /// @dev Keeper pokes until the oracle no longer holds a capped quote change (one block each).
    function _settleQuote() internal {
        for (uint256 i = 0; i < 8; ++i) {
            clOracle.poke{gas: 5_000_000}();
            debtOracle.poke{gas: 5_000_000}();
            if (clOracle.getPriceState().reasons & (1 << QUOTE_CHANGE_CAPPED) == 0) return;
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 12);
        }
    }

    function _step(
        uint256 secondsForward
    ) internal {
        vm.roll(block.number + 1 + secondsForward / 12);
        vm.warp(block.timestamp + secondsForward);
    }

    /// @notice LPVaultSwap calls `poke()` on the market's real LPOracle before its first read of the price state, the
    /// poke writes the oracle's storage before that read, and the liquidation settles.
    // TEST-049 verifies: REQ-ORACLE-109, REQ-SWAP-008, Q-199
    function test_TEST_049_pokesTheRealLPOracleBeforeReading() public {
        _step(60);
        _refresh();
        vm.startStateDiffRecording();
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        assertGt(r.unitsSeized, 0, "the liquidation settled");
        address o = address(clOracle);
        (bool poked, uint256 iPoke) = acc.firstCall(o, ILPOracle.poke.selector, address(lvs), 0);
        (bool read, uint256 iRead) = acc.firstCall(o, ILPOracle.getPriceState.selector, address(lvs), 0);
        assertTrue(poked, "LPVaultSwap poked the LPOracle");
        assertTrue(read, "LPVaultSwap read the price state");
        assertLt(iPoke, iRead, "poke before the first read");
        assertTrue(acc.wroteStorage(o, iPoke, iRead), "the poke stored state before the read");
        (bool readTokens, uint256 iTokens) = acc.firstCall(o, ILPOracle.getTokenPrices.selector, address(lvs), 0);
        assertTrue(!readTokens || iPoke < iTokens, "leg prices read after the poke");
    }

    /// @notice LPVaultSwap calls `poke()` on the real DebtOracle of the repaid USDC reserve before it reads that oracle's
    /// state, the poke writes the oracle's storage, and the liquidation settles; a GHO repayment never touches it.
    // TEST-049 verifies: REQ-ORACLE-110, REQ-SWAP-091, Q-199
    function test_TEST_049_pokesTheRealDebtOracleBeforeReading() public {
        _step(60);
        _refresh();
        vm.startStateDiffRecording();
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        assertGt(r.unitsSeized, 0, "the liquidation settled");
        address o = address(debtOracle);
        (bool poked, uint256 iPoke) = acc.firstCall(o, IDebtOracle.poke.selector, address(lvs), 0);
        (bool read, uint256 iRead) = acc.firstCall(o, IDebtOracle.getPriceState.selector, address(lvs), 0);
        assertTrue(poked, "LPVaultSwap poked the DebtOracle");
        assertTrue(read, "LPVaultSwap read the DebtOracle's state");
        assertLt(iPoke, iRead, "poke before the read");
        assertTrue(acc.wroteStorage(o, iPoke, iRead), "the poke stored state before the read");
    }

    /// @notice LPVaultSwap reads the account's health factor only after it has poked the market's LPOracle and the
    /// repaid reserve's DebtOracle, so `NotLiquidatable`, the grace check and the bonus use the health factor Aave
    /// applies in `liquidationCall` (a poke can move the price Aave reads in the same block,
    /// `LPOraclePokeInvarianceUnitTest`). Regression for the HF read that preceded the pokes.
    // TEST-049 verifies: REQ-SWAP-006, REQ-SWAP-008, REQ-SWAP-009, REQ-SWAP-091, Q-199
    function test_TEST_049_readsTheHealthFactorAfterBothPokes() public {
        _step(60);
        _refresh();
        vm.startStateDiffRecording();
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        assertGt(r.unitsSeized, 0, "the liquidation settled");
        (bool lpPoked, uint256 iLp) = acc.firstCall(address(clOracle), ILPOracle.poke.selector, address(lvs), 0);
        (bool debtPoked, uint256 iDebt) = acc.firstCall(address(debtOracle), IDebtOracle.poke.selector, address(lvs), 0);
        (bool read, uint256 iHf) =
            acc.firstCall(aave.cdpSpoke, IAaveV4Spoke.getUserAccountData.selector, address(lvs), 0);
        assertTrue(lpPoked && debtPoked && read, "both pokes and the HF read happened");
        assertGt(iHf, iLp, "HF read after the LPOracle poke");
        assertGt(iHf, iDebt, "HF read after the DebtOracle poke");
    }

    /// @notice USD-band breach with both routes fresh and agreeing (USDC and USDT at $0.89, below the 0.90 band): the
    /// real LPOracle reports the USD_BAND reason and refuses borrowing, liquidation is not paused, and LPVaultSwap
    /// liquidates at the served price.
    // TEST-043 verifies: REQ-SWAP-008, REQ-ORACLE-109
    function test_TEST_043_usdBandBreachLiquidates() public {
        _step(60);
        cl.setPrices(89_000_000, 89_000_000);
        debtBuilder.refresh();
        _settleQuote();
        PriceStateView memory v = clOracle.getPriceState();
        assertTrue(v.reasons & (1 << USD_BAND) != 0, "USD band breached");
        assertFalse(v.borrowAllowed, "borrowing refused");
        assertFalse(v.liquidationPaused, "liquidation open");
        assertFalse(v.disagreementPauseActive, "routes agree");
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertGt(r.unitsSeized, 0, "liquidated at the served price");
    }

    /// @notice Disagreement pause and its expiry: token1's alternate route reads $0.97 against $1.00 (beyond the 150 bps
    /// agreement tolerance). From the first stored observation seizure reverts `StalePrice` inside the pause; after
    /// `disagreementPauseMax` (3,600 s) with the routes still apart the market stays refused (Expired for its own
    /// seizure); once the routes agree again seizure resumes.
    // TEST-044 verifies: REQ-SWAP-008, REQ-ORACLE-022; shared: the disagreement pause of TEST-044 is the first half of this test, before the expiry TEST-157 adds
    // TEST-157 verifies: REQ-SWAP-008, REQ-ORACLE-022
    function test_TEST_157_persistentDisagreementStopsSeizureUntilRoutesAgree() public {
        _step(60);
        _refresh();
        cl.setAlternate1(97_000_000);
        clOracle.poke{gas: 5_000_000}();
        PriceStateView memory v = clOracle.getPriceState();
        assertGt(v.disagreeSince, 0, "first observation stored");
        assertTrue(v.disagreementPauseActive, "pause active");
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.StalePrice.selector));
        _step(3601);
        _refresh();
        cl.setAlternate1(97_000_000);
        clOracle.poke{gas: 5_000_000}();
        v = clOracle.getPriceState();
        assertTrue(v.disagreementExpired, "disagreement outlasted disagreementPauseMax");
        assertTrue(v.liquidationPaused, "seizure of this market stays stopped");
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.StalePrice.selector));
        _step(60);
        _refresh();
        _settleQuote();
        assertEq(clOracle.getPriceState().disagreeSince, 0, "routes agree again");
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertGt(r.unitsSeized, 0, "seizure resumes");
    }

    /// @notice Stress valuation, collateral side: with every feed of the market stale the real LPOracle fails, is
    /// Cached for `cachedWindow` and then Expired, serving 1; LPVaultSwap's seizure of that market reverts `StalePrice`.
    // TEST-230 verifies: REQ-SWAP-008, INV-087
    function test_TEST_230_expiredMarketServedAtOneAndRefused() public {
        _step(88_201);
        debtBuilder.refresh();
        clOracle.poke{gas: 5_000_000}();
        assertEq(uint8(clOracle.getPriceState().state), uint8(PriceState.Cached), "Cached after the failure");
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.StalePrice.selector));
        _step(3601);
        debtBuilder.refresh();
        clOracle.poke{gas: 5_000_000}();
        assertEq(uint8(clOracle.getPriceState().state), uint8(PriceState.Expired), "Expired");
        assertEq(clOracle.latestAnswer(), 1, "an Expired market is served at 1");
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.StalePrice.selector));
    }

    /// @notice Stress valuation, debt side: with every USDC feed stale the real DebtOracle goes Cached, then Expired,
    /// and serves `⌈accepted × (10⁴ + 500) / 10⁴⌉`; a liquidation repaying that USDC reserve reverts
    /// `DebtPriceStale(r)` while the LPOracle is fresh.
    // TEST-230 verifies: REQ-SWAP-091, REQ-ORACLE-110, INV-030
    function test_TEST_230_expiredDebtOracleRefusesRepayment() public {
        (uint256 accepted,) = debtOracle.lastAcceptedPrice();
        _step(88_201);
        cl.refresh();
        debtOracle.poke{gas: 5_000_000}();
        _step(3601);
        cl.refresh();
        _settleQuote();
        assertEq(uint8(debtOracle.getPriceState().state), uint8(PriceState.Expired), "DebtOracle Expired");
        assertEq(uint256(debtOracle.latestAnswer()), (accepted * 10_500 + 9999) / 10_000, "stress price served");
        _expectLiquidateRevert(
            keeper, _params(proxy, 1950e6), _lvsError(ILPVaultSwapErrors.DebtPriceStale.selector, usdcReserveId)
        );
    }
}
