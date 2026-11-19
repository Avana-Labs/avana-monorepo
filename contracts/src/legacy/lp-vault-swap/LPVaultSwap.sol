// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashReceiver} from "../../flash/IFlashReceiver.sol";
import {ILPVaultSwap} from "./ILPVaultSwap.sol";
import {ILPVaultSwapLogic} from "./ILPVaultSwapLogic.sol";
import {LPVaultSwapStorage} from "./LPVaultSwapStorage.sol";
import {
    DeleverageRequest,
    LPVaultSwapImmutables,
    LPVaultSwapLogics,
    LiquidationParams,
    LiquidationResult
} from "./types/LPVaultSwapTypes.sol";
import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// The keeper events follow a view read; the setters are restricted by the AccessManager.
// forge-lint: disable-start(reentrancy-events)
// A zero or repeated initial keeper must revert the initialisation.
// forge-lint: disable-start(require-revert-in-loop)
/// @title LPVaultSwap
/// @notice The chain's liquidator: access control, the committed-operator registry, and dispatch of `liquidate`,
/// `settlePending`, `deleverage` and `onFlashLoan` to their logic contracts by delegatecall.
/// @dev UUPS proxy; only the AccessManager's governance role can upgrade it.
contract LPVaultSwap is ILPVaultSwap, LPVaultSwapStorage, AccessManagedUpgradeable, UUPSUpgradeable {
    address internal immutable _LIQUIDATION_LOGIC;
    address internal immutable _PENDING_LOGIC;
    address internal immutable _DELEVERAGE_LOGIC;

    /// @notice Fixes the implementation immutables, checks each logic contract and disables initializers.
    constructor(
        LPVaultSwapImmutables memory im,
        LPVaultSwapLogics memory logics
    ) LPVaultSwapStorage(im) {
        _requireLogic(logics.liquidation, keccak256("LPVaultSwapLiquidationLogic"));
        _requireLogic(logics.pending, keccak256("LPVaultSwapPendingLogic"));
        _requireLogic(logics.deleverage, keccak256("LPVaultSwapDeleverageLogic"));
        _LIQUIDATION_LOGIC = logics.liquidation;
        _PENDING_LOGIC = logics.pending;
        _DELEVERAGE_LOGIC = logics.deleverage;
        _disableInitializers();
    }

    /// @inheritdoc ILPVaultSwap
    function liquidate(
        LiquidationParams calldata
    )
        external
        override
        returns (
            LiquidationResult memory /* result */
        )
    {
        _delegate(_LIQUIDATION_LOGIC);
    }

    /// @inheritdoc ILPVaultSwap
    function settlePending(
        uint256,
        uint256
    )
        external
        override
        returns (
            uint256, /* units */
            uint256[] memory, /* amounts */
            uint256 /* added */
        )
    {
        _delegate(_PENDING_LOGIC);
    }

    /// @inheritdoc ILPVaultSwap
    function deleverage(
        DeleverageRequest calldata
    )
        external
        override
        returns (
            uint256, /* debtRepaid */
            uint256 /* debtAssetOut */
        )
    {
        _delegate(_DELEVERAGE_LOGIC);
    }

    /// @inheritdoc IFlashReceiver
    function onFlashLoan(
        address,
        uint256,
        uint256,
        bytes calldata
    )
        external
        override
        returns (
            bytes32 /* magic */
        )
    {
        _delegate(_DELEVERAGE_LOGIC);
    }

    /// @inheritdoc ILPVaultSwap
    function initialize(
        address authority,
        address[] calldata initialKeepers
    ) external override initializer {
        if (authority == address(0)) revert ZeroAddress();
        __AccessManaged_init(authority);
        __UUPSUpgradeable_init();
        uint256 n = initialKeepers.length;
        if (n > _MAX_KEEPERS) revert TooManyKeepers(_MAX_KEEPERS);
        if (n < _KEEPER_FLOOR) revert KeeperFloor(n, _KEEPER_FLOOR);
        for (uint256 i = 0; i < n; ++i) {
            _register(initialKeepers[i]);
        }
    }

    /// @inheritdoc ILPVaultSwap
    function addKeeper(
        address keeper
    ) external override restricted {
        Layout storage l = _s();
        if (keeper == address(0) || l.keepers[keeper]) revert InvalidKeeper();
        if (l.keeperList.length >= _MAX_KEEPERS) revert TooManyKeepers(_MAX_KEEPERS);
        _register(keeper);
    }

    /// @inheritdoc ILPVaultSwap
    function removeKeeper(
        address keeper
    ) external override restricted {
        Layout storage l = _s();
        if (!l.keepers[keeper]) revert InvalidKeeper();
        address[] storage list = l.keeperList;
        uint256 activeAfter = list.length - 1;
        if (activeAfter < _KEEPER_FLOOR) revert KeeperFloor(activeAfter, _KEEPER_FLOOR);
        uint256 last = list.length - 1;
        uint256 index = 0;
        while (list[index] != keeper) {
            ++index;
        }
        list[index] = list[last];
        list.pop();
        l.keepers[keeper] = false;
        emit KeeperRemoved(keeper);
    }

    /// @inheritdoc ILPVaultSwap
    function isApprovedKeeper(
        address keeper
    ) external view override returns (bool approved) {
        approved = _s().keepers[keeper];
    }

    /// @inheritdoc ILPVaultSwap
    function approvedKeeperCount() external view override returns (uint256 count) {
        count = _s().keeperList.length;
    }

    /// @inheritdoc ILPVaultSwap
    function activeKeeperCount() external view override returns (uint256 count) {
        count = _s().keeperList.length;
    }

    /// @inheritdoc ILPVaultSwap
    function getKeepers() external view override returns (address[] memory keepers) {
        keepers = _s().keeperList;
    }

    /// @inheritdoc ILPVaultSwap
    function MAX_REPAY_TRANSFERS() external pure override returns (uint256 count) {
        count = _MAX_REPAY_TRANSFERS;
    }

    /// @inheritdoc ILPVaultSwap
    function KEEPER_FLOOR() external view override returns (uint256 floor) {
        floor = _KEEPER_FLOOR;
    }

    /// @inheritdoc ILPVaultSwap
    function MAX_KEEPERS() external pure override returns (uint256 max) {
        max = _MAX_KEEPERS;
    }

    /// @inheritdoc ILPVaultSwap
    function LOCK() external view override returns (address lock) {
        lock = _LOCK;
    }

    /// @inheritdoc ILPVaultSwap
    function AAVE_ADAPTER() external view override returns (address adapter) {
        adapter = _AAVE_ADAPTER;
    }

    /// @inheritdoc ILPVaultSwap
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc ILPVaultSwap
    function MARKET_REGISTRY() external view override returns (address registry) {
        registry = _MARKET_REGISTRY;
    }

    /// @inheritdoc ILPVaultSwap
    function PARAMETER_STORE() external view override returns (address store) {
        store = _PARAMETER_STORE;
    }

    /// @inheritdoc ILPVaultSwap
    function PAYOUT_ESCROW() external view override returns (address escrow) {
        escrow = _PAYOUT_ESCROW;
    }

    /// @inheritdoc ILPVaultSwap
    function PAYOUT_TRANSFER_GAS() external pure override returns (uint256 gas) {
        gas = _PAYOUT_TRANSFER_GAS;
    }

    function _register(
        address keeper
    ) private {
        Layout storage l = _s();
        if (keeper == address(0) || l.keepers[keeper]) revert InvalidKeeper();
        l.keepers[keeper] = true;
        l.keeperList.push(keeper);
        emit KeeperAdded(keeper);
    }

    function _authorizeUpgrade(
        address
    ) internal override restricted {}

    function _delegate(
        address logic
    ) private {
        _onlyDelegated();
        // Passes the return data through unchanged, as a proxy does.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), logic, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    function _requireLogic(
        address logic,
        bytes32 kind
    ) private view {
        if (logic == address(0)) revert ZeroAddress();
        (bytes32 k, bytes32 h) = ILPVaultSwapLogic(logic).logicConfig();
        if (k != kind || h != _IMMUTABLES_HASH) revert InvalidLogic();
    }
}
// forge-lint: disable-end(reentrancy-events)
// forge-lint: disable-end(require-revert-in-loop)
