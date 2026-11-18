// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../governance/roles/AvanaRoles.sol";
import {IParameterStore} from "./IParameterStore.sol";
import {ParameterStoreForwardAdmin} from "./ParameterStoreForwardAdmin.sol";
import {ParameterStoreForwardRisk} from "./ParameterStoreForwardRisk.sol";
import {ParameterStoreRouter} from "./ParameterStoreRouter.sol";
import {
    DebtReserveParams,
    FeedDef,
    GlobalParams,
    MarketParams,
    ParameterStoreLogics
} from "./types/ParameterStoreTypes.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title ParameterStore
/// @notice Every Avana risk and feed parameter of one chain, with its bounds and change direction.
/// @dev UUPS proxy; only the timelock can upgrade it. Setter bodies run in five logic contracts by delegatecall.
contract ParameterStore is UUPSUpgradeable, ParameterStoreForwardRisk, ParameterStoreForwardAdmin {
    /// @inheritdoc IParameterStore
    function getMarketParams(
        uint256 marketId
    ) external view override returns (MarketParams memory params) {
        params = _s().market[marketId];
    }

    /// @inheritdoc IParameterStore
    function tokenCollateralFactorBps(
        address token
    ) external view override returns (uint16 bps) {
        bps = _s().tokenCollateralFactorBps[token];
    }

    /// @inheritdoc IParameterStore
    function getFeed(
        address feed
    ) external view override returns (FeedDef memory def) {
        def = _s().feeds[feed];
    }

    /// @inheritdoc IParameterStore
    function slippageAllowanceMinBps(
        uint256 marketId
    ) external view override returns (uint16 bps) {
        bps = _s().market[marketId].slippageAllowanceMinBps;
    }

    /// @inheritdoc IParameterStore
    function borrowPriceMaxAge(
        address feed
    ) external view override returns (uint32 age) {
        age = _s().feeds[feed].borrowPriceMaxAge;
    }

    /// @inheritdoc IParameterStore
    function liquidationPriceMaxAge(
        address feed
    ) external view override returns (uint32 age) {
        age = _s().feeds[feed].liquidationPriceMaxAge;
    }

    /// @inheritdoc IParameterStore
    function maxFlashFeeBps() external view override returns (uint16 value) {
        value = _s().g.maxFlashFeeBps;
    }

    /// @inheritdoc IParameterStore
    function avanaFeeShareBps() external view override returns (uint16 value) {
        value = _s().g.avanaFeeShareBps;
    }

    /// @inheritdoc IParameterStore
    function feeRecipient() external view override returns (address recipient) {
        recipient = _s().g.feeRecipient;
    }

    /// @inheritdoc IParameterStore
    function floorRoundingAllowance(
        address asset
    ) external view override returns (uint256 value) {
        value = _s().floorRoundingAllowance[asset];
    }

    /// @inheritdoc IParameterStore
    function MAX_HEARTBEAT_MARGIN() external pure override returns (uint32 value) {
        value = HEARTBEAT_MARGIN_MAX;
    }

    /// @inheritdoc IParameterStore
    function lastLoosenedAt(
        bytes32 paramKey
    ) external view override returns (uint64 at) {
        at = _s().lastLoosenedAt[paramKey];
    }

    /// @inheritdoc IParameterStore
    function LOOSEN_CAP_STEP_BPS() external pure override returns (uint16 value) {
        value = CAP_STEP_BPS;
    }

    /// @inheritdoc IParameterStore
    function LOOSEN_SLIPPAGE_STEP_BPS() external pure override returns (uint16 value) {
        value = SLIPPAGE_STEP_BPS;
    }

    /// @inheritdoc IParameterStore
    function TIMELOCK() external view override returns (address timelock) {
        timelock = _TIMELOCK;
    }

    /// @inheritdoc IParameterStore
    function marketUsdCap(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().marketUsdCap[marketId];
    }

    /// @inheritdoc IParameterStore
    function topUpSliceUsd(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().topUpSliceUsd[marketId];
    }

    /// @inheritdoc IParameterStore
    function stressFloorUsd(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().stressFloorUsd[marketId];
    }

    /// @inheritdoc IParameterStore
    function tokenUsdCap(
        address hub,
        address token
    ) external view override returns (uint256 value) {
        value = _s().tokenUsdCap[hub][token];
    }

    /// @inheritdoc IParameterStore
    function minPledgeUsd(
        uint256 marketId
    ) external view override returns (uint256 value) {
        value = _s().market[marketId].minPledgeUsd;
    }

    /// @inheritdoc IParameterStore
    function debtAssetParams(
        address asset
    ) external view override returns (DebtReserveParams memory p) {
        p.floorRoundingAllowance = _s().floorRoundingAllowance[asset];
    }

    /// @inheritdoc IParameterStore
    function routeDepthThreshold(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view override returns (uint256 value) {
        value = _s().routeDepth[keccak256(abi.encode(marketId, token, debtAsset, kind))];
    }

    /// @inheritdoc IParameterStore
    function MARKET_REGISTRY() external view override returns (address registry) {
        registry = address(_REGISTRY);
    }

    /// @notice Fixes the implementation immutables and the five logic contracts.
    constructor(
        address timelock,
        address marketRegistry,
        uint32 chainBlockTime,
        ParameterStoreLogics memory logics
    ) ParameterStoreRouter(timelock, marketRegistry, chainBlockTime, logics) {}

    /// @inheritdoc IParameterStore
    function initialize(
        address timelock,
        GlobalParams calldata
    ) external override initializer {
        if (timelock != _TIMELOCK) revert AdminRoleOnlyTimelock(DEFAULT_ADMIN_ROLE, timelock);
        __AccessControl_init();
        __UUPSUpgradeable_init();
        _setRoleAdmin(AvanaRoles.APPLICATION_RISK_STEWARD, AvanaRoles.APPLICATION_ADMIN);
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
        _grantRole(AvanaRoles.APPLICATION_ADMIN, timelock);
        _forward(_ADMIN_RISK_LOGIC);
    }

    /// @inheritdoc IParameterStore
    /// @dev Runs in the oracle-admin logic, whose return data ends the call; the `return` below is not reached.
    function liquidationLivenessHolds(
        address,
        uint256,
        uint256
    ) external view override returns (bool holds) {
        _forwardView(_ADMIN_ORACLE_LOGIC);
        return holds;
    }

    /// @inheritdoc IParameterStore
    function maxShortfallBps() external view override returns (uint16 value) {
        value = _s().g.maxShortfallBps;
    }

    /// @inheritdoc IParameterStore
    function debtStressRiseBps(
        address asset
    ) external view override returns (uint16 value) {
        value = _s().debtStressRiseBps[asset];
    }

    /// @inheritdoc IParameterStore
    function deficitMax(
        address hub,
        address asset
    ) external view override returns (uint256 value) {
        value = _s().deficitMax[hub][asset];
    }

    /// @inheritdoc IParameterStore
    function CHAIN_BLOCK_TIME() external view override returns (uint32 value) {
        value = _BLOCK_TIME;
    }

    /// @inheritdoc IParameterStore
    function heartbeatMargin(
        address feed
    ) external view override returns (uint32 margin) {
        margin = _s().feeds[feed].heartbeatMargin;
    }

    /// @inheritdoc IParameterStore
    function coverageRatioBps() external view override returns (uint16 value) {
        value = _s().coverageRatioBps;
    }

    /// @inheritdoc IParameterStore
    function tightenDeficitMax(
        address,
        address,
        uint256
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function loosenDeficitMax(
        address,
        address,
        uint256
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function tightenMaxShortfallBps(
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function loosenMaxShortfallBps(
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function tightenDebtStressRiseBps(
        address,
        uint16
    ) external override onlyAdminOrSteward {
        _forward(_TIGHTEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function loosenDebtStressRiseBps(
        address,
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LOOSEN_LOGIC);
    }

    /// @inheritdoc IParameterStore
    function setCoverageRatioBps(
        uint16
    ) external override onlyRole(AvanaRoles.APPLICATION_ADMIN) {
        _forward(_LISTING_LOGIC);
    }

    /// @dev Only `APPLICATION_ADMIN` (the timelock) upgrades, at the normal delay.
    function _authorizeUpgrade(
        address
    ) internal view override onlyRole(AvanaRoles.APPLICATION_ADMIN) {}
}
