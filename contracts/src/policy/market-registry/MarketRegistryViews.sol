// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason, Market, PauseReason, PauseState} from "../../types/MarketTypes.sol";
import {IMarketRegistry} from "./IMarketRegistry.sol";
import {IMarketRegistryDriftLogic} from "./IMarketRegistryDriftLogic.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {DebtReserveDef, RiskTier, SpokeDef, TokenDef, WindDownState} from "./types/MarketRegistryTypes.sol";

/// @title MarketRegistryViews
/// @notice Every view of the MarketRegistry, served from its own storage.
/// @dev Views never revert; an unknown key returns zeros and `false`.
abstract contract MarketRegistryViews is MarketRegistryStorage, IMarketRegistry {
    /// @dev First drift of a recorded Spoke (implementation, then each liquidatable market); `(0, None)` if none.
    function _spokeDrift(
        address spoke
    ) internal view returns (uint256 marketId, DriftReason reason) {
        SpokeDef storage sp = _s().spokes[spoke];
        if (!sp.approved) return (0, DriftReason.None);
        (,, bool current) = _spokeImplementation(spoke);
        if (!current) return (0, DriftReason.SpokeImplementation);
        uint256[] storage ids = _s().marketsOfSpoke[spoke];
        for (uint256 i = 0; i < ids.length; ++i) {
            Market storage m = _s().markets[ids[i]];
            if (!_liquidatable(m.status)) continue;
            // Per-market reads run in the activation logic (code size limit).
            // forge-lint: disable-start(calls-loop)
            reason = IMarketRegistryDriftLogic(_driftLogic())
                .marketDrift(spoke, sp.hub, m.vaultToken, m.reserveId, m.hubAssetId);
            // forge-lint: disable-end(calls-loop)
            if (reason != DriftReason.None) return (ids[i], reason);
        }
        return (0, DriftReason.None);
    }

    /// @dev The logic contract that serves `marketDrift` (the activation logic).
    function _driftLogic() internal view virtual returns (address);

    /// @inheritdoc IMarketRegistry
    function getMarket(
        uint256 marketId
    ) external view override returns (Market memory market) {
        market = _s().markets[marketId];
    }

    /// @inheritdoc IMarketRegistry
    function getToken(
        address token
    ) external view override returns (TokenDef memory def) {
        def = _s().tokens[token];
    }

    /// @inheritdoc IMarketRegistry
    function getSpoke(
        address spoke
    ) external view override returns (SpokeDef memory def) {
        def = _s().spokes[spoke];
    }

    /// @inheritdoc IMarketRegistry
    function getSpokes() external view override returns (address[] memory spokes) {
        spokes = _s().spokeList;
    }

    /// @inheritdoc IMarketRegistry
    function marketsOfSpoke(
        address spoke
    ) external view override returns (uint256[] memory marketIds) {
        marketIds = _s().marketsOfSpoke[spoke];
    }

    /// @inheritdoc IMarketRegistry
    function marketOfKey(
        bytes32 key
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfKey[key];
    }

    /// @inheritdoc IMarketRegistry
    function marketOfVaultToken(
        address vaultToken
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfVaultToken[vaultToken];
    }

    /// @inheritdoc IMarketRegistry
    function marketOfLpOracle(
        address lpOracle
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfLpOracle[lpOracle];
    }

    /// @inheritdoc IMarketRegistry
    function marketOfReserve(
        address spoke,
        uint256 reserveId
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfReserve[spoke][reserveId];
    }

    /// @inheritdoc IMarketRegistry
    function marketOfHubAsset(
        address hub,
        uint256 hubAssetId
    ) external view override returns (uint256 marketId) {
        marketId = _s().marketOfHubAsset[hub][hubAssetId];
    }

    /// @inheritdoc IMarketRegistry
    function marketCount() external view override returns (uint256 count) {
        count = _s().marketCount;
    }

    /// @inheritdoc IMarketRegistry
    function getDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view override returns (DebtReserveDef memory def) {
        def = _s().debtReserves[spoke][reserveId];
    }

    /// @inheritdoc IMarketRegistry
    function getDebtReserveIds(
        address spoke
    ) external view override returns (uint256[] memory reserveIds) {
        reserveIds = _s().debtReserveIds[spoke];
    }

    /// @inheritdoc IMarketRegistry
    function isApprovedDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view override returns (bool approved) {
        approved = _s().debtReserves[spoke][reserveId].approved;
    }

    /// @inheritdoc IMarketRegistry
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

    /// @inheritdoc IMarketRegistry
    function hubTier(
        address hub
    ) external view override returns (RiskTier tier) {
        tier = _s().hubTier[hub];
    }

    /// @inheritdoc IMarketRegistry
    function isRecordedHub(
        address account
    ) external view override returns (bool recorded) {
        recorded = _s().hubTier[account] != RiskTier.None;
    }

    /// @inheritdoc IMarketRegistry
    function getHubs() external view override returns (address[] memory hubs) {
        hubs = _s().hubList;
    }

    /// @inheritdoc IMarketRegistry
    function hubOf(
        address spoke
    ) external view override returns (address hub) {
        hub = _s().spokes[spoke].hub;
    }

    /// @inheritdoc IMarketRegistry
    function integrationOf(
        uint32 integrationId
    ) external view override returns (address lpVault, address pricing) {
        lpVault = _s().integrationLpVault[integrationId];
        pricing = _s().integrationPricing[integrationId];
    }

    /// @inheritdoc IMarketRegistry
    function integrationIdOf(
        address lpVault
    ) external view override returns (uint32 integrationId) {
        integrationId = _s().integrationIdOf[lpVault];
    }

    /// @inheritdoc IMarketRegistry
    function firstLossReserveOf(
        address hub,
        address asset
    ) external view override returns (address firstLossReserve) {
        firstLossReserve = _s().firstLossReserveOf[hub][asset];
    }

    /// @inheritdoc IMarketRegistry
    function drawCapCoverage(
        address hub,
        address asset
    ) external view override returns (uint256 drawCapSum, uint256 required, uint256 funded) {
        (drawCapSum, required, funded) = _coverage(hub, asset);
    }

    /// @inheritdoc IMarketRegistry
    function isApprovedSpokeCodeHash(
        bytes32 codeHash
    ) external view override returns (bool approved) {
        approved = _spokeHashApproved(codeHash);
    }

    /// @inheritdoc IMarketRegistry
    function spokeImplementationStatus(
        address spoke
    ) external view override returns (address implementation, bytes32 codeHash, bool current) {
        (implementation, codeHash, current) = _spokeImplementation(spoke);
    }

    /// @inheritdoc IMarketRegistry
    function integrationContracts(
        uint32 integrationId
    ) external view override returns (address[] memory contracts) {
        contracts = _s().integrationContracts[integrationId];
    }

    /// @inheritdoc IMarketRegistry
    function pauseState(
        address hub
    ) external view override returns (PauseState state) {
        state = _s().pauseState[hub];
    }

    /// @inheritdoc IMarketRegistry
    function pauseReason(
        address hub
    ) external view override returns (PauseReason reason) {
        reason = _s().pauseReason[hub];
    }

    /// @inheritdoc IMarketRegistry
    function isFrozenAddress(
        address account
    ) external view override returns (bool frozen) {
        frozen = _s().frozen[account];
    }

    /// @inheritdoc IMarketRegistry
    function freezesInWindow(
        address caller
    ) external view override returns (uint256 count) {
        // Block timestamps and chain identifiers fit 64 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        count = _freezesInWindow(caller, uint64(block.timestamp / 3600));
    }

    /// @inheritdoc IMarketRegistry
    function MAX_ADDRESS_FREEZES_PER_DAY() external pure override returns (uint256 limit) {
        limit = _MAX_FREEZES_PER_DAY;
    }

    /// @inheritdoc IMarketRegistry
    function marketBreaker(
        uint256 marketId
    ) external view override returns (uint32 latchedReasons, uint64 lastBreach) {
        bytes32 key = bytes32(marketId);
        latchedReasons = _s().latched[key];
        lastBreach = _s().lastBreachAt[key];
    }

    /// @inheritdoc IMarketRegistry
    function debtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (uint32 latchedReasons, uint64 lastBreach) {
        bytes32 key = _debtKey(spoke, debtReserveId);
        latchedReasons = _s().latched[key];
        lastBreach = _s().lastBreachAt[key];
    }

    /// @inheritdoc IMarketRegistry
    function lastBreachAt(
        bytes32 key
    ) external view override returns (uint64 at) {
        at = _s().lastBreachAt[key];
    }

    /// @inheritdoc IMarketRegistry
    function activeMarketCount(
        address spoke
    ) external view override returns (uint256 count) {
        uint256[] storage ids = _s().marketsOfSpoke[spoke];
        for (uint256 i = 0; i < ids.length; ++i) {
            if (_liquidatable(_s().markets[ids[i]].status)) ++count;
        }
    }

    /// @inheritdoc IMarketRegistry
    function windDownState(
        uint256 marketId
    ) external view override returns (WindDownState memory state) {
        state = _s().windDown[marketId];
    }

    /// @inheritdoc IMarketRegistry
    function settlementReserve(
        uint256 marketId
    ) external view override returns (uint256 debtReserveId) {
        debtReserveId = _s().settlementReserve[marketId];
    }

    /// @inheritdoc IMarketRegistry
    function spokeSettingsDrift(
        address spoke
    ) external view override returns (uint256 marketId, DriftReason reason) {
        (marketId, reason) = _spokeDrift(spoke);
    }
}
