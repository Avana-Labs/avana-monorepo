// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILensHubReads} from "../../src/lens/lens/ILensHubReads.sol";
import {AccountRiskView} from "../../src/lens/lens/types/AccountRiskView.sol";
import {MarketView} from "../../src/lens/lens/types/MarketView.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensMarketRiskUnitTest
/// @notice The risk configuration `getMarket` adds for the market pages (REQ-LENS-057): collateral risk, liquidation fee
/// and configuration, hard floor, Avana's caps, the Hub's add cap and the market's borrow rate per debt reserve, which
/// equals the rate of every account of the market.
/// forge-config: default.isolate = false
contract LensMarketRiskUnitTest is LensFixture {
    function setUp() public {
        _deployLens();
    }

    function _setRisk(
        uint256 bps
    ) internal {
        _spokeConfig(
            abi.encodeWithSignature("updateCollateralRisk(address,uint256,uint256)", aave.cdpSpoke, vtReserveId, bps)
        );
    }

    // TEST-247 verifies: REQ-LENS-057, REQ-LENS-045
    function test_TEST_247_marketRiskConfiguration() public {
        _setRisk(1500);
        store.setHardHealthFloor(MARKET_ID, 1.05e18);
        MarketView memory v = lens.getMarket(MARKET_ID);
        assertEq(v.collateralRiskBps, 1500, "collateral risk");
        assertEq(v.liquidationFeeBps, 0, "the required liquidation fee");
        assertEq(v.targetHealthFactor, 1.1e18, "target health factor");
        assertEq(v.healthFactorForMaxBonus, 0.95e18, "health factor for the maximum bonus");
        assertEq(v.liquidationBonusFactorBps, 5000, "bonus factor");
        assertEq(v.hardHealthFloor, 1.05e18, "hard floor");
        assertEq(v.marketUsdCap, 1_000_000e8, "market cap");
        assertEq(v.topUpSliceUsd, 100_000e8, "top-up slice");
        assertEq(v.depositorUsdCap, 500_000e8, "the Hub's depositor cap");
        assertEq(v.tokenUsdCaps.length, 2, "one cap per pool token");
        assertEq(v.tokenUsdCaps[0], 300_000e8, "USDC");
        assertEq(v.tokenUsdCaps[1], 250_000e8, "USDT");
        assertEq(v.addCap, 5_500_000, "the Hub's add cap of the vault token, whole units");
        assertEq(v.marketHeadroomUsd, v.marketUsdCap, "nothing pledged: the whole cap");
    }

    // TEST-247 verifies: REQ-LENS-057
    function test_TEST_247_marketBorrowRateIsDrawnRateTimesOnePlusCollateralRisk() public {
        _setRisk(1500);
        _open(alice, aliceProxy, 1, 50_000e6);
        _borrow(aliceProxy, 30_000e18);
        _borrowUsdc(aliceProxy, 10_000e6);
        vm.warp(block.timestamp + 40 days);
        MarketView memory v = lens.getMarket(MARKET_ID);
        assertEq(v.debtReserveIds.length, 2, "both debt reserves");
        assertEq(v.debtReserveIds[0], debtReserveId, "GHO");
        assertEq(v.debtReserveIds[1], usdcReserveId, "USDC");
        uint256 drawn = ILensHubReads(aave.hub).getAssetDrawnRate(ghoAssetId);
        assertGt(drawn, 0, "a drawn rate");
        assertEq(v.borrowRatesRay[0], Math.mulDiv(drawn, 11_500, 1e4, Math.Rounding.Ceil), "drawn x 1.15");
        // An account holding only this market pays the same: Aave's risk premium is the reserve's collateral risk.
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy).riskPremium, 1500, "risk premium");
        AccountRiskView memory r = lens.getAccountRisk(alice, MARKET_ID);
        assertEq(r.borrowRatesRay, v.borrowRatesRay, "the market's rate is every account's rate");
    }

    // TEST-247 verifies: REQ-LENS-057
    function test_TEST_247_marketRiskFollowsTheLatestConfiguration() public {
        _spokeConfig(
            abi.encodeWithSignature("addLiquidationFee(address,uint256,uint256)", aave.cdpSpoke, vtReserveId, 150)
        );
        _spokeConfig(
            abi.encodeWithSignature("updateLiquidationTargetHealthFactor(address,uint256)", aave.cdpSpoke, 1.2e18)
        );
        _setAddCap(vtAssetId, aave.cdpSpoke, 777);
        store.setTokenCap(aave.hub, address(usdt), 1e8);
        MarketView memory v = lens.getMarket(MARKET_ID);
        assertEq(v.liquidationFeeBps, 150, "the latest key's fee, which the backing check flags");
        assertEq(v.targetHealthFactor, 1.2e18, "new target");
        assertEq(v.addCap, 777, "new add cap");
        assertEq(v.tokenUsdCaps[1], 1e8, "new USDT cap");
        assertEq(v.collateralRiskBps, 0, "no collateral risk");
        assertEq(v.borrowRatesRay[1], ILensHubReads(aave.hub).getAssetDrawnRate(usdcAssetId), "drawn rate alone");
        MarketView[] memory page = lens.getMarkets(0, 10);
        assertEq(abi.encode(page[MARKET_ID - 1]), abi.encode(v), "the page carries the same view");
    }
}
