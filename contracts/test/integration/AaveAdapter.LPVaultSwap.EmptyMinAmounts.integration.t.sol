// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";

/// @title AaveAdapterLPVaultSwapEmptyMinAmountsIntegrationTest
/// @notice A repay with collateral whose `minAmounts` is empty, on the real stack (`RealStackFlows`: the real
/// AaveAdapter, LPVaultSwap, AaveV3FlashSource, Uniswap v3 LPVault on the NonfungiblePositionManager and
/// `DexPathRoute`s): the Adapter's session binds one zero per market token, the array LPVaultSwap passes to
/// `deleverageRelease` for an empty `minAmounts` (2.6 REQ-ADAPTER-080, 2.11 REQ-SWAP-106), so the release step
/// matches the session and the call settles. Found by the integration review; the LPVaultSwap suites' Adapter stand-in
/// did not compare the minimums.
/// @dev Bob's account: 10,000 vault tokens ($20,000 at $2.00) against 3,000 USDC; 1,500 vault tokens ($3,000) are
/// released, unwound and their USDT swapped into USDC.
/// forge-config: default.isolate = false
contract AaveAdapterLPVaultSwapEmptyMinAmountsIntegrationTest is RealStackFlows {
    uint256 internal mA;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-SWAP-106
    function test_TEST_239_emptyMinAmountsRepayWithCollateral() public {
        (bytes32 key, address proxy) = _pledgeAs(bob, mA, UNITS);
        _borrowAs(bob, mA, usdcReserveId, 3000e6);
        RepayWithCollateralParams memory p = _rwcParams(mA, key, 1500e6, usdcReserveId);
        p.minAmounts = new uint256[](0);
        uint256 debtBefore = _debtOf(proxy, usdcReserveId);
        vm.prank(bob);
        (uint256 repaid,) = adapterC.repayWithCollateral(p);
        assertGt(repaid, 0, "an empty minAmounts settles");
        assertEq(debtBefore - _debtOf(proxy, usdcReserveId), repaid, "the Spoke's debt fell by debtRepaid");
    }
}
