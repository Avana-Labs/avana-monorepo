// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {IParameterStoreLogic} from "./IParameterStoreLogic.sol";
import {ParameterStoreRisk} from "./ParameterStoreRisk.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {ParameterStoreLogics} from "./types/ParameterStoreLogics.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title ParameterStoreRouter
/// @notice Roles of the ParameterStore and the dispatch of its setters to the five logic contracts.
/// @dev Roles are OpenZeppelin AccessControl: `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` can be held only by
/// `TIMELOCK` (`_grantRole` reverts `AdminRoleOnlyTimelock` for any other grantee), and `APPLICATION_PAUSE_GUARDIAN`,
/// administered by `APPLICATION_ADMIN`, calls `useStandbySecondSource` only; `APPLICATION_RISK_STEWARD`, administered by
/// `APPLICATION_ADMIN`, calls the tighten setters and `setAvanaFeeShareBps` beside the timelock. Every setter checks its
/// role here and then
/// delegatecalls its logic contract with the unchanged calldata; the logic addresses are implementation immutables
/// whose `logicConfig()` the constructor checks, so a new logic contract is part of a new implementation and waits
/// the normal delay of `upgradeToAndCall`.
/// @custom:spec REQ-PSTORE-001, REQ-PSTORE-002, REQ-ACCESS-153, Q-226, Q-259
abstract contract ParameterStoreRouter is AccessControlUpgradeable, ParameterStoreRisk {
    /// @dev Every tighten setter.
    address internal immutable _TIGHTEN_LOGIC;

    /// @dev Every loosen setter.
    address internal immutable _LOOSEN_LOGIC;

    /// @dev Listing setters, Spoke expectations, the sequencer check and the coverage ratio.
    address internal immutable _LISTING_LOGIC;

    /// @dev Oracle structural setters, the liquidation-liveness setters (slippage floor, flash-fee ceiling) and the
    /// views `getOracleConfig` and `liquidationLivenessHolds`.
    address internal immutable _ADMIN_ORACLE_LOGIC;

    /// @dev Risk structural setters, second sources and the initial parameter write.
    address internal immutable _ADMIN_RISK_LOGIC;

    /// @notice Fixes the implementation immutables, checks each logic contract and disables initializers on the
    /// implementation itself.
    /// @param timelock The chain's AvanaTimelock.
    /// @param marketRegistry The chain's MarketRegistry proxy (may be a predicted address without code yet).
    /// @param chainBlockTime Seconds per block, > 0.
    /// @param hasSequencer Whether the chain runs an L2 sequencer.
    /// @param logics The five logic contracts, each built with the same four values.
    /// @custom:spec REQ-PSTORE-001, REQ-PSTORE-023, REQ-PSTORE-027
    constructor(
        address timelock,
        address marketRegistry,
        uint32 chainBlockTime,
        bool hasSequencer,
        ParameterStoreLogics memory logics
    ) ParameterStoreStorage(timelock, marketRegistry, chainBlockTime, hasSequencer) {
        _requireLogic(logics.tighten, keccak256("ParameterStoreTightenLogic"));
        _requireLogic(logics.loosen, keccak256("ParameterStoreLoosenLogic"));
        _requireLogic(logics.listing, keccak256("ParameterStoreListingLogic"));
        _requireLogic(logics.adminOracle, keccak256("ParameterStoreAdminOracleLogic"));
        _requireLogic(logics.adminRisk, keccak256("ParameterStoreAdminRiskLogic"));
        _TIGHTEN_LOGIC = logics.tighten;
        _LOOSEN_LOGIC = logics.loosen;
        _LISTING_LOGIC = logics.listing;
        _ADMIN_ORACLE_LOGIC = logics.adminOracle;
        _ADMIN_RISK_LOGIC = logics.adminRisk;
        _disableInitializers();
    }

    /// @dev Either admin role can be held only by `TIMELOCK`, through `initialize` or any later grant.
    /// @custom:spec REQ-PSTORE-001, REQ-ACCESS-153, Q-259
    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        if ((role == DEFAULT_ADMIN_ROLE || role == AvanaRoles.APPLICATION_ADMIN) && account != _TIMELOCK) {
            revert AdminRoleOnlyTimelock(role, account);
        }
        granted = super._grantRole(role, account);
    }

    /// @dev The tighten setters and `setAvanaFeeShareBps`: `APPLICATION_ADMIN` (the timelock, at the delay of its
    /// operation) or `APPLICATION_RISK_STEWARD` (the Joint Configuration Safe, at once). A caller with neither reverts
    /// `AccessControlUnauthorizedAccount(caller, APPLICATION_ADMIN)`.
    /// @custom:spec REQ-PSTORE-002, REQ-PSTORE-010
    modifier onlyAdminOrSteward() {
        _checkAdminOrSteward();
        _;
    }

    /// @dev The check of `onlyAdminOrSteward`.
    function _checkAdminOrSteward() private view {
        if (
            !hasRole(AvanaRoles.APPLICATION_ADMIN, msg.sender)
                && !hasRole(AvanaRoles.APPLICATION_RISK_STEWARD, msg.sender)
        ) revert AccessControlUnauthorizedAccount(msg.sender, AvanaRoles.APPLICATION_ADMIN);
    }

    /// @dev Runs the current call's body in `logic`, in this contract's storage; reverts bubble up unchanged.
    function _forward(
        address logic
    ) internal {
        Address.functionDelegateCall(logic, msg.data);
    }

    /// @dev Runs the current view's calldata in `logic` by delegatecall and ends the call with the logic's return data,
    /// or its revert data. A view runs here only as a view: the logic's view body writes nothing and makes only static
    /// calls, and a STATICCALL into the store keeps the whole frame static.
    function _forwardView(
        address logic
    ) internal view {
        _asView(_delegateAndReturn)(logic);
    }

    /// @dev The delegatecall of `_forwardView`; it never returns to its caller.
    function _delegateAndReturn(
        address logic
    ) internal {
        // Ends the call with the logic's raw return or revert data, which Solidity's call syntax would re-encode.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), logic, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }

    /// @dev `fn` typed as a view: `_delegateAndReturn` runs only view bodies of a logic contract (`_forwardView`).
    function _asView(
        function(address) internal fn
    ) private pure returns (function(address) internal view out) {
        // Reinterprets the function pointer; the code it points to is unchanged.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            out := fn
        }
    }

    /// @dev Reverts `OutOfBounds` unless `logic` reports `kind` and the same four implementation immutables.
    function _requireLogic(
        address logic,
        bytes32 kind
    ) private view {
        (bytes32 k, address t, address r, uint32 b, bool h) = IParameterStoreLogic(logic).logicConfig();
        if (k != kind || t != _TIMELOCK || r != address(_REGISTRY) || b != _BLOCK_TIME || h != _HAS_SEQUENCER) {
            revert OutOfBounds();
        }
    }
}
