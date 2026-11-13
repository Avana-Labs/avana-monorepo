// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @title LPVaultSwapDustBoundariesUnitTest
/// @notice Boundary vectors of a routed liquidation on the real local Aave V4 (5.1 TEST-072, TEST-161): a settlement
/// that would leave the account's debt just above or just below Aave's `DUST_LIQUIDATION_THRESHOLD` ($1,000), and the
/// recovery floor `minRec = max(0, ⌈V × (10⁴ − s) / 10⁴⌉ − U − ε)` from one raw seized unit up to amounts where the
/// percentage slippage dominates the rounding terms, with a recovery below the floor closed by the caller's top-up.
/// forge-config: default.isolate = false
contract LPVaultSwapDustBoundariesUnitTest is LPVaultSwapUnitBase {
    /// @dev Aave V4's `MustNotLeaveDust()`, passed through unchanged by LPVaultSwap (REQ-SWAP-055).
    bytes4 internal constant MUST_NOT_LEAVE_DUST = bytes4(keccak256("MustNotLeaveDust()"));

    /// @notice Carol owes 3,600 USDC against 2,000 vault tokens; at $2.00 her HF is 0.889 (maximum bonus 10,500) and
    /// Aave's target-HF amount (2,923 USDC) is above both vectors. Repaying 2,595 USDC leaves 1,005 USDC of debt, above
    /// the $1,000 dust threshold, and settles; repaying 2,605 USDC would leave 995 USDC, below it, so Aave requires the
    /// whole debt and the call reverts `MustNotLeaveDust` with nothing moved; repaying the whole 3,600 USDC settles and
    /// clears the debt.
    // TEST-072 verifies: REQ-SWAP-055, REQ-SWAP-042, SPEC-LIQ-004
    function test_TEST_072_debtJustAboveAndJustBelowAaveDust() public {
        (address proxy,) = _openAccount(carol, 2000e6, 3600e6, 250_000_000);
        lpOracle.setAnswer(200_000_000);
        assertEq(_debtOf(proxy, usdcReserveId), 3600e6, "debt");
        assertLt(_hf(proxy), 0.95e18, "maximum bonus applies");

        uint256 snapshot = vm.snapshotState();
        Snap memory s0 = _snap(keeper);
        LiquidationResult memory above = _liquidateAs(keeper, _params(proxy, 2595e6));
        assertEq(above.debtRepaid, 2595e6, "D = X");
        assertEq(_debtOf(proxy, usdcReserveId), 1005e6, "1,005 USDC left, above the dust threshold");
        assertGt(_suppliedUnits(proxy), 0, "collateral left");
        _assertNeutral(s0);
        vm.revertToState(snapshot);

        uint256 units = _suppliedUnits(proxy);
        uint256 supply = vt.totalSupply();
        _expectLiquidateRevert(keeper, _params(proxy, 2605e6), abi.encodeWithSelector(MUST_NOT_LEAVE_DUST));
        assertEq(_debtOf(proxy, usdcReserveId), 3600e6, "nothing repaid");
        assertEq(_suppliedUnits(proxy), units, "nothing seized");
        assertEq(vt.totalSupply(), supply, "nothing burned");

        LiquidationResult memory whole = _liquidateAs(keeper, _params(proxy, 3600e6));
        assertEq(whole.debtRepaid, 3600e6, "the whole debt");
        assertEq(_debtOf(proxy, usdcReserveId), 0, "no dust debt left");
        assertEq(
            whole.callerFunds + whole.recovered + whole.shortfall,
            whole.debtRepaid + whole.avanaFee + whole.borrowerSurplus + whole.keeperOut,
            "debt asset conserved"
        );
    }

    /// @notice From one raw seized unit up to 50 USDC of repayment, every settlement's floor, fee, reward, borrower
    /// surplus and `keeperOut` equal the independent model: the floor is 0 while `V` is within `U + ε` (about 1 USDC)
    /// and follows `⌈V × 0.99⌉ − U − ε` above it; a recovery between the floor and `D` is borne by the caller in
    /// `keeperOut`. With the vault priced above what its released tokens fetch, a recovery below the floor reverts
    /// `RecoveryBelowFloor` when the caller allows no top-up and is closed by a top-up of exactly the gap when it does.
    // TEST-161 verifies: SPEC-LIQ-005, SPEC-LIQ-019, REQ-SWAP-121, INV-038
    function test_TEST_161_dustFloorFromOneRawUnit() public {
        (address proxy,) = _bobAccount();
        uint256[5] memory amounts = [uint256(3), 1e6, 3e6, 10e6, 50e6];
        for (uint256 i = 0; i < amounts.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, amounts[i]));
            assertGe(r.unitsSeized, 1, "seized");
            Expect memory e = _expectUsdc(r.unitsSeized, r.debtRepaid, r.callerFunds, r.recovered, 10_500, P_VAULT, 0);
            _assertResult(r, e);
            if (i == 0) assertEq(r.minOut, 0, "floor 0 for one raw unit");
            assertEq(r.shortfall, 0, "honest routes need no top-up");
            vm.revertToState(snapshot);
        }

        // Vault priced at $2.15 while its released tokens are worth about $2.09 a unit at the routes' prices: every leg
        // meets its minimum, yet R stays below the floor.
        lpOracle.setAnswer(215_000_000);
        LiquidationParams memory p = _params(proxy, 200e6);
        _expectLiquidateRevert(keeper, p, abi.encodeWithSelector(ILPVaultSwapErrors.RecoveryBelowFloor.selector));
        p.maxShortfall = 30e6;
        LiquidationResult memory topped = _liquidateAs(keeper, p);
        assertGt(topped.shortfall, 0, "top-up pulled");
        assertEq(topped.recovered + topped.shortfall, topped.minOut, "the top-up closes exactly the gap");
    }
}
