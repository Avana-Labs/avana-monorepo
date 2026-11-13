// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../src/amm/IAmmIntegration.sol";
import {FeeMode} from "../../src/amm/types/FeeMode.sol";
import {IntegrationCapabilities} from "../../src/amm/types/IntegrationCapabilities.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {PositionFeesView} from "../../src/lens/lens/types/PositionFeesView.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {LensFeesV3Fixture, LensRecordsStub} from "../utils/fixtures/LensFeesFixture.sol";
import {AaveAdapterLensMock} from "../utils/mocks/AaveAdapterLensMock.sol";
import {MintableToken, MockNFPM} from "../utils/mocks/UniswapV3Mocks.sol";

/// @title LensFeesUnitTest
/// @notice `getPositionFees` and `getAccountFees` on the real Uniswap v3 LPVault: for a position below, inside and above
/// its range, after an earlier collect and across a fee-growth wrap, the Lens's amounts equal what the LPVault's
/// `collectFees` pays the depositor in the same block.
/// forge-config: default.isolate = false
contract LensFeesUnitTest is LensFeesV3Fixture {
    uint256 internal constant Q128 = 1 << 128;
    uint128 internal constant L = 2e12;

    address internal aliceProxy = makeAddr("aliceProxy");

    /// @dev Collects through the LPVault as Collateralization and returns what the depositor received.
    function _collect(
        bytes32 key,
        address depositor
    ) internal returns (uint256[2] memory got) {
        uint256 b0 = _token0().balanceOf(depositor);
        uint256 b1 = _token1().balanceOf(depositor);
        uint256[] memory paid = abi.decode(_asColl(abi.encodeCall(vault.collectFees, (key, depositor))), (uint256[]));
        got = [_token0().balanceOf(depositor) - b0, _token1().balanceOf(depositor) - b1];
        assertEq(paid[0], got[0], "returned = received, token0");
        assertEq(paid[1], got[1], "returned = received, token1");
    }

    function _assertMatches(
        bytes32 key
    ) internal returns (PositionFeesView memory f) {
        f = lens.getPositionFees(M1, key);
        assertTrue(f.supported, "supported");
        uint256[2] memory got = _collect(key, alice);
        assertEq(f.amounts[0], got[0], "token0 = collectFees");
        assertEq(f.amounts[1], got[1], "token1 = collectFees");
    }

    // ─── equality with collectFees ───

    // TEST-247 verifies: REQ-LENS-050, REQ-LENS-005
    function test_TEST_247_inRangeFeesEqualCollect() public {
        bytes32 key = _pledge1(alice, L);
        pool500.setPrice(0);
        // Global growth of 3 and 5 units per unit of liquidity, of which 1 and 2 accrued below the range.
        pool500.setFeeGrowthGlobal(3 * Q128, 5 * Q128);
        pool500.setFeeGrowthOutside(M1_LOWER, Q128, 2 * Q128);
        PositionFeesView memory f = _assertMatches(key);
        assertEq(f.amounts[0], 2 * uint256(L), "inside growth 2 x L");
        assertEq(f.amounts[1], 3 * uint256(L), "inside growth 3 x L");
        assertEq(f.blockNumber, block.number, "block");
        assertEq(f.timestamp, block.timestamp, "time");
        assertEq(f.marketId, M1, "market");
        assertEq(f.positionKey, key, "key");
        assertEq(f.liquidity, L, "liquidity");
        assertTrue(f.inCustody, "custody");
        assertEq(f.depositor, alice, "depositor");
        assertEq(f.tokensOwed[0], 0, "nothing owed yet");
        assertEq(lens.getPositionFees(M1, key).amounts[0], 0, "collected");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_belowRangeUsesGrowthBelowLower() public {
        bytes32 key = _pledge1(alice, L);
        pool500.setPrice(-60);
        // Below the range: inside = outside(lower) - outside(upper) for a tick below both.
        pool500.setFeeGrowthGlobal(10 * Q128, 10 * Q128);
        pool500.setFeeGrowthOutside(M1_LOWER, 7 * Q128, 6 * Q128);
        pool500.setFeeGrowthOutside(M1_UPPER, 3 * Q128, 5 * Q128);
        PositionFeesView memory f = _assertMatches(key);
        assertEq(f.amounts[0], 4 * uint256(L), "7 - 3");
        assertEq(f.amounts[1], 1 * uint256(L), "6 - 5");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_aboveRangeUsesGrowthAboveUpper() public {
        bytes32 key = _pledge1(alice, L);
        pool500.setPrice(60);
        pool500.setFeeGrowthGlobal(10 * Q128, 10 * Q128);
        pool500.setFeeGrowthOutside(M1_LOWER, 2 * Q128, 1 * Q128);
        pool500.setFeeGrowthOutside(M1_UPPER, 9 * Q128, 4 * Q128);
        PositionFeesView memory f = _assertMatches(key);
        assertEq(f.amounts[0], 7 * uint256(L), "9 - 2");
        assertEq(f.amounts[1], 3 * uint256(L), "4 - 1");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_tickAtBoundsCountsAsInsideAtLowerAndAboveAtUpper() public {
        bytes32 key = _pledge1(alice, L);
        pool500.setFeeGrowthGlobal(10 * Q128, 10 * Q128);
        pool500.setFeeGrowthOutside(M1_LOWER, 2 * Q128, 2 * Q128);
        pool500.setFeeGrowthOutside(M1_UPPER, 3 * Q128, 3 * Q128);
        pool500.setPrice(M1_LOWER);
        assertEq(lens.getPositionFees(M1, key).amounts[0], 5 * uint256(L), "at lower: 10 - 2 - 3");
        pool500.setPrice(M1_UPPER);
        assertEq(lens.getPositionFees(M1, key).amounts[0], 1 * uint256(L), "at upper: outside(upper) - outside(lower)");
        _assertMatches(key);
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_growthSinceLastCollectAndOwedTokens() public {
        bytes32 key = _pledge1(alice, L);
        pool500.setFeeGrowthGlobal(4 * Q128, 4 * Q128);
        _collect(key, alice);
        // Only growth after the collect counts, plus owed tokens credited to the position.
        pool500.setFeeGrowthGlobal(6 * Q128, 9 * Q128);
        nfpm.accrue(uint256(key), 1234, 5678);
        PositionFeesView memory f = _assertMatches(key);
        assertEq(f.tokensOwed[0], 1234, "owed 0");
        assertEq(f.tokensOwed[1], 5678, "owed 1");
        assertEq(f.amounts[0], 2 * uint256(L) + 1234, "growth 2 + owed");
        assertEq(f.amounts[1], 5 * uint256(L) + 5678, "growth 5 + owed");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_fractionalGrowthRoundsDownAsTheManager() public {
        bytes32 key = _pledge1(alice, 3);
        // 3 x (Q128 / 2 + 1) / Q128 = 1.5 + tiny: floored to 1.
        pool500.setFeeGrowthGlobal(Q128 / 2 + 1, Q128 - 1);
        PositionFeesView memory f = _assertMatches(key);
        assertEq(f.amounts[0], 1, "floor");
        assertEq(f.amounts[1], 2, "3 x (1 - 2^-128) floors to 2");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_feeGrowthWrapsAsInTheSources() public {
        bytes32 key = _pledge1(alice, L);
        // Snapshot near the top of uint256, then wrap past zero: the difference is taken mod 2^256.
        uint256 high = type(uint256).max - 2 * Q128 + 1;
        pool500.setFeeGrowthGlobal(high, high);
        _collect(key, alice);
        pool500.setFeeGrowthGlobal(Q128, 3 * Q128);
        PositionFeesView memory f = _assertMatches(key);
        assertEq(f.amounts[0], 3 * uint256(L), "wrap: 1 - (-2) = 3");
        assertEq(f.amounts[1], 5 * uint256(L), "wrap: 3 - (-2) = 5");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_outsideAboveGlobalWrapsBelowAndAbove() public {
        bytes32 key = _pledge1(alice, L);
        pool500.setPrice(-60);
        // Outside values above the global (initialized when the tick was below): global - outside wraps.
        pool500.setFeeGrowthGlobal(2 * Q128, 2 * Q128);
        pool500.setFeeGrowthOutside(M1_LOWER, 5 * Q128, 5 * Q128);
        pool500.setFeeGrowthOutside(M1_UPPER, 4 * Q128, 4 * Q128);
        PositionFeesView memory f = _assertMatches(key);
        assertEq(f.amounts[0], uint256(L), "5 - 4");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_noLiquidityReportsOwedOnly() public {
        bytes32 key = _pledge1(alice, L);
        nfpm.accrue(uint256(key), 77, 88);
        // The position manager skips the fee update of an empty position; the Lens reads the owed tokens alone.
        vm.mockCall(
            address(nfpm),
            abi.encodeWithSignature("positions(uint256)", uint256(key)),
            abi.encode(0, 0, pool500.token0(), pool500.token1(), uint24(500), M1_LOWER, M1_UPPER, 0, 0, 0, 77, 88)
        );
        pool500.setFeeGrowthGlobal(9 * Q128, 9 * Q128);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        vm.clearMockedCalls();
        assertEq(f.liquidity, 0, "empty");
        assertEq(f.amounts[0], 77, "owed 0 only");
        assertEq(f.amounts[1], 88, "owed 1 only");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_positionOutOfCustodyStillReported() public {
        bytes32 key = _mint1(alice, L);
        pool500.setFeeGrowthGlobal(Q128, Q128);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        assertTrue(f.supported, "a position of the market's pool");
        assertFalse(f.inCustody, "not pledged");
        assertEq(f.depositor, address(0), "no depositor");
        assertEq(f.amounts[0], uint256(L), "growth since mint");
        vm.prank(alice);
        (uint256 a0,) = nfpm.collect(MockNFPM.CollectParams(uint256(key), alice, type(uint128).max, type(uint128).max));
        assertEq(a0, f.amounts[0], "the owner's own collect");
    }

    // ─── unsupported ───

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_otherPoolOrFeeTierIsUnsupported() public {
        bytes32 key = _mint(alice, pool3000, -60, 60, L);
        pool3000.setFeeGrowthGlobal(Q128, Q128);
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        assertFalse(f.supported, "fee tier 3000 is not market 1's");
        assertEq(f.amounts.length, 2, "one entry per pool token");
        assertEq(f.amounts[0] + f.amounts[1], 0, "no amounts");
        // Same fee tier, other pair.
        MintableToken other = new MintableToken("DAI", 18);
        // No pool of these pairs exists, so the stand-in cannot snapshot their fee growth at mint.
        nfpm.setTrackFees(false);
        uint256 id = nfpm.mint(alice, address(other), pool500.token1(), 500, M1_LOWER, M1_UPPER, L);
        assertFalse(lens.getPositionFees(M1, bytes32(id)).supported, "token0 differs");
        id = nfpm.mint(alice, pool500.token0(), address(other), 500, M1_LOWER, M1_UPPER, L);
        assertFalse(lens.getPositionFees(M1, bytes32(id)).supported, "token1 differs");
    }

    // TEST-247 verifies: REQ-LENS-050
    function test_TEST_247_unknownProtocolOrRolledInFeesAreUnsupported() public {
        bytes32 key = _pledge1(alice, L);
        pool500.setFeeGrowthGlobal(Q128, Q128);
        vm.mockCall(address(vault), abi.encodeCall(IAmmIntegration.AMM_PROTOCOL, ()), abi.encode(keccak256("CURVE")));
        PositionFeesView memory f = lens.getPositionFees(M1, key);
        assertFalse(f.supported, "no fee reader");
        assertTrue(f.inCustody, "custody still reported");
        assertEq(f.amounts[0], 0, "no amount");
        vm.clearMockedCalls();
        IntegrationCapabilities memory caps = vault.capabilities();
        caps.feeMode = FeeMode.RolledIn;
        vm.mockCall(address(vault), abi.encodeCall(IAmmIntegration.capabilities, ()), abi.encode(caps));
        assertFalse(lens.getPositionFees(M1, key).supported, "fees roll into the position");
        vm.clearMockedCalls();
        assertTrue(lens.getPositionFees(M1, key).supported, "back to separate fees");
    }

    // ─── accounts ───

    // TEST-247 verifies: REQ-LENS-051, REQ-LENS-005
    function test_TEST_247_accountFeesFollowTheRecordsInOrder() public {
        bytes32 k1 = _pledge1(alice, L);
        bytes32 k2 = _pledge1(alice, 3 * L);
        AaveAdapterLensMock(adapter).bind(alice, aliceProxy, address(0x5509E), M1, address(0x7777), 1);
        bytes32[] memory keys = new bytes32[](2);
        (keys[0], keys[1]) = (k2, k1);
        LensRecordsStub(coll).setRecords(aliceProxy, keys);
        pool500.setFeeGrowthGlobal(Q128, 2 * Q128);
        PositionFeesView[] memory fs = lens.getAccountFees(alice, M1);
        assertEq(fs.length, 2, "two records");
        assertEq(fs[0].positionKey, k2, "seizure-list order");
        assertEq(fs[0].amounts[0], 3 * uint256(L), "record 1");
        assertEq(fs[1].amounts[1], 2 * uint256(L), "record 2");
        assertEq(abi.encode(fs[1]), abi.encode(lens.getPositionFees(M1, k1)), "same as getPositionFees");
        uint256[2] memory got = _collect(k2, alice);
        assertEq(got[1], fs[0].amounts[1], "collectFees of record 1");
    }

    // TEST-247 verifies: REQ-LENS-051
    function test_TEST_247_accountWithNoRecordsHasNoFees() public {
        AaveAdapterLensMock(adapter).bind(alice, aliceProxy, address(0x5509E), M1, address(0x7777), 1);
        assertEq(lens.getAccountFees(alice, M1).length, 0, "no records");
    }

    // ─── failures ───

    // TEST-247 verifies: REQ-LENS-006, REQ-LENS-021, REQ-LENS-022
    function test_TEST_247_lockedAndUnknownMarketRevert() public {
        bytes32 key = _pledge1(alice, L);
        _lock();
        vm.expectRevert(ILensErrors.Locked.selector);
        lens.getPositionFees(M1, key);
        vm.expectRevert(ILensErrors.Locked.selector);
        lens.getAccountFees(alice, M1);
        _unlock();
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 9));
        lens.getPositionFees(9, key);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownMarket.selector, 9));
        lens.getAccountFees(alice, 9);
    }
}
