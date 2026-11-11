// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionShape} from "../../../src/types/PositionShape.sol";
import {ShapeKind} from "../../../src/types/ShapeKind.sol";
import {VaultTokenFactory} from "../../../src/vault-token/vault-token-factory/VaultTokenFactory.sol";
import {VaultToken} from "../../../src/vault-token/vault-token/VaultToken.sol";
import {CollateralizationLockMock} from "../../utils/mocks/CollateralizationLockMock.sol";
import {LPVaultIdentityMock} from "../../utils/mocks/LPVaultIdentityMock.sol";

/// @title VaultTokenFactoryProperties
/// @notice Echidna and Medusa properties of the VaultTokenFactory (2.4). Between transactions: the factory's bindings
/// never change, every registered integration and every deployed (Spoke, market key) entry keeps its first value,
/// and every deployed token sits at `predictAddress` and is recognised by `isVaultToken`. Inside each assertion entry
/// point: a registration or deployment succeeds exactly when the 2.4 rules allow it.
/// @dev The harness is the timelock. Two Spokes, three ranges, three Hub candidates and three LPOracle candidates are
/// chosen by `if` branches on small indexes, so hevm sees finite branching; candidate addresses include shared
/// bindings, so the refusal paths are reached.
contract VaultTokenFactoryProperties {
    uint256 internal constant SPOKES = 2;
    uint256 internal constant RANGES = 3;

    VaultTokenFactory internal immutable FACTORY;
    address internal immutable COLL;
    address internal immutable V3;
    address internal immutable SLIP;
    address internal immutable BAD_LOCK_VAULT;
    address internal constant ADAPTER = address(0xADA9);
    address internal constant SWAP = address(0x5A9);
    address internal constant LOCK = address(0x10C);
    address internal constant HUB = address(0x4B);
    address internal constant ORACLE = address(0x0AC1E);
    address internal constant POOL = address(0x9001);
    address internal constant REGISTRY = address(0x4E61);

    /// @notice Ghost of each deployed entry, by (spoke index, range index).
    mapping(uint256 slot => address token) public ghostToken;
    /// @notice Ghost of integration 2's registration.
    address public ghostSlip;

    constructor() {
        CollateralizationLockMock coll = new CollateralizationLockMock(LOCK);
        COLL = address(coll);
        FACTORY = new VaultTokenFactory(ADAPTER, SWAP, COLL, address(this), REGISTRY);
        coll.setCore(address(FACTORY), ADAPTER, SWAP);
        V3 = address(new LPVaultIdentityMock(1, COLL, LOCK, keccak256("UNISWAP_V3"), address(this), REGISTRY));
        SLIP =
            address(new LPVaultIdentityMock(2, COLL, LOCK, keccak256("AERODROME_SLIPSTREAM"), address(this), REGISTRY));
        BAD_LOCK_VAULT = address(
            new LPVaultIdentityMock(2, COLL, address(0xBAD), keccak256("AERODROME_SLIPSTREAM"), address(this), REGISTRY)
        );
        FACTORY.registerIntegration(1, V3);
    }

    // ─── Properties (between transactions) ───

    function property_bindingsFixed() external view returns (bool) {
        return FACTORY.ADAPTER() == ADAPTER && FACTORY.LP_VAULT_SWAP() == SWAP && FACTORY.COLLATERALIZATION() == COLL
            && FACTORY.TIMELOCK() == address(this) && FACTORY.MARKET_REGISTRY() == REGISTRY;
    }

    function property_integrationsWriteOnce() external view returns (bool) {
        return FACTORY.lpVaultOf(1) == V3 && FACTORY.lpVaultOf(2) == ghostSlip && FACTORY.lpVaultOf(0) == address(0);
    }

    function property_entriesWriteOnceAtPrediction() external view returns (bool) {
        for (uint256 s = 0; s < SPOKES; ++s) {
            for (uint256 r = 0; r < RANGES; ++r) {
                address spoke = _spoke(s);
                bytes32 key = _key(r);
                address t = FACTORY.tokenOf(spoke, key);
                if (t != ghostToken[s * RANGES + r]) return false;
                if (t != address(0)) {
                    if (t != FACTORY.predictAddress(spoke, key) || !FACTORY.isVaultToken(t)) return false;
                    if (t.code.length == 0 || VaultToken(t).spoke() != spoke) return false;
                }
            }
        }
        return true;
    }

    // ─── Assertion entry points ───

    /// @notice Registration of integration 2 succeeds exactly once, for the matching LPVault.
    function register(
        uint8 which
    ) external {
        uint8 w = which % 3;
        address target = w == 0 ? SLIP : (w == 1 ? BAD_LOCK_VAULT : V3);
        bool expected = w == 0 && ghostSlip == address(0);
        try FACTORY.registerIntegration(2, target) {
            assert(expected);
            ghostSlip = SLIP;
        } catch {
            assert(!expected);
        }
    }

    /// @notice A deployment succeeds exactly for an empty pair with distinct bindings, at the predicted address.
    function deploy(
        uint8 spokeIndex,
        uint8 rangeIndex,
        uint8 hubIndex,
        uint8 oracleIndex
    ) external {
        uint256 s = spokeIndex % SPOKES;
        uint256 r = rangeIndex % RANGES;
        address spoke = _spoke(s);
        address hub = _candidate(hubIndex % 3, HUB);
        address oracle = _candidate(oracleIndex % 3, ORACLE);
        bytes32 key = _key(r);
        address predicted = FACTORY.predictAddress(spoke, key);
        bool expected = ghostToken[s * RANGES + r] == address(0) && hub != ADAPTER && oracle != ADAPTER && hub != spoke
            && oracle != spoke && hub != oracle;
        try FACTORY.deployVaultToken(1, POOL, bytes32(0), _shape(r), hub, spoke, 4, oracle, 6, "VT", "VT") returns (
            address t
        ) {
            assert(expected && t == predicted);
            ghostToken[s * RANGES + r] = t;
        } catch {
            assert(!expected);
        }
    }

    // ─── Candidates ───

    function _spoke(
        uint256 s
    ) internal pure returns (address) {
        return s == 0 ? address(0x590) : address(0x591);
    }

    /// @dev The valid address, a shared binding (the Adapter), or the first Spoke (shared with the Spoke of index 0).
    function _candidate(
        uint256 i,
        address valid
    ) internal pure returns (address) {
        if (i == 0) return valid;
        if (i == 1) return ADAPTER;
        return address(0x590);
    }

    function _shape(
        uint256 r
    ) internal pure returns (PositionShape memory) {
        if (r == 0) return PositionShape(ShapeKind.TickRange, -887_270, 887_270);
        if (r == 1) return PositionShape(ShapeKind.TickRange, -50, 50);
        return PositionShape(ShapeKind.TickRange, -10, 10);
    }

    function _key(
        uint256 r
    ) internal view returns (bytes32) {
        return FACTORY.marketKeyOf(1, POOL, bytes32(0), _shape(r));
    }
}
