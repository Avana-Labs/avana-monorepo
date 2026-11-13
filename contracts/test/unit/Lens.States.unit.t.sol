// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILensAccount} from "../../src/lens/lens/ILensAccount.sol";
import {ILensLiquidation} from "../../src/lens/lens/ILensLiquidation.sol";
import {ILensMarket} from "../../src/lens/lens/ILensMarket.sol";
import {ILensPreview} from "../../src/lens/lens/ILensPreview.sol";
import {ILensRisk} from "../../src/lens/lens/ILensRisk.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensStatesUnitTest
/// @notice Every view answers in every market and position state the spec says the Lens reports: paused and frozen
/// Hubs, paused Aave reserves, Cached and Expired collateral prices, an Expired debt price, a market offboarding or
/// closed, unusable swap routes, a frozen wallet, latched breakers, a seized account and a wallet with no positions.
/// forge-config: default.isolate = false
contract LensStatesUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 20_000e6);
        _open(alice, aliceProxy, 2, 5000e6);
        _borrow(aliceProxy, 15_000e18);
        _borrowUsdc(aliceProxy, 5000e6);
    }

    // TEST-247 verifies: REQ-LENS-007, REQ-LENS-031
    function test_TEST_247_answersUnderEveryPauseState() public {
        _allAnswer("baseline");
        reg.setPause(aave.hub, PauseState.Frozen, PauseReason.None);
        _allAnswer("Frozen");
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        _allAnswer("Paused(General)");
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.MintPathSuspect);
        _allAnswer("Paused(MintPathSuspect)");
    }

    // TEST-247 verifies: REQ-LENS-007, REQ-LENS-009, REQ-LENS-016
    function test_TEST_247_answersWithAaveReservesPaused() public {
        _setReservePaused(vtReserveId, true);
        _setReservePaused(debtReserveId, true);
        _setReservePaused(usdcReserveId, true);
        _allAnswer("Aave reserves paused");
    }

    // TEST-247 verifies: REQ-LENS-007, REQ-LENS-015, REQ-ORACLE-085
    function test_TEST_247_answersInEveryCollateralPriceState() public {
        lpo.setTokenAt(0, uint64(block.timestamp - 200_000), 0);
        lpo.setState(PriceState.Cached, 1 << 8, true);
        _allAnswer("Cached with stale inputs");
        lpo.setState(PriceState.Expired, 0, true);
        _setVtPrice(1);
        _allAnswer("Expired, served at 1");
        lpo.setDisagreement(uint64(block.timestamp - 10_000), false, true);
        _allAnswer("disagreement past its bound");
        lpo.setAnswer(true, 0);
        _allAnswer("a zero answer");
    }

    // TEST-247 verifies: REQ-LENS-007, REQ-LENS-030
    function test_TEST_247_answersWithExpiredDebtPrice() public {
        usdcOracle.set(1.05e8, PriceState.Expired, 1e8, uint64(block.timestamp - 500_000));
        _allAnswer("Expired USDC at its stress price");
        usdcOracle.set(1e8, PriceState.Cached, 1e8, uint64(block.timestamp - 5000));
        _allAnswer("Cached USDC");
    }

    // TEST-247 verifies: REQ-LENS-007, REQ-LENS-034
    function test_TEST_247_answersForWoundDownMarkets() public {
        reg.setStatus(MARKET_ID, uint8(MarketStatus.Offboarding));
        _allAnswer("Offboarding");
        reg.setStatus(MARKET_ID, uint8(MarketStatus.Closed));
        _allAnswer("Closed");
    }

    // TEST-247 verifies: REQ-LENS-007, REQ-LENS-016
    function test_TEST_247_answersWithBrokenRoutes() public {
        for (uint8 k = 0; k < 2; ++k) {
            reg.setRoute(MARKET_ID, address(usdc), address(debt), k, address(0), false);
            reg.setRoute(MARKET_ID, address(usdt), address(debt), k, address(0), false);
            reg.setRoute(MARKET_ID, address(usdt), address(usdc), k, address(0), false);
        }
        _allAnswer("no usable route");
    }

    // TEST-247 verifies: REQ-LENS-007, REQ-LENS-037, Q-241, Q-242
    function test_TEST_247_answersWithFreezesAndBreakers() public {
        reg.setFrozen(alice, true);
        rm.setMarketBreaker(MARKET_ID, 512 | 1024, type(uint64).max);
        rm.setDebtBreaker(aave.cdpSpoke, debtReserveId, 32, type(uint64).max);
        rm.setGate(aliceProxy, false, true, PauseState.None);
        _allAnswer("frozen wallet, latched breakers, unavailable status");
    }

    // TEST-247 verifies: REQ-LENS-007, REQ-LENS-011, REQ-LENS-026
    function test_TEST_247_answersAfterSeizureAndDeficit() public {
        _setVtPrice(0.3e8);
        _seizeAndKeep(aliceProxy, 20_000e18);
        _allAnswer("seized, possibly with a deficit");
    }

    // TEST-247 verifies: REQ-LENS-007, REQ-LENS-008, REQ-LENS-009
    function test_TEST_247_answersForWalletWithNoPositions() public view {
        _allAnswerFor(carol, address(0), "no account");
    }

    // TEST-247 verifies: REQ-LENS-007, REQ-LENS-020
    function test_TEST_247_answersAfterLongIdle() public {
        vm.warp(block.timestamp + 400 days);
        vm.roll(block.number + 2_600_000);
        _allAnswer("a year of interest and stale feeds");
    }

    // ─── helpers ───

    function _allAnswer(
        string memory why
    ) internal view {
        _allAnswerFor(alice, aliceProxy, why);
    }

    function _allAnswerFor(
        address wallet,
        address proxy,
        string memory why
    ) internal view {
        bytes[] memory c = new bytes[](proxy == address(0) ? 22 : 26);
        address[] memory toks = new address[](2);
        (toks[0], toks[1]) = (address(usdc), address(debt));
        uint256[] memory ids = new uint256[](1);
        ids[0] = MARKET_ID;
        uint256 t = block.timestamp + 600;
        c[0] = abi.encodeCall(ILensAccount.predictProxy, (wallet, MARKET_ID));
        c[1] = abi.encodeCall(ILensAccount.getAccount, (wallet, MARKET_ID));
        c[2] = abi.encodeCall(ILensAccount.getAccounts, (wallet, ids));
        c[3] = abi.encodeCall(ILensAccount.getEscrowClaimable, (wallet, toks));
        c[4] = abi.encodeCall(ILensMarket.checkBacking, (vt));
        c[5] = abi.encodeCall(ILensMarket.checkRecordBacking, (vt, 0, 200));
        c[6] = abi.encodeCall(ILensMarket.getPendingSettlement, (vt));
        c[7] = abi.encodeCall(ILensMarket.getCapHeadroom, (vt, wallet));
        c[8] = abi.encodeCall(ILensLiquidation.getPriceState, (vt));
        c[9] = abi.encodeCall(ILensLiquidation.getDebtPriceState, (aave.cdpSpoke, debtReserveId));
        c[10] = abi.encodeCall(ILensLiquidation.getDebtPriceState, (aave.cdpSpoke, usdcReserveId));
        c[11] = abi.encodeCall(ILensLiquidation.getApplicationState, (aave.hub));
        c[12] = abi.encodeCall(ILensLiquidation.getPauseReason, (aave.hub));
        c[13] = abi.encodeCall(ILensRisk.getBreakerStatus, (MARKET_ID));
        c[14] = abi.encodeCall(ILensRisk.getDebtBreakerStatus, (aave.cdpSpoke, debtReserveId));
        c[15] = abi.encodeCall(ILensRisk.isFrozenAddress, (wallet));
        c[16] = abi.encodeCall(ILensRisk.getTailCoverage, (aave.hub, address(debt)));
        c[17] = abi.encodeCall(ILensRisk.uncoveredDeficit, (aave.hub, address(debt)));
        c[18] = abi.encodeCall(ILensRisk.getHubAssetExposure, (aave.hub, address(usdc)));
        c[19] = abi.encodeCall(ILensPreview.previewBorrowRecommended, (wallet, MARKET_ID, usdcReserveId, t));
        c[20] = abi.encodeCall(ILensPreview.quoteRepayAll, (wallet, MARKET_ID, debtReserveId, t));
        c[21] =
            abi.encodeCall(ILensPreview.previewRepayWithCollateral, (wallet, MARKET_ID, _key(1), 1e6, debtReserveId));
        if (proxy != address(0)) {
            c[22] = abi.encodeCall(ILensAccount.getRecords, (proxy, 0, 16));
            c[23] = abi.encodeCall(ILensLiquidation.previewLiquidation, (proxy, debtReserveId, t));
            c[24] = abi.encodeCall(ILensLiquidation.previewLiquidation, (proxy, usdcReserveId, t));
            c[25] = abi.encodeCall(ILensPreview.previewRecredit, (MARKET_ID, _key(1)));
        }
        for (uint256 i = 0; i < c.length; ++i) {
            (bool ok,) = address(lens).staticcall(c[i]);
            assertTrue(ok, string.concat(why, ": view #", vm.toString(i)));
        }
    }
}
