// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {DebtReserveView} from "../../src/lens/lens/types/DebtReserveView.sol";
import {MarketView} from "../../src/lens/lens/types/MarketView.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensMarketsUnitTest
/// @notice `getMarkets`, `getMarket`, `getDebtReserve` and `getDebtReserves` on the real Aave V4 Hub, Spoke and rate
/// strategy and the real vault token.
/// forge-config: default.isolate = false
contract LensMarketsUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
        _open(alice, aliceProxy, 1, 10_000e6);
    }

    // ─── markets ───

    // TEST-247 verifies: REQ-LENS-045, REQ-LENS-005
    function test_TEST_247_marketIdentity() public view {
        MarketView memory v = lens.getMarket(MARKET_ID);
        assertEq(v.blockNumber, block.number, "block");
        assertEq(v.marketId, MARKET_ID, "market");
        assertEq(v.chainId, block.chainid, "chain");
        assertEq(uint8(v.status), uint8(MarketStatus.Active), "Active");
        assertEq(v.pool, pool, "pool");
        assertEq(v.tokens.length, 2, "two tokens");
        assertEq(v.tokens[0], address(usdc), "pool order");
        assertEq(v.tokenDecimals[1], 6, "USDT decimals");
        assertEq(v.feeTier, 100, "the integration's fee tier in pips");
        assertEq(v.tickLower, -50, "lower tick");
        assertEq(v.tickUpper, 50, "upper tick");
        assertEq(v.integrationId, INTEGRATION, "integration");
        assertEq(v.ammProtocol, keccak256("UNISWAP_V3"), "AMM protocol tag");
        assertEq(v.vaultToken, vt, "vault token");
        assertEq(v.name, "Avana USDC/USDT", "name");
        assertEq(v.symbol, "avUSDC-USDT", "symbol");
        assertEq(v.lpOracle, address(lpo), "LPOracle");
        assertEq(v.hub, aave.hub, "Hub");
        assertEq(v.spoke, aave.cdpSpoke, "Spoke");
        assertEq(v.reserveId, vtReserveId, "reserve");
        assertEq(v.hubAssetId, vtAssetId, "Hub asset");
    }

    // TEST-247 verifies: REQ-LENS-045
    function test_TEST_247_marketPriceSupplyAndLimits() public view {
        MarketView memory v = lens.getMarket(MARKET_ID);
        assertEq(v.acceptedPrice, 2e8, "accepted $2.00");
        assertEq(uint8(v.priceState), uint8(PriceState.Live), "Live");
        assertEq(v.suppliedUnits, 10_000_000_000, "10,000 whole vault tokens supplied");
        assertEq(v.suppliedUsd, 2_000_000_000_000, "$20,000");
        assertEq(v.collateralFactorBps, 8000, "CF 80 %");
        assertEq(v.liquidationThresholdBps, 8000, "Aave V4 liquidates on the same factor");
        assertEq(v.maxLiquidationBonusBps, 10_500, "max bonus");
        assertEq(v.marketHeadroomUsd, 1_000_000e8 - 20_000e8, "market cap minus the booked charge");
        assertEq(v.sliceHeadroomUsd, 100_000e8, "slice");
        assertEq(v.addHeadroom, 5_500_000e6 - 10_000e6, "Aave add cap headroom");
        assertEq(uint8(v.pauseState), uint8(PauseState.None), "open");
        assertEq(v.breakerReasons, 0, "no breaker");
    }

    // TEST-247 verifies: REQ-LENS-045, REQ-LENS-007
    function test_TEST_247_marketStateChanges() public {
        rm.setMarketBreaker(MARKET_ID, 4, uint64(block.timestamp + 60));
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        lpo.setState(PriceState.Expired, 0, true);
        lpo.setAccepted(1.9e8, uint64(block.timestamp));
        reg.setStatus(MARKET_ID, uint8(MarketStatus.Offboarding));
        MarketView memory v = lens.getMarket(MARKET_ID);
        assertEq(v.breakerReasons, 4, "breaker");
        assertEq(uint8(v.pauseState), uint8(PauseState.Paused), "paused");
        assertEq(uint8(v.priceState), uint8(PriceState.Expired), "Expired, reported");
        assertEq(v.suppliedUsd, 1_900_000_000_000, "valued at the accepted price");
        assertEq(uint8(v.status), uint8(MarketStatus.Offboarding), "Offboarding");
    }

    // TEST-247 verifies: REQ-LENS-022
    function test_TEST_247_unknownMarketReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 9));
        lens.getMarket(9);
    }

    // TEST-247 verifies: REQ-LENS-045, REQ-LENS-023, REQ-LENS-024
    function test_TEST_247_marketPaging() public {
        MarketView[] memory all = lens.getMarkets(0, 200);
        assertEq(all.length, reg.marketCount(), "every market ID");
        assertEq(all[MARKET_ID - 1].marketId, MARKET_ID, "position p is market p + 1");
        assertEq(all[MARKET_ID - 1].suppliedUnits, 10_000e6, "the full view");
        assertEq(all[0].vaultToken, address(0), "an ID with no listing reports its empty record");
        MarketView[] memory one = lens.getMarkets(MARKET_ID - 1, 1);
        assertEq(one.length, 1, "one");
        assertEq(keccak256(abi.encode(one[0])), keccak256(abi.encode(lens.getMarket(MARKET_ID))), "= getMarket");
        assertEq(lens.getMarkets(0, 0).length, 0, "limit 0");
        assertEq(lens.getMarkets(MARKET_ID, 200).length, 0, "offset = n");
        assertEq(lens.getMarkets(type(uint256).max, 200).length, 0, "offset max");
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.LimitTooHigh.selector, 201));
        lens.getMarkets(0, 201);
    }

    // ─── debt reserves ───

    // TEST-247 verifies: REQ-LENS-046, REQ-LENS-005
    function test_TEST_247_debtReserveTotalsAndRates() public {
        _borrow(aliceProxy, 6000e18);
        vm.warp(block.timestamp + 30 days);
        DebtReserveView memory v = lens.getDebtReserve(aave.cdpSpoke, debtReserveId);
        assertEq(v.blockNumber, block.number, "block");
        assertEq(v.spoke, aave.cdpSpoke, "Spoke");
        assertEq(v.reserveId, debtReserveId, "reserve");
        assertEq(v.asset, address(debt), "GHO");
        assertEq(v.decimals, 18, "decimals");
        assertEq(v.price, 1e8, "price");
        assertTrue(v.fixedPrice, "fixed");
        assertEq(v.hub, aave.hub, "funding Hub");
        assertEq(v.hubAssetId, ghoAssetId, "asset");
        IAaveV4Hub hub = IAaveV4Hub(aave.hub);
        assertEq(v.added, hub.getAddedAssets(ghoAssetId), "added");
        assertEq(v.liquidity, hub.getAssetLiquidity(ghoAssetId), "liquidity");
        assertGt(v.drawn, 6000e18 - 1, "drawn with interest");
        uint256 owed = v.drawn + v.premium;
        assertEq(v.utilizationBps, owed * 1e4 / v.added, "utilization, rounded down");
        assertGt(v.drawnRateRay, 0, "a positive drawn rate at this utilization");
        assertEq(v.supplyRateRay, Math.mulDiv(v.drawnRateRay, owed * 1e4, v.added * 1e4), "no liquidity fee");
        assertLe(v.supplyRateRay, v.drawnRateRay, "suppliers never earn more than borrowers pay");
    }

    // TEST-247 verifies: REQ-LENS-046
    function test_TEST_247_debtReserveRateCurveAndFee() public {
        _borrow(aliceProxy, 6000e18);
        _hubConfig(abi.encodeWithSignature("updateLiquidityFee(address,uint256,uint256)", aave.hub, ghoAssetId, 1000));
        DebtReserveView memory v = lens.getDebtReserve(aave.cdpSpoke, debtReserveId);
        assertEq(v.optimalUsageBps, 9000, "optimal usage");
        assertEq(v.baseDrawnRateBps, 0, "base");
        assertEq(v.rateGrowthBeforeOptimalBps, 400, "slope before");
        assertEq(v.rateGrowthAfterOptimalBps, 6000, "slope after");
        assertEq(v.liquidityFeeBps, 1000, "10 % fee");
        uint256 owed = v.drawn + v.premium;
        assertEq(
            v.supplyRateRay, Math.mulDiv(v.drawnRateRay, owed * 9000, v.added * 1e4), "the fee share is not paid out"
        );
    }

    // TEST-247 verifies: REQ-LENS-046, REQ-LENS-019
    function test_TEST_247_debtReserveCapsAndFlags() public {
        _borrowUsdc(aliceProxy, 300e6);
        _setReservePaused(usdcReserveId, true);
        rm.setDebtBreaker(aave.cdpSpoke, usdcReserveId, 32, type(uint64).max);
        DebtReserveView memory v = lens.getDebtReserve(aave.cdpSpoke, usdcReserveId);
        assertEq(v.asset, address(usdc), "USDC");
        assertFalse(v.fixedPrice, "DebtOracle");
        assertEq(v.price, 0.9999e8, "served price");
        assertEq(v.drawCap, 500_000, "draw cap, whole units");
        assertEq(v.drawHeadroom, 500_000e6 - 300e6, "headroom");
        assertTrue(v.paused, "paused");
        assertTrue(v.borrowable, "borrowable");
        assertFalse(v.frozen, "not frozen");
        assertEq(v.breakerReasons, 32, "DEFICIT");
        assertEq(uint8(v.pauseState), uint8(PauseState.None), "the funding Hub's pause state");
    }

    // TEST-247 verifies: REQ-LENS-046
    function test_TEST_247_debtReservesListAndEmptyHub() public {
        DebtReserveView[] memory all = lens.getDebtReserves(aave.cdpSpoke);
        assertEq(all.length, 2, "both enabled reserves");
        assertEq(all[0].reserveId, debtReserveId, "registry order");
        assertEq(all[1].reserveId, usdcReserveId, "USDC");
        assertEq(lens.getDebtReserves(aave.lendSpoke).length, 0, "a Spoke with no enabled reserve");
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAddedAssets(uint256)", usdcAssetId), abi.encode(0));
        DebtReserveView memory v = lens.getDebtReserve(aave.cdpSpoke, usdcReserveId);
        assertEq(v.utilizationBps, 0, "no added assets: 0");
        assertEq(v.supplyRateRay, 0, "no supply rate");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-046, REQ-LENS-032
    function test_TEST_247_unknownDebtReserveReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtReserve.selector, aave.cdpSpoke, 3));
        lens.getDebtReserve(aave.cdpSpoke, 3);
    }
}
