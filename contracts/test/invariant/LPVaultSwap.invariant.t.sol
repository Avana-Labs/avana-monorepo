// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";
import {LPVaultSwapHandler} from "./handlers/LPVaultSwapHandler.sol";

/// @title LPVaultSwapInvariantTest
/// @notice Invariant suite of LPVaultSwap on the real local Aave V4 (TEST-090, TEST-092, TEST-093 for LPVaultSwap):
/// random sequences of liquidations by registered and unregistered callers in both route modes with shortfall
/// budgets, pause-state moves (None, Frozen, Paused with either reason), price and route moves, donations, direct `liquidationCall` attempts by an attacker and pending
/// settlements. After every call: every completed liquidation conserved the debt asset and met its floor with
/// `D ≤ Kf`; no direct liquidation ever seized; LPVaultSwap holds only donations (no debt asset, pool token or vault
/// token of its own) and grants no allowance; the Lock is free; vault-token supply stays within credited plus
/// pending units; the registry keeps its floor; and while an account was solvent at the bonus a liquidation never
/// lowered its health factor.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 32
contract LPVaultSwapInvariantTest is LPVaultSwapUnitBase {
    LPVaultSwapHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory proxies = new address[](3);
        (proxies[0],) = _openAccount(bob, 10_000e6, 18_000e6, 250_000_000);
        (proxies[1],) = _openAccount(alice, 6000e6, 10_300e6, 250_000_000);
        (proxies[2],) = _openAccount(carol, 1500e6, 2600e6, 250_000_000);
        address[] memory callers = new address[](3);
        (callers[0], callers[1], callers[2]) = (keeper, makeAddr("anyEoa"), makeAddr("otherKeeper"));
        handler = new LPVaultSwapHandler(
            LPVaultSwapHandler.Env({
                lvs: lvs,
                usdc: usdc,
                usdt: usdt,
                vt: address(vt),
                spoke: aave.cdpSpoke,
                hub: aave.hub,
                usdcAssetId: usdcAssetId,
                vtReserveId: vtReserveId,
                usdcReserveId: usdcReserveId,
                marketId: MARKET_ID,
                lpOracle: lpOracle,
                registry: registry,
                primaryPool: usdtUsdcPool,
                backupPool: usdtUsdcPool2,
                proxies: proxies,
                callers: callers,
                attacker: attacker
            })
        );
        targetContract(address(handler));
    }

    // TEST-093 verifies: SPEC-LIQ-010, REQ-SWAP-029, REQ-SWAP-073, INV-035, INV-037, INV-038, INV-097
    // TEST-104 verifies: SPEC-LIQ-010, REQ-SWAP-073, INV-035, INV-038
    function invariant_TEST_093_everyLiquidationConservesAndMeetsFloor() public view {
        assertEq(handler.conservationBreaks(), 0, "Kf + R + shortfall != D + A + B + keeperOut");
        assertEq(handler.floorBreaks(), 0, "floor or D <= Kf broken");
    }

    // TEST-090 verifies: REQ-SWAP-084, INV-013, INV-041, ATTACK-002
    // TEST-215 verifies: REQ-SWAP-084, ATTACK-002
    function invariant_TEST_090_seizureOnlyThroughLPVaultSwap() public view {
        assertEq(handler.directSeizures(), 0, "a direct liquidationCall seized");
        assertEq(vt.balanceOf(attacker), 0, "attacker holds vault tokens");
    }

    // TEST-092 verifies: REQ-SWAP-042, REQ-SWAP-043, REQ-SWAP-044, INV-021, INV-035, INV-070
    // TEST-093 verifies: REQ-SWAP-042, INV-037
    function invariant_TEST_092_lpVaultSwapHoldsOnlyDonations() public view {
        assertEq(usdc.balanceOf(address(lvs)), handler.donatedUsdc(), "LPVaultSwap kept or lost USDC");
        assertEq(usdt.balanceOf(address(lvs)), handler.donatedUsdt(), "LPVaultSwap kept or lost USDT");
        assertEq(vt.balanceOf(address(lvs)), 0, "LPVaultSwap kept vault tokens");
        assertEq(gho.balanceOf(address(lvs)), 0, "LPVaultSwap kept GHO");
        _assertNoAllowances();
        assertFalse(lock.isLocked(), "Lock left held");
    }

    // TEST-092 verifies: INV-001, INV-080, REQ-SWAP-092
    function invariant_TEST_092_supplyBacked() public view {
        assertLe(vt.totalSupply(), coll.getTotalCredited(address(vt)) + coll.getPending(address(vt)).units, "backing");
    }

    // TEST-098 verifies: REQ-SWAP-034, INV-048
    function invariant_TEST_098_registryFloor() public view {
        assertGe(lvs.approvedKeeperCount(), 1, "registry below its floor");
    }

    // TEST-216 verifies: INV-076
    function invariant_TEST_216_solventAccountHealthNeverFalls() public view {
        assertEq(handler.hfDrops(), 0, "a liquidation lowered the HF of an account solvent at the bonus");
    }

    // TEST-093 verifies: REQ-SWAP-029, REQ-SWAP-121
    /// @notice Every refused liquidation fails with an error the spec names for its condition (never a raw panic, an
    /// unnamed revert, a pause error or an Aave error other than the dust rule), in every pause state the handler moves
    /// the MarketRegistry through.
    // TEST-100 verifies: REQ-SWAP-121, INV-038, Q-404
    // TEST-193 verifies: REQ-ACCESS-068, INV-045, INV-046
    function invariant_TEST_093_refusalsAreNamed() public {
        if (handler.unexpectedReverts() != 0) emit log_bytes(handler.lastUnexpected());
        assertEq(handler.unexpectedReverts(), 0, "a liquidation reverted with an unnamed error");
    }

    /// @notice The handler's actions settle: a fixed sequence of donations, a pending settlement attempt, a direct
    /// liquidation attempt and route moves leaves all three accounts liquidatable through LPVaultSwap by different
    /// callers in both route modes.
    function test_handlerSequenceSettles() public {
        handler.donate(5, 7);
        handler.settlePending(1);
        handler.directLiquidation(0, 100e6, true);
        handler.moveRoutes(9600, 10_400);
        handler.liquidate(0, 1950e6, false, 0, 0);
        handler.liquidate(1, 1950e6, true, 0, 1);
        handler.liquidate(2, 900e6, true, 0, 2);
        assertEq(handler.liquidations(), 3, "every action settled");
        assertEq(handler.unexpectedReverts(), 0, "no unnamed refusal");
        assertEq(handler.directSeizures(), 0, "direct attempt refused");
        invariant_TEST_092_lpVaultSwapHoldsOnlyDonations();
    }
}
