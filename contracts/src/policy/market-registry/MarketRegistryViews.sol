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
/// @dev Views never revert; an unknown key returns zeros and `false`.
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
    function getMarket(
        uint256 marketId
    ) external view override returns (Market memory market) {
        market = _s().markets[marketId];
    }

    /// @inheritdoc IMarketRegistryViews
    function getToken(
        address token
    ) external view override returns (TokenDef memory def) {
        def = _s().tokens[token];
    }

    /// @inheritdoc IMarketRegistryViews
    function getSpoke(
        address spoke
    ) external view override returns (SpokeDef memory def) {
        def = _s().spokes[spoke];
    }

    /// @inheritdoc IMarketRegistryViews
    function getSpokes() external view override returns (address[] memory spokes) {
        spokes = _s().spokeList;
    }

    /// @inheritdoc IMarketRegistryViews
    function marketsOfSpoke(
        address spoke
    ) external view override returns (uint256[] memory marketIds) {
        marketIds = _s().marketsOfSpoke[spoke];
    }

    /// @inheritdoc IMarketRegistryViews
    function marketOfKey(
        bytes32 key
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfKey[key];
    }

    /// @inheritdoc IMarketRegistryViews
    function marketOfVaultToken(
        address vaultToken
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfVaultToken[vaultToken];
    }

    /// @inheritdoc IMarketRegistryViews
    function marketOfLpOracle(
        address lpOracle
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfLpOracle[lpOracle];
    }

    /// @inheritdoc IMarketRegistryViews
    function marketOfReserve(
        address spoke,
        uint256 reserveId
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfReserve[spoke][reserveId];
    }

    /// @inheritdoc IMarketRegistryViews
    function marketOfHubAsset(
        address hub,
        uint256 hubAssetId
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfHubAsset[hub][hubAssetId];
    }

    /// @inheritdoc IMarketRegistryViews
    function marketCount() external view override returns (uint256 count) {
        count = _s().marketCount;
    }

    /// @inheritdoc IMarketRegistryRouteViews
    function getDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view override returns (DebtReserveDef memory def) {
        def = _s().debtReserves[spoke][reserveId];
    }

    /// @inheritdoc IMarketRegistryRouteViews
    function getDebtReserveIds(
        address spoke
    ) external view override returns (uint256[] memory reserveIds) {
        reserveIds = _s().debtReserveIds[spoke];
    }

    /// @inheritdoc IMarketRegistryRouteViews
    function isApprovedDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view override returns (bool approved) {
        approved = _s().debtReserves[spoke][reserveId].approved;
    }

    /// @inheritdoc IMarketRegistryRouteViews
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
    function hubTier(
        address hub
    ) external view override returns (RiskTier tier) {
        tier = _s().hubTier[hub];
    }

    /// @inheritdoc IMarketRegistryHubs
    function isRecordedHub(
        address account
    ) external view override returns (bool recorded) {
        recorded = _s().hubTier[account] != RiskTier.None;
    }

    /// @inheritdoc IMarketRegistryHubs
    function getHubs() external view override returns (address[] memory hubs) {
        hubs = _s().hubList;
    }

    /// @inheritdoc IMarketRegistryHubs
    function hubOf(
        address spoke
    ) external view override returns (address hub) {
        hub = _s().spokes[spoke].hub;
    }

    /// @inheritdoc IMarketRegistryHubs
    function integrationOf(
        uint32 integrationId
    ) external view override returns (address lpVault, address pricing) {
        lpVault = _s().integrationLpVault[integrationId];
        pricing = _s().integrationPricing[integrationId];
    }

    /// @inheritdoc IMarketRegistryHubs
    function integrationIdOf(
        address lpVault
    ) external view override returns (uint32 integrationId) {
        integrationId = _s().integrationIdOf[lpVault];
    }

    /// @inheritdoc IMarketRegistryHubs
    function firstLossReserveOf(
        address hub,
        address asset
    ) external view override returns (address firstLossReserve) {
        firstLossReserve = _s().firstLossReserveOf[hub][asset];
    }

    /// @inheritdoc IMarketRegistryHubs
    function crossHubLineCap(
        address fundingHub,
        address asset,
        address spoke
    ) external view override returns (uint256 cap) {
        cap = _s().crossHubLineCap[fundingHub][asset][spoke];
    }

    /// @inheritdoc IMarketRegistryHubs
    function crossHubLineTotal(
        address fundingHub,
        address asset
    ) external view override returns (uint256 total) {
        total = _s().crossHubLineTotal[fundingHub][asset];
    }

    /// @inheritdoc IMarketRegistryHubs
    function crossHubLinesEnabled() external view override returns (bool enabled) {
        enabled = _s().crossHubLinesEnabled;
    }

    /// @inheritdoc IMarketRegistryCreditLines
    function creditLine(
        address fundingHub,
        address asset
    ) external view override returns (uint256 line, uint256 drawCapSum) {
        CreditLine storage cl = _s().creditLines[fundingHub][asset];
        line = cl.line;
        drawCapSum = cl.drawCapSum;
    }

    /// @inheritdoc IMarketRegistryCreditLines
    function creditLineCoverage(
        address fundingHub,
        address asset
    ) external view override returns (uint256 required, uint256 funded) {
        (required, funded) = _coverage(fundingHub, asset, _s().creditLines[fundingHub][asset].line);
    }

    /// @inheritdoc IMarketRegistryApprovals
    function isApprovedSpokeCodeHash(
        bytes32 codeHash
    ) external view override returns (bool approved) {
        approved = _spokeHashApproved(codeHash);
    }

    /// @inheritdoc IMarketRegistryApprovals
    function spokeImplementationStatus(
        address spoke
    ) external view override returns (address implementation, bytes32 codeHash, bool current) {
        (implementation, codeHash, current) = _spokeImplementation(spoke);
    }

    /// @inheritdoc IMarketRegistryApprovals
    function integrationContracts(
        uint32 integrationId
    ) external view override returns (address[] memory contracts) {
        contracts = _s().integrationContracts[integrationId];
    }

    /// @inheritdoc IMarketRegistryPause
    function pauseState(
        address hub
    ) external view override returns (PauseState state) {
        state = _s().pauseState[hub];
    }

    /// @inheritdoc IMarketRegistryPause
    function pauseReason(
        address hub
    ) external view override returns (PauseReason reason) {
        reason = _s().pauseReason[hub];
    }

    /// @inheritdoc IMarketRegistryFreeze
    function isFrozenAddress(
        address account
    ) external view override returns (bool frozen) {
        frozen = _s().frozen[account];
    }

    /// @inheritdoc IMarketRegistryFreeze
    function freezesInWindow(
        address caller
    ) external view override returns (uint256 count) {
        // Block timestamps and chain identifiers fit 64 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        count = _freezesInWindow(caller, uint64(block.timestamp / 3600));
    }

    /// @inheritdoc IMarketRegistryFreeze
    function MAX_ADDRESS_FREEZES_PER_DAY() external pure override returns (uint256 limit) {
        limit = _MAX_FREEZES_PER_DAY;
    }

    /// @inheritdoc IMarketRegistryBreakers
    function marketBreaker(
        uint256 marketId
    ) external view override returns (uint32 latchedReasons, uint64 lastBreach) {
        bytes32 key = bytes32(marketId);
        latchedReasons = _s().latched[key];
        lastBreach = _s().lastBreachAt[key];
    }

    /// @inheritdoc IMarketRegistryBreakers
    function debtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (uint32 latchedReasons, uint64 lastBreach) {
        bytes32 key = _debtKey(spoke, debtReserveId);
        latchedReasons = _s().latched[key];
        lastBreach = _s().lastBreachAt[key];
    }

    /// @inheritdoc IMarketRegistryBreakers
    function lastBreachAt(
        bytes32 key
    ) external view override returns (uint64 at) {
        at = _s().lastBreachAt[key];
    }

    /// @inheritdoc IMarketRegistryBreakers
    function activeMarketCount(
        address spoke
    ) external view override returns (uint256 count) {
        uint256[] storage ids = _s().marketsOfSpoke[spoke];
        for (uint256 i = 0; i < ids.length; ++i) {
            if (_liquidatable(_s().markets[ids[i]].status)) ++count;
        }
    }

    /// @inheritdoc IMarketRegistryStandby
    function activePriceRoutes(
        address token
    ) external view override returns (address[] memory primary, address[] memory alternate, RouteSlot replaced) {
        TokenDef storage t = _s().tokens[token];
        replaced = t.replacedSlot;
        primary = replaced == RouteSlot.Primary ? t.standbyRoute : t.primaryRoute;
        alternate = replaced == RouteSlot.Alternate ? t.standbyRoute : t.alternateRoute;
    }

    /// @inheritdoc IMarketRegistryStandby
    function standbySwitchLockedUntil(
        address token
    ) external view override returns (uint256 until) {
        uint64 at = _s().standbyCancelledAt[token];
        until = at == 0 ? 0 : uint256(at) + _STANDBY_RESWITCH_COOLDOWN;
    }

    /// @inheritdoc IMarketRegistryStandby
    function priceRouteVersion(
        address token
    ) external view override returns (uint64 version) {
        version = _s().priceRouteVersion[token];
    }

    /// @inheritdoc IMarketRegistryWindDown
    function windDownState(
        uint256 marketId
    ) external view override returns (WindDownState memory state) {
        state = _s().windDown[marketId];
    }

    /// @inheritdoc IMarketRegistryWindDown
    function settlementReserve(
        uint256 marketId
    ) external view override returns (uint256 debtReserveId) {
        debtReserveId = _s().settlementReserve[marketId];
    }

    /// @inheritdoc IMarketRegistryHubs
    function spokeSettingsDrift(
        address spoke
    ) external view override returns (uint256 marketId, DriftReason reason) {
        (marketId, reason) = _spokeDrift(spoke);
    }
}
