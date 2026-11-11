// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPayoutEscrow} from "../../src/liquidation/payout-escrow/IPayoutEscrow.sol";
import {IFlashLiquidatorErrors} from "../../src/periphery/flash-liquidator/IFlashLiquidatorErrors.sol";
import {IFlashLiquidatorEvents} from "../../src/periphery/flash-liquidator/IFlashLiquidatorEvents.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {FlashLiquidatorFixture} from "../utils/fixtures/FlashLiquidatorFixture.sol";

/// @notice The operator variant of the flash liquidation helper (2.11 `REQ-HELPER-011`): only `SIGNER` calls; the
/// inventory and every top-up come only from `FUNDING_SAFE`, and the payout and every market token go only to it; each
/// top-up is bounded by `⌊D × MAX_TOP_UP_BPS / 10⁴⌋` (D the debt repaid) as well as `maxTopUp`; `claimEscrowed` claims
/// the helper's PayoutEscrow credit to the Safe.
contract FlashLiquidatorOperatorUnitTest is FlashLiquidatorFixture {
    function setUp() public {
        _deployHelpers();
    }

    function _signerLiquidates(
        FlashLiquidationRequest memory request
    ) internal returns (uint256) {
        vm.prank(signer);
        return opHelper.flashLiquidate(request);
    }

    // TEST-174 verifies: REQ-HELPER-011, REQ-HELPER-003, REQ-HELPER-013, Q-219
    function testFuzz_TEST_174_operatorHelperRefusesNonSigner(
        address who
    ) public {
        vm.assume(who != signer);
        FlashLiquidationRequest memory request = _exampleRequest();
        vm.prank(who);
        vm.expectRevert(IFlashLiquidatorErrors.NotSigner.selector);
        opHelper.flashLiquidate(request);
        vm.prank(who);
        vm.expectRevert(IFlashLiquidatorErrors.NotSigner.selector);
        opHelper.claimEscrowed(address(usdtToken));
    }

    /// @notice The Safe pays the inventory and receives the payout and the residue; the signer's own funds and
    /// approval are never used.
    // TEST-174 verifies: REQ-HELPER-004, REQ-HELPER-008, REQ-HELPER-011, REQ-HELPER-012, Q-219, Q-381
    function test_TEST_174_operatorHelperSignerSafe() public {
        _fund(safe, address(opHelper), 97.5e6);
        _fund(signer, address(opHelper), 1_000_000e6);
        lvs.addResidue(usdtToken, 0.4e6);
        vm.expectEmit(true, true, true, true, address(opHelper));
        emit IFlashLiquidatorEvents.FlashLiquidated(
            signer, safe, address(usdcToken), 1950e6, 975_000, 2118.3e6, 0, 167.325e6
        );
        uint256 payout = _signerLiquidates(_request(2047.5e6, 1950e6, 975_000, 0, 167e6));
        assertEq(payout, 167.325e6);
        assertEq(usdcToken.balanceOf(safe), 167.325e6, "Safe paid 97.5 and received the payout");
        assertEq(usdtToken.balanceOf(safe), 0.4e6, "residue to the Safe");
        assertEq(usdcToken.balanceOf(signer), 1_000_000e6, "signer untouched");
        assertEq(usdcToken.allowance(signer, address(opHelper)), 1_000_000e6);
        assertEq(lvs.lastCaller(), address(opHelper));
        assertEq(usdcToken.balanceOf(address(opHelper)), 0);
        assertEq(usdtToken.balanceOf(address(opHelper)), 0);
    }

    /// @notice `MAX_TOP_UP_BPS = 100` and a liquidation repaying `D = 9,800` USDC bound the top-up at 98 USDC whatever
    /// `maxTopUp` the signer sends; a smaller `maxTopUp` binds when it is below. The 98 USDC top-up is the Safe's whole
    /// net outlay here, at its bound.
    // TEST-174 verifies: REQ-HELPER-007, REQ-HELPER-011, REQ-SWAP-081, Q-219
    // Sources: 2.11 REQ-HELPER-011 example
    function test_TEST_174_operatorTopUpCappedByBps() public {
        _fund(safe, address(opHelper), 1000e6);
        uint256 x = 9800e6;
        uint256 premium = 4.9e6;
        // keeperOut = R when D = X and A = 0; the top-up is X + premium - R.
        lvs.setOutcome(x, x + premium - 98e6 - 1, 0);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.TopUpExceeded.selector, 98e6 + 1, 98e6));
        _signerLiquidates(_request(x, x, premium, 1000e6, 0));
        lvs.setOutcome(x, x + premium - 98e6, 0);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidatorErrors.TopUpExceeded.selector, 98e6, 50e6));
        _signerLiquidates(_request(x, x, premium, 50e6, 0));
        uint256 payout = _signerLiquidates(_request(x, x, premium, 1000e6, 0));
        assertEq(payout, 0);
        assertEq(usdcToken.balanceOf(safe), 1000e6 - 98e6, "98 USDC of top-up from the Safe");
    }

    /// @notice A residue the operator helper cannot receive is escrowed for it, and the signer claims it to the Safe.
    // TEST-174 verifies: REQ-HELPER-010, REQ-HELPER-011, REQ-SWAP-076, Q-389
    function test_TEST_174_operatorClaimEscrowedToSafe() public {
        lvs.addResidue(usdtToken, 0.4e6);
        usdtToken.setBlocked(address(opHelper), true);
        _signerLiquidates(_exampleRequest());
        assertEq(escrow.claimable(address(usdtToken), address(opHelper)), 0.4e6);
        assertEq(usdcToken.balanceOf(safe), 69.825e6);
        vm.prank(signer);
        uint256 claimed = opHelper.claimEscrowed(address(usdtToken));
        assertEq(claimed, 0.4e6);
        assertEq(usdtToken.balanceOf(safe), 0.4e6, "claimed to the Safe");
        assertEq(usdtToken.balanceOf(signer), 0);
        vm.prank(signer);
        vm.expectRevert(IPayoutEscrow.NothingToClaim.selector);
        opHelper.claimEscrowed(address(usdtToken));
    }
}
