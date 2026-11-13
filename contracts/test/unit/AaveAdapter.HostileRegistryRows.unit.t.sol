// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";

/// @title AaveAdapterHostileRegistryRowsUnitTest
/// @notice A hostile MarketRegistry seen from the reviewed AaveAdapter (TEST-133): the fixture's settable
/// `AdapterRegistryMock` plays a registry implementation that remaps a market to another Spoke, Hub and vault token,
/// rewrites a debt reserve's definition and reports Paused. Driven through the real Adapter on the real local Aave V4,
/// Collateralization, vault tokens, ProxyManager and PositionProxies.
/// forge-config: default.isolate = false
contract AaveAdapterHostileRegistryRowsUnitTest is AaveAdapterFixture {
    bytes32 internal key;
    address internal proxy;
    address internal bobAccount;

    // TEST-133 verifies: REQ-ADAPTER-047, REQ-ADAPTER-065, REQ-ADAPTER-098, INV-017, INV-018, ATTACK-106
    // Sources: 5.1 TEST-133 (Adapter side), Q-119, Q-226, Q-227
    /// @notice Remapping market A to another Spoke, Hub and vault token and rewriting the GHO reserve's definition
    /// changes no vault-token immutable, no proxy's Spoke or market and no Collateralization record, and mints
    /// nothing: a new pledge into the remapped market is refused. With the remap still in force and the switch
    /// reporting Paused(MintPathSuspect), the borrower's repay and debt-free withdrawal and an honest liquidation of
    /// another account all complete, since none of them reads the registry's pause state.
    function test_TEST_133_hostileRegistryChangesNoBindingAndBlocksNoExit() public {
        (key, proxy) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        (, bobAccount) = _pledgeAs(bob, MARKET_ID, UNITS);
        _borrowAs(bob, MARKET_ID, debtReserveId, 15_000e18);
        BackingRecord memory r0 = coll.getRecord(coll.recordIdOf(INTEGRATION, key));
        uint256 supply0 = token.totalSupply();
        _hostileRemap();
        _bindingsUnchanged(r0);
        _noMint(supply0);
        _exitsAndLiquidationPass();
    }

    /// @dev Remaps market A to another Spoke, Hub and vault token, rewrites the GHO reserve and reports Paused.
    function _hostileRemap() internal {
        registry.setMarketSpoke(MARKET_ID, aave.lendSpoke);
        registry.setMarketHub(MARKET_ID, makeAddr("attackerHub"));
        registry.setMarketVaultToken(MARKET_ID, vtB);
        registry.setDebtReserve(
            aave.cdpSpoke, debtReserveId, _debtDef(debtReserveId, address(usdcDebt), 6, usdcAssetId)
        );
        registry.setPause(aave.hub, PauseState.Paused, PauseReason.MintPathSuspect);
    }

    /// @dev Bindings are immutables of the token and the proxy, and Collateralization's record is untouched.
    function _bindingsUnchanged(
        BackingRecord memory r0
    ) internal view {
        assertEq(token.spoke(), aave.cdpSpoke, "token spoke");
        assertEq(token.hub(), aave.hub, "token hub");
        assertEq(token.marketId(), MARKET_ID, "token market");
        assertEq(token.adapter(), adapter, "token adapter");
        assertEq(token.collateralization(), address(coll), "token collateralization");
        assertEq(IPositionProxy(proxy).SPOKE(), aave.cdpSpoke, "proxy spoke");
        assertEq(IPositionProxy(proxy).MARKET_ID(), MARKET_ID, "proxy market");
        BackingRecord memory r1 = coll.getRecord(coll.recordIdOf(INTEGRATION, key));
        assertEq(r1.proxy, r0.proxy, "record proxy");
        assertEq(r1.marketId, r0.marketId, "record market");
        assertEq(r1.credited, r0.credited, "record credit");
    }

    /// @dev Nothing is minted for the remapped market.
    function _noMint(
        uint256 supply0
    ) internal {
        bytes32 k2 = _newKey();
        lpVault.mintPosition(k2, carol, MARKET_ID, UNITS);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnknownMarket.selector, MARKET_ID));
        vm.prank(carol);
        adapterC.pledge(MARKET_ID, _ref(k2), d);
        assertEq(token.totalSupply(), supply0, "no mint in market A");
        assertEq(tokenB.totalSupply(), 0, "no mint in market B");
    }

    /// @dev Exits and liquidation pass with the remap and the Paused report in force.
    function _exitsAndLiquidationPass() internal {
        uint256 owed = _debtOf(proxy, debtReserveId);
        _fund(alice, debtReserveId, owed);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, owed, true, _deadline());
        assertEq(_debtOf(proxy, debtReserveId), 0, "repaid");
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(key), UNITS, _deadline(), 0);
        assertEq(lpVault.ownerOf(key), alice, "debt-free withdrawal");
        vtPrice.set(1.6e8);
        uint256 seized =
            swap.liquidate(aave.cdpSpoke, MARKET_ID, vt, vtReserveId, debtReserveId, bobAccount, 2000e18, 2);
        assertGt(seized, 0, "liquidation completed");
        assertLe(token.totalSupply(), coll.getTotalCredited(vt) + coll.getPending(vt).units, "backed");
    }
}
