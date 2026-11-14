// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";

/// @title DeleverageRepayWithCollateralFeeOnTransferIntegrationTest
/// @notice Repay with collateral under a transfer fee on the debt asset, through the real AaveAdapter, LPVaultSwap,
/// `AaveV3FlashSource` and Aave V4 Hub: LPVaultSwap measures the loan it received by balance delta and the Hub refuses
/// the short repayment, so the whole call reverts with no state change; with the fee back at 0 the same call settles in
/// the next block (2.11 REQ-SWAP-123).
/// @dev Kept on the stand-in fixture: it needs a debt asset whose transfer fee can be switched on (`CollPoolToken`),
/// and the real stack's debt assets (`ClTestToken`) have none. The rest of the suite is on the real stack in
/// `Deleverage.RepayWithCollateral`.
/// forge-config: default.isolate = false
contract DeleverageRepayWithCollateralFeeOnTransferIntegrationTest is IntegrationFlows {
    function setUp() public {
        _deployIntegration();
    }

    // TEST-287 verifies: REQ-SWAP-108, REQ-SWAP-123, INV-095, ATTACK-197, Q-390
    function test_TEST_287_deleverageRefusedByHubUnderFee() public {
        _setPrice(MARKET_ID, P_VAULT);
        (bytes32 k3,) = _pledgeVia(carol, MARKET_ID, 5000e6);
        _borrowVia(carol, MARKET_ID, debtReserveId, 5000e18);
        address p3 = adapterC.proxyOf(carol, MARKET_ID);
        RepayWithCollateralParams memory p = _rwcParams(MARKET_ID, k3, 1000e6, debtReserveId);
        uint256 debtBefore = _debtOf(p3, debtReserveId);
        uint256 supplyBefore = token.totalSupply();
        debt.setFeeBps(10);
        vm.prank(carol);
        (bool ok, bytes memory err) = address(adapterC).call(abi.encodeCall(adapterC.repayWithCollateral, (p)));
        assertFalse(ok, "refused under the fee");
        assertEq(
            bytes4(err), bytes4(keccak256("InsufficientTransferred(uint256)")), "the Hub's InsufficientTransferred"
        );
        assertEq(_debtOf(p3, debtReserveId), debtBefore, "no debt moved");
        assertEq(token.totalSupply(), supplyBefore, "no unit moved");
        assertFalse(lock.isLocked(), "Lock free");
        debt.setFeeBps(0);
        vm.roll(block.number + 1);
        vm.prank(carol);
        (uint256 repaid,) = adapterC.repayWithCollateral(p);
        assertGt(repaid, 0, "settles once the fee is 0");
    }
}
