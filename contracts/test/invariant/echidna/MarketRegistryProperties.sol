// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../../src/governance/roles/AvanaRoles.sol";
import {IMarketRegistry} from "../../../src/policy/market-registry/IMarketRegistry.sol";
import {MarketRegistry} from "../../../src/policy/market-registry/MarketRegistry.sol";
import {MarketRegistrySafetyLogic} from "../../../src/policy/market-registry/MarketRegistrySafetyLogic.sol";
import {MarketRegistryStorage} from "../../../src/policy/market-registry/MarketRegistryStorage.sol";
import {MarketRegistryImmutables} from "../../../src/policy/market-registry/types/MarketRegistryImmutables.sol";
import {MarketRegistryLogics} from "../../../src/policy/market-registry/types/MarketRegistryLogics.sol";
import {RiskTier} from "../../../src/policy/market-registry/types/RiskTier.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {RegistryAdapterMock} from "../../utils/mocks/MarketRegistryMocks.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @notice A logic contract that reports a kind and immutables hash and serves no body.
contract RegistryLogicStub {
    bytes32 internal immutable KIND;
    bytes32 internal immutable HASH;

    constructor(
        bytes32 kind,
        bytes32 hash
    ) {
        KIND = kind;
        HASH = hash;
    }

    function logicConfig() external view returns (bytes32 kind, bytes32 immutablesHash) {
        return (KIND, HASH);
    }
}

/// @notice The hubs logic of the harness: the real `recordHub` body (without the flash-source check, the flash source
/// being unset) on the registry's storage layout, and nothing else.
contract HarnessHubsLogic is MarketRegistryStorage {
    constructor(
        MarketRegistryImmutables memory im
    ) MarketRegistryStorage(im) {}

    function logicConfig() external view returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("MarketRegistryHubsLogic"), _IMMUTABLES_HASH);
    }

    function recordHub(
        address hub,
        RiskTier tier
    ) external {
        _onlyDelegated();
        _s().hubTier[hub] = tier;
        _s().hubList.push(hub);
    }
}

/// @notice Calls the MarketRegistry as one fixed role holder.
contract RegistryActor {
    IMarketRegistry internal immutable REGISTRY;

    constructor(
        IMarketRegistry registry
    ) {
        REGISTRY = registry;
    }

    function run(
        bytes calldata data
    ) external returns (bool ok) {
        (ok,) = address(REGISTRY).call(data);
    }
}

