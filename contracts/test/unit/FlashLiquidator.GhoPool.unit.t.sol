// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashLiquidator} from "../../src/periphery/flash-liquidator/IFlashLiquidator.sol";
import {IFlashLiquidatorErrors} from "../../src/periphery/flash-liquidator/IFlashLiquidatorErrors.sol";
import {IFlashLiquidatorEvents} from "../../src/periphery/flash-liquidator/IFlashLiquidatorEvents.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {FlashLiquidatorFixture} from "../utils/fixtures/FlashLiquidatorFixture.sol";

/// @notice GHO-debt liquidations through the flash liquidation helper (2.11 `REQ-HELPER-015`, `REQ-FLASH-010`): the
/// helper borrows GHO from the chain's Aave V3 Pool exactly as it borrows every other debt asset, with the Pool's
/// quotes, premium bounds, callback binding and Hub rule; it has no other lender and no ERC-3156 minter callback. The
/// 2.11 example in GHO: `D = 1,950`, `R = 2,040.3`, `A = 19.5` GHO, 5 bps Pool premium.
/// @dev Calls of one test share a transaction (`isolate = false`).
/// forge-config: default.isolate = false
contract FlashLiquidatorGhoPoolUnitTest is FlashLiquidatorFixture {
    uint256 internal constant D_GHO = 1950e18;
    uint256 internal constant PREMIUM_GHO = 0.975e18;
    uint256 internal constant KEEPER_OUT_GHO = 2020.8e18;
    uint256 internal constant PAYOUT_GHO = 69.825e18;

    /// @notice The ERC-3156 borrower callback a GHO flash minter calls: `onFlashLoan(address,address,uint256,uint256,
    /// bytes)`, selector `0x23e30c8b`.
    bytes4 internal constant ERC3156_CALLBACK = bytes4(keccak256("onFlashLoan(address,address,uint256,uint256,bytes)"));

    function setUp() public {
        _deployHelpers();
        lvs.setDebtAsset(ghoToken);
        lvs.setOutcome(D_GHO, 2040.3e18, 19.5e18);
    }

    function _ghoRequest(
        uint256 x,
        uint256 f,
        uint256 maxPremium,
        uint256 minPayout
    ) internal view returns (FlashLiquidationRequest memory r) {
        r = _request(x, f, maxPremium, 0, minPayout);
        r.params.debtReserveId = GHO_RESERVE;
    }

    function _example() internal view returns (FlashLiquidationRequest memory) {
        return _ghoRequest(D_GHO, D_GHO, PREMIUM_GHO, 69e18);
    }

    function _assertGhoClean(
        address h
    ) internal view {
        assertEq(ghoToken.balanceOf(h), 0, "helper holds GHO");
        assertEq(ghoToken.allowance(h, address(aavePool)), 0, "Pool allowance left");
        assertEq(ghoToken.allowance(h, address(lvs)), 0, "LPVaultSwap allowance left");
    }

    /// @notice The GHO example borrows 1,950 GHO from the Pool: premium 0.975 GHO (5 bps, half up), the Pool's GHO
    /// reserve is repaid `F + premium`, the caller receives 69.825 GHO, and nothing stays in the helper.
    // TEST-292 verifies: REQ-HELPER-015, REQ-FLASH-010, REQ-HELPER-004, REQ-HELPER-006, REQ-HELPER-007, REQ-HELPER-008
    function test_TEST_292_ghoBorrowedFromPool() public {
        assertEq(helper.maxFlashLoan(address(ghoToken)), IDLE_GHO, "the Pool's idle GHO");
        assertEq(helper.flashPremium(address(ghoToken), D_GHO), PREMIUM_GHO);
        vm.expectEmit(true, true, true, true, address(helper));
        emit IFlashLiquidatorEvents.FlashLiquidated(
            caller, caller, address(ghoToken), D_GHO, PREMIUM_GHO, KEEPER_OUT_GHO, 0, PAYOUT_GHO
        );
        vm.prank(caller);
        uint256 payout = helper.flashLiquidate(_example());
        assertEq(payout, PAYOUT_GHO);
        assertEq(ghoToken.balanceOf(caller), PAYOUT_GHO);
        assertEq(aavePool.flashLoanCalls(), 1, "GHO lent by the Pool");
        assertEq(ghoToken.balanceOf(aGho), IDLE_GHO + PREMIUM_GHO, "the Pool's GHO reserve repaid F + premium");
        assertEq(aavePool.getVirtualUnderlyingBalance(address(ghoToken)), IDLE_GHO + PREMIUM_GHO);
        assertEq(lvs.lastCaller(), address(helper));
        _assertGhoClean(address(helper));

        // USDC in the same transaction goes to the same Pool.
        lvs.setDebtAsset(usdcToken);
        lvs.setOutcome(D_EXAMPLE, R_EXAMPLE, A_EXAMPLE);
        vm.prank(caller);
        assertEq(helper.flashLiquidate(_exampleRequest()), 69.825e6);
        assertEq(aavePool.flashLoanCalls(), 2);
    }

    /// @notice GHO quotes are the Pool's: its idle GHO while the reserve is active, unpaused and flash-enabled, else
    /// 0, and the ceiling premium, 0 once the helper holds `FLASH_BORROWER`. A loan above the quote reverts before the
    /// Pool is called.
    // TEST-292 verifies: REQ-HELPER-009, REQ-HELPER-015, REQ-HELPER-003, REQ-FLASH-010
    function test_TEST_292_ghoQuotesReadFromPool() public {
        aavePool.setVirtualBalance(address(ghoToken), 1000e18);
        assertEq(helper.maxFlashLoan(address(ghoToken)), 1000e18);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.InsufficientFlashLiquidity.selector, 1000e18));
        helper.flashLiquidate(_example());

        aavePool.setVirtualBalance(address(ghoToken), uint128(IDLE_GHO));
        aavePool.setFlags(address(ghoToken), true, false, false, false);
        assertEq(helper.maxFlashLoan(address(ghoToken)), 0, "flash-disabled GHO reserve");
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.InsufficientFlashLiquidity.selector, 0));
        helper.flashLiquidate(_example());
        // Configuration bits above the flash-loan flag (a supply cap, bits 116-151) do not stand in for it.
        aavePool.setConfiguration(
            address(ghoToken), aavePool.getConfiguration(address(ghoToken)) | (uint256(1_000_000) << 116)
        );
        assertEq(helper.maxFlashLoan(address(ghoToken)), 0, "flash-disabled GHO reserve with a supply cap");
        aavePool.setFlags(address(ghoToken), true, false, true, true);
        assertEq(helper.maxFlashLoan(address(ghoToken)), 0, "paused GHO reserve");
        aavePool.setFlags(address(ghoToken), true, true, false, true);
        assertEq(helper.maxFlashLoan(address(ghoToken)), IDLE_GHO, "a frozen GHO reserve still lends");
        assertEq(aavePool.flashLoanCalls(), 0);

        acl.addFlashBorrower(address(helper));
        assertEq(helper.flashPremium(address(ghoToken), D_GHO), 0, "FLASH_BORROWER pays no premium");
        vm.prank(caller);
        assertEq(helper.flashLiquidate(_ghoRequest(D_GHO, D_GHO, 0, 0)), PAYOUT_GHO + PREMIUM_GHO);
    }

    /// @notice The Pool's GHO premium is held to `maxFlashFeeBps` (launch 10) before the loan and in the callback, and
    /// to the caller's `maxPremium` in the callback.
    // TEST-292 verifies: REQ-HELPER-005, REQ-HELPER-015, SPEC-LIQ-015, Q-135
    function test_TEST_292_ghoPremiumHeldToCapAndMaxPremium() public {
        aavePool.setPremiumTotal(20);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.FlashFeeTooHigh.selector, 3.9e18, 1.95e18));
        helper.flashLiquidate(_example());

        aavePool.setPremiumTotal(uint128(POOL_PREMIUM_BPS));
        aavePool.setPremiumOverride(2e18);
        FlashLiquidationRequest memory r = _example();
        r.maxPremium = 3e18;
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.FlashFeeTooHigh.selector, 2e18, 1.95e18));
        helper.flashLiquidate(r);

        aavePool.setPremiumOverride(1e18);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.PremiumTooHigh.selector, 1e18, PREMIUM_GHO));
        helper.flashLiquidate(_example());
    }

    /// @notice For every premium the Pool charges on GHO and every `maxPremium`, a completed call was charged within
    /// both bounds and paid the caller `keeperOut - F - premium`.
    // TEST-292 verifies: REQ-HELPER-005, REQ-HELPER-008, REQ-HELPER-015, SPEC-LIQ-015
    function testFuzz_TEST_292_ghoChargedPremiumWithinBounds(
        uint64 premium,
        uint64 maxPremium
    ) public {
        aavePool.setPremiumOverride(premium);
        FlashLiquidationRequest memory r = _ghoRequest(D_GHO, D_GHO, maxPremium, 0);
        vm.prank(caller);
        try helper.flashLiquidate(r) returns (uint256 payout) {
            assertLe(premium, maxPremium);
            assertLe(uint256(premium) * 10_000, 10 * D_GHO);
            assertEq(payout, KEEPER_OUT_GHO - D_GHO - premium);
            assertEq(aavePool.flashLoanCalls(), 1);
            _assertGhoClean(address(helper));
        } catch {
            assertEq(ghoToken.balanceOf(caller), 0, "a refused call pays nothing");
        }
    }

    /// @notice The Pool recorded as a Hub refuses GHO calls too: GHO has no second lender to fall back to.
    // TEST-292 verifies: REQ-HELPER-002, REQ-HELPER-013, REQ-HELPER-015, INV-095
    function test_TEST_292_ghoRefusedWhenPoolIsHub() public {
        registry.setHub(address(aavePool), true);
        vm.prank(caller);
        vm.expectRevert(IFlashLiquidatorErrors.FlashSourceIsHub.selector);
        helper.flashLiquidate(_example());
        assertEq(aavePool.flashLoanCalls(), 0);
    }

    /// @notice A third party's Pool loan of GHO naming the helper as receiver carries the third party as initiator and
    /// is refused, as for any asset.
    // TEST-292 verifies: REQ-HELPER-005, REQ-HELPER-015, INV-040
    function test_TEST_292_thirdPartyGhoPoolLoanToHelperReverts() public {
        address[] memory assets = new address[](1);
        assets[0] = address(ghoToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = D_GHO;
        uint256[] memory modes = new uint256[](1);
        vm.prank(makeAddr("thirdParty"));
        vm.expectRevert(IFlashLiquidatorErrors.InvalidFlashCallback.selector);
        aavePool.flashLoan(address(helper), assets, amounts, modes, address(helper), abi.encode(_example().params), 0);
    }

    /// @notice The helper has no ERC-3156 minter callback: `onFlashLoan` reaches no function of either variant, from
    /// any caller and with any arguments, outside a loan and from inside a GHO loan, and the selector is absent from
    /// their runtime code.
    // TEST-292 verifies: REQ-HELPER-001, REQ-HELPER-015, REQ-HELPER-005
    function testFuzz_TEST_292_noMinterCallback(
        address from,
        address initiator,
        uint256 amount,
        uint256 fee
    ) public {
        bytes memory data = abi.encodeWithSelector(
            ERC3156_CALLBACK, initiator, address(ghoToken), amount, fee, abi.encode(_example().params)
        );
        vm.prank(from);
        (bool ok, bytes memory ret) = address(helper).call(data);
        assertFalse(ok, "public helper answered onFlashLoan");
        assertEq(ret.length, 0, "no function reached");
        vm.prank(from);
        (ok, ret) = address(opHelper).call(data);
        assertFalse(ok, "operator helper answered onFlashLoan");
        assertEq(ret.length, 0, "no function reached");
    }

    /// @notice The `onFlashLoan` selector is absent from both variants' runtime code, and a minter-style callback sent
    /// from inside an open GHO loan reaches no function and reverts the whole call; an honest call settles next.
    // TEST-292 verifies: REQ-HELPER-001, REQ-HELPER-015, REQ-HELPER-005
    function test_TEST_292_noMinterCallbackInsideGhoLoan() public {
        assertFalse(_hasPush4(address(helper).code, ERC3156_CALLBACK), "selector in the public helper");
        assertFalse(_hasPush4(address(opHelper).code, ERC3156_CALLBACK), "selector in the operator helper");
        // Sanity: the dispatcher's selectors are found the same way.
        assertTrue(_hasPush4(address(helper).code, IFlashLiquidator.executeOperation.selector));

        bytes memory data = abi.encodeWithSelector(
            ERC3156_CALLBACK, address(helper), address(ghoToken), D_GHO, PREMIUM_GHO, abi.encode(_example().params)
        );
        lvs.setHook(address(helper), data);
        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(helper).call(abi.encodeCall(IFlashLiquidator.flashLiquidate, (_example())));
        assertFalse(ok, "a minter callback inside the loan is refused");
        assertEq(ret.length, 0, "it reached no function");
        lvs.setHook(address(0), "");
        vm.prank(caller);
        assertEq(helper.flashLiquidate(_example()), PAYOUT_GHO, "an honest call settles next");
        _assertGhoClean(address(helper));
    }

    /// @notice The operator variant borrows GHO from the Pool under its loan and outlay bounds: a loan above
    /// `ceil(D x 1.05)` is refused, and an honest one pays the Safe.
    // TEST-292 verifies: REQ-HELPER-011, REQ-HELPER-015
    function test_TEST_292_operatorGhoFromPool() public {
        uint256 x = 10_000e18;
        FlashLiquidationRequest memory r = _ghoRequest(x, x, 5e18, 0);
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.FlashAmountAboveNeed.selector, x, 2047.5e18));
        opHelper.flashLiquidate(r);
        vm.prank(signer);
        assertEq(opHelper.flashLiquidate(_example()), PAYOUT_GHO);
        assertEq(ghoToken.balanceOf(safe), PAYOUT_GHO);
        assertEq(aavePool.flashLoanCalls(), 1);
        _assertGhoClean(address(opHelper));
    }

    /// @dev Whether `code` holds `PUSH4 selector` as an instruction (push data skipped).
    function _hasPush4(
        bytes memory code,
        bytes4 selector
    ) internal pure returns (bool) {
        uint256 i = 0;
        while (i < code.length) {
            uint8 op = uint8(code[i]);
            if (op == 0x63 && i + 4 < code.length) {
                bytes4 word = bytes4(
                    (uint32(uint8(code[i + 1])) << 24) | (uint32(uint8(code[i + 2])) << 16)
                        | (uint32(uint8(code[i + 3])) << 8) | uint32(uint8(code[i + 4]))
                );
                if (word == selector) return true;
            }
            i += (op >= 0x60 && op <= 0x7f) ? uint256(op) - 0x5e : 1;
        }
        return false;
    }
}
