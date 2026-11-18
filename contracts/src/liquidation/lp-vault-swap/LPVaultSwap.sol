// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashReceiver} from "../../flash/IFlashReceiver.sol";
import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {IMarketRegistry} from "../../policy/market-registry/IMarketRegistry.sol";
import {ILPVaultSwap} from "./ILPVaultSwap.sol";
import {ILPVaultSwapAdmin} from "./ILPVaultSwapAdmin.sol";
import {ILPVaultSwapDeleverage} from "./ILPVaultSwapDeleverage.sol";
import {ILPVaultSwapLiquidation} from "./ILPVaultSwapLiquidation.sol";
import {ILPVaultSwapLogic} from "./ILPVaultSwapLogic.sol";
import {ILPVaultSwapViews} from "./ILPVaultSwapViews.sol";
import {LPVaultSwapStorage} from "./LPVaultSwapStorage.sol";
import {DeleverageRequest} from "./types/DeleverageRequest.sol";
import {LPVaultSwapImmutables} from "./types/LPVaultSwapImmutables.sol";
import {LPVaultSwapLogics} from "./types/LPVaultSwapLogics.sol";
import {LiquidationParams} from "./types/LiquidationParams.sol";
import {LiquidationResult} from "./types/LiquidationResult.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

// activeKeeperCount reads the freeze list once per keeper, at most MAX_KEEPERS; a view.
// forge-lint: disable-start(calls-loop)
// The keeper events follow a view read; the setters are timelock-only.
// forge-lint: disable-start(reentrancy-events)
// A zero or repeated initial keeper must revert the initialisation.
// forge-lint: disable-start(require-revert-in-loop)
/// @title LPVaultSwap
/// @notice The chain's liquidator: roles, the committed-operator registry, and dispatch of `liquidate`,
/// `settlePending`, `deleverage` and `onFlashLoan` to their logic contracts by delegatecall.
/// @dev UUPS proxy; only the timelock can upgrade it.
contract LPVaultSwap is ILPVaultSwap, LPVaultSwapStorage, AccessControlUpgradeable, UUPSUpgradeable {
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

    /// @inheritdoc ILPVaultSwapLiquidation
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

    /// @inheritdoc ILPVaultSwapLiquidation
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

    /// @inheritdoc ILPVaultSwapDeleverage
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

    /// @inheritdoc ILPVaultSwapAdmin
    function initialize(
        address timelock,
        address[] calldata initialKeepers
    ) external override initializer {
        if (timelock == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _s().timelock = timelock;
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        _grantRole(AvanaRoles.APPLICATION_ADMIN, timelock);
        uint256 n = initialKeepers.length;
        if (n > _MAX_KEEPERS) revert TooManyKeepers(_MAX_KEEPERS);
        if (n < _KEEPER_FLOOR) revert KeeperFloor(n, _KEEPER_FLOOR);
        for (uint256 i = 0; i < n; ++i) {
            _register(initialKeepers[i]);
        }
    }

    /// @inheritdoc ILPVaultSwapAdmin
    function addKeeper(
        address keeper
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        Layout storage l = _s();
        if (keeper == address(0) || l.keepers[keeper]) revert InvalidKeeper();
        if (IMarketRegistry(_MARKET_REGISTRY).isFrozenAddress(keeper)) revert AddressIsFrozen(keeper);
        if (l.keeperList.length >= _MAX_KEEPERS) revert TooManyKeepers(_MAX_KEEPERS);
        _register(keeper);
    }

    /// @inheritdoc ILPVaultSwapAdmin
    function removeKeeper(
        address keeper
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        Layout storage l = _s();
        if (!l.keepers[keeper]) revert InvalidKeeper();
        uint256 active = activeKeeperCount();
        uint256 activeAfter = IMarketRegistry(_MARKET_REGISTRY).isFrozenAddress(keeper) ? active : active - 1;
        if (activeAfter < _KEEPER_FLOOR) revert KeeperFloor(activeAfter, _KEEPER_FLOOR);
        address[] storage list = l.keeperList;
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

    /// @inheritdoc ILPVaultSwapViews
    function isApprovedKeeper(
        address keeper
    ) external view override returns (bool approved) {
        approved = _s().keepers[keeper];
    }

    /// @inheritdoc ILPVaultSwapViews
    function approvedKeeperCount() external view override returns (uint256 count) {
        count = _s().keeperList.length;
    }

    /// @inheritdoc ILPVaultSwapViews
    function activeKeeperCount() public view override returns (uint256 count) {
        address[] storage list = _s().keeperList;
        IMarketRegistry mr = IMarketRegistry(_MARKET_REGISTRY);
        uint256 n = list.length;
        for (uint256 i = 0; i < n; ++i) {
            if (!mr.isFrozenAddress(list[i])) ++count;
        }
    }

    /// @inheritdoc ILPVaultSwapViews
    function getKeepers() external view override returns (address[] memory keepers) {
        keepers = _s().keeperList;
    }

    /// @inheritdoc ILPVaultSwapViews
    function MAX_REPAY_TRANSFERS() external pure override returns (uint256 count) {
        count = _MAX_REPAY_TRANSFERS;
    }

    /// @inheritdoc ILPVaultSwapViews
    function KEEPER_FLOOR() external view override returns (uint256 floor) {
        floor = _KEEPER_FLOOR;
    }

    /// @inheritdoc ILPVaultSwapViews
    function MAX_KEEPERS() external pure override returns (uint256 max) {
        max = _MAX_KEEPERS;
    }

    /// @inheritdoc ILPVaultSwapViews
    function APPLICATION_ADMIN() external pure override returns (bytes32 role) {
        role = AvanaRoles.APPLICATION_ADMIN;
    }

    /// @inheritdoc ILPVaultSwapViews
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _s().timelock;
    }

    /// @inheritdoc ILPVaultSwapViews
    function LOCK() external view override returns (address lock) {
        lock = _LOCK;
    }

    /// @inheritdoc ILPVaultSwapViews
    function AAVE_ADAPTER() external view override returns (address adapter) {
        adapter = _AAVE_ADAPTER;
    }

    /// @inheritdoc ILPVaultSwapViews
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc ILPVaultSwapViews
    function MARKET_REGISTRY() external view override returns (address registry) {
        registry = _MARKET_REGISTRY;
    }

    /// @inheritdoc ILPVaultSwapViews
    function PARAMETER_STORE() external view override returns (address store) {
        store = _PARAMETER_STORE;
    }

    /// @inheritdoc ILPVaultSwapViews
    function PAYOUT_ESCROW() external view override returns (address escrow) {
        escrow = _PAYOUT_ESCROW;
    }

    /// @inheritdoc ILPVaultSwapViews
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

    /// @dev Either admin role can be held only by the timelock `initialize` set.
    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        if ((role == DEFAULT_ADMIN_ROLE || role == AvanaRoles.APPLICATION_ADMIN) && account != _s().timelock) {
            revert AdminRoleOnlyTimelock(role, account);
        }
        granted = super._grantRole(role, account);
    }

    function _authorizeUpgrade(
        address
    ) internal override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}

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
// forge-lint: disable-end(calls-loop)
// forge-lint: disable-end(reentrancy-events)
// forge-lint: disable-end(require-revert-in-loop)
