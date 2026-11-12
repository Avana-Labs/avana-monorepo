// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "./ILPVaultSwapErrors.sol";
import {ILPVaultSwapEvents} from "./ILPVaultSwapEvents.sol";
import {LPVaultSwapImmutables} from "./types/LPVaultSwapImmutables.sol";

/// @title LPVaultSwapStorage
/// @notice The implementation immutables, constants and ERC-7201 storage shared by the LPVaultSwap implementation and
/// its three logic contracts.
/// @dev Storage lives at the ERC-7201 namespace `avana.storage.LPVaultSwap` of the proxy: the timelock, the
/// committed-operator registry and the `carry` of pending-settlement proceeds worth less than one Hub share. Every
/// other value is an immutable fixed at construction, identical in the implementation and each logic contract (the
/// implementation checks the hash), so a change is a new implementation behind `upgradeToAndCall` at the normal delay.
/// No liquidation or deleverage value is kept across calls (REQ-SWAP-103).
/// @custom:spec REQ-SWAP-040, REQ-SWAP-047, REQ-SWAP-070, REQ-SWAP-103
abstract contract LPVaultSwapStorage is ILPVaultSwapEvents, ILPVaultSwapErrors {
    /// @notice Gas forwarded to each gas-limited escrowable payout transfer (REQ-SWAP-076).
    uint256 internal constant _PAYOUT_TRANSFER_GAS = 100_000;
    /// @notice Gas kept after a payout transfer returns, for the balance read and the escrow deposit's setup.
    uint256 internal constant _POST_CALL_GAS = 10_000;
    /// @notice `⌈_PAYOUT_TRANSFER_GAS × 64 / 63⌉ + _POST_CALL_GAS` = 101,588 + 10,000.
    uint256 internal constant _PAYOUT_GAS_REQUIRED = 111_588;
    /// @notice Most transfers `onFlashLoan` makes to bring the flash source up to the amount owed (REQ-SWAP-122).
    uint256 internal constant _MAX_REPAY_TRANSFERS = 4;
    /// @notice Most registered committed operators (REQ-SWAP-033, Q-400).
    uint256 internal constant _MAX_KEEPERS = 32;
    /// @notice A health factor of 1, WAD.
    uint256 internal constant _HF_ONE = 1e18;

    /// @notice ERC-7201 slot of `Layout`:
    /// `keccak256(abi.encode(uint256(keccak256("avana.storage.LPVaultSwap")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _STORAGE_SLOT = 0x91af63178751821a6b1a96f50867937bf3006ecc962b49702910546a3afa6f00;

    /// @dev The chain's Lock.
    address internal immutable _LOCK;
    /// @dev The chain's AaveAdapter fixed proxy address.
    address internal immutable _AAVE_ADAPTER;
    /// @dev The chain's Collateralization.
    address internal immutable _COLLATERALIZATION;
    /// @dev The MarketRegistry fixed proxy address.
    address internal immutable _MARKET_REGISTRY;
    /// @dev The ParameterStore fixed proxy address.
    address internal immutable _PARAMETER_STORE;
    /// @dev The PayoutEscrow.
    address internal immutable _PAYOUT_ESCROW;
    /// @dev `keeperFloor`.
    uint256 internal immutable _KEEPER_FLOOR;
    /// @dev This contract's own address, so a body reached other than through the proxy refuses to run.
    address internal immutable _SELF;
    /// @dev `keccak256(abi.encode(im))` of the construction values.
    bytes32 internal immutable _IMMUTABLES_HASH;

    /// @custom:storage-location erc7201:avana.storage.LPVaultSwap
    struct Layout {
        // The chain's AvanaTimelock, set once by `initialize`.
        address timelock;
        // Registered committed operators.
        mapping(address operator => bool registered) keepers;
        // Their enumeration, at most `_MAX_KEEPERS` long.
        address[] keeperList;
        // Pending-settlement proceeds per settlement asset worth less than one Hub share, held for the next
        // `settlePending` into that asset (REQ-SWAP-070).
        mapping(address asset => uint256 amount) carry;
    }

    /// @notice Fixes the implementation immutables.
    /// @dev Reverts `ZeroAddress` for a zero address and `KeeperFloor(keeperFloor, MAX_KEEPERS)` unless
    /// `1 <= keeperFloor <= MAX_KEEPERS`.
    /// @param im The per-chain addresses and the keeper floor.
    /// @custom:spec REQ-SWAP-034, REQ-SWAP-040
    constructor(
        LPVaultSwapImmutables memory im
    ) {
        if (
            im.lock == address(0) || im.aaveAdapter == address(0) || im.collateralization == address(0)
                || im.marketRegistry == address(0) || im.parameterStore == address(0) || im.payoutEscrow == address(0)
        ) revert ZeroAddress();
        if (im.keeperFloor == 0 || im.keeperFloor > _MAX_KEEPERS) revert KeeperFloor(im.keeperFloor, _MAX_KEEPERS);
        _LOCK = im.lock;
        _AAVE_ADAPTER = im.aaveAdapter;
        _COLLATERALIZATION = im.collateralization;
        _MARKET_REGISTRY = im.marketRegistry;
        _PARAMETER_STORE = im.parameterStore;
        _PAYOUT_ESCROW = im.payoutEscrow;
        _KEEPER_FLOOR = im.keeperFloor;
        _SELF = address(this);
        _IMMUTABLES_HASH = keccak256(abi.encode(im));
    }

    /// @dev The proxy's ERC-7201 storage.
    function _s() internal pure returns (Layout storage l) {
        // ERC-7201 namespaced storage: the slot is a compile-time constant.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            l.slot := _STORAGE_SLOT
        }
    }

    /// @dev Reverts `NotDelegated` when this contract's own code runs at its own address, outside the proxy.
    function _onlyDelegated() internal view {
        if (address(this) == _SELF) revert NotDelegated();
    }
}
