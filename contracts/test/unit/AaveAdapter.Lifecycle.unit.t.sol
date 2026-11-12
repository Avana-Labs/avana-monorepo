// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";

/// @dev The SpokeConfigurator call that adds a dynamic configuration key with a new collateral factor (aave-v4 a3ef63e).
interface ILifecycleSpokeConfigurator {
    function addCollateralFactor(
        address spoke,
        uint256 reserveId,
        uint16 collateralFactor
    ) external returns (uint32);
}

/// @title AaveAdapterLifecycleUnitTest
/// @notice The walkthrough of `src/policy/aave-adapter/LIFECYCLE.md` with its numbers, on the real Aave V4 Spoke: one
/// whole vault token is worth $2.00, `CF_LP = 3,120` bps, USDC at $0.9999; Carol pledges `key1` (`L = 10,000,000,000`,
/// $20,000), borrows 5,000 USDC at `minHealthFactor = 1.20e18`, tops up `keyB` (`L = 2,500,000,000`), withdraws
/// `keyB` with debt, repays all, removes 2,000 vault tokens debt-free and closes the account.
/// forge-config: default.isolate = false
contract AaveAdapterLifecycleUnitTest is AaveAdapterFixture {
    uint128 internal constant L1 = 10_000_000_000;
    uint128 internal constant LB = 2_500_000_000;

    function setUp() public override {
        super.setUp();
        vm.prank(aaveDao);
        ILifecycleSpokeConfigurator(aave.spokeConfigurator).addCollateralFactor(aave.cdpSpoke, vtReserveId, 3120);
    }

    function _borrowUsdc(
        uint256 amount,
        uint256 minHf
    ) internal {
        address proxy = adapterC.proxyOf(carol, MARKET_ID);
        uint256 nonce = adapterC.borrowNonce(proxy);
        uint256 d = _deadline();
        vm.prank(carol);
        adapterC.borrow(MARKET_ID, usdcReserveId, amount, carol, d, minHf, nonce);
    }

    // TEST-010 verifies: REQ-ADAPTER-065, REQ-ADAPTER-066, REQ-ADAPTER-068, REQ-PROXY-022, REQ-PROXY-036, SPEC-PROXY-001, SPEC-PROXY-006
    // Sources: LIFECYCLE.md walkthrough steps 1, 2, 3 and 5
    /// @notice Steps 1–3 and 5: after the 5,000 USDC borrow `hf = 6,240 / 4,999.50 = 1.2481`; 5,700 USDC would give
    /// 1.0948 < 1.20; the top-up of `keyB` gives `hf = 7,800 / 4,999.50 = 1.5602`; the with-debt withdrawal of `keyB`
    /// returns it to 1.2481, while withdrawing `key1` instead is refused by Aave.
    function test_TEST_010_walkthroughBorrowSide() public {
        (bytes32 key1, address proxy) = _pledgeAs(carol, MARKET_ID, L1);
        assertEq(_sharesOf(proxy, vtReserveId), L1, "step 1: 10,000,000,000 supplied");
        uint256 snap = vm.snapshotState();
        uint256 d = _deadline();
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.HealthFactorTooLow.selector,
                uint256(6240e26) * 1e18 / (5_700_000_000 * 99_990_000 * 1e12),
                1.2e18
            )
        );
        vm.prank(carol);
        adapterC.borrow(MARKET_ID, usdcReserveId, 5_700_000_000, carol, d, 1.2e18, 0);
        vm.revertToState(snap);
        _borrowUsdc(5_000_000_000, 1.2e18);
        uint256 hf2 = _hf(proxy);
        assertEq(hf2, uint256(6240e26) * 1e18 / (5_000_000_000 * 99_990_000 * 1e12), "step 2: 1.2481");
        assertEq((hf2 + 5e13) / 1e14, 12_481, "1.2481 to four decimals");
        (bytes32 keyB,) = _pledgeAs(carol, MARKET_ID, LB);
        assertEq(_hf(proxy), uint256(7800e26) * 1e18 / (5_000_000_000 * 99_990_000 * 1e12), "step 3: exact");
        assertEq((_hf(proxy) + 5e13) / 1e14, 15_602, "step 3: 1.5602 to four decimals");
        assertEq(coll.getOpenRecordCount(proxy, vt), 2, "record 2 of 16");
        snap = vm.snapshotState();
        vm.expectRevert(bytes4(keccak256("HealthFactorBelowThreshold()")));
        vm.prank(carol);
        adapterC.withdraw(MARKET_ID, _ref(key1), L1, d, 0);
        vm.revertToState(snap);
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.CollateralWithdrawn(carol, MARKET_ID, vt, keyB, LB, true, hf2);
        vm.prank(carol);
        adapterC.withdraw(MARKET_ID, _ref(keyB), LB, d, 1.2e18);
        assertEq(_hf(proxy), hf2, "step 5: back to 1.2481");
    }

    // TEST-237 verifies: REQ-ADAPTER-078, REQ-ADAPTER-085, REQ-PROXY-031, REQ-PROXY-039
    // Sources: LIFECYCLE.md walkthrough steps 6, 8 and 11
    /// @notice Steps 6, 8 and 11: a repay-all at a cap above the live debt refunds the margin and leaves
    /// `borrowCount = 0`; a debt-free removal of 2,000,000,000 units keeps 8,000,000,000 credited; the last withdrawal
    /// closes the account with no units left anywhere.
    function test_TEST_237_walkthroughExitSide() public {
        (bytes32 key1, address proxy) = _pledgeAs(carol, MARKET_ID, L1);
        _borrowUsdc(5_000_000_000, 1.2e18);
        vm.warp(block.timestamp + 30 days);
        uint256 live = _debtOf(proxy, usdcReserveId);
        uint256 cap = live * 1001 / 1000 + 1;
        _fund(carol, usdcReserveId, cap);
        uint256 before = usdcDebt.balanceOf(carol);
        vm.prank(carol);
        adapterC.repay(carol, MARKET_ID, usdcReserveId, cap, true, _deadline());
        assertEq(before - usdcDebt.balanceOf(carol), live, "step 6: Aave took the live debt, the rest refunded");
        assertEq(_borrowCountOf(proxy), 0, "borrowCount 0");
        uint256[] memory amounts;
        uint256 d = _deadline();
        vm.prank(carol);
        amounts = adapterC.removeLiquidity(MARKET_ID, _ref(key1), 2_000_000_000, _mins(), d, 0);
        assertEq(coll.previewRelease(INTEGRATION, key1), 8_000_000_000, "step 8: 8,000,000,000 units left");
        assertEq(amounts[0], 1_600_000_000, "USDC leg at the stand-in's 0.8 per unit");
        assertEq(amounts[1], 2_500_000_000, "USDT leg at the stand-in's 1.25 per unit");
        vm.prank(carol);
        adapterC.withdraw(MARKET_ID, _ref(key1), 8_000_000_000, d, 0);
        assertEq(token.totalSupply(), 0, "step 11: account closed");
        assertEq(token.balanceOf(proxy) + token.balanceOf(adapter), 0, "no units left");
        assertEq(lpVault.ownerOf(key1), carol, "key1 back with Carol");
    }
}
