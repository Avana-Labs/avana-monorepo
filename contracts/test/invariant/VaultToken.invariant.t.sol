// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollWorld, CollateralizationHandler} from "./handlers/CollateralizationHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";
import {VaultTokenAttackerHandler} from "./handlers/VaultTokenAttackerHandler.sol";

/// @title VaultTokenInvariantTest
/// @notice Hub-side and holder invariants of the real vault token on the real local Aave V4 and the real
/// Collateralization, under the Collateralization handler's pledges, withdrawals, partial removals, re-credits,
/// borrows, repays, price moves, honest liquidations, seize-and-keep liquidations by a non-conforming LPVaultSwap and
/// pending settlements, and an attacker handler that sends transfers off the three allowed paths. After every call:
/// the Hub's vault-token balance equals its recorded liquidity and the proxies' supplied units, with added shares equal
/// to added assets; vault tokens sit only in the Hub and, for kept seizures, in LPVaultSwap, exactly the units the
/// pending balance and the unreconciled kept seizures account for; no proxy, the Adapter, the LPVault,
/// Collateralization or the attacker holds any; and every off-path transfer reverted `UnauthorizedTransfer`.
/// @dev The LPVault, RiskModule and LPOracle are the fixture's mocks; the AaveAdapter and LPVaultSwap are pranked
/// addresses (their contracts come later).
/// forge-config: default.isolate = false
contract VaultTokenInvariantTest is CollateralizationFixture, HandlerReach {
    CollateralizationHandler internal handler;
    VaultTokenAttackerHandler internal attacker_;

    function setUp() public {
        _deployCollateralization();
        CollWorld memory world = CollWorld({
            coll: coll,
            lock: lock,
            token: token,
            lpVault: lpVault,
            spoke: IAaveV4Spoke(aave.cdpSpoke),
            debt: debt,
            vtPrice: vtPrice,
            adapter: adapter,
            lpVaultSwap: lpVaultSwap,
            vtReserveId: vtReserveId,
            debtReserveId: debtReserveId,
            marketId: MARKET_ID
        });
        handler = new CollateralizationHandler(world, [aliceProxy, bobProxy], [alice, bob]);
        handler.seedAccounts();
        attacker_ = new VaultTokenAttackerHandler(
            token, [aave.hub, aliceProxy, bobProxy, lpVaultSwap, adapter, address(lpVault), address(coll), attacker]
        );
        targetContract(address(handler));
        targetContract(address(attacker_));
        bytes4[] memory actions = new bytes4[](10);
        actions[0] = CollateralizationHandler.pledge.selector;
        actions[1] = CollateralizationHandler.withdraw.selector;
        actions[2] = CollateralizationHandler.borrow.selector;
        actions[3] = CollateralizationHandler.repay.selector;
        actions[4] = CollateralizationHandler.setPrice.selector;
        actions[5] = CollateralizationHandler.liquidate.selector;
        actions[6] = CollateralizationHandler.seizeAndKeep.selector;
        actions[7] = CollateralizationHandler.settlePending.selector;
        actions[8] = CollateralizationHandler.partialRemove.selector;
        actions[9] = CollateralizationHandler.recredit.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    // TEST-082 verifies: TEST-007
    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls from set-up, counts per action the calls that
    /// changed the state of a contract other than the handler and this test, the skipped and failed calls and the
    /// calls that returned without changing anything; each action must change the state in at least its floor of
    /// calls (`forge test -vv` prints the table).
    function test_TEST_082_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r =
            _replayLanded(address(handler), actions, CollateralizationHandler.Skipped.selector, 32, 50, 0, own, true);
        _check(r, names, new string[](0), _floors(10, 0), new uint256[](0));
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions()
        internal
        pure
        returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds)
    {
        (actions, names, kinds) = (new bytes4[](10), new string[](10), new int16[][](10));
        (actions[0], names[0]) = (CollateralizationHandler.pledge.selector, "pledge");
        kinds[0] = new int16[](2);
        kinds[0][0] = 256;
        kinds[0][1] = 256;
        (actions[1], names[1]) = (CollateralizationHandler.withdraw.selector, "withdraw");
        kinds[1] = new int16[](2);
        kinds[1][0] = 256;
        kinds[1][1] = 256;
        (actions[2], names[2]) = (CollateralizationHandler.borrow.selector, "borrow");
        kinds[2] = new int16[](2);
        kinds[2][0] = 256;
        kinds[2][1] = 256;
        (actions[3], names[3]) = (CollateralizationHandler.repay.selector, "repay");
        kinds[3] = new int16[](1);
        kinds[3][0] = 256;
        (actions[4], names[4]) = (CollateralizationHandler.setPrice.selector, "setPrice");
        kinds[4] = new int16[](1);
        kinds[4][0] = 256;
        (actions[5], names[5]) = (CollateralizationHandler.liquidate.selector, "liquidate");
        kinds[5] = new int16[](3);
        kinds[5][0] = 256;
        kinds[5][1] = 256;
        kinds[5][2] = 256;
        (actions[6], names[6]) = (CollateralizationHandler.seizeAndKeep.selector, "seizeAndKeep");
        kinds[6] = new int16[](3);
        kinds[6][0] = 256;
        kinds[6][1] = 256;
        kinds[6][2] = 256;
        (actions[7], names[7]) = (CollateralizationHandler.settlePending.selector, "settlePending");
        kinds[7] = new int16[](1);
        kinds[7][0] = 256;
        (actions[8], names[8]) = (CollateralizationHandler.partialRemove.selector, "partialRemove");
        kinds[8] = new int16[](3);
        kinds[8][0] = 256;
        kinds[8][1] = 256;
        kinds[8][2] = 256;
        (actions[9], names[9]) = (CollateralizationHandler.recredit.selector, "recredit");
        kinds[9] = new int16[](3);
        kinds[9][0] = 256;
        kinds[9][1] = 256;
        kinds[9][2] = 256;
    }

    function _calldata(
        bytes4 selector,
        uint256 seed
    ) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
    }

    /// @notice Hub side: the Hub's vault-token balance equals its recorded liquidity for the asset and the sum of the
    /// proxies' supplied units on the CDP Spoke, and the asset's added shares equal its added assets.
    /// @dev Kills: a vault-token move to or from the Hub off the Spoke's accounting (a transfer path into the Hub other
    /// than the proxy's supply, or a Hub payout other than a withdrawal or a seizure).
    // TEST-086 verifies: INV-003, REQ-VTOKEN-006
    function invariant_TEST_086_hubBalanceEqualsLiquidityAndSuppliedUnits() public view {
        IAaveV4Hub hub = IAaveV4Hub(aave.hub);
        uint256 supplied = _shares(aliceProxy) + _shares(bobProxy);
        assertEq(token.balanceOf(aave.hub), hub.getAssetLiquidity(vtAssetId), "Hub balance = liquidity");
        assertEq(token.balanceOf(aave.hub), supplied, "Hub balance = supplied units");
        assertEq(hub.getAddedShares(vtAssetId), hub.getAddedAssets(vtAssetId), "added shares = added assets");
        assertEq(hub.getAddedAssets(vtAssetId), supplied, "added assets = supplied units");
    }

    /// @notice Holders at transaction end: the Hub and LPVaultSwap hold the whole supply; LPVaultSwap holds exactly
    /// the kept units, which are the pending units plus the kept seizures not yet reconciled; proxies, the Adapter,
    /// the LPVault, Collateralization and the attacker hold none.
    /// @dev Kills: a path that leaves units in a proxy, the Adapter, the LPVault or Collateralization between calls, or
    /// a transfer path that lets the attacker receive units.
    // TEST-087 verifies: INV-003, INV-011, REQ-VTOKEN-006, REQ-VTOKEN-016
    function invariant_TEST_087_holdersAtTransactionEnd() public view {
        assertEq(token.balanceOf(aliceProxy), 0, "alice proxy holds units");
        assertEq(token.balanceOf(bobProxy), 0, "bob proxy holds units");
        assertEq(token.balanceOf(adapter), 0, "Adapter holds units");
        assertEq(token.balanceOf(address(lpVault)), 0, "LPVault holds units");
        assertEq(token.balanceOf(address(coll)), 0, "Collateralization holds units");
        assertEq(token.balanceOf(attacker), 0, "attacker holds units");
        assertEq(token.balanceOf(aave.hub) + token.balanceOf(lpVaultSwap), token.totalSupply(), "only Hub and swap");
        uint256 unreconciled = handler.unreconciled(aliceProxy) + handler.unreconciled(bobProxy);
        assertEq(token.balanceOf(lpVaultSwap), handler.keptHeld(), "LPVaultSwap holds exactly the kept units");
        assertEq(
            token.balanceOf(lpVaultSwap), coll.getPending(vt).units + unreconciled, "kept = pending + unreconciled"
        );
    }

    /// @notice Every transfer the attacker handler sent off the paths proxy → Hub, Hub → proxy and Hub → LPVaultSwap
    /// (a zero amount, the wrong sender to an allowed recipient, or any other pair) reverted `UnauthorizedTransfer`.
    /// @dev Kills: removing or loosening the path check in `transfer`, `transferFrom` or `_update`.
    // TEST-087 verifies: INV-011, REQ-VTOKEN-006, REQ-VTOKEN-008, REQ-VTOKEN-030, REQ-VTOKEN-041
    function invariant_TEST_087_offPathTransfersRevert() public view {
        assertEq(attacker_.offPathAccepted(), 0, "off-path transfer accepted");
        assertEq(attacker_.wrongRevert(), 0, "off-path transfer reverted with another error");
    }

    /// @notice The supply bound of the backing invariant: total supply never exceeds the market's credited units plus
    /// its pending units, and equals them here because every burn is settled in its own call.
    // TEST-083 verifies: INV-001, REQ-VTOKEN-016
    function invariant_TEST_083_supplyAtMostCreditedPlusPending() public view {
        uint256 backing = coll.getTotalCredited(vt) + coll.getPending(vt).units;
        assertLe(token.totalSupply(), backing, "supply above backing");
        assertEq(token.totalSupply(), backing, "every burn settled in its call");
    }
}
