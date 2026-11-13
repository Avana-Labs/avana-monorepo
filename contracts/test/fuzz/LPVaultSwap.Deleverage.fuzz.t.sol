// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapDeleverageFuzzTest
/// @notice Repay with collateral fuzzed on the real local Aave V4 and the core flash source (2.11 SPEC-LIQ-020,
/// REQ-SWAP-106, REQ-SWAP-122): for any number of units, vault price, route rate, flash premium rate and debt, a
/// `deleverage` either settles with `x = min(debt, ⌊(⌊V (10⁴ − s)/10⁴⌋ − U − ε) × 10⁴ / (10⁴ + maxFlashFeeBps)⌋)`,
/// the Pool's half-up premium, `assetOut = R − x − φ` to the wallet, the debt down by exactly `x`, the health factor
/// not lower, LPVaultSwap and the source unchanged and no allowance left; or reverts with one of the errors the spec
/// names for its condition.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 256
contract LPVaultSwapDeleverageFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;
    bytes32 internal key;

    function setUp() public override {
        super.setUp();
        (proxy, key) = _openAccount(alice, 10_000e6, 15_000e6, 250_000_000);
    }

    /// @dev SPEC-LIQ-020 sizing with USDC debt (`U = 2`, `ε = 1e6`) at the fixture's `maxFlashFeeBps` and 100 bps.
    function _capOf(
        uint256 units,
        uint256 pc
    ) internal pure returns (uint256) {
        uint256 v = _valueOf(units, pc, PRICE_UNIT, 6);
        uint256 term = v * (BPS - SLIPPAGE_BPS) / BPS;
        uint256 cut = 2 + FLOOR_ROUNDING_ALLOWANCE_USDC;
        if (term <= cut) return 0;
        return (term - cut) * BPS / (BPS + MAX_FLASH_FEE_BPS);
    }

    function _known(
        bytes memory reason
    ) internal pure returns (bool) {
        bytes4 s = bytes4(reason);
        return s == ILPVaultSwapErrors.DeleverageShortfall.selector
            || s == ILPVaultSwapErrors.DeleverageTooSmall.selector || s == ILPVaultSwapErrors.NoRouteAvailable.selector
            || s == ILPVaultSwapErrors.FlashFeeTooHigh.selector
            // The AaveAdapter's own rule (2.6): a repay with collateral that would lower the health factor reverts.
            || s == bytes4(keccak256("HealthFactorNotImproved(uint256,uint256)"))
            // Aave's own rule: the release withdraws collateral, refused while the account stays below HF 1.
            || s == bytes4(keccak256("HealthFactorBelowThreshold()"));
    }

    /// @notice Any units, price, USDT route rate and Pool premium: the model's figures or a named refusal.
    // TEST-239 verifies: SPEC-LIQ-020, REQ-SWAP-106, REQ-SWAP-122, REQ-SWAP-013, INV-089, PROP-072, Q-255
    function testFuzz_TEST_239_deleverageMatchesModel(
        uint256 units,
        uint256 price8,
        uint256 rateBps,
        uint256 premiumBps
    ) public {
        units = bound(units, 1e6, 9000e6);
        price8 = bound(price8, 180_000_000, 260_000_000);
        rateBps = bound(rateBps, 9900, 10_100);
        premiumBps = bound(premiumBps, 0, 12);
        lpOracle.setAnswer(int256(price8));
        usdtUsdcPool.setRate(rateBps, 10_000);
        usdtUsdcPool2.setRate(rateBps, 10_000);
        v3Pool.setPremiumTotal(uint128(premiumBps));
        uint256 debt = _debtOf(proxy, usdcReserveId);
        uint256 hf = _hf(proxy);
        uint256 wallet = usdc.balanceOf(alice);
        uint256 sourceBefore = usdc.balanceOf(address(flashSource));
        Snap memory s0 = _snap(alice);
        uint256 cap = _capOf(units, price8);
        uint256 x = debt < cap ? debt : cap;
        vm.prank(alice);
        try adapter.repayWithCollateral(
            proxy, _position(key), uint128(units), usdcReserveId, new uint256[](2), 0
        ) returns (
            uint256 repaid, uint256 out
        ) {
            (uint256 a0, uint256 a1) = _released(units);
            uint256 recovered = a0 + a1 * rateBps / 10_000;
            uint256 phi = (x * premiumBps + 5000) / 10_000;
            assertLe(premiumBps, MAX_FLASH_FEE_BPS, "a premium above the cap never settles");
            assertEq(repaid, x, "x = min(debt, cap)");
            assertEq(out, recovered - x - phi, "assetOut = R - x - phi");
            assertEq(_debtOf(proxy, usdcReserveId), debt - x, "debt down by x");
            assertGe(_hf(proxy), hf, "HF never falls");
            assertEq(usdc.balanceOf(alice), wallet + out, "wallet paid assetOut");
            assertEq(usdc.balanceOf(address(flashSource)), sourceBefore, "source neutral");
            _assertNeutral(s0);
            _assertNoAllowances();
        } catch (bytes memory reason) {
            assertTrue(_known(reason) || premiumBps > MAX_FLASH_FEE_BPS, "unexpected refusal");
            if (premiumBps > MAX_FLASH_FEE_BPS && x != 0) {
                assertEq(bytes4(reason), ILPVaultSwapErrors.FlashFeeTooHigh.selector, "premium above the cap");
            }
            assertEq(_debtOf(proxy, usdcReserveId), debt, "a refusal repays nothing");
        }
    }

    /// @notice `minDebtRepaid` is honoured exactly: a minimum at `x` settles, `x + 1` reverts
    /// `DeleverageTooSmall(x, x + 1)`.
    // TEST-239 verifies: SPEC-LIQ-020, REQ-SWAP-116
    function testFuzz_TEST_239_minDebtRepaidExact(
        uint256 units
    ) public {
        units = bound(units, 10e6, 5000e6);
        uint256 cap = _capOf(units, P_VAULT);
        uint256 debt = _debtOf(proxy, usdcReserveId);
        uint256 x = debt < cap ? debt : cap;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DeleverageTooSmall.selector, x, x + 1));
        adapter.repayWithCollateral(proxy, _position(key), uint128(units), usdcReserveId, new uint256[](2), x + 1);
        vm.prank(alice);
        (uint256 repaid,) =
            adapter.repayWithCollateral(proxy, _position(key), uint128(units), usdcReserveId, new uint256[](2), x);
        assertEq(repaid, x, "a minimum equal to x settles");
    }

    /// @notice Successive deleverages by the same account each repay the model's `x` for their units and never lower
    /// the health factor; the account ends with less debt and fewer units, and LPVaultSwap holds nothing.
    // TEST-239 verifies: SPEC-LIQ-020, REQ-SWAP-106, INV-089
    function testFuzz_TEST_239_successiveDeleverages(
        uint256 first,
        uint256 second
    ) public {
        first = bound(first, 10e6, 3000e6);
        second = bound(second, 10e6, 3000e6);
        uint256 debt = _debtOf(proxy, usdcReserveId);
        uint256 hf = _hf(proxy);
        vm.prank(alice);
        (uint256 r1,) =
            adapter.repayWithCollateral(proxy, _position(key), uint128(first), usdcReserveId, new uint256[](2), 0);
        uint256 hfMid = _hf(proxy);
        vm.prank(alice);
        (uint256 r2,) =
            adapter.repayWithCollateral(proxy, _position(key), uint128(second), usdcReserveId, new uint256[](2), 0);
        assertEq(r1, _capOf(first, P_VAULT), "first x");
        assertEq(r2, _capOf(second, P_VAULT), "second x");
        assertEq(_debtOf(proxy, usdcReserveId), debt - r1 - r2, "debt down by both");
        assertGe(hfMid, hf, "first never lowers HF");
        assertGe(_hf(proxy), hfMid, "second never lowers HF");
        assertEq(usdc.balanceOf(address(lvs)), 0, "LPVaultSwap keeps no USDC");
        assertEq(usdt.balanceOf(address(lvs)), 0, "LPVaultSwap keeps no USDT");
        assertEq(vt.balanceOf(address(lvs)), 0, "LPVaultSwap keeps no vault tokens");
    }
}
