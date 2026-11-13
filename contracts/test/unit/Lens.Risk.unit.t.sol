// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {HubAssetExposureView} from "../../src/lens/lens/types/HubAssetExposureView.sol";
import {TailCoverageView} from "../../src/lens/lens/types/TailCoverageView.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {Market} from "../../src/types/Market.sol";
import {LensFixture} from "../utils/fixtures/LensFixture.sol";

/// @title LensRiskUnitTest
/// @notice Breaker and freeze pass-through, the cap-based tail coverage of SPEC-CAP-008, the uncovered deficit and the
/// (Hub, asset) exposure view on the real Aave V4 Hub.
/// forge-config: default.isolate = false
contract LensRiskUnitTest is LensFixture {
    uint256 internal constant SECOND = 5;

    function setUp() public {
        _deployLens();
        _setDrawCap(ghoAssetId, aave.cdpSpoke, 600_000);
        store.setCaps(MARKET_ID, 1_000_000e8, 20_000e8, 1e8);
        _listSecondMarket(aave.hub, MarketStatus.Active);
    }

    // ─── breakers and freezes ───

    // TEST-228 verifies: REQ-LENS-037, Q-241, Q-399
    function test_TEST_228_breakerStatusPassThrough() public {
        assertEq(_marketReasons(), 0, "nothing blocks");
        rm.setMarketBreaker(MARKET_ID, 4, uint64(block.timestamp + 1800));
        (uint32 reasons, uint64 reopensAt) = lens.getBreakerStatus(MARKET_ID);
        assertEq(reasons, 4, "POOL_SHARE recovering");
        assertEq(reopensAt, block.timestamp + 1800, "lastBreachAt + gateRecoverySeconds");
        rm.setMarketBreaker(MARKET_ID, 4 | 512, type(uint64).max);
        (reasons, reopensAt) = lens.getBreakerStatus(MARKET_ID);
        assertEq(reasons, 516, "MANUAL latched too");
        assertEq(reopensAt, type(uint64).max, "a security freeze reopens only by reset");
    }

    // TEST-228 verifies: REQ-LENS-037, Q-241
    function test_TEST_228_debtBreakerStatusPassThrough() public {
        rm.setDebtBreaker(aave.cdpSpoke, debtReserveId, 32, type(uint64).max);
        (uint32 reasons, uint64 reopensAt) = lens.getDebtBreakerStatus(aave.cdpSpoke, debtReserveId);
        assertEq(reasons, 32, "DEFICIT");
        assertEq(reopensAt, type(uint64).max, "latched");
        (reasons, reopensAt) = lens.getDebtBreakerStatus(aave.cdpSpoke, usdcReserveId);
        assertEq(reasons, 0, "the other reserve is open");
        assertEq(reopensAt, 0, "nothing blocks");
    }

    // TEST-229 verifies: REQ-LENS-037, Q-242
    function test_TEST_229_isFrozenAddress() public {
        assertFalse(lens.isFrozenAddress(alice), "not frozen");
        reg.setFrozen(alice, true);
        assertTrue(lens.isFrozenAddress(alice), "frozen chain-wide");
        assertFalse(lens.isFrozenAddress(bob), "others unaffected");
        reg.setFrozen(alice, false);
        assertFalse(lens.isFrozenAddress(alice), "unfrozen");
    }

    // ─── tail coverage ───

    // TEST-247 verifies: REQ-LENS-034, SPEC-CAP-008, REQ-LENS-005, Q-249
    function test_TEST_247_tailCoverageWorstToken() public view {
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.blockNumber, block.number, "block");
        assertEq(t.hub, aave.hub, "Hub");
        assertEq(t.debtAsset, address(debt), "asset");
        assertEq(t.coverageSpoke, address(ghoCov), "the reserve's Coverage Spoke");
        assertEq(t.funded, 100_000e18, "funded");
        assertEq(t.minimum, 100_000e18, "minimum");
        assertEq(t.fundedUsd, 100_000e8, "at $1.00");
        assertEq(t.drawCapUsd, 600_000e8, "600,000 GHO of draw caps");
        // USDC: $300,000 cap + $20,000 slice; USDT: $250,000 + $20,000 + $10,000; both at CF 80 %.
        assertEq(t.worstToken, address(usdc), "USDC has the largest tail");
        assertEq(t.tailUsd, 256_000e8, "320,000 x 0.8");
        assertEq(t.ratioBps, 3906, "floor(100,000 x 1e4 / 256,000)");
    }

    // TEST-247 verifies: REQ-LENS-034, SPEC-CAP-008
    function test_TEST_247_tailCoverageCappedByDrawCaps() public {
        _setDrawCap(ghoAssetId, aave.cdpSpoke, 1000);
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.drawCapUsd, 1000e8, "$1,000 of draw caps");
        assertEq(t.tailUsd, 1000e8, "every tail capped");
        assertEq(t.worstToken, address(usdc), "first in listing order on a tie");
        assertEq(t.ratioBps, 1_000_000, "100,000 / 1,000");
    }

    // TEST-247 verifies: REQ-LENS-034
    function test_TEST_247_tailCoverageUnlimitedDrawCap() public {
        _setDrawCap(ghoAssetId, aave.cdpSpoke, type(uint40).max);
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.drawCapUsd, type(uint256).max, "not summed, never overflows");
        assertEq(t.tailUsd, 256_000e8, "tails are the capped exposures");
    }

    // TEST-247 verifies: REQ-LENS-034, SPEC-CAP-008
    function test_TEST_247_tailCoverageSlicesAndUsdtTail() public {
        store.setTokenCap(aave.hub, address(usdc), 100_000e8);
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.worstToken, address(usdt), "USDT now the largest");
        assertEq(t.tailUsd, 224_000e8, "(250,000 + 20,000 + 10,000) x 0.8");
    }

    // TEST-247 verifies: REQ-LENS-034
    function test_TEST_247_tailCoverageTokenCapPerHomeHub() public {
        address hub2 = makeAddr("homeHub2");
        _listSecondMarket(hub2, MarketStatus.Active);
        store.setTokenCap(hub2, address(usdt), 100_000e8);
        store.setTokenCap(aave.hub, address(usdc), 0);
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.worstToken, address(usdt), "USDT");
        assertEq(t.tailUsd, 312_000e8, "(250,000 + 100,000, once per home Hub, + 40,000 of slices) x 0.8");
    }

    // TEST-247 verifies: REQ-LENS-034
    function test_TEST_247_tailCoverageSkipsUnlistedMarkets() public {
        reg.setStatus(SECOND, uint8(MarketStatus.Closed));
        assertEq(lens.getTailCoverage(aave.hub, address(debt)).tailUsd, 256_000e8, "USDC unchanged");
        store.setTokenCap(aave.hub, address(usdc), 0);
        assertEq(
            lens.getTailCoverage(aave.hub, address(debt)).tailUsd, 216_000e8, "USDT without the closed market's slice"
        );
        reg.setStatus(SECOND, uint8(MarketStatus.Offboarding));
        assertEq(lens.getTailCoverage(aave.hub, address(debt)).tailUsd, 224_000e8, "an offboarding market counts");
    }

    // TEST-247 verifies: REQ-LENS-034
    function test_TEST_247_tailCoverageZeroTail() public {
        store.setTokenCap(aave.hub, address(usdc), 0);
        store.setTokenCap(aave.hub, address(usdt), 0);
        store.setCaps(MARKET_ID, 1_000_000e8, 0, 1e8);
        store.setCaps(SECOND, 1_000_000e8, 0, 1e8);
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(debt));
        assertEq(t.tailUsd, 0, "no exposure");
        assertEq(t.ratioBps, type(uint256).max, "ratio unbounded");
        assertEq(t.worstToken, address(0), "no worst token");
    }

    // TEST-247 verifies: REQ-LENS-034, REQ-LENS-039
    function test_TEST_247_tailCoverageUnknownDebtAsset() public {
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtAsset.selector, address(usdt)));
        lens.getTailCoverage(aave.hub, address(usdt));
        vm.expectRevert(abi.encodeWithSelector(ILensErrors.UnknownDebtAsset.selector, address(debt)));
        lens.getTailCoverage(makeAddr("otherHub"), address(debt));
    }

    // TEST-247 verifies: REQ-LENS-034
    function test_TEST_247_tailCoverageUsdcDebtExcludesUsdcLeg() public view {
        TailCoverageView memory t = lens.getTailCoverage(aave.hub, address(usdc));
        assertEq(t.coverageSpoke, address(usdcCov), "USDC Coverage Spoke");
        assertEq(t.worstToken, address(usdt), "the debt asset itself has no tail");
        assertEq(t.drawCapUsd, 500_000 * 0.9999e8, "draw caps at the served price");
        assertEq(t.fundedUsd, 50_000 * 0.9999e8, "funded at the served price, rounded down");
    }

    // ─── uncovered deficit and exposure ───

    // TEST-247 verifies: REQ-LENS-042, Q-353
    function test_TEST_247_uncoveredDeficitExample() public {
        // Base units: deficits of 1,500,000.4 and 2,800,000 against 4,000,000 funded.
        _deficit(aave.cdpSpoke, 1_500_000.4e27);
        _deficit(aave.lendSpoke, 2_800_000e27);
        ghoCov.set(4_000_000, 100_000e18);
        assertEq(lens.uncoveredDeficit(aave.hub, address(debt)), 300_001, "1,500,001 + 2,800,000 - 4,000,000");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-042
    function test_TEST_247_uncoveredDeficitCoveredIsZero() public {
        _deficit(aave.cdpSpoke, 10_000e18 * 1e27);
        assertEq(lens.uncoveredDeficit(aave.hub, address(debt)), 0, "within the funded reserve");
        reg.setCoverageSpoke(aave.hub, address(debt), address(0));
        assertEq(lens.uncoveredDeficit(aave.hub, address(debt)), 10_000e18, "no Coverage Spoke: all uncovered");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-042
    function test_TEST_247_uncoveredDeficitRoundsUp() public {
        _deficit(aave.cdpSpoke, 1);
        reg.setCoverageSpoke(aave.hub, address(debt), address(0));
        assertEq(lens.uncoveredDeficit(aave.hub, address(debt)), 1, "a sub-unit deficit counts one unit");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-043, REQ-LENS-005, Q-353
    function test_TEST_247_hubAssetExposure() public {
        _borrow(_openAlice(), 4000e18);
        HubAssetExposureView memory v = lens.getHubAssetExposure(aave.hub, address(debt));
        assertEq(v.blockNumber, block.number, "block");
        assertEq(v.hub, aave.hub, "Hub");
        assertEq(v.asset, address(debt), "asset");
        assertEq(v.coverageSpoke, address(ghoCov), "Coverage Spoke");
        assertEq(v.fundedBalance, 100_000e18, "funded");
        assertEq(v.line, 2_000_000, "credit line");
        assertFalse(v.coverageBoundHolds, "2,000,000 x 10 % > 100,000");
        assertEq(v.uncovered, 0, "no deficit");
        uint256 n = IAaveV4Hub(aave.hub).getSpokeCount(ghoAssetId);
        assertEq(v.spokes.length, n, "every Spoke on the asset");
        bool seen = false;
        for (uint256 i = 0; i < n; ++i) {
            if (v.spokes[i].spoke != aave.cdpSpoke) continue;
            seen = true;
            assertEq(v.spokes[i].homeHub, aave.hub, "home Hub of the CDP Spoke");
            assertEq(v.spokes[i].drawCap, 600_000, "draw cap");
            assertEq(v.spokes[i].drawn, 4000e18, "drawn");
            assertEq(v.spokes[i].deficit, 0, "deficit");
        }
        assertTrue(seen, "the CDP Spoke is listed");
    }

    // TEST-247 verifies: REQ-LENS-043, REQ-CONFIG-081
    function test_TEST_247_hubAssetExposureBoundAndPrice() public {
        ghoCov.set(200_000e18, 100_000e18);
        assertTrue(lens.getHubAssetExposure(aave.hub, address(debt)).coverageBoundHolds, "exactly at the bound");
        ghoCov.set(4_000_000, 100_000e18);
        _deficit(aave.cdpSpoke, 1_500_000.4e27);
        _deficit(aave.lendSpoke, 2_800_000e27);
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAddedAssets(uint256)", ghoAssetId), abi.encode(50_000_000));
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAddedShares(uint256)", ghoAssetId), abi.encode(48_000_000));
        HubAssetExposureView memory v = lens.getHubAssetExposure(aave.hub, address(debt));
        assertEq(v.uncovered, 300_001, "uncovered");
        assertEq(v.priceAdj, 1_035_416_645_833_333_333, "floor((A - uncovered) x 1e18 / Sh)");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-043
    function test_TEST_247_hubAssetExposureNoSharesOrDeficitAboveAssets() public {
        vm.mockCall(aave.hub, abi.encodeWithSignature("getAddedShares(uint256)", ghoAssetId), abi.encode(0));
        assertEq(lens.getHubAssetExposure(aave.hub, address(debt)).priceAdj, 0, "no share: 0");
        vm.clearMockedCalls();
        reg.setCoverageSpoke(aave.hub, address(debt), address(0));
        _deficit(aave.cdpSpoke, 2_000_000e18 * 1e27);
        assertEq(lens.getHubAssetExposure(aave.hub, address(debt)).priceAdj, 0, "deficit above the assets: 0");
        vm.clearMockedCalls();
    }

    // TEST-247 verifies: REQ-LENS-042, REQ-LENS-022
    function test_TEST_247_unknownHubAssetReverts() public {
        vm.expectRevert();
        lens.uncoveredDeficit(aave.hub, makeAddr("notAnAsset"));
    }

    // ─── helpers ───

    function _marketReasons() internal view returns (uint32 reasons) {
        (reasons,) = lens.getBreakerStatus(MARKET_ID);
    }

    function _openAlice() internal returns (address) {
        _open(alice, aliceProxy, 1, 10_000e6);
        return aliceProxy;
    }

    /// @dev A registry-only second market (USDT/GHO) on the same CDP Spoke and vault-token reserve, slice $10,000.
    function _listSecondMarket(
        address homeHub,
        MarketStatus status
    ) internal {
        Market memory m = reg.getMarket(MARKET_ID);
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (address(usdt), address(debt));
        (m.tokens, m.hub, m.status) = (tokens, homeHub, status);
        m.vaultToken = makeAddr(string(abi.encode("secondVaultToken", homeHub)));
        uint256 id = reg.marketCount() + 1;
        reg.setMarket(id, m);
        store.setCaps(id, 1_000_000e8, 10_000e8, 1e8);
    }

    function _deficit(
        address spoke,
        uint256 ray
    ) internal {
        vm.mockCall(
            aave.hub, abi.encodeWithSignature("getSpokeDeficitRay(uint256,address)", ghoAssetId, spoke), abi.encode(ray)
        );
    }
}
