// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {IParameterStoreLogic} from "./IParameterStoreLogic.sol";
import {ParameterStoreRisk} from "./ParameterStoreRisk.sol";
import {ParameterStoreStorage} from "./ParameterStoreStorage.sol";
import {ParameterStoreLogics} from "./types/ParameterStoreTypes.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title ParameterStoreRouter
/// @notice Roles of the ParameterStore and the dispatch of its setters to the five logic contracts.
/// @dev Only `TIMELOCK` can hold `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`.
abstract contract ParameterStoreRouter is AccessControlUpgradeable, ParameterStoreRisk {
    address internal immutable _TIGHTEN_LOGIC;

    address internal immutable _LOOSEN_LOGIC;

    address internal immutable _LISTING_LOGIC;

    address internal immutable _ADMIN_ORACLE_LOGIC;

    address internal immutable _ADMIN_RISK_LOGIC;

    /// @notice Fixes the implementation immutables, checks each logic contract and disables initializers.
    /// @param marketRegistry The chain's MarketRegistry proxy (may be a predicted address without code yet).
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

    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        if ((role == DEFAULT_ADMIN_ROLE || role == AvanaRoles.APPLICATION_ADMIN) && account != _TIMELOCK) {
            revert AdminRoleOnlyTimelock(role, account);
        }
        granted = super._grantRole(role, account);
    }

    /// @dev Caller holds `APPLICATION_ADMIN` or `APPLICATION_RISK_STEWARD`.
    modifier onlyAdminOrSteward() {
        _checkAdminOrSteward();
        _;
    }

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

    /// @dev Delegatecalls a logic view body and ends the call with its return or revert data.
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
