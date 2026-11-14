// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {IntegrationCapabilities} from "../../amm/types/IntegrationCapabilities.sol";
import {PoolKeying} from "../../amm/types/PoolKeying.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAggregatorV3} from "../../interfaces/external/chainlink/IAggregatorV3.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {AmmConstants} from "../../types/AmmConstants.sol";
import {MarketDef} from "../../types/MarketDef.sol";
import {PositionShape} from "../../types/PositionShape.sol";
import {ShapeKind} from "../../types/ShapeKind.sol";
import {IVaultTokenFactory} from "../../vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {IVaultToken} from "../../vault-token/vault-token/IVaultToken.sol";
import {IParameterStoreViews} from "../parameter-store/IParameterStoreViews.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {MarketStatus} from "./types/MarketStatus.sol";
import {RiskTier} from "./types/RiskTier.sol";
import {TokenDef} from "./types/TokenDef.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MarketRegistryMarketChecks
/// @notice The registration checks of `listCollateralMarket` (REQ-CONFIG-029 to REQ-CONFIG-037, REQ-MREG-030) that
/// do not need the market's own storage record.
/// @dev Every call made here is a view.
/// @custom:spec REQ-CONFIG-021, REQ-CONFIG-029, REQ-CONFIG-030, REQ-CONFIG-031, REQ-CONFIG-032, REQ-CONFIG-033, REQ-CONFIG-035, REQ-CONFIG-037, REQ-MREG-030
// Chainlink and ParameterStore views over a primary route's one or two legs.
// forge-lint: disable-start(calls-loop)
abstract contract MarketRegistryMarketChecks is MarketRegistryStorage {
    /// @dev Pool keying and canonical shape: exactly the key the integration's `poolKeying` requires, the
    /// integration's shape kind, both ticks 0 for a full pool and `tickLower < tickUpper` for a tick range (the
    /// integration's `bindMarket` checks tick spacing and the usable range).
    function _checkShape(
        address lpVault,
        MarketDef calldata def
    ) internal view {
        IntegrationCapabilities memory caps = IAmmIntegration(lpVault).capabilities();
        bool byAddress = caps.poolKeying == PoolKeying.Address;
        if (byAddress ? (def.pool == address(0) || def.poolId != 0) : (def.pool != address(0) || def.poolId == 0)) {
            revert ListingCheckFailed("pool");
        }
        PositionShape calldata sh = def.shape;
        if (sh.kind == ShapeKind.None || sh.kind != caps.shapeKind) revert ListingCheckFailed("shape");
        if (sh.kind == ShapeKind.FullPool ? (sh.tickLower != 0 || sh.tickUpper != 0) : sh.tickLower >= sh.tickUpper) {
            revert ListingCheckFailed("shape");
        }
    }

    /// @dev REQ-MREG-030: the factory's token of (Spoke, market key) must be `def.vaultToken`; its `marketId()` is the
    /// next identifier for a new listing, or the reserved identifier of the same pair's Cancelled market.
    function _resolveMarketId(
        MarketDef calldata def,
        bytes32 key
    ) internal view returns (uint256 marketId, bool relisting) {
        Layout storage l = _s();
        if (
            def.vaultToken == address(0)
                || IVaultTokenFactory(_VAULT_TOKEN_FACTORY).tokenOf(def.spoke, key) != def.vaultToken
        ) {
            revert VaultTokenMismatch();
        }
        marketId = IVaultToken(def.vaultToken).marketId();
        if (marketId == l.marketCount + 1) return (marketId, false);
        if (
            marketId == 0 || marketId > l.marketCount || l.markets[marketId].status != MarketStatus.Cancelled
                || l.keyOf[marketId] != key || l.markets[marketId].spoke != def.spoke
        ) revert VaultTokenMismatch();
        relisting = true;
    }

    /// @dev REQ-CONFIG-032: the token's market key, integration, Hub, Spoke, market ID, LPOracle and decimals match
    /// the market, and its AaveAdapter, Collateralization and LPVaultSwap are this chain's.
    function _checkVaultToken(
        MarketDef calldata def,
        bytes32 key,
        uint256 marketId,
        address lpVault,
        uint8 unitDecimals
    ) internal view {
        IVaultToken t = IVaultToken(def.vaultToken);
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

    /// @dev REQ-CONFIG-017, REQ-CONFIG-018, REQ-CONFIG-021, REQ-CONFIG-031, REQ-CONFIG-033: between 2 and 8 pool tokens,
    /// each listed with its three price routes (a monitoring-only listing, which has no alternate route, is refused
    /// with `ListingCheckFailed("routeLength")`), each a USD stablecoin on a Stable-tier Spoke, and the vault-token
    /// decimals inside the home Hub's range.
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

    /// @dev REQ-CONFIG-035 for a two-token pool: with `a0`, `a1` the 8-decimal answers of each token's primary
    /// route, `10^4 × a0 × 10^d1 < 2^128 × a1 × 10^d0`, so the TWAP reference price stays below `2^128`, the ratio up
    /// to which `SPEC-ORC-009` computes the sqrt price without clamping, under a 100× shock. The former `2^64` bound
    /// (the lower branch only) refused WBTC against an 18-decimal stable once BTC reached about $184,467 (INTEG-04);
    /// at `2^128` that pair lists up to the `MAX_ROUTE_ANSWER` price. Answers are bounded below `2^96`, so the left
    /// side and `2^128 × a1` fit in 256 bits.
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

    /// @dev REQ-CONFIG-037: the LPOracle reports 8 decimals, a seeded answer above 0, this market and its integration.
    function _checkLpOracleSeed(
        address lpOracle,
        uint256 marketId,
        address lpVault
    ) internal view {
        ILPOracle o = ILPOracle(lpOracle);
        if (lpOracle == address(0) || o.decimals() != _ORACLE_DECIMALS || o.latestAnswer() <= 0) {
            revert ListingCheckFailed("lpOracle");
        }
        if (o.marketId() != marketId || o.integration() != lpVault) revert ListingCheckFailed("lpOracle");
    }

    /// @dev 8-decimal USD answer of a token's primary route, `a = 10^8 × Π answer_i / 10^dec_i` with each leg applied
    /// by `mulDiv` (floor); 0 when a leg's answer is not positive, a leg or the result is not below `2^96`, or a
    /// leg has more than 36 decimals.
    function _primaryAnswer8(
        address token
    ) internal view returns (uint256 a) {
        address[] storage route = _s().tokens[token].primaryRoute;
        a = 1e8;
        for (uint256 i = 0; i < route.length; ++i) {
            // Only the answer is used: the raw-price bound is a listing-time magnitude check, not a price read.
            // forge-lint: disable-next-line(unused-return)
            (, int256 answer,,,) = IAggregatorV3(route[i]).latestRoundData();
            uint8 dec = IParameterStoreViews(_PARAMETER_STORE).getFeed(route[i]).decimals;
            if (answer <= 0 || answer >= 2 ** 96 || dec > 36) return 0;
            // `0 < answer < 2^96`, so the conversion is exact.
            // forge-lint: disable-next-line(unsafe-typecast)
            a = Math.mulDiv(a, uint256(answer), 10 ** uint256(dec));
        }
        if (a >= 2 ** 96) a = 0;
    }
}
// forge-lint: disable-end(calls-loop)
