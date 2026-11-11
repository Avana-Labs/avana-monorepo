// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {IVaultTokenFactory} from "../../src/vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {VaultTokenFactory} from "../../src/vault-token/vault-token-factory/VaultTokenFactory.sol";
import {VaultToken} from "../../src/vault-token/vault-token/VaultToken.sol";
import {VaultTokenFactoryFixture} from "../utils/fixtures/VaultTokenFactoryFixture.sol";
import {LPVaultIdentityMock} from "../utils/mocks/LPVaultIdentityMock.sol";

/// LPVault exposing every ILPVault identity getter, with a foreign TIMELOCK and MARKET_REGISTRY.
contract ForeignGovLPVault {
    uint32 public immutable INTEGRATION_ID;
    address public immutable COLLATERALIZATION;
    address public immutable LOCK;
    bytes32 public constant AMM_PROTOCOL = bytes32(0);
    address public immutable TIMELOCK;
    address public immutable MARKET_REGISTRY;

    constructor(uint32 id, address c, address l, address t, address r) {
        INTEGRATION_ID = id;
        COLLATERALIZATION = c;
        LOCK = l;
        TIMELOCK = t;
        MARKET_REGISTRY = r;
    }
}

contract VaultTokenFactoryReviewTest is VaultTokenFactoryFixture {
    function setUp() public {
        _deployFactory();
        _register(V3_ID, address(v3Vault));
    }

    function _dep(Listing memory l, string memory n) internal returns (address t) {
        vm.prank(address(timelock));
        t = factory.deployVaultToken(
            l.integrationId, l.pool, l.poolId, l.shape, l.hub, l.spoke, l.marketId, l.lpOracle, l.decimals, n, SYMBOL
        );
    }

    /// The factory neither validates nor canonicalises the shape or the pool keying, so one economic market
    /// (v3 pool, one Spoke) gets several keys and several tokens.
    function test_PoC_nonCanonicalShapeAndKeying_manyTokensOneMarket() public {
        Listing memory l = _listing();
        l.shape = PositionShape(ShapeKind.FullPool, 0, 0);
        address a = _dep(l, NAME);
        l.shape = PositionShape(ShapeKind.FullPool, 1, 2); // FullPool with non-zero ticks
        address b = _dep(l, NAME);
        l.shape = PositionShape(ShapeKind.None, 0, 0); // kind None
        address c = _dep(l, NAME);
        l.shape = PositionShape(ShapeKind.TickRange, 50, -50); // inverted range
        address d = _dep(l, NAME);
        l.shape = _fullRange();
        address e = _dep(l, NAME);
        l.pool = address(0);
        l.poolId = bytes32(uint256(uint160(pool))); // same v3 pool, passed as a poolId
        address f = _dep(l, NAME);
        assertTrue(a != b && b != c && c != d && d != e && e != f, "six tokens");
        assertTrue(factory.isVaultToken(f), "all registered");
    }

    /// registerIntegration does not compare the LPVault's TIMELOCK or MARKET_REGISTRY with the chain's core, and
    /// accepts AMM_PROTOCOL == 0; it never checks Collateralization points back at this factory.
    function test_PoC_lpVaultWithForeignTimelockAndRegistryAccepted() public {
        address attacker = makeAddr("attackerTimelock");
        ForeignGovLPVault v =
            new ForeignGovLPVault(SLIPSTREAM_ID, address(collateralization), lock, attacker, attacker);
        _register(SLIPSTREAM_ID, address(v));
        assertEq(factory.lpVaultOf(SLIPSTREAM_ID), address(v));
        assertEq(v.TIMELOCK(), attacker);
    }

    /// Empty name and symbol, marketId >= 2^32 (REQ-CONFIG-006 bound) are all accepted by the factory.
    function test_PoC_emptyNameAndHugeMarketIdAccepted() public {
        Listing memory l = _listing();
        l.marketId = type(uint256).max;
        vm.prank(address(timelock));
        address t = factory.deployVaultToken(
            l.integrationId, l.pool, l.poolId, l.shape, l.hub, l.spoke, l.marketId, l.lpOracle, l.decimals, "", ""
        );
        assertEq(VaultToken(t).marketId(), type(uint256).max);
        assertEq(bytes(VaultToken(t).name()).length, 0);
    }

    /// The same market (same key) on two Spokes gets two tokens; the factory relies on the registry for
    /// "one market, one Spoke", whose marketOfShape key also contains the Spoke.
    function test_PoC_sameMarketTwoSpokesConcurrently() public {
        Listing memory l = _listing();
        address a = _dep(l, NAME);
        l.spoke = successorSpoke;
        address b = _dep(l, NAME);
        assertTrue(a != b);
        assertEq(VaultToken(a).marketKey(), VaultToken(b).marketKey());
    }

    /// Registering an LPVault whose getter reverts/aborts propagates; a codeless Collateralization makes every
    /// registration revert (no factory-level reason).
    function test_PoC_registrationWithCodelessCollateralizationReverts() public {
        VaultTokenFactory f2 =
            new VaultTokenFactory(adapter, address(lpVaultSwap), makeAddr("noCodeColl"), address(timelock));
        LPVaultIdentityMock v = new LPVaultIdentityMock(7, makeAddr("noCodeColl"), lock, UNISWAP_V3);
        vm.expectRevert();
        vm.prank(address(timelock));
        f2.registerIntegration(7, address(v));
    }
}
