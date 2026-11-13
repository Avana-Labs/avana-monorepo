// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BackingRecord} from "../../src/custody/collateralization/types/BackingRecord.sol";
import {Market} from "../../src/types/Market.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

/// @title VaultTokenHostileRegistryUnitTest
/// @notice A hostile MarketRegistry against the real vault token and Collateralization (5.1 TEST-133, vault-token and
/// Collateralization part): remapping the market to an attacker pool, Spoke, Hub, vault token and LPOracle, and
/// reporting `Paused`, changes none of the vault token's fixed bindings, no Collateralization record or total, and
/// mints nothing; the registry cannot mint or move vault tokens itself.
/// forge-config: default.isolate = false
contract VaultTokenHostileRegistryUnitTest is LPVaultSwapUnitBase {
    // TEST-133 verifies: REQ-VTOKEN-001, REQ-VTOKEN-003, REQ-COLL-002, Q-226
    function test_TEST_133_hostileRemapChangesNoBindingRecordOrSupply() public {
        (address proxy, bytes32 key) = _bobAccount();
        uint256 id = coll.recordIdOf(INTEGRATION, key);
        BackingRecord memory before = coll.getRecord(id);
        uint256 supply = vt.totalSupply();
        uint256 credited = coll.getAccountCredited(proxy, address(vt));
        uint256 total = coll.getTotalCredited(address(vt));

        Market memory m = registry.getMarket(MARKET_ID);
        m.pool = makeAddr("attackerPool");
        m.spoke = makeAddr("attackerSpoke");
        m.hub = makeAddr("attackerHub");
        m.vaultToken = makeAddr("attackerToken");
        m.lpOracle = makeAddr("attackerOracle");
        m.integration = makeAddr("attackerLPVault");
        registry.setMarket(MARKET_ID, m);
        registry.setPause(2, 1);

        assertEq(vt.spoke(), aave.cdpSpoke, "Spoke binding");
        assertEq(vt.hub(), aave.hub, "Hub binding");
        assertEq(vt.marketId(), MARKET_ID, "market binding");
        assertEq(vt.integration(), address(lpVault), "LPVault binding");
        assertEq(vt.lpOracle(), address(lpOracle), "LPOracle binding");
        assertEq(vt.adapter(), address(adapter), "Adapter binding");
        assertEq(vt.lpVaultSwap(), address(lvs), "LPVaultSwap binding");
        assertEq(vt.collateralization(), address(coll), "Collateralization binding");

        BackingRecord memory afterRemap = coll.getRecord(id);
        assertEq(afterRemap.positionKey, before.positionKey, "record key");
        assertEq(afterRemap.depositor, before.depositor, "record depositor");
        assertEq(afterRemap.proxy, before.proxy, "record proxy");
        assertEq(afterRemap.marketId, before.marketId, "record market");
        assertEq(afterRemap.credited, before.credited, "record credit");
        assertEq(afterRemap.currentUsdCharge, before.currentUsdCharge, "record charge");
        assertEq(coll.getAccountCredited(proxy, address(vt)), credited, "account credit");
        assertEq(coll.getTotalCredited(address(vt)), total, "market total");
        assertEq(vt.totalSupply(), supply, "nothing minted");

        vm.startPrank(address(registry));
        vm.expectRevert();
        vt.mint(proxy, 1);
        vm.expectRevert();
        vt.addValidProxy(attacker);
        vm.stopPrank();
        assertFalse(vt.isValidProxy(attacker), "no proxy registered by the registry");
        assertEq(vt.totalSupply(), supply, "still nothing minted");
    }
}
