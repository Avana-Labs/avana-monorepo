// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapBase} from "./ILPVaultSwapBase.sol";
import {LPVaultSwapImmutables} from "./types/LPVaultSwapTypes.sol";

/// @title LPVaultSwapStorage
/// @notice The implementation immutables, constants and ERC-7201 storage shared by the LPVaultSwap implementation and
/// its three logic contracts.
/// @dev No liquidation or deleverage value is kept across calls.
abstract contract LPVaultSwapStorage is ILPVaultSwapBase {
    /// @notice Gas forwarded to each gas-limited escrowable payout transfer.
    uint256 internal constant _PAYOUT_TRANSFER_GAS = 100_000;
    /// @notice `⌈_PAYOUT_TRANSFER_GAS × 64 / 63⌉` plus 10,000 kept for the work after the transfer returns.
    uint256 internal constant _PAYOUT_GAS_REQUIRED = 111_588;
    /// @notice Most transfers `onFlashLoan` makes to bring the flash source up to the amount owed.
    uint256 internal constant _MAX_REPAY_TRANSFERS = 4;
    uint256 internal constant _MAX_KEEPERS = 32;
    /// @notice A health factor of 1, WAD.
    uint256 internal constant _HF_ONE = 1e18;

    /// @notice ERC-7201 slot of `Layout`.
    bytes32 private constant _STORAGE_SLOT = 0x91af63178751821a6b1a96f50867937bf3006ecc962b49702910546a3afa6f00;

    address internal immutable _LOCK;
    address internal immutable _AAVE_ADAPTER;
    address internal immutable _COLLATERALIZATION;
    address internal immutable _MARKET_REGISTRY;
    address internal immutable _PARAMETER_STORE;
    address internal immutable _PAYOUT_ESCROW;
    uint256 internal immutable _KEEPER_FLOOR;
    /// @dev This contract's own address, so a body called outside the proxy refuses to run.
    address internal immutable _SELF;
    bytes32 internal immutable _IMMUTABLES_HASH;

    /// @custom:storage-location erc7201:avana.storage.LPVaultSwap
    struct Layout {
        // The chain's AvanaTimelock, set once by `initialize`.
        address timelock;
        mapping(address operator => bool registered) keepers;
        address[] keeperList;
        // Pending-settlement proceeds per asset worth less than one Hub share, held for the next `settlePending`.
        mapping(address asset => uint256 amount) carry;
    }

    /// @notice Fixes the implementation immutables.
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

    function _s() internal pure returns (Layout storage l) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            l.slot := _STORAGE_SLOT
        }
    }

    function _onlyDelegated() internal view {
        if (address(this) == _SELF) revert NotDelegated();
    }
}
