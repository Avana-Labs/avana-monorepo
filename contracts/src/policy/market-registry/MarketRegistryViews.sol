// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "../../types/DriftReason.sol";
import {Market} from "../../types/Market.sol";
import {PauseReason} from "../../types/PauseReason.sol";
import {PauseState} from "../../types/PauseState.sol";
import {RouteSlot} from "../../types/RouteSlot.sol";
import {IMarketRegistryApprovals} from "./IMarketRegistryApprovals.sol";
import {IMarketRegistryBreakers} from "./IMarketRegistryBreakers.sol";
import {IMarketRegistryCreditLines} from "./IMarketRegistryCreditLines.sol";
import {IMarketRegistryFreeze} from "./IMarketRegistryFreeze.sol";
import {IMarketRegistryHubs} from "./IMarketRegistryHubs.sol";
import {IMarketRegistryPause} from "./IMarketRegistryPause.sol";
import {IMarketRegistryRouteViews} from "./IMarketRegistryRouteViews.sol";
import {IMarketRegistryStandby} from "./IMarketRegistryStandby.sol";
import {IMarketRegistryViews} from "./IMarketRegistryViews.sol";
import {IMarketRegistryWindDown} from "./IMarketRegistryWindDown.sol";
import {MarketRegistryDriftView} from "./MarketRegistryDriftView.sol";
import {DebtReserveDef} from "./types/DebtReserveDef.sol";
import {RiskTier} from "./types/RiskTier.sol";
import {SpokeDef} from "./types/SpokeDef.sol";
import {TokenDef} from "./types/TokenDef.sol";
import {WindDownState} from "./types/WindDownState.sol";

