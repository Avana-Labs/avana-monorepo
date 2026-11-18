// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILock} from "../../lock/lock/ILock.sol";
import {IAaveAdapterBase} from "./IAaveAdapterBase.sol";
import {AaveAdapterImmutables, AdapterAccount} from "./types/AaveAdapterTypes.sol";

/// @title AaveAdapterStorage
/// @notice Storage, immutables, Lock steps and transient session shared by the AaveAdapter and its logic contracts.
abstract contract AaveAdapterStorage is IAaveAdapterBase {
    /// @custom:storage-location erc7201:avana.storage.AaveAdapter
    struct Layout {
        mapping(address wallet => mapping(uint256 marketId => address proxy)) proxyOf;
        mapping(address proxy => address wallet) walletOf;
        mapping(address proxy => AdapterAccount account) accountOf;
        mapping(address proxy => uint256 nonce) borrowNonce;
    }

    /// @dev `keccak256(abi.encode(uint256(keccak256("avana.storage.AaveAdapter")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 internal constant STORAGE_SLOT = 0x2072e6d03f11061b0cb3832feb372a04fa53d710ed44fa8554d505a1e2dbd700;

    /// @dev First of eight transient slots holding the repay-with-collateral session.
    bytes32 internal constant SESSION_SLOT = 0x0db5971807d1207a74b49bb675c29f58fab52360e24e9e8ddf89f8f844ac41b9;

    uint256 internal constant STEP_REPAID = 1;
    uint256 internal constant STEP_RELEASED = 2;

    /// @dev Gas given to the RiskModule's `creditRepay` after a repay step, about twice the measured cost.
    uint256 internal constant SPEED_CREDIT_GAS = 250_000;
    /// @dev Gas a repay step must hold before the credit call, so the credit always gets its full stipend.
    uint256 internal constant SPEED_CREDIT_FLOOR = SPEED_CREDIT_GAS + SPEED_CREDIT_GAS / 63 + 10_000;

    address internal immutable _PROXY_MANAGER;
    address internal immutable _COLLATERALIZATION;
    address internal immutable _RISK_MODULE;
    address internal immutable _MARKET_REGISTRY;
    address internal immutable _PARAMETER_STORE;
    address internal immutable _LP_VAULT_SWAP;
    address internal immutable _LOCK;
    address internal immutable _VAULT_TOKEN_FACTORY;
    address internal immutable _TIMELOCK;
    /// @dev `keccak256(abi.encode(immutables))`, compared between the router and each logic contract.
    bytes32 internal immutable _IMMUTABLES_HASH;
    /// @dev This contract's own address, used to refuse direct calls to a logic contract.
    address internal immutable _SELF;

    constructor(
        AaveAdapterImmutables memory im
    ) {
        if (
            im.proxyManager == address(0) || im.collateralization == address(0) || im.riskModule == address(0)
                || im.marketRegistry == address(0) || im.parameterStore == address(0) || im.lpVaultSwap == address(0)
                || im.lock == address(0) || im.vaultTokenFactory == address(0) || im.timelock == address(0)
        ) revert ZeroAddress();
        _PROXY_MANAGER = im.proxyManager;
        _COLLATERALIZATION = im.collateralization;
        _RISK_MODULE = im.riskModule;
        _MARKET_REGISTRY = im.marketRegistry;
        _PARAMETER_STORE = im.parameterStore;
        _LP_VAULT_SWAP = im.lpVaultSwap;
        _LOCK = im.lock;
        _VAULT_TOKEN_FACTORY = im.vaultTokenFactory;
        _TIMELOCK = im.timelock;
        _IMMUTABLES_HASH = keccak256(abi.encode(im));
        _SELF = address(this);
    }

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        // Reason: binding a storage pointer to the fixed ERC-7201 slot needs one assignment of `.slot`.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    function _onlyDelegated() internal view {
        if (address(this) == _SELF) revert NotDelegated();
    }

    /// @dev Takes the Lock: the first external call of every user entry point.
    function _acquire() internal {
        ILock(_LOCK).acquire();
    }

    /// @dev Frees the Lock: the last step of every user entry point, never of an inner callee.
    function _release() internal {
        ILock(_LOCK).release();
    }

    function _openSession(
        address proxy,
        uint256 marketId,
        bytes32 positionKey,
        uint256 units,
        uint256 debtReserveId,
        bytes32 minAmountsHash
    ) internal {
        bytes32 slot = SESSION_SLOT;
        // Reason: the session lives in EIP-1153 transient storage, which Solidity reaches only through TSTORE.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            tstore(slot, proxy)
            tstore(add(slot, 1), marketId)
            tstore(add(slot, 2), positionKey)
            tstore(add(slot, 3), units)
            tstore(add(slot, 4), debtReserveId)
            tstore(add(slot, 5), minAmountsHash)
            tstore(add(slot, 6), 0)
            tstore(add(slot, 7), 0)
        }
    }

    /// @dev Reads the session; `proxy == address(0)` when none is open.
    function _session()
        internal
        view
        returns (
            address proxy,
            uint256 marketId,
            bytes32 positionKey,
            uint256 units,
            uint256 debtReserveId,
            bytes32 minAmountsHash,
            uint256 steps
        )
    {
        bytes32 slot = SESSION_SLOT;
        // Reason: the session lives in EIP-1153 transient storage, which Solidity reaches only through TLOAD.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            proxy := tload(slot)
            marketId := tload(add(slot, 1))
            positionKey := tload(add(slot, 2))
            units := tload(add(slot, 3))
            debtReserveId := tload(add(slot, 4))
            minAmountsHash := tload(add(slot, 5))
            steps := tload(add(slot, 6))
        }
    }

    function _markStep(
        uint256 step
    ) internal {
        bytes32 slot = SESSION_SLOT;
        // Reason: the session lives in EIP-1153 transient storage, which Solidity reaches only through TLOAD/TSTORE.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let s := add(slot, 6)
            tstore(s, or(tload(s), step))
        }
    }

    /// @dev Records the session's health factor before, read by `deleverageRepay` after LPVaultSwap's pokes.
    function _setHfBefore(
        uint256 hf
    ) internal {
        bytes32 slot = SESSION_SLOT;
        // Reason: the session lives in EIP-1153 transient storage, which Solidity reaches only through TSTORE.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            tstore(add(slot, 7), hf)
        }
    }

    function _hfBefore() internal view returns (uint256 hf) {
        bytes32 slot = SESSION_SLOT;
        // Reason: the session lives in EIP-1153 transient storage, which Solidity reaches only through TLOAD.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            hf := tload(add(slot, 7))
        }
    }

    /// @dev Closes the session before the entry point returns, so no later call of the transaction can reach a step.
    function _clearSession() internal {
        bytes32 slot = SESSION_SLOT;
        // Reason: the session lives in EIP-1153 transient storage, which Solidity reaches only through TSTORE.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            tstore(slot, 0)
            tstore(add(slot, 1), 0)
            tstore(add(slot, 2), 0)
            tstore(add(slot, 3), 0)
            tstore(add(slot, 4), 0)
            tstore(add(slot, 5), 0)
            tstore(add(slot, 6), 0)
            tstore(add(slot, 7), 0)
        }
    }
}
