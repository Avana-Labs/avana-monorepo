// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPayoutEscrow} from "../../src/liquidation/payout-escrow/IPayoutEscrow.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
import {LPVaultSwapHandler} from "./handlers/LPVaultSwapHandler.sol";

/// @title LPVaultSwapInvariantTest
/// @notice Invariant suite of LPVaultSwap on the real local Aave V4 (TEST-090, TEST-092, TEST-093, TEST-100 for
/// LPVaultSwap): random sequences of liquidations by registered and unregistered callers in both route modes with
/// shortfall budgets, pause-state moves (None, Frozen, Paused with either reason), price and route moves, donations,
/// direct `liquidationCall` attempts by an attacker and pending settlements. After every call: every completed
/// liquidation conserved the debt asset on token balances (what left the caller and the unwind reached the Hub, the
/// fee recipient and the borrower, nothing appeared or vanished) and its result reported those balance changes; it met
/// its floor with `D ≤ Kf`; every account with HF < 1 can be liquidated by an unregistered caller; no direct
/// liquidation ever seized; LPVaultSwap holds only donations and the units an earlier implementation kept until
/// `settlePending` burns them (no debt asset, pool token or other vault token of its own) and grants no allowance; the Lock is free; vault-token supply stays within credited plus pending units; the registry
/// keeps its floor; and while an account was solvent at the bonus a liquidation never lowered its health factor.
/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 32
contract LPVaultSwapInvariantTest is LPVaultSwapUnitBase, HandlerReach {
    LPVaultSwapHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory proxies = new address[](3);
        (proxies[0],) = _openAccount(bob, 10_000e6, 18_000e6, 250_000_000);
        (proxies[1],) = _openAccount(alice, 6000e6, 10_300e6, 250_000_000);
        (proxies[2],) = _openAccount(carol, 1500e6, 2600e6, 250_000_000);
        // An earlier implementation seized 2,000 USDC of Bob's debt and kept the units: the next liquidation of Bob
        // reconciles them into Collateralization's pending balance, which `settlePending` then burns and settles.
        uint256 kept = _seizeAndKeep(proxies[0], 2000e6);
        address[] memory wallets = new address[](3);
        (wallets[0], wallets[1], wallets[2]) = (bob, alice, carol);
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
                wallets: wallets,
                callers: callers,
                attacker: attacker,
                feeRecipient: feeRecipient,
                escrow: IPayoutEscrow(address(escrow)),
                lpVault: address(lpVault),
                coll: address(coll),
                keptUnits: kept
            })
        );
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _actions()}));
    }

    // TEST-093 verifies: SPEC-LIQ-010, REQ-SWAP-029, REQ-SWAP-073, INV-035, INV-037, INV-038, INV-097
    // TEST-104 verifies: SPEC-LIQ-010, REQ-SWAP-073, INV-035, INV-038
    /// @notice Conservation on balances: for every completed liquidation, the USDC that left the caller and the unwind
    /// (the LPVault and both route pools) equals what reached the Hub, the fee recipient and the borrower (paid or
    /// escrowed), LPVaultSwap's balance is unchanged and the escrow rose by exactly the escrowed credit; the result's
    /// `D`, `A`, `B`, `R` and the caller's net equal those balance changes; `R + shortfall >= minOut` and `D <= Kf`.
    function invariant_TEST_093_everyLiquidationConservesAndMeetsFloor() public view {
        assertEq(handler.conservationBreaks(), 0, "USDC in (caller + unwind) != USDC out (Hub + fee + borrower)");
        assertEq(handler.reportBreaks(), 0, "the result does not report the balance changes");
        assertEq(handler.floorBreaks(), 0, "floor or D <= Kf broken");
    }

    // TEST-100 verifies: INV-046, INV-062, INV-067
    /// @notice Liveness: after every call, each account with HF < 1 and debt is liquidated (from a snapshot) by an
    /// unregistered caller funding all of its debt, in whatever pause state, price and routes the run reached, and is
    /// left at HF >= 1, with no debt or with no collateral; only `NoRouteAvailable` with both routes below the leg
    /// minimum may refuse it.
    function invariant_TEST_100_liquidatableAccountsCanBeLiquidated() public {
        (uint256 failures, bytes memory last,) = handler.probeLiveness();
        if (failures != 0) emit log_bytes(last);
        assertEq(failures, 0, "a liquidatable account could not be liquidated");
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
        assertEq(
            vt.balanceOf(address(lvs)), handler.keptUnits(), "LPVaultSwap holds vault tokens beyond the kept units"
        );
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

    /// @notice The handler's actions settle: a fixed sequence of donations, a pending settlement attempt (the kept
    /// units are not reconciled yet, so nothing is pending and the handler reports it skipped), a direct liquidation attempt and route moves leaves all three
    /// accounts liquidatable through LPVaultSwap by different callers in both route modes.
    // TEST-092 verifies: REQ-SWAP-042, INV-021
    function test_TEST_092_handlerSequenceSettles() public {
        handler.donate(5, 7);
        vm.expectRevert(LPVaultSwapHandler.Skipped.selector);
        handler.settlePending(1);
        handler.directLiquidation(0, 100e6, true);
        handler.moveRoutes(9600, 10_400);
        handler.liquidate(0, 1950e6, false, 0, 0);
        handler.liquidate(1, 1950e6, true, 0, 1);
        handler.liquidate(2, 900e6, true, 0, 2);
        assertEq(handler.liquidations(), 3, "every action settled");
        assertEq(handler.unexpectedReverts(), 0, "no unnamed refusal");
        assertEq(handler.directSeizures(), 0, "direct attempt refused");
        assertEq(handler.conservationBreaks() + handler.reportBreaks() + handler.floorBreaks(), 0, "balances");
        invariant_TEST_092_lpVaultSwapHoldsOnlyDonations();
    }

    // TEST-082 verifies: TEST-007
    /// @notice The handler does real work: over 32 fixed-seed runs of 32 calls from this suite's set-up state, each
    /// action succeeds in at least 30 % of its calls (a liquidation counts only when it completes; `settlePending` at
    /// least 5 %, since one call settles all that is pending), and the runs reach each target state: a completed
    /// liquidation, one by an unregistered caller and one paying a borrower surplus in at least 75 % of the runs, a
    /// backup-only liquidation in 60 %, a liquidation under Frozen or Paused and a pending settlement (which needs a
    /// liquidation of Bob first, to reconcile the kept units) in 50 %, and a shortfall top-up in 15 % (it needs the
    /// LPOracle price above the unwind's value, about $2.11, with the account still below HF 1 there, so mostly Bob's
    /// first liquidation).
    function test_TEST_082_handlerReach() public {
        string[] memory names = new string[](7);
        (names[0], names[1], names[2], names[3]) = ("liquidate", "movePause", "movePrice", "moveRoutes");
        (names[4], names[5], names[6]) = ("donate", "directLiquidation", "settlePending");
        uint256[] memory minOk = _floors(7, 30);
        minOk[6] = 5;
        string[] memory targets = new string[](7);
        (targets[0], targets[1], targets[2]) = ("liquidation", "liquidation while paused", "backup-only liquidation");
        (targets[3], targets[4], targets[5]) =
        ("unregistered caller liquidation", "shortfall top-up", "borrower surplus");
        targets[6] = "pending settlement";
        uint256[] memory minReach = _floors(7, 75);
        (minReach[1], minReach[2], minReach[4], minReach[6]) = (50, 60, 15, 50);
        Reach memory r = _replay(address(handler), _actions(), LPVaultSwapHandler.Skipped.selector, 32, 32, 7);
        _check(r, names, targets, minOk, minReach);
    }

    /// @dev `liquidate` and `directLiquidation` take a `bool` third argument.
    function _calldata(
        bytes4 selector,
        uint256 seed
    ) internal pure override returns (bytes memory) {
        if (selector == LPVaultSwapHandler.liquidate.selector) {
            return abi.encodeWithSelector(
                selector, _word(seed, 1), _word(seed, 2), _word(seed, 3) % 2 == 0, _word(seed, 4), _word(seed, 5)
            );
        }
        if (selector == LPVaultSwapHandler.directLiquidation.selector) {
            return abi.encodeWithSelector(selector, _word(seed, 1), _word(seed, 2), _word(seed, 3) % 2 == 0);
        }
        return abi.encodeWithSelector(selector, _word(seed, 1), _word(seed, 2), _word(seed, 3));
    }

    function _reached() internal view override returns (bool[] memory hit) {
        hit = new bool[](7);
        hit[0] = handler.liquidations() != 0;
        hit[1] = handler.liquidationsWhilePaused() != 0;
        hit[2] = handler.backupOnlyLiquidations() != 0;
        hit[3] = handler.unregisteredLiquidations() != 0;
        hit[4] = handler.shortfallLiquidations() != 0;
        hit[5] = handler.surplusLiquidations() != 0;
        hit[6] = handler.settlements() != 0;
    }

    function _actions() internal pure returns (bytes4[] memory actions) {
        actions = new bytes4[](7);
        actions[0] = LPVaultSwapHandler.liquidate.selector;
        actions[1] = LPVaultSwapHandler.movePause.selector;
        actions[2] = LPVaultSwapHandler.movePrice.selector;
        actions[3] = LPVaultSwapHandler.moveRoutes.selector;
        actions[4] = LPVaultSwapHandler.donate.selector;
        actions[5] = LPVaultSwapHandler.directLiquidation.selector;
        actions[6] = LPVaultSwapHandler.settlePending.selector;
    }
}
