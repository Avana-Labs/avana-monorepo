// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {Market} from "../../types/Market.sol";
import {MarketDef} from "../../types/MarketDef.sol";
import {PositionShape} from "../../types/PositionShape.sol";
import {RouteSlot} from "../../types/RouteSlot.sol";
import {IVaultTokenFactory} from "../../vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {IParameterStoreViews} from "../parameter-store/IParameterStoreViews.sol";
import {IRiskModuleChecks} from "../risk-module/IRiskModuleChecks.sol";
import {IRiskModuleViews} from "../risk-module/IRiskModuleViews.sol";
import {IMarketRegistryHubs} from "./IMarketRegistryHubs.sol";
import {IMarketRegistryLogic} from "./IMarketRegistryLogic.sol";
import {MarketRegistryMarketChecks} from "./MarketRegistryMarketChecks.sol";
import {MarketRegistryOracleChecks} from "./MarketRegistryOracleChecks.sol";
import {MarketRegistryRouteChecks} from "./MarketRegistryRouteChecks.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {MarketRegistryImmutables} from "./types/MarketRegistryImmutables.sol";
import {MarketStatus} from "./types/MarketStatus.sol";
import {SpokeDef} from "./types/SpokeDef.sol";
import {TokenDef} from "./types/TokenDef.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title MarketRegistryListingLogic
/// @notice Bodies of `listToken`, `setPriceSource` and `listCollateralMarket`. Normal delay.
/// @dev Runs only by delegatecall from the MarketRegistry, which checks `APPLICATION_ADMIN` first.
// Bodies of IMarketRegistry selectors; this contract inherits no interface piece.
// solhint-disable comprehensive-interface
// forge-lint: disable-start(reentrancy-events)
// setPriceSource re-checks every market using the token with view calls; bounded by the market count.
// forge-lint: disable-start(calls-loop)
contract MarketRegistryListingLogic is
    MarketRegistryMarketChecks,
    MarketRegistryOracleChecks,
    MarketRegistryRouteChecks,
    IMarketRegistryLogic
{
    constructor(
        MarketRegistryImmutables memory im
    ) MarketRegistryStorage(im) {}

    /// @inheritdoc IMarketRegistryLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("MarketRegistryListingLogic"), _IMMUTABLES_HASH);
    }

    function listToken(
        address token,
        TokenDef calldata def
    ) external {
        _onlyDelegated();
        TokenDef storage t = _s().tokens[token];
        if (token == address(0) || t.listed) revert ListingCheckFailed("listed");
        if (def.replacedSlot != RouteSlot.None) revert ListingCheckFailed("replacedSlot");
        // An ERC-777 token is never listed, so its hooks never run inside a custody, settlement or route call.
        if (_isErc777Token(token)) revert ListingCheckFailed("erc777");
        if (def.alternateRoute.length == 0 && def.standbyRoute.length == 0) {
            // Monitoring-only listing: one route; serves only a fixed-price debt reserve.
            bytes32 bad = _routeLegsCheck(def.primaryRoute);
            if (bad != 0) revert ListingCheckFailed(bad);
        } else {
            _checkThreeRoutes(def.primaryRoute, def.alternateRoute, def.standbyRoute);
        }
        uint8 dec = IERC20Metadata(token).decimals();
        t.listed = true;
        t.decimals = dec;
        t.isUsdStable = def.isUsdStable;
        t.primaryRoute = def.primaryRoute;
        t.alternateRoute = def.alternateRoute;
        t.standbyRoute = def.standbyRoute;
        t.replacedSlot = RouteSlot.None;
        t.issuerProbe = def.issuerProbe;
        t.pegModule = def.pegModule;
        emit TokenListed(token, dec, def.primaryRoute, def.alternateRoute, def.pegModule);
    }

    function setPriceSource(
        address token,
        address[] calldata primaryRoute,
        address[] calldata alternateRoute,
        address[] calldata standbyRoute
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        TokenDef storage t = l.tokens[token];
        if (!t.listed) revert TokenNotListed(token);
        _checkThreeRoutes(primaryRoute, alternateRoute, standbyRoute);
        t.primaryRoute = primaryRoute;
        t.alternateRoute = alternateRoute;
        t.standbyRoute = standbyRoute;
        t.replacedSlot = RouteSlot.None;
        delete l.standbyCancelledAt[token];
        ++l.priceRouteVersion[token];
        // The checks below read the routes from this registry, so they run after the write.
        IParameterStoreViews ps = IParameterStoreViews(_PARAMETER_STORE);
        if (ps.feedAgreementToleranceBps(token) < ps.feedAgreementToleranceMinBps(token)) {
            revert ListingCheckFailed("tolerance");
        }
        uint256 count = l.marketCount;
        bytes32 failed = 0;
        for (uint256 id = 1; id <= count && failed == 0; ++id) {
            Market storage m = l.markets[id];
            if (_keyFree(id) || !_holds(m.tokens, token)) continue;
            address[] memory marketTokens = m.tokens;
            failed = _checkMarketRoutes(id, marketTokens, m.lpOracle);
        }
        if (failed != 0) revert ListingCheckFailed(failed);
        emit PriceSourceSet(token, primaryRoute, alternateRoute, standbyRoute);
    }

    function listCollateralMarket(
        MarketDef calldata def
    ) external returns (uint256 marketId) {
        _onlyDelegated();
        (address lpVault, bytes32 key, bool relisting, uint256 id) = _preflight(def);
        marketId = id;
        address[] memory tokens = _bindAndCheck(def, lpVault, key, marketId, relisting);
        Layout storage l = _s();
        l.keyOf[marketId] = key;
        l.marketOfKey[key] = marketId;
        l.marketOfVaultToken[def.vaultToken] = marketId;
        l.marketOfLpOracle[def.lpOracle] = marketId;
        l.settlementReserve[marketId] = l.debtReserveIds[def.spoke][0];
        if (!relisting) {
            l.marketCount = marketId;
            l.marketsOfSpoke[def.spoke].push(marketId);
        } else {
            // A relisted market starts clean: a new route epoch hides old routes; breaker state is cleared.
            l.routeEpoch[marketId] += 1;
            delete l.latched[bytes32(marketId)];
            _clearBreachTimes(l, bytes32(marketId));
        }
        try IRiskModuleChecks(_RISK_MODULE).checkAaveConfig(def.spoke, new uint256[](0)) {}
        catch {
            revert ActivationCheckFailed(marketId, "aaveConfig");
        }
        emit MarketRegistered(
            marketId, def.integrationId, def.pool, def.poolId, tokens, def.vaultToken, def.lpOracle, def.spoke
        );
    }

    function _preflight(
        MarketDef calldata def
    ) private view returns (address lpVault, bytes32 key, bool relisting, uint256 marketId) {
        Layout storage l = _s();
        SpokeDef storage sp = l.spokes[def.spoke];
        if (!sp.approved || sp.hub != def.hub) revert InvalidSpoke(def.spoke);
        lpVault = l.integrationLpVault[def.integrationId];
        if (sp.integrationId != def.integrationId || lpVault == address(0)) {
            revert IMarketRegistryHubs.InvalidIntegration(def.integrationId);
        }
        _checkShape(lpVault, def);
        key = IVaultTokenFactory(_VAULT_TOKEN_FACTORY).marketKeyOf(def.integrationId, def.pool, def.poolId, def.shape);
        if (
            !_keyFree(l.marketOfKey[key]) || !_keyFree(l.marketOfVaultToken[def.vaultToken])
                || !_keyFree(l.marketOfLpOracle[def.lpOracle])
        ) revert DuplicateMarketKey();
        (marketId, relisting) = _resolveMarketId(def, key);
        // Bounds every walk over 1..marketCount; a relisting reuses an existing identifier.
        if (!relisting && marketId > _MAX_MARKET_COUNT) revert MarketCountLimit(_MAX_MARKET_COUNT);
        if (l.debtReserveIds[def.spoke].length == 0) revert ListingCheckFailed("settlementReserve");
    }

    function _bindAndCheck(
        MarketDef calldata def,
        address lpVault,
        bytes32 key,
        uint256 marketId,
        bool relisting
    ) private returns (address[] memory tokens) {
        uint8 unitDecimals;
        (tokens, unitDecimals) = _bind(lpVault, marketId, relisting, def);
        _checkVaultToken(def, key, marketId, lpVault, unitDecimals);
        uint8[] memory decs = _checkTokens(tokens, _s().spokes[def.spoke].riskTier, def.hub, unitDecimals);
        if (!_commonModeHolds(tokens)) revert ListingCheckFailed("commonMode");
        _checkRawPrice(tokens, decs);
        _checkLpOracleSeed(def.lpOracle, marketId, lpVault);
        _writeMarket(marketId, lpVault, tokens, decs, unitDecimals, def);
    }

    function _checkThreeRoutes(
        address[] calldata primary,
        address[] calldata alternate,
        address[] calldata standby
    ) private view {
        bytes32 bad = _routeLegsCheck(primary);
        if (bad == 0) bad = _routeLegsCheck(alternate);
        if (bad == 0) bad = _routeLegsCheck(standby);
        if (bad != 0) revert ListingCheckFailed(bad);
        if (_shareFeed(primary, alternate) || _shareFeed(primary, standby) || _shareFeed(alternate, standby)) {
            revert ListingCheckFailed("sharedFeed");
        }
    }

    function _bind(
        address lpVault,
        uint256 marketId,
        bool relisting,
        MarketDef calldata def
    ) private returns (address[] memory tokens, uint8 unitDecimals) {
        if (!relisting) {
            return IAmmIntegration(lpVault).bindMarket(marketId, def.pool, def.poolId, def.shape, def.integrationData);
        }
        PositionShape memory sh;
        address pool;
        bytes32 poolId;
        (pool, poolId, sh, tokens) = IAmmIntegration(lpVault).marketOf(marketId);
        if (
            pool != def.pool || poolId != def.poolId || sh.kind != def.shape.kind || sh.tickLower != def.shape.tickLower
                || sh.tickUpper != def.shape.tickUpper
        ) revert ListingCheckFailed("binding");
        unitDecimals = _s().markets[marketId].decimals;
    }

    function _writeMarket(
        uint256 marketId,
        address lpVault,
        address[] memory tokens,
        uint8[] memory decs,
        uint8 unitDecimals,
        MarketDef calldata def
    ) private {
        Market storage m = _s().markets[marketId];
        // Block timestamps and chain identifiers fit 64 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        m.chainId = uint64(block.chainid);
        m.hub = def.hub;
        m.spoke = def.spoke;
        m.integrationId = def.integrationId;
        m.integration = lpVault;
        m.pool = def.pool;
        m.poolId = def.poolId;
        m.shape = def.shape;
        m.tokens = tokens;
        m.tokenDecimals = decs;
        m.vaultToken = def.vaultToken;
        m.decimals = unitDecimals;
        m.lpOracle = def.lpOracle;
        m.hubAssetId = 0;
        m.reserveId = 0;
        m.status = MarketStatus.Registered;
        // Block timestamps and chain identifiers fit 64 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        m.registeredAt = uint64(block.timestamp);
        m.activatedAt = 0;
    }

    /// @dev Returns the first failed check's name, or 0.
    function _checkMarketRoutes(
        uint256 marketId,
        address[] memory tokens,
        address lpOracle
    ) private view returns (bytes32 failed) {
        if (!_commonModeHolds(tokens)) return "commonMode";
        uint256 cfLp = IRiskModuleViews(_RISK_MODULE).expectedCollateralFactorBps(marketId);
        if (!_listingMarginHolds(cfLp, tokens)) return "listingMargin";
        if (!_oracleConfigPasses(lpOracle)) return "oracleConfig";
    }

    function _holds(
        address[] storage list,
        address token
    ) private view returns (bool) {
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == token) return true;
        }
        return false;
    }
}
// forge-lint: disable-end(calls-loop)