/// @title MarketRegistryProperties
/// @notice Echidna and Medusa properties of the MarketRegistry's pause state machine (INV-049) and address freeze
/// (INV-085): the real registry behind its proxy, three role holders (a guardian with both roles, a freeze-only holder
/// and the timelock as `APPLICATION_ADMIN`) and a stranger, two Hubs.
/// @dev Entry points pick an actor and an operation by index (finite branching); `property_` functions are checked
/// after every call. The harness itself is the timelock, so it can act as `APPLICATION_ADMIN` directly.
contract MarketRegistryProperties {
    address internal constant HUB_A = address(0xA001);
    address internal constant HUB_B = address(0xA002);

    IMarketRegistry internal registry;
    RegistryAdapterMock internal adapter;
    RegistryActor internal guardian;
    RegistryActor internal freezer;
    RegistryActor internal stranger;
    mapping(address => bool) internal fixedProtected;
    address[] internal frozenSeen;
    bool internal freezerLifted;

    constructor() {
        adapter = new RegistryAdapterMock();
        MarketRegistryImmutables memory im = MarketRegistryImmutables({
            timelock: address(this),
            aaveGovernanceExecutor: address(0xB001),
            vaultTokenFactory: address(0xB002),
            aaveAdapter: address(adapter),
            collateralization: address(0xB003),
            lock: address(0xB004),
            proxyManager: address(0xB005),
            parameterStore: address(0xB006),
            riskModule: address(0xB007),
            lpVaultSwap: address(0xB008),
            payoutEscrow: address(0xB009),
            flashLiquidator: address(0xB00B),
            standardSpokeImplementation: address(0xB00A)
        });
        // Only the safety logic is exercised in full. The hubs logic is a harness copy of `recordHub` on the same storage
        // layout and the other four are identity stubs, which keeps the harness's initcode within the EIP-3860 limit;
        // the full logic contracts are covered by the unit and Halmos suites.
        bytes32 h = keccak256(abi.encode(im));
        MarketRegistryLogics memory l;
        l.hubs = address(new HarnessHubsLogic(im));
        l.listing = address(new RegistryLogicStub(keccak256("MarketRegistryListingLogic"), h));
        l.activation = address(new RegistryLogicStub(keccak256("MarketRegistryActivationLogic"), h));
        l.routes = address(new RegistryLogicStub(keccak256("MarketRegistryRoutesLogic"), h));
        l.safety = address(new MarketRegistrySafetyLogic(im));
        l.windDown = address(new RegistryLogicStub(keccak256("MarketRegistryWindDownLogic"), h));
        MarketRegistry impl = new MarketRegistry(im, l);
        registry = IMarketRegistry(
            address(new ERC1967Proxy(address(impl), abi.encodeCall(MarketRegistry.initialize, (address(this)))))
        );
        guardian = new RegistryActor(registry);
        freezer = new RegistryActor(registry);
        stranger = new RegistryActor(registry);
        registry.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, address(guardian));
        registry.grantRole(AvanaRoles.APPLICATION_FREEZE_GUARDIAN, address(guardian));
        registry.grantRole(AvanaRoles.APPLICATION_FREEZE_GUARDIAN, address(freezer));
        registry.recordHub(HUB_A, RiskTier.Stable);
        registry.recordHub(HUB_B, RiskTier.Correlated);
        address[14] memory fixedSet = [
            address(this),
            address(0xB001),
            address(0xB002),
            address(adapter),
            address(0xB003),
            address(0xB004),
            address(0xB005),
            address(0xB006),
            address(0xB007),
            address(0xB008),
            address(0xB009),
            address(0xB00B),
            address(registry),
            HUB_A
        ];
        for (uint256 i = 0; i < fixedSet.length; ++i) {
            fixedProtected[fixedSet[i]] = true;
        }
        fixedProtected[HUB_B] = true;
    }

    /// @notice One pause-state call on one Hub by one actor.
    /// @param actor 0 guardian, 1 freeze-only, 2 timelock, 3 stranger.
    /// @param op 0 freeze, 1 pause, 2 unfreeze, 3 unpause, 4 freezeAll, 5 pauseAll.
    /// @param reason Pause reason index.
    /// @param hubB True for the second Hub.
    function pauseOp(
        uint8 actor,
        uint8 op,
        uint8 reason,
        bool hubB
    ) external {
        address hub = hubB ? HUB_B : HUB_A;
        PauseReason r = PauseReason(reason % 3);
        bytes memory data;
        uint8 k = op % 6;
        if (k == 0) data = abi.encodeCall(registry.freeze, (hub));
        else if (k == 1) data = abi.encodeCall(registry.pause, (hub, r));
        else if (k == 2) data = abi.encodeCall(registry.unfreeze, (hub));
        else if (k == 3) data = abi.encodeCall(registry.unpause, (hub));
        else if (k == 4) data = abi.encodeCall(registry.freezeAll, ());
        else data = abi.encodeCall(registry.pauseAll, (r));
        PauseState before = registry.pauseState(hub);
        bool ok = _run(actor % 4, data);
        if (ok && actor % 4 == 1 && before != PauseState.None && registry.pauseState(hub) == PauseState.None) {
            freezerLifted = true;
        }
    }

    /// @notice One address freeze by one actor.
    /// @param actor 0 guardian, 1 freeze-only, 2 timelock, 3 stranger.
    /// @param target Address to freeze.
    /// @param proxyOf True to register `target` as a proxy first.
    function freezeOp(
        uint8 actor,
        address target,
        bool proxyOf
    ) external {
        if (proxyOf) adapter.setWallet(target, address(0xCAFE));
        if (_run(actor % 4, abi.encodeCall(registry.freezeAddress, (target)))) frozenSeen.push(target);
    }

    /// @notice Unfreezes one address as the timelock.
    /// @param target Address to unfreeze.
    function unfreezeOp(
        address target
    ) external {
        try registry.unfreezeAddress(target) {} catch {}
    }

    /// @notice INV-049: the reason is None exactly when a Hub is not Paused.
    /// @return holds True when the property holds.
    function property_reasonNoneExactlyWhenNotPaused() external view returns (bool holds) {
        holds = (registry.pauseState(HUB_A) == PauseState.Paused) == (registry.pauseReason(HUB_A) != PauseReason.None)
            && (registry.pauseState(HUB_B) == PauseState.Paused) == (registry.pauseReason(HUB_B) != PauseReason.None);
    }

    /// @notice INV-049: the freeze-only holder never moved a Hub toward None.
    /// @return holds True when the property holds.
    function property_freezeRoleNeverLifts() external view returns (bool holds) {
        holds = !freezerLifted;
    }

    /// @notice INV-085: no protected address and no registered proxy was ever frozen.
    /// @return holds True when the property holds.
    function property_protectedNeverFrozen() external view returns (bool holds) {
        holds = true;
        for (uint256 i = 0; i < frozenSeen.length; ++i) {
            address a = frozenSeen[i];
            if (fixedProtected[a] || a == address(0)) holds = false;
        }
    }

    /// @notice REQ-MREG-019: no actor ever has more than 20 freezes in the rolling window.
    /// @return holds True when the property holds.
    function property_freezeLimit() external view returns (bool holds) {
        holds = registry.freezesInWindow(address(guardian)) <= 20 && registry.freezesInWindow(address(freezer)) <= 20
            && registry.freezesInWindow(address(this)) <= 20;
    }

    function _run(
        uint8 actor,
        bytes memory data
    ) internal returns (bool ok) {
        if (actor == 0) return guardian.run(data);
        if (actor == 1) return freezer.run(data);
        if (actor == 3) return stranger.run(data);
        (ok,) = address(registry).call(data);
    }
}