/// @title MarketRegistryViews
/// @notice Every view of the MarketRegistry, served from its own storage.
/// @dev Every view is `view`, never reverts and returns zeros and `false` for an unknown key, so every usability and
/// approval check fails closed (REQ-CONFIG-064).
/// @custom:spec REQ-CONFIG-063, REQ-CONFIG-064, REQ-MREG-014, REQ-MREG-031, Q-378
abstract contract MarketRegistryViews is
    MarketRegistryDriftView,
    IMarketRegistryHubs,
    IMarketRegistryPause,
    IMarketRegistryFreeze,
    IMarketRegistryBreakers,
    IMarketRegistryStandby,
    IMarketRegistryCreditLines,
    IMarketRegistryWindDown,
    IMarketRegistryApprovals,
    IMarketRegistryViews,
    IMarketRegistryRouteViews
{
    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-006, REQ-CONFIG-064
    function getMarket(
        uint256 marketId
    ) external view override returns (Market memory market) {
        market = _s().markets[marketId];
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-064
    function getToken(
        address token
    ) external view override returns (TokenDef memory def) {
        def = _s().tokens[token];
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-016, REQ-CONFIG-064
    function getSpoke(
        address spoke
    ) external view override returns (SpokeDef memory def) {
        def = _s().spokes[spoke];
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-064
    function getSpokes() external view override returns (address[] memory spokes) {
        spokes = _s().spokeList;
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec Q-378
    function marketsOfSpoke(
        address spoke
    ) external view override returns (uint256[] memory marketIds) {
        marketIds = _s().marketsOfSpoke[spoke];
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-007
    function marketOfKey(
        bytes32 key
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfKey[key];
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-007
    function marketOfVaultToken(
        address vaultToken
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfVaultToken[vaultToken];
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-007
    function marketOfLpOracle(
        address lpOracle
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfLpOracle[lpOracle];
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-007
    function marketOfReserve(
        address spoke,
        uint256 reserveId
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfReserve[spoke][reserveId];
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-007
    function marketOfHubAsset(
        address hub,
        uint256 hubAssetId
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfHubAsset[hub][hubAssetId];
    }

    /// @inheritdoc IMarketRegistryViews
    /// @custom:spec REQ-CONFIG-006
    function marketCount() external view override returns (uint256 count) {
        count = _s().marketCount;
    }

    /// @inheritdoc IMarketRegistryRouteViews
    /// @custom:spec REQ-MREG-006, REQ-MREG-009
    function getDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view override returns (DebtReserveDef memory def) {
        def = _s().debtReserves[spoke][reserveId];
    }

    /// @inheritdoc IMarketRegistryRouteViews
    /// @custom:spec REQ-MREG-007
    function getDebtReserveIds(
        address spoke
    ) external view override returns (uint256[] memory reserveIds) {
        reserveIds = _s().debtReserveIds[spoke];
    }

    /// @inheritdoc IMarketRegistryRouteViews
    /// @custom:spec REQ-MREG-007
    function isApprovedDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view override returns (bool approved) {
        approved = _s().debtReserves[spoke][reserveId].approved;
    }

    /// @inheritdoc IMarketRegistryRouteViews
    /// @custom:spec REQ-CONFIG-063, REQ-MREG-014
    function getRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view override returns (address route, bool usable) {
        RouteRecord storage r = _s().routes[_slotKey(marketId, token, debtAsset, kind)];
        route = r.route;
        usable = route != address(0) && r.active;
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec REQ-CONFIG-083
    function hubTier(
        address hub
    ) external view override returns (RiskTier tier) {
        tier = _s().hubTier[hub];
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec REQ-CONFIG-005, REQ-CONFIG-083, INV-095
    function isRecordedHub(
        address account
    ) external view override returns (bool recorded) {
        recorded = _s().hubTier[account] != RiskTier.None;
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec REQ-CONFIG-083
    function getHubs() external view override returns (address[] memory hubs) {
        hubs = _s().hubList;
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec REQ-CONFIG-083
    function hubOf(
        address spoke
    ) external view override returns (address hub) {
        hub = _s().spokes[spoke].hub;
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec REQ-CONFIG-075
    function integrationOf(
        uint32 integrationId
    ) external view override returns (address lpVault, address pricing) {
        lpVault = _s().integrationLpVault[integrationId];
        pricing = _s().integrationPricing[integrationId];
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec REQ-CONFIG-075
    function integrationIdOf(
        address lpVault
    ) external view override returns (uint32 integrationId) {
        integrationId = _s().integrationIdOf[lpVault];
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec REQ-MREG-009
    function firstLossReserveOf(
        address hub,
        address asset
    ) external view override returns (address firstLossReserve) {
        firstLossReserve = _s().firstLossReserveOf[hub][asset];
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec Q-378
    function crossHubLineCap(
        address fundingHub,
        address asset,
        address spoke
    ) external view override returns (uint256 cap) {
        cap = _s().crossHubLineCap[fundingHub][asset][spoke];
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec Q-378
    function crossHubLineTotal(
        address fundingHub,
        address asset
    ) external view override returns (uint256 total) {
        total = _s().crossHubLineTotal[fundingHub][asset];
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec REQ-CONFIG-081
    function crossHubLinesEnabled() external view override returns (bool enabled) {
        enabled = _s().crossHubLinesEnabled;
    }

    /// @inheritdoc IMarketRegistryCreditLines
    /// @custom:spec REQ-CONFIG-081
    function creditLine(
        address fundingHub,
        address asset
    ) external view override returns (uint256 line, uint256 drawCapSum) {
        CreditLine storage cl = _s().creditLines[fundingHub][asset];
        line = cl.line;
        drawCapSum = cl.drawCapSum;
    }

    /// @inheritdoc IMarketRegistryCreditLines
    /// @custom:spec REQ-CONFIG-081, REQ-RISK-082
    function creditLineCoverage(
        address fundingHub,
        address asset
    ) external view override returns (uint256 required, uint256 funded) {
        (required, funded) = _coverage(fundingHub, asset, _s().creditLines[fundingHub][asset].line);
    }

    /// @inheritdoc IMarketRegistryApprovals
    /// @custom:spec REQ-CONFIG-074
    function isApprovedSpokeCodeHash(
        bytes32 codeHash
    ) external view override returns (bool approved) {
        approved = _spokeHashApproved(codeHash);
    }

    /// @inheritdoc IMarketRegistryApprovals
    /// @custom:spec REQ-CONFIG-074, REQ-CONFIG-016, REQ-RISK-088
    function spokeImplementationStatus(
        address spoke
    ) external view override returns (address implementation, bytes32 codeHash, bool current) {
        (implementation, codeHash, current) = _spokeImplementation(spoke);
    }

    /// @inheritdoc IMarketRegistryApprovals
    /// @custom:spec REQ-MREG-020
    function integrationContracts(
        uint32 integrationId
    ) external view override returns (address[] memory contracts) {
        contracts = _s().integrationContracts[integrationId];
    }

    /// @inheritdoc IMarketRegistryPause
    /// @custom:spec REQ-MREG-001, REQ-MREG-002, REQ-MREG-003
    function pauseState(
        address hub
    ) external view override returns (PauseState state) {
        state = _s().pauseState[hub];
    }

    /// @inheritdoc IMarketRegistryPause
    /// @custom:spec REQ-MREG-024
    function pauseReason(
        address hub
    ) external view override returns (PauseReason reason) {
        reason = _s().pauseReason[hub];
    }

    /// @inheritdoc IMarketRegistryFreeze
    /// @custom:spec REQ-MREG-022, REQ-MREG-023
    function isFrozenAddress(
        address account
    ) external view override returns (bool frozen) {
        frozen = _s().frozen[account];
    }

    /// @inheritdoc IMarketRegistryFreeze
    /// @custom:spec REQ-MREG-019
    function freezesInWindow(
        address caller
    ) external view override returns (uint256 count) {
        // Block timestamps and chain identifiers fit 64 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        count = _freezesInWindow(caller, uint64(block.timestamp / 3600));
    }

    /// @inheritdoc IMarketRegistryFreeze
    /// @custom:spec REQ-MREG-019
    function MAX_ADDRESS_FREEZES_PER_DAY() external pure override returns (uint256 limit) {
        limit = _MAX_FREEZES_PER_DAY;
    }

    /// @inheritdoc IMarketRegistryBreakers
    /// @custom:spec REQ-MREG-025
    function marketBreaker(
        uint256 marketId
    ) external view override returns (uint32 latchedReasons, uint64 lastBreach) {
        bytes32 key = bytes32(marketId);
        latchedReasons = _s().latched[key];
        lastBreach = _s().lastBreachAt[key];
    }

    /// @inheritdoc IMarketRegistryBreakers
    /// @custom:spec REQ-MREG-025
    function debtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (uint32 latchedReasons, uint64 lastBreach) {
        bytes32 key = _debtKey(spoke, debtReserveId);
        latchedReasons = _s().latched[key];
        lastBreach = _s().lastBreachAt[key];
    }

    /// @inheritdoc IMarketRegistryBreakers
    /// @custom:spec REQ-MREG-025
    function lastBreachAt(
        bytes32 key
    ) external view override returns (uint64 at) {
        at = _s().lastBreachAt[key];
    }

    /// @inheritdoc IMarketRegistryBreakers
    /// @custom:spec REQ-MREG-031
    function activeMarketCount(
        address spoke
    ) external view override returns (uint256 count) {
        uint256[] storage ids = _s().marketsOfSpoke[spoke];
        for (uint256 i = 0; i < ids.length; ++i) {
            if (_liquidatable(_s().markets[ids[i]].status)) ++count;
        }
    }

    /// @inheritdoc IMarketRegistryStandby
    /// @custom:spec REQ-MREG-028
    function activePriceRoutes(
        address token
    ) external view override returns (address[] memory primary, address[] memory alternate, RouteSlot replaced) {
        TokenDef storage t = _s().tokens[token];
        replaced = t.replacedSlot;
        primary = replaced == RouteSlot.Primary ? t.standbyRoute : t.primaryRoute;
        alternate = replaced == RouteSlot.Alternate ? t.standbyRoute : t.alternateRoute;
    }

    /// @inheritdoc IMarketRegistryStandby
    /// @custom:spec REQ-MREG-028
    function standbySwitchLockedUntil(
        address token
    ) external view override returns (uint256 until) {
        uint64 at = _s().standbyCancelledAt[token];
        until = at == 0 ? 0 : uint256(at) + _STANDBY_RESWITCH_COOLDOWN;
    }

    /// @inheritdoc IMarketRegistryStandby
    /// @custom:spec REQ-MREG-028
    function priceRouteVersion(
        address token
    ) external view override returns (uint64 version) {
        version = _s().priceRouteVersion[token];
    }

    /// @inheritdoc IMarketRegistryWindDown
    /// @custom:spec REQ-CONFIG-080
    function windDownState(
        uint256 marketId
    ) external view override returns (WindDownState memory state) {
        state = _s().windDown[marketId];
    }

    /// @inheritdoc IMarketRegistryWindDown
    /// @custom:spec REQ-MREG-033
    function settlementReserve(
        uint256 marketId
    ) external view override returns (uint256 debtReserveId) {
        debtReserveId = _s().settlementReserve[marketId];
    }

    /// @inheritdoc IMarketRegistryHubs
    /// @custom:spec REQ-ADAPTER-028, REQ-ADAPTER-029, REQ-ADAPTER-030, REQ-CONFIG-076
    function spokeSettingsDrift(
        address spoke
    ) external view override returns (uint256 marketId, DriftReason reason) {
        (marketId, reason) = _spokeDrift(spoke);
    }
}
