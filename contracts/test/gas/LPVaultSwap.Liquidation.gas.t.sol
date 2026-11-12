// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";

/// @title LPVaultSwapLiquidationGasTest
/// @notice TEST-123 on the local Aave V4 with LPVaultSwap, Collateralization and the routes: an account-market of 16
/// records (15 small, one large; the record bound of `INV-096`) whose collateral is seized in full below
/// HF = bonus × CF, in successive calls the keeper sizes from the account's remaining debt. Every call stays within
/// the per-call budget, the calls together seize every unit, and a small call costs about the same on an account of
/// 16 records as on an account of one: gas grows with the records a call debits, not with the records held. Run for
/// USDC debt (caller funding and swap legs into USDC) and GHO debt (legs into GHO). The LPVault and the pool are the
/// fixture's constant-cost mocks, so the figures are LPVaultSwap's, Collateralization's and Aave's work; the fork
/// suite of TEST-269 measures real unwinds against `G(16) = 5.15M`.
/// forge-config: default.isolate = false
contract LPVaultSwapLiquidationGasTest is LPVaultSwapUnitBase {
    /// @notice Per-call budget: `G(16)` of SPEC-BACK-016, the whole worst-case liquidation with real unwinds.
    uint256 internal constant CALL_BUDGET = 5_150_000;
    /// @notice A small call on a 16-record account costs at most this much more than on a one-record account.
    uint256 internal constant HELD_RECORDS_SLACK = 50_000;

    uint256 internal constant SMALL_UNITS = 100e6;
    uint256 internal constant LARGE_UNITS = 8500e6;

    function _sixteenRecords(
        address wallet,
        uint256 borrowed,
        bool ghoDebt
    ) internal returns (address proxy) {
        (proxy,) = _openAccount(wallet, uint128(LARGE_UNITS), 0, 250_000_000);
        lpOracle.setAnswer(250_000_000);
        for (uint256 i = 0; i < 15; ++i) {
            _addRecord(proxy, wallet, uint128(SMALL_UNITS));
        }
        if (ghoDebt) adapter.borrow(proxy, ghoReserveId, address(gho), borrowed * 1e12, wallet);
        else adapter.borrow(proxy, usdcReserveId, address(usdc), borrowed, wallet);
        lpOracle.setAnswer(int256(P_VAULT));
    }

    function _oneRecord(
        address wallet,
        uint256 borrowed
    ) internal returns (address proxy) {
        (proxy,) = _openAccount(wallet, uint128(LARGE_UNITS + 15 * SMALL_UNITS), borrowed, 250_000_000);
    }

    function _call(
        address proxy,
        uint256 debtToCover,
        bool ghoDebt
    ) internal returns (bool ok, uint256 used, LiquidationResult memory r) {
        LiquidationParams memory p = _params(proxy, debtToCover);
        if (ghoDebt) p.debtReserveId = ghoReserveId;
        (ghoDebt ? gho : usdc).mint(keeper, debtToCover);
        vm.startPrank(keeper);
        (ghoDebt ? gho : usdc).approve(address(lvs), debtToCover);
        uint256 start = gasleft();
        try lvs.liquidate(p) returns (LiquidationResult memory res) {
            used = start - gasleft();
            (ok, r) = (true, res);
        } catch {}
        (ghoDebt ? gho : usdc).approve(address(lvs), 0);
        vm.stopPrank();
    }

    function _bobAccountFor(
        address wallet
    ) internal returns (address proxy, bytes32 key) {
        (proxy, key) = _openAccount(wallet, 10_000e6, 18_000e6, 250_000_000);
    }

    /// @dev Seizes the account in calls of a quarter of its remaining debt (at least 1,000 USDC worth) until it holds
    /// no vault-token units or is no longer liquidatable; returns the number of calls and the largest call's gas.
    function _seizeAll(
        address proxy,
        bool ghoDebt
    ) internal returns (uint256 calls, uint256 maxUsed) {
        uint256 reserveId = ghoDebt ? ghoReserveId : usdcReserveId;
        uint256 minCall = ghoDebt ? 1000e18 : 1000e6;
        for (uint256 i = 0; i < 24 && _suppliedUnits(proxy) != 0 && _hf(proxy) < 1e18; ++i) {
            uint256 debt = _debtOf(proxy, reserveId);
            uint256 size = debt / 4 > minCall ? debt / 4 : debt;
            (bool ok, uint256 used,) = _call(proxy, size, ghoDebt);
            assertTrue(ok, "every sized call settles");
            if (used > maxUsed) maxUsed = used;
            ++calls;
        }
    }

    /// @notice USDC debt: 16 records at $1.85 (HF 0.80, below bonus × CF = 0.84, the whole-reserve branch); every call
    /// within `G(16)`, all units seized over the calls.
    // TEST-123 verifies: SPEC-BACK-016, REQ-SWAP-121, INV-096, Q-193, Q-194, Q-230
    function test_TEST_123_fullSeizureAcrossSixteenRecordsUsdc() public {
        address proxy = _sixteenRecords(bob, 18_000e6, false);
        lpOracle.setAnswer(185_000_000);
        assertLt(_hf(proxy), 0.84e18, "below bonus x CF");
        (uint256 calls, uint256 maxUsed) = _seizeAll(proxy, false);
        emit log_named_uint("calls, USDC debt, 16 records", calls);
        emit log_named_uint("largest call gas, USDC debt, 16 records", maxUsed);
        assertGt(calls, 1, "successive calls");
        assertLe(maxUsed, CALL_BUDGET, "per-call gas within G(16)");
        assertTrue(_suppliedUnits(proxy) == 0 || _hf(proxy) >= 1e18, "everything seized or the account restored");
        assertEq(coll.getAccountCredited(proxy, address(vt)), _suppliedUnits(proxy), "ledger follows Aave");
    }

    /// @notice GHO debt: the same 16-record account borrowing GHO, legs swapped into GHO.
    // TEST-123 verifies: SPEC-BACK-016, REQ-SWAP-121, REQ-SWAP-088, Q-235
    function test_TEST_123_fullSeizureAcrossSixteenRecordsGho() public {
        address proxy = _sixteenRecords(alice, 18_000e6, true);
        lpOracle.setAnswer(185_000_000);
        assertLt(_hf(proxy), 0.84e18, "below bonus x CF");
        (uint256 calls, uint256 maxUsed) = _seizeAll(proxy, true);
        emit log_named_uint("calls, GHO debt, 16 records", calls);
        emit log_named_uint("largest call gas, GHO debt, 16 records", maxUsed);
        assertGt(calls, 1, "successive calls");
        assertLe(maxUsed, CALL_BUDGET, "per-call gas within G(16)");
        assertTrue(_suppliedUnits(proxy) == 0 || _hf(proxy) >= 1e18, "everything seized or the account restored");
    }

    /// @notice A 50 USDC call on a 16-record account costs at most `HELD_RECORDS_SLACK` more than the same call on a
    /// one-record account of the same size and debt, both measured after a warm-up liquidation of a third account:
    /// records held but not debited add no per-record cost.
    // TEST-123 verifies: SPEC-BACK-016, Q-230
    function test_TEST_123_smallCallCostIndependentOfRecordsHeld() public {
        address many = _sixteenRecords(bob, 18_000e6, false);
        address one = _oneRecord(carol, 18_000e6);
        (address warm,) = _bobAccountFor(makeAddr("warmUp"));
        (bool okWarm,,) = _call(warm, 50e6, false); // warms the shared contracts so both measured calls run warm
        assertTrue(okWarm, "warm-up");
        (bool okMany, uint256 usedMany, LiquidationResult memory rMany) = _call(many, 50e6, false);
        (bool okOne, uint256 usedOne, LiquidationResult memory rOne) = _call(one, 50e6, false);
        assertTrue(okMany && okOne, "both settle");
        assertEq(rMany.unitsSeized, rOne.unitsSeized, "same seizure");
        emit log_named_uint("small call gas, 16 records held", usedMany);
        emit log_named_uint("small call gas, 1 record held", usedOne);
        assertLe(usedMany, usedOne + HELD_RECORDS_SLACK, "cost follows records debited, not held");
    }
}
