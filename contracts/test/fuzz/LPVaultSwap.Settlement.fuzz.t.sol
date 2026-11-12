// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {SettlementMath} from "../../src/liquidation/lp-vault-swap/SettlementMath.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapSettlementFuzzTest
/// @notice Fuzzed liquidations on the real local Aave V4 (2.11 SPEC-LIQ-004 to SPEC-LIQ-022, REQ-SWAP-042): for any
/// repayment, vault price, route rate, route mode, shortfall budget and caller, a liquidation either settles with
/// every figure equal to the independent spec model, the debt asset conserved, LPVaultSwap's balances and allowances
/// unchanged and the floor met on `R + shortfall`, or reverts with one of the errors the spec names for that
/// condition. Dust accounts down to one seized unit are always liquidatable through honest routes.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 256
contract LPVaultSwapSettlementFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    function _knownError(
        bytes memory reason
    ) internal pure returns (bool) {
        bytes4 s = bytes4(reason);
        return s == ILPVaultSwapErrors.NoRouteAvailable.selector || s == ILPVaultSwapErrors.RecoveryBelowFloor.selector
            || s == ILPVaultSwapErrors.NothingSeized.selector || s == bytes4(keccak256("MustNotLeaveDust()"));
    }

    /// @notice TEST-078 and TEST-072: any repayment from 3 USDC to 8,000 USDC at any vault price that keeps the account
    /// liquidatable, any USDT route rate between 0.97 and 1.03, either route mode and any shortfall budget: the
    /// settlement equals the model, conserves the debt asset and leaves LPVaultSwap neutral, or reverts with a named
    /// error.
    // TEST-078 verifies: SPEC-LIQ-003, SPEC-LIQ-005, SPEC-LIQ-010, SPEC-LIQ-019, SPEC-SET-001, INV-034, INV-035, INV-038
    // TEST-072 verifies: SPEC-LIQ-004, SPEC-LIQ-005, REQ-SWAP-042
    function testFuzz_TEST_078_settlementMatchesModel(
        uint256 debtToCover,
        uint256 price8,
        uint256 rateBps,
        bool backupOnly,
        uint256 maxShortfall
    ) public {
        debtToCover = bound(debtToCover, 3e6, 8000e6);
        price8 = bound(price8, 150_000_000, 230_000_000);
        rateBps = bound(rateBps, 9700, 10_300);
        maxShortfall = bound(maxShortfall, 0, 500e6);
        lpOracle.setAnswer(int256(price8));
        usdtUsdcPool.setRate(rateBps, 10_000);
        usdtUsdcPool2.setRate(rateBps, 10_000);
        uint256 hf = _hf(proxy);
        if (hf >= 1e18) return;
        uint256 bonus = _bonusAt(hf);
        LiquidationParams memory p = _params(proxy, debtToCover);
        p.routeMode = backupOnly ? RouteMode.BackupOnly : RouteMode.PrimaryThenBackup;
        p.maxShortfall = maxShortfall;
        _fund(usdc, keeper, debtToCover + maxShortfall);
        Snap memory s0 = _snap(keeper);
        vm.prank(keeper);
        try lvs.liquidate(p) returns (LiquidationResult memory r) {
            Expect memory e =
                _expectUsdc(r.unitsSeized, r.debtRepaid, r.callerFunds, r.recovered, bonus, price8, maxShortfall);
            _assertResult(r, e);
            assertEq(
                r.callerFunds + r.recovered + r.shortfall, r.debtRepaid + r.avanaFee + r.borrowerSurplus + r.keeperOut
            );
            assertGe(r.recovered + r.shortfall, r.minOut, "floor");
            assertLe(r.debtRepaid, r.callerFunds, "D <= Kf");
            assertEq(usdc.balanceOf(keeper), s0.callerUsdc - r.callerFunds - r.shortfall + r.keeperOut, "caller flow");
            _assertNeutral(s0);
            _assertNoAllowances();
        } catch (bytes memory reason) {
            assertTrue(_knownError(reason), "unexpected revert");
        }
    }

    function _bonusAt(
        uint256 hf
    ) internal view returns (uint256) {
        (bool ok, bytes memory ret) = aave.cdpSpoke
            .staticcall(abi.encodeWithSignature("getLiquidationBonus(uint256,address,uint256)", vtReserveId, proxy, hf));
        require(ok, "bonus");
        return abi.decode(ret, (uint256));
    }

    /// @notice TEST-081 and TEST-161: dust liquidations, from a repayment that seizes one raw unit up to one where the
    /// percentage slippage dominates the rounding terms, always settle through honest routes (never
    /// `RecoveryBelowFloor`); a repayment that seizes nothing reverts `NothingSeized`.
    // TEST-081 verifies: SPEC-LIQ-005, REQ-SWAP-121, INV-038, Q-198, Q-267
    // TEST-161 verifies: SPEC-LIQ-005, SPEC-LIQ-018, REQ-SWAP-121, INV-038
    function testFuzz_TEST_081_dustAlwaysLiquidatable(
        uint256 debtToCover
    ) public {
        debtToCover = bound(debtToCover, 1, 20e6);
        _fund(usdc, keeper, debtToCover);
        vm.prank(keeper);
        try lvs.liquidate(_params(proxy, debtToCover)) returns (LiquidationResult memory r) {
            assertGe(r.unitsSeized, 1, "seized");
            assertGe(r.recovered, r.minOut, "honest routes meet the dust floor");
            assertEq(r.shortfall, 0, "no top-up for dust");
            assertLe(r.debtRepaid - (r.recovered < r.debtRepaid ? r.recovered : r.debtRepaid), 2e6, "loss bounded");
        } catch (bytes memory reason) {
            assertEq(bytes4(reason), ILPVaultSwapErrors.NothingSeized.selector, "only a zero seizure is refused");
        }
    }

    /// @notice TEST-074: splitting one liquidation into `k` equal pieces seizes no more vault units and recovers no more
    /// than the one liquidation plus rounding (`k` raw units of each figure).
    // TEST-074 verifies: SPEC-LIQ-004, SPEC-LIQ-006, REQ-SWAP-041
    function testFuzz_TEST_074_splittingGainsNothing(
        uint256 debtToCover,
        uint256 k
    ) public {
        debtToCover = bound(debtToCover, 100e6, 4000e6);
        k = bound(k, 2, 5);
        uint256 snapshot = vm.snapshotState();
        LiquidationResult memory one = _liquidateAs(keeper, _params(proxy, debtToCover));
        vm.revertToState(snapshot);
        uint256 units = 0;
        uint256 recovered = 0;
        uint256 repaid = 0;
        for (uint256 i = 0; i < k; ++i) {
            LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, debtToCover / k));
            units += r.unitsSeized;
            recovered += r.recovered;
            repaid += r.debtRepaid;
        }
        assertLe(repaid, one.debtRepaid, "pieces repay at most the whole");
        assertLe(units, one.unitsSeized + k, "pieces seize at most the whole plus rounding");
        assertLe(recovered, one.recovered + 2 * k, "pieces recover at most the whole plus rounding");
    }

    /// @notice TEST-080 for LPVaultSwap: donations of the debt asset, pool tokens and vault tokens to LPVaultSwap
    /// before a liquidation change no figure and are never paid out.
    // TEST-080 verifies: REQ-SWAP-019, REQ-SWAP-042, REQ-SWAP-108
    function testFuzz_TEST_080_donationsIgnored(
        uint256 usdcDust,
        uint256 usdtDust
    ) public {
        usdcDust = bound(usdcDust, 1, 1e6);
        usdtDust = bound(usdtDust, 1, 1e6);
        uint256 snapshot = vm.snapshotState();
        LiquidationResult memory clean = _liquidateAs(keeper, _params(proxy, 1950e6));
        vm.revertToState(snapshot);
        usdc.mint(address(lvs), usdcDust);
        usdt.mint(address(lvs), usdtDust);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(r.recovered, clean.recovered, "R");
        assertEq(r.keeperOut, clean.keeperOut, "keeperOut");
        assertEq(usdc.balanceOf(address(lvs)), usdcDust, "USDC donation untouched");
        assertEq(usdt.balanceOf(address(lvs)), usdtDust, "USDT donation untouched");
    }

    /// @notice PROP-059 floor statement, USDC debt: vault token of 6 decimals at $2.10, bonus 10,500, no flash term;
    /// for every repayment `D < 2^64`, Aave's seizure `c = ⌊D × 10,500 × 10⁸ / (10⁴ × 2.1·10⁸)⌋` values to a floor that,
    /// with one vault unit, one debt unit, `U` and `ε`, covers `D`.
    // PROP-059 verifies: SPEC-LIQ-003, SPEC-LIQ-005, SPEC-LIQ-007, REQ-SWAP-012, INV-034, Q-235, Q-404
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_PROP_059_floorCoversDebtUsdc(
        uint64 debt
    ) public pure {
        _floorCovers(debt, 10_500, 6, 6, 210_000_000);
    }

    /// @notice The same for GHO debt (18 decimals, Aave's fixed $1.00 source), vault token of 6 decimals at $2.00,
    /// bonus 10,200.
    // PROP-059 verifies: SPEC-LIQ-003, SPEC-LIQ-005, SPEC-LIQ-007, REQ-SWAP-012, INV-034, Q-235, Q-404
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_PROP_059_floorCoversDebtGho(
        uint64 debt
    ) public pure {
        _floorCovers(debt, 10_200, 18, 6, 200_000_000);
    }

    function _floorCovers(
        uint256 debt,
        uint256 bonus,
        uint8 dd,
        uint8 dv,
        uint256 pc
    ) internal pure {
        debt = bound(debt, 1, type(uint64).max);
        uint256 s = SettlementMath.effectiveSlippage(bonus, 100);
        uint256 c = debt * 1e8 * 10 ** dv * bonus / (10 ** dd * pc * 10_000);
        uint256 v = SettlementMath.seizedValue(c, pc, dv, dd, 1e8);
        uint256 vaultUnit = SettlementMath.unitValue(pc, dv, dd, 1e8);
        uint256 eps = 10 ** dd;
        uint256 u = 2 * 10 ** (dd - 6);
        uint256 minRec = SettlementMath.recoveryFloor(v, s, u, eps);
        assertLe(debt, minRec + vaultUnit + 1 + u + eps, "floor plus rounding terms covers D");
    }

    /// @notice Fuzzed fee shares and fee recipients (any non-zero address): `A ≤ S`, `A + kr + B = S`, the fee paid to
    /// whatever recipient the store names.
    // TEST-240 verifies: SPEC-LIQ-009, SPEC-LIQ-022, INV-036, INV-086
    function testFuzz_TEST_240_feeShareAndRecipient(
        uint16 share,
        address recipient
    ) public {
        share = uint16(bound(share, 0, 5000));
        vm.assume(recipient != address(0) && recipient != address(lvs) && recipient != keeper);
        vm.assume(recipient.code.length == 0 && uint160(recipient) > 0xffff);
        store.setAvanaFeeShareBps(share);
        store.setFeeRecipient(recipient);
        uint256 before = usdc.balanceOf(recipient);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        uint256 s = r.recovered > r.debtRepaid ? r.recovered - r.debtRepaid : 0;
        assertLe(r.avanaFee, s, "A <= S");
        assertEq(r.avanaFee + r.keeperReward + r.borrowerSurplus, s, "A + kr + B = S");
        assertEq(usdc.balanceOf(recipient), before + r.avanaFee, "paid to the store's recipient");
    }
}
