// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ILPVaultErrors} from "../../src/custody/lp-vault/ILPVaultErrors.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {SpokeDef} from "../../src/policy/market-registry/types/SpokeDef.sol";
import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title AaveAdapterPledgeRowsUnitTest
/// @notice The AaveAdapter's share of the pledge rejections (TEST-011) and of the vault-token proxy registry
/// (TEST-188), driven through the real Adapter on the real local Aave V4, Collateralization, vault tokens, ProxyManager
/// and PositionProxies: which checks the Adapter runs before custody, that a refused pledge mints nothing, and when the
/// Adapter registers a proxy in a vault token.
/// forge-config: default.isolate = false
contract AaveAdapterPledgeRowsUnitTest is AaveAdapterFixture {
    // ─── TEST-011: pledge rejections ───

    // TEST-011 verifies: REQ-ADAPTER-065, REQ-PROXY-062, REQ-ADAPTER-077, INV-017
    /// @notice Before any custody call the Adapter refuses an expired deadline (`DeadlineExpired`), a market the
    /// registry does not know or whose vault token names another Spoke (`UnknownMarket`) and an unapproved Spoke
    /// (`UnknownSpoke`); none of them takes the NFT, deploys a proxy or mints.
    function test_TEST_011_adapterRefusalsBeforeCustody() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        uint256 past = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DeadlineExpired.selector, past));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), past);

        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnknownMarket.selector, 99));
        vm.prank(alice);
        adapterC.pledge(99, _ref(key), d);

        // The registry names another Spoke than the vault token's own `spoke()`.
        registry.setMarketSpoke(MARKET_ID, aave.lendSpoke);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnknownMarket.selector, MARKET_ID));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
        registry.setMarketSpoke(MARKET_ID, aave.cdpSpoke);

        registry.setSpoke(
            aave.cdpSpoke, SpokeDef(false, aave.hub, INTEGRATION, RiskTier.Stable, address(0), address(0))
        );
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnknownSpoke.selector, aave.cdpSpoke));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);

        assertEq(token.totalSupply(), 0, "nothing minted");
        assertEq(adapterC.proxyOf(alice, MARKET_ID), address(0), "no proxy deployed");
        (address owner,,,,) = lpVault.positions(key);
        assertEq(owner, alice, "NFT still with its owner");
    }

    // TEST-011 verifies: REQ-COLL-005, REQ-COLL-010, REQ-VAULT-012, ATTACK-001
    /// @notice Through the Adapter: a caller that does not own the NFT reverts `NotTokenOwner` in the LPVault, a
    /// position of another market's range reverts `RangeMismatch`, and an NFT already backing an open record reverts
    /// `AlreadyPledged` whether it is pledged again into the same market or into another one; each refusal mints
    /// nothing and leaves the one open record as it was.
    function test_TEST_011_ownershipRangeAndDuplicateThroughTheAdapter() public {
        uint256 d = _deadline();
        bytes32 bobKey = _newKey();
        lpVault.mintPosition(bobKey, bob, MARKET_ID, UNITS);
        vm.expectRevert(ILPVaultErrors.NotTokenOwner.selector);
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(bobKey), d);
        assertEq(token.totalSupply(), 0, "non-owner minted nothing");

        // A position bound to market B's range, named for market A.
        bytes32 otherRange = _newKey();
        lpVault.mintPosition(otherRange, alice, MARKET_B, UNITS);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultErrors.RangeMismatch.selector, int24(-1), int24(1)));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(otherRange), d);
        assertEq(token.totalSupply(), 0, "range mismatch minted nothing");

        vm.prank(bob);
        adapterC.pledge(MARKET_ID, _ref(bobKey), d);
        uint256 recordId = coll.recordIdOf(INTEGRATION, bobKey);
        assertGt(recordId, 0, "record open");
        vm.expectRevert(ICollateralizationErrors.AlreadyPledged.selector);
        vm.prank(bob);
        adapterC.pledge(MARKET_ID, _ref(bobKey), d);
        vm.expectRevert(ICollateralizationErrors.AlreadyPledged.selector);
        vm.prank(bob);
        adapterC.pledge(MARKET_B, _ref(bobKey), d);
        assertEq(token.totalSupply(), UNITS, "one credit in market A");
        assertEq(tokenB.totalSupply(), 0, "nothing in market B");
        assertEq(coll.recordIdOf(INTEGRATION, bobKey), recordId, "same record");
    }

    // TEST-011 verifies: REQ-ADAPTER-051, REQ-ADAPTER-066, INV-064, INV-096
    /// @notice Each account holds exactly one market: a wallet's pledge into a second market goes to that market's
    /// own proxy, not to the first market's account; and a 17th open record of one account-market reverts
    /// `TooManyRecords(16)` while the 16 already open stay.
    function test_TEST_011_oneMarketPerAccountAndSixteenRecords() public {
        (, address proxyA) = _pledgeAs(alice, MARKET_ID, UNITS);
        (, address proxyB) = _pledgeAs(alice, MARKET_B, UNITS);
        assertTrue(proxyA != proxyB, "own proxy per market");
        assertEq(IPositionProxy(proxyA).MARKET_ID(), MARKET_ID, "proxy A market");
        assertEq(IPositionProxy(proxyB).MARKET_ID(), MARKET_B, "proxy B market");
        assertEq(_sharesOf(proxyA, vtReserveIdB), 0, "market B never on account A");
        assertEq(_sharesOf(proxyB, vtReserveId), 0, "market A never on account B");

        for (uint256 i = 1; i < 16; ++i) {
            _pledgeAs(alice, MARKET_ID, 1_000_000_000);
        }
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, 1_000_000_000);
        uint256 supply = token.totalSupply();
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(ICollateralizationErrors.TooManyRecords.selector, 16));
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
        assertEq(token.totalSupply(), supply, "17th record minted nothing");
    }

    // ─── TEST-188: proxy registry in each vault token ───

    // TEST-188 verifies: REQ-VTOKEN-007, REQ-VTOKEN-039, INV-012, Q-225
    /// @notice The Adapter registers a proxy in a vault token on the proxy's first pledge into that market only: a
    /// wallet pledging into markets A and B on one Spoke produces one `ProxyAdded` in each token, and its later top-ups
    /// produce none; the other market's token never registers the proxy and the wallet itself is never registered.
    function test_TEST_188_adapterRegistersOncePerMarket() public {
        vm.recordLogs();
        (, address proxyA) = _pledgeAs(alice, MARKET_ID, UNITS);
        (, address proxyB) = _pledgeAs(alice, MARKET_B, UNITS);
        _pledgeAs(alice, MARKET_ID, UNITS);
        _pledgeAs(alice, MARKET_B, UNITS);
        _pledgeAs(alice, MARKET_ID, UNITS);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_proxyAdded(logs, vt, proxyA), 1, "one ProxyAdded in token A");
        assertEq(_proxyAdded(logs, vtB, proxyB), 1, "one ProxyAdded in token B");
        assertEq(_proxyAdded(logs, vt, proxyB) + _proxyAdded(logs, vtB, proxyA), 0, "no cross registration");
        assertEq(_allProxyAdded(logs), 2, "no event on top-ups");
        assertTrue(token.isValidProxy(proxyA) && tokenB.isValidProxy(proxyB), "registered");
        assertFalse(token.isValidProxy(proxyB) || tokenB.isValidProxy(proxyA), "not in the other token");
        assertFalse(token.isValidProxy(alice) || tokenB.isValidProxy(alice), "wallet never registered");
    }

    // TEST-188 verifies: REQ-VTOKEN-007, REQ-VTOKEN-032, INV-012
    /// @notice Only the Adapter's own call registers: the ProxyManager, LPVaultSwap, the timelock and the wallet are
    /// refused `OnlyAdapter`, and a proxy the Adapter has not registered cannot receive the market's tokens.
    function test_TEST_188_onlyTheAdapterRegisters() public {
        address predicted = adapterC.predictProxy(bob, MARKET_ID);
        address[4] memory callers = [address(proxyManager), lpVaultSwap, timelock, bob];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.expectRevert();
            vm.prank(callers[i]);
            token.addValidProxy(predicted);
        }
        assertFalse(token.isValidProxy(predicted), "not registered");
        assertFalse(token.isAllowedRecipient(predicted), "cannot receive");
        (, address proxy) = _pledgeAs(bob, MARKET_ID, UNITS);
        assertEq(proxy, predicted, "the Adapter's pledge registers the predicted proxy");
        assertTrue(token.isValidProxy(proxy), "registered by the Adapter");
    }

    function _proxyAdded(
        Vm.Log[] memory logs,
        address emitter,
        address proxy
    ) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == emitter && logs[i].topics.length == 2
                    && logs[i].topics[0] == IVaultToken.ProxyAdded.selector
                    && logs[i].topics[1] == bytes32(uint256(uint160(proxy)))
            ) ++n;
        }
    }

    function _allProxyAdded(
        Vm.Log[] memory logs
    ) internal pure returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == IVaultToken.ProxyAdded.selector) ++n;
        }
    }
}
