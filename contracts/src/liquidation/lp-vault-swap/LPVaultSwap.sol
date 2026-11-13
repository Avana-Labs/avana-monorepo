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

// activeKeeperCount reads the MarketRegistry freeze list once per registered keeper, at most MAX_KEEPERS (32);
// a view, so a revert only fails the read.
// forge-lint: disable-start(calls-loop)
// KeeperAdded and KeeperRemoved follow the registry's freeze read (a view); the setters are timelock-only.
// forge-lint: disable-start(reentrancy-events)
// initialize registers each launch keeper through the same check as addKeeper; a zero or repeated entry must
// revert the initialisation.
// forge-lint: disable-start(require-revert-in-loop)
/// @title LPVaultSwap
/// @notice The chain's only Avana liquidator, behind its fixed ERC-1967 proxy: roles, the committed-operator registry,
/// the implementation immutables and the dispatch of `liquidate`, `settlePending`, `deleverage` and `onFlashLoan` to
/// their logic contracts.
/// @dev UUPS: `_authorizeUpgrade` requires `APPLICATION_ADMIN`, and `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` can be
/// held only by the timelock `initialize` names (`AdminRoleOnlyTimelock`). The three logic contracts are
/// implementation immutables checked at construction (kind and immutables hash), so a new body is a new
/// implementation and waits the normal delay. Each dispatch runs the logic by delegatecall with the unchanged calldata
/// in the proxy's storage and returns its return data unchanged; a call to the implementation itself reverts
/// `NotDelegated`. The registry gates no call: `liquidate` is open to every address that is not frozen (Q-404).
/// @custom:spec REQ-SWAP-001, REQ-SWAP-032, REQ-SWAP-033, REQ-SWAP-034, REQ-SWAP-035, REQ-SWAP-036, REQ-SWAP-037, REQ-SWAP-038, REQ-SWAP-040, REQ-SWAP-043, REQ-SWAP-048, REQ-SWAP-065, REQ-SWAP-069, REQ-SWAP-072, REQ-SWAP-080, REQ-SWAP-085, REQ-SWAP-107, REQ-SWAP-113, REQ-SWAP-117, REQ-ACCESS-153, Q-259, Q-400, Q-404
contract LPVaultSwap is ILPVaultSwap, LPVaultSwapStorage, AccessControlUpgradeable, UUPSUpgradeable {
    /// @dev Body of `liquidate`.
    address internal immutable _LIQUIDATION_LOGIC;
    /// @dev Body of `settlePending`.
    address internal immutable _PENDING_LOGIC;
    /// @dev Bodies of `deleverage` and `onFlashLoan`.
    address internal immutable _DELEVERAGE_LOGIC;

    /// @notice Fixes the implementation immutables, checks each logic contract and disables initializers on the
    /// implementation itself.
    /// @param im The per-chain addresses and the keeper floor (`keeperFloor = 1` at launch).
    /// @param logics The three logic contracts, each built with `im`.
    /// @custom:spec REQ-SWAP-034, REQ-SWAP-040
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

    // ───────────────────────────────────────────────────────────────────────────────────────────── entry points

    /// @inheritdoc ILPVaultSwapLiquidation
    /// @custom:spec REQ-SWAP-001, REQ-SWAP-072, REQ-SWAP-085, REQ-SWAP-086
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
    /// @custom:spec REQ-SWAP-066
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
    /// @custom:spec REQ-SWAP-106
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
    /// @custom:spec REQ-SWAP-013, REQ-FLASH-004
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

    // ───────────────────────────────────────────────────────────────────────────────────────────── governance

    /// @inheritdoc ILPVaultSwapAdmin
    /// @custom:spec REQ-SWAP-032, REQ-SWAP-034, REQ-SWAP-040, REQ-ACCESS-153
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
    /// @custom:spec REQ-SWAP-033, REQ-SWAP-069, REQ-SWAP-107, REQ-SWAP-117
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
    /// @custom:spec REQ-SWAP-035, REQ-SWAP-038, REQ-SWAP-065, REQ-SWAP-069, REQ-SWAP-107
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

    // ───────────────────────────────────────────────────────────────────────────────────────────────── views

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-001, REQ-SWAP-032
    function isApprovedKeeper(
        address keeper
    ) external view override returns (bool approved) {
        approved = _s().keepers[keeper];
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-034
    function approvedKeeperCount() external view override returns (uint256 count) {
        count = _s().keeperList.length;
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-034, REQ-SWAP-039, REQ-SWAP-107
    function activeKeeperCount() public view override returns (uint256 count) {
        address[] storage list = _s().keeperList;
        IMarketRegistry mr = IMarketRegistry(_MARKET_REGISTRY);
        uint256 n = list.length;
        for (uint256 i = 0; i < n; ++i) {
            if (!mr.isFrozenAddress(list[i])) ++count;
        }
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-032
    function getKeepers() external view override returns (address[] memory keepers) {
        keepers = _s().keeperList;
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-122
    function MAX_REPAY_TRANSFERS() external pure override returns (uint256 count) {
        count = _MAX_REPAY_TRANSFERS;
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-034
    function KEEPER_FLOOR() external view override returns (uint256 floor) {
        floor = _KEEPER_FLOOR;
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-033
    function MAX_KEEPERS() external pure override returns (uint256 max) {
        max = _MAX_KEEPERS;
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-040
    function APPLICATION_ADMIN() external pure override returns (bytes32 role) {
        role = AvanaRoles.APPLICATION_ADMIN;
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-040
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _s().timelock;
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-002
    function LOCK() external view override returns (address lock) {
        lock = _LOCK;
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-020, REQ-SWAP-092
    function AAVE_ADAPTER() external view override returns (address adapter) {
        adapter = _AAVE_ADAPTER;
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-015, REQ-SWAP-020
    function COLLATERALIZATION() external view override returns (address collateralization) {
        collateralization = _COLLATERALIZATION;
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-004, REQ-SWAP-047
    function MARKET_REGISTRY() external view override returns (address registry) {
        registry = _MARKET_REGISTRY;
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-047
    function PARAMETER_STORE() external view override returns (address store) {
        store = _PARAMETER_STORE;
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-076
    function PAYOUT_ESCROW() external view override returns (address escrow) {
        escrow = _PAYOUT_ESCROW;
    }

    /// @inheritdoc ILPVaultSwapViews
    /// @custom:spec REQ-SWAP-076
    function PAYOUT_TRANSFER_GAS() external pure override returns (uint256 gas) {
        gas = _PAYOUT_TRANSFER_GAS;
    }

    // ────────────────────────────────────────────────────────────────────────────────────────────────── internal

    /// @dev Registers `keeper` (`InvalidKeeper` for zero or a duplicate) and emits `KeeperAdded`.
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
    /// @custom:spec REQ-SWAP-040, REQ-ACCESS-153, Q-259
    function _grantRole(
        bytes32 role,
        address account
    ) internal override returns (bool granted) {
        if ((role == DEFAULT_ADMIN_ROLE || role == AvanaRoles.APPLICATION_ADMIN) && account != _s().timelock) {
            revert AdminRoleOnlyTimelock(role, account);
        }
        granted = super._grantRole(role, account);
    }

    /// @dev UUPS: only `APPLICATION_ADMIN` (the timelock, normal delay).
    /// @custom:spec REQ-SWAP-040, REQ-SWAP-069
    function _authorizeUpgrade(
        address
    ) internal override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}

    /// @dev Runs the current call in `logic` by delegatecall with the unchanged calldata and returns or reverts with
    /// its data unchanged; refuses to run at the implementation's own address.
    function _delegate(
        address logic
    ) private {
        _onlyDelegated();
        // Forwarding to an implementation immutable: the return data is passed through unchanged, as a proxy does.
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

    /// @dev `InvalidLogic` unless `logic` reports `kind` and the same implementation immutables.
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
