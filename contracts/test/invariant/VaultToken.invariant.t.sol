// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";
import {CollWorld, CollateralizationHandler} from "./handlers/CollateralizationHandler.sol";
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
contract VaultTokenInvariantTest is CollateralizationFixture {
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
