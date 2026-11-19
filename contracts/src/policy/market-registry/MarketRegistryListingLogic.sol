// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title MarketRegistryListingLogic
/// @notice Bodies of `listToken`, `setPriceSource` and `listCollateralMarket`. Normal delay.
/// @dev Runs only by delegatecall from the MarketRegistry, which checks the caller with the AccessManager first.
// Bodies of IMarketRegistry selectors; this contract inherits no interface piece.
// solhint-disable comprehensive-interface
// forge-lint: disable-start(reentrancy-events)
// setPriceSource re-checks every market using the token with view calls; bounded by the market count.
// forge-lint: disable-start(calls-loop)

import {IntegrationCapabilities, PoolKeying} from "../../amm/types/AmmTypes.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAggregatorV3} from "../../interfaces/external/chainlink/IAggregatorV3.sol";
import {ILegacyLPOracle} from "../../legacy/ILegacyLPOracle.sol";
import {ILegacyLPVault} from "../../legacy/ILegacyLPVault.sol";
import {ILegacyVaultToken} from "../../legacy/ILegacyVaultToken.sol";
import {ILegacyVaultTokenFactory} from "../../legacy/ILegacyVaultTokenFactory.sol";
import {ILegacyRiskModule} from "../../legacy/risk-module/ILegacyRiskModule.sol";
import {AmmConstants} from "../../types/AmmConstants.sol";
import {Market, MarketDef} from "../../types/MarketTypes.sol";
import {PositionShape, ShapeKind} from "../../types/PositionTypes.sol";
import {IParameterStore} from "../parameter-store/IParameterStore.sol";
import {IMarketRegistry} from "./IMarketRegistry.sol";
import {IMarketRegistryLogic} from "./IMarketRegistryLogic.sol";
import {MarketRegistryRouteChecks} from "./MarketRegistryRouteChecks.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {MarketRegistryImmutables, MarketStatus, RiskTier, SpokeDef, TokenDef} from "./types/MarketRegistryTypes.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MarketRegistryListingLogic is MarketRegistryRouteChecks, IMarketRegistryLogic {
    function _checkShape(
        address lpVault,
        MarketDef calldata def
    ) internal view {
        IntegrationCapabilities memory caps = ILegacyLPVault(lpVault).capabilities();
        bool byAddress = caps.poolKeying == PoolKeying.Address;
        if (byAddress ? (def.pool == address(0) || def.poolId != 0) : (def.pool != address(0) || def.poolId == 0)) {
            revert ListingCheckFailed("pool");
        }
        PositionShape calldata sh = def.shape;
        if (sh.kind == ShapeKind.None || sh.kind != caps.shapeKind) revert ListingCheckFailed("shape");
        if (sh.kind == ShapeKind.FullPool ? (sh.tickLower != 0 || sh.tickUpper != 0) : sh.tickLower >= sh.tickUpper) {
            revert ListingCheckFailed("shape");
        }
        uint256 records = ILegacyLPVault(lpVault).maxRecordsPerAccountMarket();
        if (records == 0 || records > AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET) {
            revert ListingCheckFailed("records");
        }
    }

    function _resolveMarketId(
        MarketDef calldata def,
        bytes32 key
    ) internal view returns (uint256 marketId, bool relisting) {
        Layout storage l = _s();
        if (
            def.vaultToken == address(0)
                || ILegacyVaultTokenFactory(_VAULT_TOKEN_FACTORY).tokenOf(def.spoke, key) != def.vaultToken
        ) {
            revert VaultTokenMismatch();
        }
        marketId = ILegacyVaultToken(def.vaultToken).marketId();
        if (marketId == l.marketCount + 1) return (marketId, false);
        if (
            marketId == 0 || marketId > l.marketCount || l.markets[marketId].status != MarketStatus.Cancelled
                || l.keyOf[marketId] != key || l.markets[marketId].spoke != def.spoke
        ) revert VaultTokenMismatch();
        relisting = true;
    }

    function _checkVaultToken(
        MarketDef calldata def,
        bytes32 key,
        uint256 marketId,
        address lpVault,
        uint8 unitDecimals
    ) internal view {
        ILegacyVaultToken t = ILegacyVaultToken(def.vaultToken);
        if (
            t.marketKey() != key || t.integrationId() != def.integrationId || t.integration() != lpVault
                || t.hub() != def.hub || t.spoke() != def.spoke || t.marketId() != marketId
                || t.lpOracle() != def.lpOracle
        ) revert VaultTokenMismatch();
        if (
            t.decimals() != unitDecimals || t.adapter() != _AAVE_ADAPTER || t.collateralization() != _COLLATERALIZATION
                || t.lpVaultSwap() != _LP_VAULT_SWAP
        ) revert VaultTokenMismatch();
    }

    function _checkTokens(
        address[] memory tokens,
        RiskTier tier,
        address hub,
        uint8 unitDecimals
    ) internal view returns (uint8[] memory decs) {
        uint256 n = tokens.length;
        if (n < AmmConstants.MIN_POOL_TOKENS || n > AmmConstants.MAX_POOL_TOKENS) revert ListingCheckFailed("tokens");
        decs = new uint8[](n);
        address unlisted = address(0);
        bool classOk = true;
        bool routesOk = true;
        for (uint256 i = 0; i < n; ++i) {
            TokenDef storage t = _s().tokens[tokens[i]];
            if (!t.listed && unlisted == address(0)) unlisted = tokens[i];
            if (tier == RiskTier.Stable && !t.isUsdStable) classOk = false;
            if (t.alternateRoute.length == 0) routesOk = false;
            decs[i] = t.decimals;
        }
        if (unlisted != address(0)) revert TokenNotListed(unlisted);
        if (!routesOk) revert ListingCheckFailed("routeLength");
        if (!classOk) revert ListingCheckFailed("tokenClass");
        IAaveV4Hub h = IAaveV4Hub(hub);
        if (unitDecimals < h.MIN_ALLOWED_UNDERLYING_DECIMALS() || unitDecimals > h.MAX_ALLOWED_UNDERLYING_DECIMALS()) {
            revert ListingCheckFailed("decimals");
        }
    }

    /// @dev For a two-token pool, the raw price ratio stays below `2^128` under a 100x shock.
    function _checkRawPrice(
        address[] memory tokens,
        uint8[] memory decs
    ) internal view {
        if (tokens.length != 2) return;
        uint256 a0 = _primaryAnswer8(tokens[0]);
        uint256 a1 = _primaryAnswer8(tokens[1]);
        if (a0 == 0 || a1 == 0 || decs[0] > 36 || decs[1] > 36) revert ListingCheckFailed("rawPrice");
        uint256 lhs = 1e4 * a0 * 10 ** uint256(decs[1]);
        uint256 rhs = (uint256(1) << 128) * a1;
        // rhs × 10^d0 can exceed 2^256 only when the bound already holds by a wide margin.
        if (rhs <= type(uint256).max / 10 ** uint256(decs[0]) && lhs >= rhs * 10 ** uint256(decs[0])) {
            revert ListingCheckFailed("rawPrice");
        }
    }

    function _checkLpOracleSeed(
        address lpOracle,
        uint256 marketId,
        address lpVault
    ) internal view {
        ILegacyLPOracle o = ILegacyLPOracle(lpOracle);
        if (lpOracle == address(0) || o.decimals() != _ORACLE_DECIMALS || o.latestAnswer() <= 0) {
            revert ListingCheckFailed("lpOracle");
        }
        if (o.marketId() != marketId || o.integration() != lpVault) revert ListingCheckFailed("lpOracle");
    }

    /// @dev 8-decimal USD answer of a token's primary route, rounded down; 0 when a leg or the result is out of range.
    function _primaryAnswer8(
        address token
    ) internal view returns (uint256 a) {
        address[] storage route = _s().tokens[token].primaryRoute;
        a = 1e8;
        for (uint256 i = 0; i < route.length; ++i) {
            // Only the answer is used: this is a listing-time magnitude check.
            // forge-lint: disable-next-line(unused-return)
            (, int256 answer,,,) = IAggregatorV3(route[i]).latestRoundData();
            uint8 dec = IParameterStore(_PARAMETER_STORE).getFeed(route[i]).decimals;
            if (answer <= 0 || answer >= 2 ** 96 || dec > 36) return 0;
            // `0 < answer < 2^96`, so the conversion is exact.
            // forge-lint: disable-next-line(unsafe-typecast)
            a = Math.mulDiv(a, uint256(answer), 10 ** uint256(dec));
        }
        if (a >= 2 ** 96) a = 0;
    }

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
        // An ERC-777 token is never listed, so its hooks never run inside a custody, settlement or route call.
        if (_isErc777Token(token)) revert ListingCheckFailed("erc777");
        if (def.alternateRoute.length == 0) {
            // Monitoring-only listing: one route; serves only a fixed-price debt reserve.
            bytes32 bad = _routeLegsCheck(def.primaryRoute);
            if (bad != 0) revert ListingCheckFailed(bad);
        } else {
            _checkTwoRoutes(def.primaryRoute, def.alternateRoute);
        }
        uint8 dec = IERC20Metadata(token).decimals();
        t.listed = true;
        t.decimals = dec;
        t.isUsdStable = def.isUsdStable;
        t.primaryRoute = def.primaryRoute;
        t.alternateRoute = def.alternateRoute;
        t.issuerProbe = def.issuerProbe;
        t.pegModule = def.pegModule;
        emit TokenListed(token, dec, def.primaryRoute, def.alternateRoute, def.pegModule);
    }

    function setPriceSource(
        address token,
        address[] calldata primaryRoute,
        address[] calldata alternateRoute
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        TokenDef storage t = l.tokens[token];
        if (!t.listed) revert TokenNotListed(token);
        _checkTwoRoutes(primaryRoute, alternateRoute);
        t.primaryRoute = primaryRoute;
        t.alternateRoute = alternateRoute;
        // The checks below read the routes from this registry, so they run after the write.
        uint256 count = l.marketCount;
        bytes32 failed = 0;
        for (uint256 id = 1; id <= count && failed == 0; ++id) {
            Market storage m = l.markets[id];
            if (_keyFree(id) || !_holds(m.tokens, token)) continue;
            address[] memory marketTokens = m.tokens;
            failed = _checkMarketRoutes(id, marketTokens, m.lpOracle);
        }
        if (failed != 0) revert ListingCheckFailed(failed);
        emit PriceSourceSet(token, primaryRoute, alternateRoute);
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
            // A relisted market starts clean: a new route epoch hides old routes.
            l.routeEpoch[marketId] += 1;
        }
        try ILegacyRiskModule(_RISK_MODULE).checkAaveConfig(def.spoke, new uint256[](0)) {}
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
        lpVault = ILegacyVaultTokenFactory(_VAULT_TOKEN_FACTORY).lpVaultOf(def.integrationId);
        if (sp.integrationId != def.integrationId || lpVault == address(0)) {
            revert IMarketRegistry.InvalidIntegration(def.integrationId);
        }
        _checkShape(lpVault, def);
        key = ILegacyVaultTokenFactory(_VAULT_TOKEN_FACTORY)
            .marketKeyOf(def.integrationId, def.pool, def.poolId, def.shape);
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

    function _checkTwoRoutes(
        address[] calldata primary,
        address[] calldata alternate
    ) private view {
        bytes32 bad = _routeLegsCheck(primary);
        if (bad == 0) bad = _routeLegsCheck(alternate);
        if (bad != 0) revert ListingCheckFailed(bad);
        if (_shareFeed(primary, alternate)) revert ListingCheckFailed("sharedFeed");
    }

    function _bind(
        address lpVault,
        uint256 marketId,
        bool relisting,
        MarketDef calldata def
    ) private returns (address[] memory tokens, uint8 unitDecimals) {
        if (!relisting) {
            return ILegacyLPVault(lpVault).bindMarket(marketId, def.pool, def.poolId, def.shape, def.integrationData);
        }
        PositionShape memory sh;
        address pool;
        bytes32 poolId;
        (pool, poolId, sh, tokens) = ILegacyLPVault(lpVault).marketOf(marketId);
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
        uint256 cfLp = ILegacyRiskModule(_RISK_MODULE).expectedCollateralFactorBps(marketId);
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
