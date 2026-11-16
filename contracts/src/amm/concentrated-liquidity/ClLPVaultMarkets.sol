// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPPriceMath} from "../../oracle/lp-oracle/LPPriceMath.sol";
import {IAmmIntegration} from "../IAmmIntegration.sol";
import {IAmmIntegrationHooks} from "../IAmmIntegrationHooks.sol";
import {IClIntegration} from "../IClIntegration.sol";
import {ClMarketConfig} from "../types/ClMarketConfig.sol";
import {ClLPVaultBase} from "./ClLPVaultBase.sol";
import {ClPriceMath} from "./ClPriceMath.sol";
import {ClUnitMath} from "./ClUnitMath.sol";
import {IClPoolObservations} from "./IClPoolObservations.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title ClLPVaultMarkets
/// @notice Market storage at binding, composition at the clamped oracle price and the AMM-neutral views and hooks of a
/// concentrated-liquidity LPVault. Binding, risk metadata, depth, the read guard and the consistency read name the
/// AMM protocol's pool layout and live in the integration layer (`ClNfpmLPVault`, `UniswapV4Integration`).
/// @dev Every function here is a view that never reverts on the Lock. `composition` reads no pool state: only the
/// stored range, the token decimals, `units` and the price vector.
/// @custom:spec REQ-AMM-CORE-003, REQ-AMM-CORE-004, REQ-AMM-CORE-012, REQ-AMM-CORE-013, REQ-AMM-CORE-017, REQ-VAULT-166, REQ-AMM-V3-002, REQ-AMM-V3-005, REQ-AMM-V3-006, REQ-AMM-V3-008, SPEC-AMM-CORE-001, SPEC-AMM-V3-001, SPEC-BACK-001
abstract contract ClLPVaultMarkets is ClLPVaultBase {
    // ─── Binding ───

    /// @inheritdoc IClIntegration
    /// @custom:spec SPEC-UNIT-002, SPEC-ORC-005
    function unitExponent(
        uint256 marketId
    ) external view override returns (uint8) {
        return _market(marketId).unitExp;
    }

    /// @inheritdoc IClIntegration
    /// @custom:spec REQ-AMM-V3-002, REQ-AMM-SLIP-002
    function clMarket(
        uint256 marketId
    ) external view override returns (ClMarketConfig memory) {
        return _market(marketId).cfg;
    }

    /// @inheritdoc IClIntegration
    /// @custom:spec REQ-AMM-V3-001, REQ-AMM-SLIP-001, SPEC-AMM-CORE-002
    function tokenIdOf(
        bytes32 positionKey
    ) external pure override returns (uint256) {
        return _tokenId(positionKey);
    }

    // ─── Composition ───

    /// @inheritdoc IAmmIntegration
    /// @dev `SPEC-AMM-V3-001`: the amounts of `SPEC-ORC-006` of `units * 10^k` liquidity at the oracle square-root
    /// price clamped to the range, each then reduced by 1 raw unit when positive. Always exact.
    /// @custom:spec REQ-AMM-CORE-006, REQ-AMM-CORE-012, REQ-AMM-V3-005, SPEC-AMM-CORE-001, SPEC-AMM-V3-001, SPEC-ORC-006, SPEC-ORC-007
    function composition(
        uint256 marketId,
        uint256 units,
        uint256[] calldata prices
    ) external view override returns (uint256[] memory amounts, bool exact) {
        Market storage m = _market(marketId);
        (uint256 a0, uint256 a1) = _oracleAmounts(m, _toLiquidity(m, units), prices);
        amounts = _pair(a0 == 0 ? 0 : a0 - 1, a1 == 0 ? 0 : a1 - 1);
        exact = true;
    }

    /// @dev Raw amounts `liquidity` holds on the market's range at the oracle square-root price of `prices`.
    function _oracleAmounts(
        Market storage m,
        uint256 liquidity,
        uint256[] calldata prices
    ) private view returns (uint256 a0, uint256 a1) {
        (uint256 p0, uint256 p1) = _prices(prices);
        uint160 sO = ClPriceMath.oracleSqrtPrice(p0, p1, m.decimals0, m.decimals1);
        (a0, a1) = _rawAmounts(m.cfg.tickLower, m.cfg.tickUpper, sO, liquidity);
    }

    /// @inheritdoc IClIntegration
    /// @dev `clamped` is true when `SPEC-ORC-009` moved the price to a bound or the range clamp changed it.
    /// @custom:spec REQ-AMM-V3-005, SPEC-ORC-009, SPEC-ORC-006, REQ-ORACLE-104
    function oracleSqrtPrice(
        uint256 marketId,
        uint256[] calldata prices
    ) external view override returns (uint160 sqrtOracleX96, uint160 sqrtUsedX96, bool clamped) {
        Market storage m = _market(marketId);
        (uint256 p0, uint256 p1) = _prices(prices);
        sqrtOracleX96 = ClPriceMath.oracleSqrtPrice(p0, p1, m.decimals0, m.decimals1);
        sqrtUsedX96 = ClPriceMath.clamp(
            sqrtOracleX96, ClPriceMath.sqrtRatioAtTick(m.cfg.tickLower), ClPriceMath.sqrtRatioAtTick(m.cfg.tickUpper)
        );
        clamped = sqrtUsedX96 != sqrtOracleX96 || ClPriceMath.oracleSqrtClamped(p0, p1, m.decimals0, m.decimals1);
    }

    /// @inheritdoc IAmmIntegrationHooks
    /// @custom:spec REQ-AMM-CORE-010
    function rateProviders(
        uint256 marketId
    ) external view override returns (address[] memory providers) {
        _requireBound(marketId);
        providers = new address[](TOKEN_COUNT);
    }

    /// @inheritdoc IAmmIntegrationHooks
    /// @custom:spec REQ-AMM-CORE-012
    function effectiveSupply(
        uint256 marketId
    ) external view override returns (uint256) {
        _requireBound(marketId);
        return 0;
    }

    // ─── Internal ───

    /// @dev `SPEC-ORC-005` over this market's raw composition (`ClUnitMath`). The unit exponent `k` is the pool's stored
    /// one, or, at the pool's first binding, `ClUnitMath.firstBindingExponent`: `max(0, e + UNIT_EXP_HEADROOM − 18)` with
    /// `e` the smallest exponent in `[6, 34]` whose `10^e` liquidity on the pool's reference range (one tick spacing,
    /// holding the listing price) is worth at least $1. Then `d` is the smallest in `[6, 18]` with
    /// `price8(10^(d + k)) >= 10^8` on this market's range. `InvalidPool` when no `e` or `d` passes or a listing price is
    /// outside `[1, MAX_ROUTE_ANSWER]`; `k <= ClUnitMath.MAX_UNIT_EXP` by the bound on `e`.
    function _unitDecimals(
        bytes32 poolRef,
        ClMarketConfig memory cfg,
        uint8 d0,
        uint8 d1,
        uint256 price0,
        uint256 price1
    ) private view returns (uint8 d, uint8 k) {
        if (
            price0 == 0 || price1 == 0 || price0 > LPPriceMath.MAX_ROUTE_ANSWER || price1 > LPPriceMath.MAX_ROUTE_ANSWER
        ) {
            revert InvalidPool();
        }
        ClUnitMath.Valuation memory v = ClUnitMath.valuation(price0, price1, d0, d1);
        uint8 stored = _poolUnitExp[poolRef];
        bool found = true;
        if (stored != 0) k = stored - 1;
        else (found, k) = ClUnitMath.firstBindingExponent(v, cfg.tickSpacing);
        if (found) (found, d) = ClUnitMath.unitDecimals(v, cfg.tickLower, cfg.tickUpper, k);
        if (!found) revert InvalidPool();
    }

    /// @dev Reads the token decimals, finds `d` and the pool's `k` (`_unitDecimals`), writes the market with its pool
    /// reference and, at the pool's first binding, the pool's exponent; returns `d`.
    function _storeMarket(
        uint256 marketId,
        bytes32 poolRef,
        ClMarketConfig memory cfg,
        uint256 price0,
        uint256 price1
    ) internal returns (uint8 d) {
        uint8 d0 = _tokenDecimals(cfg.token0);
        uint8 d1 = _tokenDecimals(cfg.token1);
        uint8 k;
        (d, k) = _unitDecimals(poolRef, cfg, d0, d1, price0, price1);
        Market storage m = _markets[marketId];
        m.cfg = cfg;
        m.decimals0 = d0;
        m.decimals1 = d1;
        m.unitExp = k;
        m.poolRef = poolRef;
        if (_poolUnitExp[poolRef] == 0) _poolUnitExp[poolRef] = k + 1;
    }

    /// @dev Token decimals read at listing; `InvalidPool` for a token without `decimals()` or above 18.
    function _tokenDecimals(
        address token
    ) private view returns (uint8 d) {
        try IERC20Metadata(token).decimals() returns (uint8 v) {
            d = v;
        } catch {
            revert InvalidPool();
        }
        if (d > MAX_TOKEN_DECIMALS) revert InvalidPool();
    }

    /// @dev `observe([window, 0])`: the tick-cumulative and seconds-per-liquidity differences, or `ok = false`.
    function _observe(
        address pool,
        uint32 window
    ) internal view returns (bool ok, int56 tickDelta, uint160 splDelta) {
        uint32[] memory ago = new uint32[](TOKEN_COUNT);
        ago[0] = window;
        try IClPoolObservations(pool).observe(ago) returns (int56[] memory ticks, uint160[] memory spl) {
            if (ticks.length != TOKEN_COUNT || spl.length != TOKEN_COUNT) return (false, 0, 0);
            unchecked {
                // Cumulatives wrap by design; the differences are taken modulo their width, as Uniswap does.
                tickDelta = ticks[1] - ticks[0];
                splDelta = spl[1] - spl[0];
            }
            ok = true;
        } catch {
            ok = false;
        }
    }
}
