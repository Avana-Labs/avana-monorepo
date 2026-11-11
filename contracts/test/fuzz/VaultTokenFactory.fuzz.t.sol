// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {VaultToken} from "../../src/vault-token/vault-token/VaultToken.sol";
import {VaultTokenFactoryFixture} from "../utils/fixtures/VaultTokenFactoryFixture.sol";

/// @title VaultTokenFactoryFuzzTest
/// @notice Fuzz twins of the VaultTokenFactory properties Halmos cannot reach, because Halmos does not derive
/// `CREATE` addresses and so never completes a CREATE3 deployment: a deployment by the timelock lands at
/// `predictAddress(spoke, marketKey)` with exactly the listing's and the factory's bindings, every later call leaves
/// the entry, and a second deployment for the pair reverts.
contract VaultTokenFactoryFuzzTest is VaultTokenFactoryFixture {
    function setUp() public {
        _deployFactory();
        _register(V3_ID, address(v3Vault));
    }

    /// @dev A valid listing on a fuzzed range, Hub, Spoke, LPOracle, market ID and decimals.
    function _fuzzListing(
        int24 lower,
        address hub_,
        address spoke_,
        address oracle_,
        uint256 marketId,
        uint8 d
    ) internal view returns (Listing memory l) {
        l = _listing();
        l.shape = PositionShape(ShapeKind.TickRange, int24(bound(lower, -887_270, 887_269)), FULL_UPPER);
        l.hub = _boundStranger(hub_);
        l.spoke = _boundStranger(spoke_);
        l.lpOracle = _boundStranger(oracle_);
        l.marketId = bound(marketId, 1, type(uint32).max);
        l.decimals = uint8(bound(d, 6, 18));
        address predicted = factory.predictAddress(l.spoke, _key(l));
        vm.assume(l.hub != l.spoke && l.hub != l.lpOracle && l.spoke != l.lpOracle);
        vm.assume(!_core(l.hub, predicted) && !_core(l.spoke, predicted) && !_core(l.lpOracle, predicted));
    }

    function _core(
        address a,
        address predicted
    ) internal view returns (bool) {
        return a == address(v3Vault) || a == adapter || a == address(lpVaultSwap) || a == address(collateralization)
            || a == predicted || a == address(timelock) || a.code.length > 0;
    }

    // TEST-024 verifies: REQ-VTOKEN-020, REQ-VTOKEN-021, REQ-VTOKEN-022, REQ-VTOKEN-023, REQ-VTOKEN-038, Q-224, Q-299
    // Sources: PROP-055 Halmos twin (CREATE3 not modelled by Halmos)
    function testFuzz_TEST_024_deployLandsAtPredictionWithBindings(
        int24 lower,
        address hub_,
        address spoke_,
        address oracle_,
        uint256 marketId,
        uint8 d
    ) public {
        Listing memory l = _fuzzListing(lower, hub_, spoke_, oracle_, marketId, d);
        bytes32 k = _key(l);
        address predicted = factory.predictAddress(l.spoke, k);
        address t = _deploy(l);
        assertEq(t, predicted, "predicted address");
        assertEq(factory.tokenOf(l.spoke, k), t, "tokenOf");
        assertTrue(factory.isVaultToken(t), "isVaultToken");
        VaultToken vt = VaultToken(t);
        assertEq(vt.hub(), l.hub, "hub");
        assertEq(vt.spoke(), l.spoke, "spoke");
        assertEq(vt.lpOracle(), l.lpOracle, "lpOracle");
        assertEq(vt.marketId(), l.marketId, "marketId");
        assertEq(vt.decimals(), l.decimals, "decimals");
        assertEq(vt.marketKey(), k, "marketKey");
        assertEq(vt.integration(), address(v3Vault), "integration");
        assertEq(vt.adapter(), adapter, "adapter");
        assertEq(vt.lpVaultSwap(), address(lpVaultSwap), "lpVaultSwap");
        assertEq(vt.collateralization(), address(collateralization), "collateralization");
    }

    // TEST-024 verifies: REQ-VTOKEN-021, REQ-VTOKEN-028, REQ-VTOKEN-035, Q-068, Q-299
    // Sources: PROP-055 Halmos twin (CREATE3 not modelled by Halmos)
    function testFuzz_TEST_024_entryIsWriteOnce(
        int24 lower,
        address hub_,
        address spoke_,
        address oracle_,
        uint256 marketId,
        uint8 d,
        address otherOracle,
        uint256 otherMarketId
    ) public {
        Listing memory l = _fuzzListing(lower, hub_, spoke_, oracle_, marketId, d);
        address t = _deploy(l);
        l.lpOracle = _boundStranger(otherOracle);
        l.marketId = bound(otherMarketId, 0, type(uint32).max);
        vm.prank(address(timelock));
        (bool ok,) = address(factory).call(_deployCall(l));
        assertFalse(ok, "second deployment");
        assertEq(factory.tokenOf(l.spoke, _key(l)), t, "entry unchanged");
    }
}
