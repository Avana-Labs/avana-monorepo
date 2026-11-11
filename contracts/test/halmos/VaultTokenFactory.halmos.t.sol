// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {IVaultTokenFactory} from "../../src/vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {VaultTokenFactory} from "../../src/vault-token/vault-token-factory/VaultTokenFactory.sol";
import {CollateralizationLockMock} from "../utils/mocks/CollateralizationLockMock.sol";
import {LPVaultIdentityMock} from "../utils/mocks/LPVaultIdentityMock.sol";
import {Test} from "forge-std/Test.sol";

/// @title VaultTokenFactoryHalmosTest
/// @notice Symbolic checks of the VaultTokenFactory: only the timelock writes; a registered integration, a deployed
/// (Spoke, market key) entry and the factory's bindings never change; a second deployment for a pair is refused by the
/// listing checks; a listing reaches deployment only with non-zero, distinct bindings, decimals in [6, 18] and a
/// market ID in `[1, 2^32)`, with the integration's canonical pool keying and shape.
/// @dev Halmos assigns its own addresses to `CREATE`, so the CREATE3 code-size check fails on every path that reaches
/// deployment and the factory reverts `DeploymentFailed()` there: under Halmos that revert marks a path that passed
/// every listing check. Deployment at `predictAddress` and the bindings of a deployed token are therefore checked by
/// the fuzz twins in `test/fuzz/VaultTokenFactory.fuzz.t.sol`. The pre-state has integration 1 registered and the
/// (SPOKE, full-range key) entry written in storage for a stand-in token address.
contract VaultTokenFactoryHalmosTest is Test {
    address internal constant TIMELOCK = address(0x7111E);
    address internal constant ADAPTER = address(0xADA9);
    address internal constant SWAP = address(0x5A9);
    address internal constant LOCK = address(0x10C);
    address internal constant REGISTRY = address(0x4E61);
    address internal constant SPOKE = address(0x590);
    address internal constant POOL = address(0x9001);
    address internal constant TOKEN = address(0x7012E);
    int24 internal constant FULL_UPPER = 887_270;
    /// @dev Solady `CREATE3.DeploymentFailed()`.
    bytes4 internal constant DEPLOYMENT_FAILED = 0x30116425;
    /// @dev Storage slots of `_tokenOf` and `_isVaultToken` (`forge inspect VaultTokenFactory storageLayout`).
    uint256 internal constant TOKEN_OF_SLOT = 2;
    uint256 internal constant IS_VAULT_TOKEN_SLOT = 3;

    VaultTokenFactory internal factory;
    address internal coll;
    address internal vault;
    address internal vault2;
    address internal wrongVault;
    bytes32 internal key;

    function setUp() public {
        CollateralizationLockMock c = new CollateralizationLockMock(LOCK);
        coll = address(c);
        factory = new VaultTokenFactory(ADAPTER, SWAP, coll, TIMELOCK, REGISTRY);
        c.setCore(address(factory), ADAPTER, SWAP);
        vault = address(new LPVaultIdentityMock(1, coll, LOCK, keccak256("UNISWAP_V3"), TIMELOCK, REGISTRY));
        vault2 = address(new LPVaultIdentityMock(2, coll, LOCK, keccak256("AERODROME_SLIPSTREAM"), TIMELOCK, REGISTRY));
        wrongVault = address(
            new LPVaultIdentityMock(2, coll, LOCK, keccak256("AERODROME_SLIPSTREAM"), TIMELOCK, address(0xBAD))
        );
        vm.prank(TIMELOCK);
        factory.registerIntegration(1, vault);
        key = factory.marketKeyOf(1, POOL, bytes32(0), PositionShape(ShapeKind.TickRange, -FULL_UPPER, FULL_UPPER));
        bytes32 inner = keccak256(abi.encode(SPOKE, TOKEN_OF_SLOT));
        vm.store(address(factory), keccak256(abi.encode(key, inner)), bytes32(uint256(uint160(TOKEN))));
        vm.store(address(factory), keccak256(abi.encode(TOKEN, IS_VAULT_TOKEN_SLOT)), bytes32(uint256(1)));
    }

    /// @dev Calls `deployVaultToken` on a tick-range market of POOL and returns success and the revert selector.
    function _deploy(
        address caller,
        uint32 id,
        int24 lower,
        address hub,
        address spoke,
        uint256 marketId,
        address oracle,
        uint8 d
    ) internal returns (bool ok, bytes4 reason) {
        PositionShape memory shape = PositionShape(ShapeKind.TickRange, lower, FULL_UPPER);
        vm.prank(caller);
        try factory.deployVaultToken(id, POOL, bytes32(0), shape, hub, spoke, marketId, oracle, d, "VT", "VT") returns (
            address
        ) {
            ok = true;
        } catch (bytes memory data) {
            reason = bytes4(data);
        }
    }

    /// @dev One of seven concrete registration targets, by a symbolic index.
    function _target(
        uint8 i
    ) internal view returns (address t) {
        uint8 j = i % 7;
        if (j == 0) t = vault;
        else if (j == 1) t = vault2;
        else if (j == 2) t = wrongVault;
        else if (j == 3) t = ADAPTER;
        else if (j == 4) t = coll;
        else if (j == 5) t = SWAP;
        else t = address(0);
    }

    // PROP-099 verifies: REQ-VTOKEN-019, REQ-VTOKEN-037, REQ-VTOKEN-044, REQ-VTOKEN-045, INV-051, INV-052, Q-228
    /// @notice Any caller other than the timelock is refused with `NotTimelock` by both writing functions, whatever
    /// the arguments.
    function check_PROP_099_writesOnlyByTimelock(
        address caller,
        bool deploy,
        uint32 id,
        address target,
        int24 lower,
        address hub,
        address spoke,
        uint256 marketId,
        uint8 d
    ) public {
        vm.assume(caller != TIMELOCK);
        bool ok;
        bytes4 reason;
        if (deploy) {
            (ok, reason) = _deploy(caller, id, lower, hub, spoke, marketId, target, d);
        } else {
            vm.prank(caller);
            try factory.registerIntegration(id, target) {
                ok = true;
            } catch (bytes memory data) {
                reason = bytes4(data);
            }
        }
        assert(!ok && reason == IVaultTokenFactory.NotTimelock.selector);
    }

    // PROP-099 verifies: REQ-VTOKEN-023, REQ-VTOKEN-044, REQ-VTOKEN-045, REQ-VTOKEN-049, REQ-AMM-CORE-001, INV-052, Q-291, Q-374
    /// @notice Whatever the caller, identifier and target, a registration leaves integration 1 (its LPVault and its
    /// recorded kind), the deployed entry and the factory's bindings unchanged, and succeeds only for an unused
    /// identifier with an LPVault whose identity matches the chain's core (a foreign MarketRegistry is refused).
    function check_PROP_099_registrationIsWriteOnce(
        address caller,
        uint32 id,
        uint8 which
    ) public {
        address target = _target(which);
        address before = factory.lpVaultOf(id);
        vm.prank(caller);
        bool ok;
        try factory.registerIntegration(id, target) {
            ok = true;
        } catch {}
        assert(factory.lpVaultOf(1) == vault);
        (, ShapeKind kind1) = factory.integrationKindOf(1);
        assert(kind1 == ShapeKind.TickRange);
        assert(factory.tokenOf(SPOKE, key) == TOKEN && factory.isVaultToken(TOKEN));
        assert(factory.ADAPTER() == ADAPTER && factory.LP_VAULT_SWAP() == SWAP);
        assert(factory.COLLATERALIZATION() == coll && factory.TIMELOCK() == TIMELOCK);
        assert(factory.MARKET_REGISTRY() == REGISTRY);
        if (ok) {
            assert(caller == TIMELOCK && id == 2 && target == vault2 && before == address(0));
            assert(factory.lpVaultOf(2) == vault2);
        } else {
            assert(factory.lpVaultOf(id) == before);
        }
    }

    // PROP-099 verifies: REQ-VTOKEN-021, REQ-VTOKEN-028, REQ-VTOKEN-035, Q-068, Q-224, Q-299
    /// @notice A second deployment for the deployed (SPOKE, full-range) pair never reaches deployment, whatever the
    /// other arguments, and the entry stays.
    function check_PROP_099_secondDeployForPairReverts(
        address hub,
        address oracle,
        uint256 marketId,
        uint8 d
    ) public {
        (bool ok, bytes4 reason) = _deploy(TIMELOCK, 1, -FULL_UPPER, hub, SPOKE, marketId, oracle, d);
        assert(!ok && reason != DEPLOYMENT_FAILED);
        assert(factory.tokenOf(SPOKE, key) == TOKEN);
    }

    // PROP-099 verifies: REQ-VTOKEN-022, REQ-VTOKEN-036, REQ-VTOKEN-046, REQ-VTOKEN-049, SPEC-UNIT-001, Q-224, Q-226
    /// @notice A listing by the timelock reaches deployment only for a registered integration, non-zero and pairwise
    /// distinct bindings none of which is the predicted token address, a canonical range (`lower < upper`), decimals in
    /// [6, 18], a market ID in `[1, 2^32)` and an empty pair.
    function check_PROP_099_onlyValidListingsReachDeployment(
        uint32 id,
        int24 lower,
        address hub,
        address spoke,
        uint256 marketId,
        address oracle,
        uint8 d
    ) public {
        bytes32 k = factory.marketKeyOf(id, POOL, bytes32(0), PositionShape(ShapeKind.TickRange, lower, FULL_UPPER));
        address predicted = factory.predictAddress(spoke, k);
        bool empty = factory.tokenOf(spoke, k) == address(0);
        (bool ok, bytes4 reason) = _deploy(TIMELOCK, id, lower, hub, spoke, marketId, oracle, d);
        if (ok || reason != DEPLOYMENT_FAILED) return;
        assert(id == 1 && empty && marketId != 0 && marketId < 1 << 32 && d >= 6 && d <= 18);
        assert(lower < FULL_UPPER);
        assert(hub != address(0) && spoke != address(0) && oracle != address(0));
        assert(hub != spoke && hub != oracle && spoke != oracle);
        _assertOutsideCore(hub, predicted);
        _assertOutsideCore(spoke, predicted);
        _assertOutsideCore(oracle, predicted);
    }

    function _assertOutsideCore(
        address a,
        address predicted
    ) internal view {
        assert(a != vault && a != ADAPTER && a != SWAP && a != coll && a != predicted);
    }
}
