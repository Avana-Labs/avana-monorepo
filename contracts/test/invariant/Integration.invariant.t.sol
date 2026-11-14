// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPayoutEscrow} from "../../src/liquidation/payout-escrow/IPayoutEscrow.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
import {IntegrationHandler} from "./handlers/IntegrationHandler.sol";

/// @title IntegrationInvariantTest
/// @notice Invariant suite of the deployed stack (TEST-100, TEST-104, TEST-193, TEST-215 on the real AaveAdapter,
/// LPVaultSwap, RiskModule, Collateralization, Lens and flash liquidation helper over the real local Aave V4): three
/// borrowers with GHO and USDC debt act through the Adapter while keepers, unregistered callers and the public helper
/// liquidate through LPVaultSwap, an attacker calls the Spoke directly, the guardians move the pause state and freeze
/// wallets, and the environment moves the vault price, the feed clock and the route rates. After every call: every
/// completed liquidation kept its settlement postconditions; every account the Lens reported liquidatable with its
/// gates open was liquidated; no exit was refused while its own checks passed, and none by a stop; borrows and repay
/// with collateral respected the pause state; supply stayed backed; LPVaultSwap, the Adapter and the helper hold
/// nothing; the Lock is free; and the Lens's account view equals the Spoke.
/// forge-config: default.invariant.runs = 16
/// forge-config: default.invariant.depth = 24
/// forge-config: default.invariant.fail-on-revert = false
contract IntegrationInvariantTest is IntegrationFlows, HandlerReach {
    IntegrationHandler internal handler;
    address[] internal wallets;

    function setUp() public {
        _deployIntegration();
        wallets = [bob, alice, carol];
        address[] memory callers = new address[](3);
        (callers[0], callers[1], callers[2]) = (keeper, makeAddr("anyEoa"), makeAddr("otherCaller"));
        handler = new IntegrationHandler(
            IntegrationHandler.Env({
                adapter: adapterC,
                lvs: lvs,
                helper: address(helper),
                lens: lens,
                reg: reg,
                lpo: lpo,
                usdcOracle: usdcOracle,
                vault: vault,
                v3Pool: v3Pool,
                primaryPool: usdtUsdcPool,
                usdc: usdc,
                usdt: usdt,
                gho: debt,
                vt: vt,
                spoke: aave.cdpSpoke,
                hub: aave.hub,
                marketId: MARKET_ID,
                vtReserveId: vtReserveId,
                usdcReserveId: usdcReserveId,
                ghoReserveId: debtReserveId,
                integrationId: INTEGRATION,
                wallets: wallets,
                callers: callers,
                attacker: attacker,
                feeRecipient: feeRecipient,
                escrow: IPayoutEscrow(address(escrow)),
                coll: address(coll),
                usdcSources: _sources(address(usdc)),
                ghoSources: _sources(address(debt))
            })
        );
        // Accounts at HF about 1.05 at $2.10: a fall below about $2.00 makes them liquidatable.
        (, bytes32 k0) = _openAccount(bob, MARKET_ID, 10_000e6, 16_000e6, P_VAULT);
        handler.seedKey(bob, k0);
        (, bytes32 k1) = _openAccount(alice, MARKET_ID, 6000e6, 0, P_VAULT);
        _borrowVia(alice, MARKET_ID, debtReserveId, 9600e18);
        handler.seedKey(alice, k1);
        (, bytes32 k2) = _openAccount(carol, MARKET_ID, 3000e6, 2300e6, P_VAULT);
        _borrowVia(carol, MARKET_ID, debtReserveId, 2500e18);
        handler.seedKey(carol, k2);
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: _actions()}));
    }

    // TEST-104 verifies: SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-022, REQ-SWAP-012, REQ-SWAP-042, REQ-SWAP-073, REQ-ADAPTER-070, INV-035, INV-038, INV-095
    /// @notice Every settlement kept its postconditions, also on balances: the debt asset that left the caller and the
    /// unwind reached the Hub, the fee recipient, the borrower and (through the public helper) the flash lender's
    /// premium, nothing appeared or vanished, and the result (direct) or the helper's `FlashLiquidated` event reported
    /// those balance changes.
    function invariant_TEST_104_everySettlementKeptItsPostconditions() public view {
        assertEq(handler.settlementBreaks(), 0, "a settlement broke a postcondition");
        assertEq(
            handler.conservationBreaks(), 0, "debt asset in (caller + unwind) != out (Hub + fee + borrower + lender)"
        );
        assertEq(handler.reportBreaks(), 0, "the result does not report the balance changes");
    }

    // TEST-082 verifies: TEST-007
    /// @notice The handler reaches the states the settlement invariants are about: over 16 fixed-seed runs of 24 calls
    /// from this suite's set-up state, a direct liquidation (checked on balances) completes in at least 50 % of the
    /// runs and one through the public flash liquidation helper in at least 40 % (before steering: 1 and 0 runs of 16).
    /// At this depth `liquidate` is called about twice a run, which bounds the reach; at the ci depth of 100, 12 and
    /// 11 runs of 16. The handler's actions return when there is nothing to do rather than revert, so per-action
    /// success is not measured here (floors 0).
    function test_TEST_082_handlerReach() public {
        string[] memory names = new string[](14);
        (names[0], names[1], names[2], names[3], names[4]) =
        ("pledge", "borrow", "repay", "withdrawDebtFree", "repayAllAndWithdraw");
        (names[5], names[6], names[7], names[8], names[9]) =
        ("repayWithCollateral", "liquidate", "settlePending", "directLiquidation", "setPause");
        (names[10], names[11], names[12], names[13]) = ("freeze", "movePrice", "moveRoutes", "warp");
        string[] memory targets = new string[](2);
        (targets[0], targets[1]) = ("direct liquidation", "helper liquidation");
        uint256[] memory minReach = new uint256[](2);
        (minReach[0], minReach[1]) = (50, 40);
        Reach memory r = _replay(address(handler), _actions(), bytes4(0), 16, 24, 2);
        _check(r, names, targets, _floors(14, 0), minReach);
    }

    function _reached() internal view override returns (bool[] memory hit) {
        hit = new bool[](2);
        hit[0] = handler.directLiquidations() != 0;
        hit[1] = handler.helperLiquidations() != 0;
    }

    /// @dev The fuzzed actions (`seedKey` is set-up only).
    function _actions() internal pure returns (bytes4[] memory a) {
        a = new bytes4[](14);
        (a[0], a[1], a[2], a[3], a[4]) =
        (
            IntegrationHandler.pledge.selector,
            IntegrationHandler.borrow.selector,
            IntegrationHandler.repay.selector,
            IntegrationHandler.withdrawDebtFree.selector,
            IntegrationHandler.repayAllAndWithdraw.selector
        );
        (a[5], a[6], a[7], a[8], a[9]) =
        (
            IntegrationHandler.repayWithCollateral.selector,
            IntegrationHandler.liquidate.selector,
            IntegrationHandler.settlePending.selector,
            IntegrationHandler.directLiquidation.selector,
            IntegrationHandler.setPause.selector
        );
        (a[10], a[11], a[12], a[13]) =
        (
            IntegrationHandler.freeze.selector,
            IntegrationHandler.movePrice.selector,
            IntegrationHandler.moveRoutes.selector,
            IntegrationHandler.warp.selector
        );
    }

    /// @dev Five words, with the `bool` parameters of `borrow`, `repay`, `repayWithCollateral`, `liquidate`, `freeze`
    /// and `settlePending` reduced to 0 or 1.
    function _calldata(
        bytes4 selector,
        uint256 seed
    ) internal pure override returns (bytes memory) {
        uint256 mask = 0;
        if (selector == IntegrationHandler.borrow.selector) mask = 1 << 2;
        else if (selector == IntegrationHandler.repay.selector) mask = 1 << 3;
        else if (selector == IntegrationHandler.repayWithCollateral.selector) mask = 1 << 3;
        else if (selector == IntegrationHandler.liquidate.selector) mask = (1 << 2) | (1 << 3) | (1 << 4);
        else if (selector == IntegrationHandler.freeze.selector) mask = 1 << 1;
        else if (selector == IntegrationHandler.settlePending.selector) mask = 1 << 1;
        uint256[5] memory w;
        for (uint256 i = 0; i < 5; ++i) {
            w[i] = _word(seed, i + 1);
            if (mask & (1 << i) != 0) w[i] %= 2;
        }
        return abi.encodeWithSelector(selector, w[0], w[1], w[2], w[3], w[4]);
    }

    /// @dev The holders a liquidation into `asset` pays from: the market's LPVault and both route pools from each
    /// other market token into `asset`.
    function _sources(
        address asset
    ) internal view returns (address[] memory s) {
        address[2] memory tokens = [address(usdc), address(usdt)];
        s = new address[](asset == tokens[0] || asset == tokens[1] ? 3 : 5);
        s[0] = address(vault);
        uint256 n = 1;
        for (uint256 i = 0; i < 2; ++i) {
            if (tokens[i] == asset) continue;
            s[n++] = address(routePools[tokens[i]][asset][0]);
            s[n++] = address(routePools[tokens[i]][asset][1]);
        }
    }

    // TEST-100 verifies: INV-046, INV-067, REQ-SWAP-001, REQ-SWAP-003, REQ-ADAPTER-070, REQ-HELPER-002
    function invariant_TEST_100_liquidatableAccountsSettle() public view {
        assertEq(handler.livenessFailures(), 0, "an account with every gate open was not liquidated");
    }

    // TEST-193 verifies: REQ-ADAPTER-047, REQ-ADAPTER-071, REQ-ADAPTER-086, REQ-PROXY-032, REQ-PROXY-035, INV-043, INV-045, INV-067, INV-081
    function invariant_TEST_193_exitsNeverRefused() public view {
        assertEq(handler.exitBlockedByStop(), 0, "an exit refused by a pause, freeze or breaker");
        assertEq(handler.exitFailures(), 0, "an exit refused while its own checks passed");
    }

    // TEST-193 verifies: REQ-ADAPTER-045, REQ-ADAPTER-046, REQ-ADAPTER-072, REQ-ADAPTER-073, REQ-ADAPTER-080, REQ-ADAPTER-082, SPEC-PROXY-009
    function invariant_TEST_193_newActivityFollowsThePauseState() public view {
        assertEq(handler.gateBreaks(), 0, "a borrow or repay with collateral passed a closed gate");
    }

    // TEST-215 verifies: INV-001, INV-021, INV-080, REQ-SWAP-042, REQ-SWAP-084, ATTACK-002
    function invariant_TEST_215_backedNeutralAndExclusive() public view {
        assertEq(token.totalSupply(), coll.getTotalCredited(vt) + coll.getPending(vt).units, "supply = credited");
        assertEq(usdc.balanceOf(lpVaultSwap) + usdt.balanceOf(lpVaultSwap) + debt.balanceOf(lpVaultSwap), 0, "LVS");
        assertEq(token.balanceOf(lpVaultSwap), 0, "LPVaultSwap holds no vault token");
        assertEq(usdc.balanceOf(adapter) + usdt.balanceOf(adapter) + debt.balanceOf(adapter), 0, "Adapter");
        assertEq(usdc.balanceOf(address(helper)) + debt.balanceOf(address(helper)), 0, "helper");
        assertEq(token.balanceOf(attacker), 0, "no direct seizure");
        assertEq(handler.directSeizures(), 0, "no direct seizure");
        assertFalse(lock.isLocked(), "Lock free");
    }

    // TEST-215 verifies: REQ-LENS-009, REQ-LENS-011
    function invariant_TEST_215_lensMatchesChain() public view {
        for (uint256 i = 0; i < wallets.length; ++i) {
            address proxy = adapterC.proxyOf(wallets[i], MARKET_ID);
            assertEq(lens.getAccount(wallets[i], MARKET_ID).healthFactor, _hf(proxy), "Lens HF = Spoke HF");
            assertEq(
                lens.getAccount(wallets[i], MARKET_ID).markets[0].credited,
                coll.getAccountCredited(proxy, vt),
                "Lens credited = Collateralization"
            );
        }
    }

    /// @notice A fixed sequence: a price fall, liquidations by the keeper (direct, GHO) and through the helper (USDC),
    /// the borrower's repay and debt-free exit under Paused(MintPathSuspect).
    // TEST-215 verifies: INV-001, INV-021, INV-080
    function test_TEST_215_handlerSequenceSettles() public {
        handler.movePrice(150_000_000);
        handler.liquidate(1, 0, true, false, false);
        handler.liquidate(0, 1, false, true, true);
        handler.setPause(3);
        handler.repay(0, 0, 3, false);
        handler.withdrawDebtFree(0, 0);
        assertGe(handler.liquidations(), 2, "both liquidations settled");
        assertEq(handler.livenessFailures(), 0, "no liveness failure");
        assertEq(handler.settlementBreaks(), 0, "postconditions held");
        assertEq(handler.exitFailures(), 0, "exits settled");
        invariant_TEST_215_backedNeutralAndExclusive();
    }
}
