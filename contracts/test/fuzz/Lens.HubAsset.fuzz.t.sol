// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {HubAssetView} from "../../src/lens/lens/types/HubAssetView.sol";
import {MarketView} from "../../src/lens/lens/types/MarketView.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensHubAssetFuzzTest
/// @notice For any borrows by two accounts, liquidity fee, collateral risk and time: the Spoke slices of every Hub asset
/// add up to the Hub's figures, the Hub balances, the supply rate never exceeds the drawn rate, and the market's borrow
/// rate is the rate each of its accounts pays.
/// forge-config: default.isolate = false
contract LensHubAssetFuzzTest is LensFixture {
    uint256 internal constant VIRTUAL = 1e6;

    function setUp() public {
        _deployLens();
    }

    function _world(
        uint256 a,
        uint256 b,
        uint256 fee,
        uint256 risk,
        uint256 dt
    ) internal {
        _open(alice, aliceProxy, 1, 200_000e6);
        _open(bob, bobProxy, 2, 100_000e6);
        risk = bound(risk, 0, 10_000);
        _spokeConfig(
            abi.encodeWithSignature("updateCollateralRisk(address,uint256,uint256)", aave.cdpSpoke, vtReserveId, risk)
        );
        _hubConfig(
            abi.encodeWithSignature(
                "updateLiquidityFee(address,uint256,uint256)", aave.hub, ghoAssetId, bound(fee, 0, 5000)
            )
        );
        _borrow(aliceProxy, bound(a, 1, 150_000e18));
        _borrowUsdc(aliceProxy, bound(b, 0, 100_000e6) + 1);
        _borrow(bobProxy, bound(b, 1, 80_000e18));
        vm.warp(block.timestamp + bound(dt, 1, 720 days));
    }

    function _check(
        HubAssetView memory v
    ) internal pure {
        uint256 n = v.spokes.length;
        uint256[5] memory sum;
        for (uint256 i = 0; i < n; ++i) {
            sum[0] += v.spokes[i].added;
            sum[1] += v.spokes[i].addedShares;
            sum[2] += v.spokes[i].drawn;
            sum[3] += v.spokes[i].drawnShares;
            sum[4] += v.spokes[i].premiumShares;
            assertEq(v.spokes[i].drawnOwed + v.spokes[i].premiumOwed, v.spokes[i].drawn, "slice owed split");
        }
        assertEq(sum[1], v.addedShares, "added shares");
        assertEq(sum[3], v.drawnShares, "drawn shares");
        assertEq(sum[4], v.premiumShares, "premium shares");
        assertLe(sum[0], v.added, "added assets round down");
        uint256 virtualPart = VIRTUAL * (v.added - v.addedShares) / (v.addedShares + VIRTUAL) + 1;
        assertGe(sum[0] + n + virtualPart, v.added, "within a unit per Spoke and the virtual share");
        assertGe(sum[2], v.owed, "owed rounds up per Spoke");
        assertLe(sum[2], v.owed + 2 * n, "within two units per Spoke");
        assertApproxEqAbs(v.added + v.accruedFees, v.liquidity + v.swept + v.owed + v.deficit, 3, "Hub balance");
        assertLe(v.supplyRateRay, v.drawnRateRay, "suppliers never earn more than borrowers pay");
        assertEq(v.drawn + v.premium, v.owed, "owed split");
    }

    // TEST-247 verifies: REQ-LENS-059, REQ-LENS-058
    function testFuzz_TEST_247_slicesAddUpToTheHub(
        uint256 a,
        uint256 b,
        uint256 fee,
        uint256 risk,
        uint256 dt
    ) public {
        _world(a, b, fee, risk, dt);
        _check(lens.getHubAsset(aave.hub, ghoAssetId));
        _check(lens.getHubAsset(aave.hub, usdcAssetId));
        _check(lens.getHubAsset(aave.hub, vtAssetId));
    }

    // TEST-247 verifies: REQ-LENS-057, REQ-LENS-047
    function testFuzz_TEST_247_marketRateIsEveryAccountsRate(
        uint256 a,
        uint256 b,
        uint256 fee,
        uint256 risk,
        uint256 dt
    ) public {
        _world(a, b, fee, risk, dt);
        MarketView memory m = lens.getMarket(MARKET_ID);
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(aliceProxy).riskPremium, m.collateralRiskBps, "rp");
        assertEq(lens.getAccountRisk(alice, MARKET_ID).borrowRatesRay, m.borrowRatesRay, "Alice pays the market rate");
        assertEq(lens.getAccountRisk(bob, MARKET_ID).borrowRatesRay, m.borrowRatesRay, "so does Bob");
    }
}
