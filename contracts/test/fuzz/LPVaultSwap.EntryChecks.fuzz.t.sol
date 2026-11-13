// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapEntryChecksFuzzTest
/// @notice The account and identifier checks of `liquidate` fuzzed (2.11 REQ-SWAP-004 to REQ-SWAP-009,
/// REQ-SWAP-030): `NotLiquidatable` exactly while Aave's health factor is at or above 1 at the vault price; any market
/// ID other than the proxy's reverts `UnknownMarket`; any address that is not a registered proxy of the market reverts
/// `UnknownProxy`; any debt reserve other than an approved, borrowable one of the Spoke reverts `UnknownDebtReserve`;
/// each refusal leaves the debt, the caller's balance and LPVaultSwap unchanged.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 256
contract LPVaultSwapEntryChecksFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    function _refusedWithNothingMoved(
        LiquidationParams memory p,
        bytes memory err
    ) internal {
        uint256 debt = _debtOf(proxy, usdcReserveId);
        Snap memory s0 = _snap(keeper);
        _expectLiquidateRevert(keeper, p, err);
        assertEq(_debtOf(proxy, usdcReserveId), debt, "debt unchanged");
        assertEq(usdc.balanceOf(address(lvs)), s0.lvsUsdc, "LPVaultSwap unchanged");
    }

    /// @notice Bob holds 10,000 units against 18,000 USDC with CF 80 %: his HF is `10,000 × P × 0.8 / 18,000`. Any
    /// price at or above $2.25 (HF ≥ 1) refuses with `NotLiquidatable`; any price below settles.
    // TEST-055 verifies: REQ-SWAP-004, REQ-SWAP-005, INV-030
    function testFuzz_TEST_055_liquidatableExactlyBelowHfOne(
        uint256 price8
    ) public {
        price8 = bound(price8, 170_000_000, 300_000_000);
        lpOracle.setAnswer(int256(price8));
        uint256 hf = _hf(proxy);
        if (hf >= 1e18) {
            _refusedWithNothingMoved(_params(proxy, 1950e6), _err(ILPVaultSwapErrors.NotLiquidatable.selector));
        } else {
            // Above $2.09 the vault is priced over its released tokens' leg value: a budget tops up the floor gap.
            LiquidationParams memory p = _params(proxy, 1950e6);
            p.maxShortfall = 300e6;
            LiquidationResult memory r = _liquidateAs(keeper, p);
            assertGt(r.unitsSeized, 0, "below HF 1 settles");
            // INV-076: an account solvent at the bonus (HF ≥ LB × CF = 0.84) gains health; below it the seizure at the
            // bonus can only lower HF.
            if (hf >= 0.84e18) assertGt(_hf(proxy), hf, "HF rises");
        }
        assertEq(price8 >= 225_000_000, hf >= 1e18, "the threshold sits at $2.25");
    }

    /// @notice Any market ID other than 4 (the proxy's) reverts `UnknownMarket`.
    // TEST-055 verifies: REQ-SWAP-006, REQ-SWAP-045
    function testFuzz_TEST_055_unknownMarketId(
        uint256 marketId
    ) public {
        vm.assume(marketId != MARKET_ID);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.marketId = marketId;
        _refusedWithNothingMoved(p, _err(ILPVaultSwapErrors.UnknownMarket.selector));
    }

    /// @notice Any address that is not a proxy of the market reverts `UnknownProxy`.
    // TEST-055 verifies: REQ-SWAP-007, ATTACK-168
    function testFuzz_TEST_055_unknownProxyAddress(
        address stranger
    ) public {
        vm.assume(stranger != proxy);
        _refusedWithNothingMoved(_params(stranger, 1950e6), _err(ILPVaultSwapErrors.UnknownProxy.selector));
    }

    /// @notice Any debt reserve ID other than the USDC and GHO reserves reverts `UnknownDebtReserve(id)`.
    // TEST-055 verifies: REQ-SWAP-005, REQ-SWAP-030
    function testFuzz_TEST_055_unknownDebtReserveId(
        uint256 reserveId
    ) public {
        vm.assume(reserveId != usdcReserveId && reserveId != ghoReserveId);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.debtReserveId = reserveId;
        _refusedWithNothingMoved(p, abi.encodeWithSelector(ILPVaultSwapErrors.UnknownDebtReserve.selector, reserveId));
    }

    /// @notice A `debtToCover` far above the debt is capped by Aave at the debt it can repay; the unused funding
    /// returns inside `keeperOut` and the caller ends with `Kf − D + kr` more than it started without the funding.
    // TEST-048 verifies: REQ-SWAP-011, REQ-SWAP-016, SPEC-LIQ-017, REQ-ROUTE-037
    function testFuzz_TEST_048_oversizedFundingReturned(
        uint256 extra
    ) public {
        extra = bound(extra, 1, 1_000_000e6);
        (address carolProxy,) = _openAccount(carol, 1500e6, 2600e6, 250_000_000);
        uint256 debt = _debtOf(carolProxy, usdcReserveId);
        LiquidationResult memory r = _liquidateAs(keeper, _params(carolProxy, debt + extra));
        assertEq(r.callerFunds, debt + extra, "Kf is the whole funding");
        assertLe(r.debtRepaid, debt, "Aave repays at most the debt");
        assertEq(r.keeperOut, r.callerFunds - r.debtRepaid + r.recovered + r.shortfall - r.avanaFee - r.borrowerSurplus);
        assertGe(r.keeperOut, r.callerFunds - r.debtRepaid, "the unused funding returns");
        assertEq(usdc.balanceOf(address(lvs)), 0, "nothing kept");
    }
}
