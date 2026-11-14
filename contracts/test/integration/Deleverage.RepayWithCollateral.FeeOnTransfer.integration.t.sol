// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {ClTestToken} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {FeeSwitchToken} from "../utils/mocks/SwapRouteMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DeleverageRepayWithCollateralFeeOnTransferIntegrationTest
/// @notice Repay with collateral under a transfer fee on the debt asset, on the real stack (`RealStackFlows`): the real
/// AaveAdapter, LPVaultSwap, `AaveV3FlashSource` and Aave V4 Hub. LPVaultSwap measures the loan it received by balance
/// delta and the Hub refuses the short repayment, so the whole call reverts with no state change; with the fee back at
/// 0 the same call settles in the next block (2.11 REQ-SWAP-123).
/// @dev The debt asset is USDF, a 6-decimal USD stable whose issuer can switch on a transfer fee as Tether can
/// (`FeeSwitchToken`, answering `basisPointsRate()`): listed with its feeds at $1.00 and the `UsdtFeeRate` issuer
/// probe, enabled as a DebtOracle-priced debt reserve while its fee is 0 (the enablement probe passes, REQ-MREG-006),
/// and the fee switched on only after Carol borrowed it, as an issuer would. Carol: 10,000 vault tokens at $2.00
/// ($20,000, CF 30 %) against 4,000 USDF (HF 1.50).
/// forge-config: default.isolate = false
contract DeleverageRepayWithCollateralFeeOnTransferIntegrationTest is RealStackFlows {
    uint128 internal constant RELEASE = 1500e6;

    FeeSwitchToken internal usdf;
    uint256 internal usdfReserveId;
    uint256 internal mA;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        usdf = new FeeSwitchToken("USDF", 6);
        vm.label(address(usdf), "USDF");
        ClTestToken t = ClTestToken(address(usdf));
        _listPricedToken(t, "USDF", 1e8, true, IssuerProbe.UsdtFeeRate);
        (,, usdfReserveId) = _addDebtReserve(t, "USDF / USD", FLOOR_ROUNDING_ALLOWANCE_USDC);
    }

    // TEST-287 verifies: REQ-SWAP-108, REQ-SWAP-123, INV-095, ATTACK-197, Q-390
    function test_TEST_287_deleverageRefusedByHubUnderFee() public {
        (bytes32 k3, address p3) = _pledgeAs(carol, mA, UNITS);
        _borrowAs(carol, mA, usdfReserveId, 4000e6);
        RepayWithCollateralParams memory p = _rwcParams(mA, k3, RELEASE, usdfReserveId);
        IERC20 vt = IERC20(mkt[mA].vaultToken);
        uint256 debtBefore = _debtOf(p3, usdfReserveId);
        uint256 supplyBefore = vt.totalSupply();
        usdf.setFeeBps(10);
        vm.prank(carol);
        (bool ok, bytes memory err) = address(adapterC).call(abi.encodeCall(adapterC.repayWithCollateral, (p)));
        assertFalse(ok, "refused under the fee");
        assertEq(
            bytes4(err), bytes4(keccak256("InsufficientTransferred(uint256)")), "the Hub's InsufficientTransferred"
        );
        assertEq(_debtOf(p3, usdfReserveId), debtBefore, "no debt moved");
        assertEq(vt.totalSupply(), supplyBefore, "no unit moved");
        assertFalse(lock.isLocked(), "Lock free");
        usdf.setFeeBps(0);
        vm.roll(block.number + 1);
        vm.prank(carol);
        (uint256 repaid,) = adapterC.repayWithCollateral(p);
        assertGt(repaid, 0, "settles once the fee is 0");
    }
}
