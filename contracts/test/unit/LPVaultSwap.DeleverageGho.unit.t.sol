// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @title LPVaultSwapDeleverageGhoUnitTest
/// @notice Repay with collateral of GHO debt (2.11 SPEC-LIQ-020 at 18 decimals, REQ-SWAP-106, REQ-SWAP-088): the core
/// flash source lends GHO from the Aave V3 Pool, both pool tokens are swapped into GHO at their minimums, the debt
/// falls by exactly `x` sized in GHO units (`U` of both legs, `ε` = 1 GHO), the wallet receives `R − x − φ` in GHO
/// and LPVaultSwap and the source end unchanged; the USDC reserve of the same account is untouched.
/// forge-config: default.isolate = false
contract LPVaultSwapDeleverageGhoUnitTest is LPVaultSwapUnitBase {
    address internal proxy;
    bytes32 internal key;

    function setUp() public override {
        super.setUp();
        (proxy, key) = _openAccount(alice, 10_000e6, 2000e6, 250_000_000);
        lpOracle.setAnswer(250_000_000);
        adapter.borrow(proxy, ghoReserveId, address(gho), 12_000e18, alice);
        lpOracle.setAnswer(int256(P_VAULT));
    }

    /// @dev SPEC-LIQ-020 for GHO: `V = ⌊units × Pc × 10¹⁸ / (10⁶ × 10⁸)⌋`, `U` of USDC and USDT in GHO units,
    /// `ε = 1e18`, cap `⌊(⌊V (10⁴ − s)/10⁴⌋ − U − ε) × 10⁴ / (10⁴ + maxFlashFeeBps)⌋`.
    function _ghoCap(
        uint256 units
    ) internal pure returns (uint256) {
        uint256 v = _valueOf(units, P_VAULT, PRICE_UNIT, 18);
        uint256 net = v * (BPS - SLIPPAGE_BPS) / BPS;
        uint256 cut = _unitsOf(false, 18, PRICE_UNIT) + FLOOR_ROUNDING_ALLOWANCE_GHO;
        return net > cut ? (net - cut) * BPS / (BPS + MAX_FLASH_FEE_BPS) : 0;
    }

    function _repayGho(
        uint128 units,
        uint256 minDebtRepaid
    ) internal returns (uint256 repaid, uint256 out) {
        vm.prank(alice);
        (repaid, out) =
            adapter.repayWithCollateral(proxy, _position(key), units, ghoReserveId, new uint256[](2), minDebtRepaid);
    }

    /// @notice 1,000 units repay the model's `x` of GHO; the wallet receives `R − x − φ` with `R` both legs at par.
    // TEST-239 verifies: SPEC-LIQ-020, REQ-SWAP-106, REQ-SWAP-088, INV-089
    function test_TEST_239_ghoDeleverageMatchesModel() public {
        uint256 ghoDebt = _debtOf(proxy, ghoReserveId);
        uint256 usdcDebt = _debtOf(proxy, usdcReserveId);
        uint256 wallet = gho.balanceOf(alice);
        uint256 hf = _hf(proxy);
        uint256 x = _ghoCap(1000e6);
        (uint256 repaid, uint256 out) = _repayGho(1000e6, 0);
        (uint256 a0, uint256 a1) = _released(1000e6);
        uint256 recovered = (a0 + a1) * 1e12;
        uint256 phi = (x * 5 + 5000) / 10_000;
        assertEq(repaid, x, "x");
        assertEq(out, recovered - x - phi, "assetOut = R - x - phi");
        assertEq(_debtOf(proxy, ghoReserveId), ghoDebt - x, "GHO debt down by x");
        assertEq(_debtOf(proxy, usdcReserveId), usdcDebt, "USDC reserve untouched");
        assertEq(gho.balanceOf(alice), wallet + out, "wallet paid in GHO");
        assertGe(_hf(proxy), hf, "HF never falls");
        assertEq(gho.balanceOf(address(lvs)), 0, "no GHO kept");
        assertEq(usdc.balanceOf(address(lvs)), 0, "no USDC kept");
        assertEq(usdt.balanceOf(address(lvs)), 0, "no USDT kept");
        _assertNoAllowances();
    }

    /// @notice Any units: `x` of the model, or `DeleverageTooSmall(x, minimum)` for a minimum above it.
    // TEST-239 verifies: SPEC-LIQ-020, REQ-SWAP-116
    function testFuzz_TEST_239_ghoDeleverageSizing(
        uint256 units,
        bool aboveMinimum
    ) public {
        units = bound(units, 10e6, 4000e6);
        uint256 debt = _debtOf(proxy, ghoReserveId);
        uint256 cap = _ghoCap(units);
        uint256 x = debt < cap ? debt : cap;
        if (aboveMinimum) {
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DeleverageTooSmall.selector, x, x + 1));
            adapter.repayWithCollateral(proxy, _position(key), uint128(units), ghoReserveId, new uint256[](2), x + 1);
        } else {
            (uint256 repaid,) = _repayGho(uint128(units), x);
            assertEq(repaid, x, "x");
            assertEq(_debtOf(proxy, ghoReserveId), debt - x, "debt down by x");
        }
    }

    /// @notice A GHO leg route paying below its minimum (a 2 % loss on USDT into GHO) leaves no route for the leg:
    /// `NoRouteAvailable`, nothing repaid, the flash loan never left the source.
    // TEST-239 verifies: SPEC-LIQ-018, REQ-SWAP-106, REQ-SWAP-022
    function test_TEST_239_ghoLegBelowMinimumRefused() public {
        registry.setRoute(
            MARKET_ID,
            address(usdt),
            address(gho),
            0,
            address(_route(address(usdt), address(gho), _clPool(usdt, gho, 98e10, 1))),
            true
        );
        uint256 debt = _debtOf(proxy, ghoReserveId);
        uint256 sourceBefore = gho.balanceOf(address(flashSource));
        vm.prank(alice);
        vm.expectRevert(ILPVaultSwapErrors.NoRouteAvailable.selector);
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, ghoReserveId, new uint256[](2), 0);
        assertEq(_debtOf(proxy, ghoReserveId), debt, "nothing repaid");
        assertEq(gho.balanceOf(address(flashSource)), sourceBefore, "source unchanged");
    }
}
