// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPPriceMath} from "../../oracle/lp-oracle/LPPriceMath.sol";
import {PositionShape} from "../../types/PositionShape.sol";
import {ShapeKind} from "../../types/ShapeKind.sol";
import {IAmmIntegration} from "../IAmmIntegration.sol";
import {IAmmIntegrationHooks} from "../IAmmIntegrationHooks.sol";
import {IClIntegration} from "../IClIntegration.sol";
import {ClMarketConfig} from "../types/ClMarketConfig.sol";
import {FeeMode} from "../types/FeeMode.sol";
import {IntegrationCapabilities} from "../types/IntegrationCapabilities.sol";
import {PoolKeying} from "../types/PoolKeying.sol";
import {PricingMode} from "../types/PricingMode.sol";
import {RiskMetadata} from "../types/RiskMetadata.sol";
import {RiskStatus} from "../types/RiskStatus.sol";
import {ClLPVaultBase} from "./ClLPVaultBase.sol";
import {ClPriceMath} from "./ClPriceMath.sol";
import {ClUnitMath} from "./ClUnitMath.sol";
import {IClPoolObservations} from "./IClPoolObservations.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title ClLPVaultMarkets
/// @notice Market binding, composition at the clamped oracle price, risk metadata and the integration hooks of a
/// concentrated-liquidity LPVault.
/// @dev `bindMarket` is MarketRegistry-only and moves no position; every other function here is a view that never
/// reverts on the Lock. `composition` reads no pool state: only the stored range, the token decimals, `units` and the
/// price vector.
/// @custom:spec REQ-AMM-CORE-003, REQ-AMM-CORE-004, REQ-AMM-CORE-012, REQ-AMM-CORE-013, REQ-AMM-CORE-017, REQ-VAULT-166, REQ-AMM-V3-002, REQ-AMM-V3-005, REQ-AMM-V3-006, REQ-AMM-V3-008, SPEC-AMM-CORE-001, SPEC-AMM-V3-001, SPEC-BACK-001
abstract contract ClLPVaultMarkets is ClLPVaultBase {
    // ─── Binding ───

    /// @inheritdoc IAmmIntegration
    /// @dev `integrationData` carries the listing valuation prices of the two tokens (8 decimals). The pool's unit
    /// exponent `k` (one vault-token unit = `10^k` liquidity) is fixed by its first market and shared by every later
    /// one; `unitDecimals` is the smallest `d` in `[6, 18]` whose whole token, `10^(d + k)` liquidity, is worth at least
    /// $1 (`SPEC-UNIT-001`, `SPEC-UNIT-002`, `SPEC-ORC-005`). Refuses `marketId == 0` (0 means "not in custody" in `marketOfPosition`), a `poolId`, any shape
    /// other than an aligned `TickRange` inside the usable ticks, and token decimals above 18.
    /// @custom:spec REQ-AMM-CORE-003, REQ-AMM-CORE-004, REQ-AMM-CORE-017, REQ-VAULT-166, REQ-AMM-V3-002, REQ-AMM-V3-007, REQ-AMM-V3-008, SPEC-BACK-001, SPEC-UNIT-001, SPEC-ORC-005
    function bindMarket(
        uint256 marketId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape,
        bytes calldata integrationData
    ) external override returns (address[] memory tokens, uint8 unitDecimals) {
        if (msg.sender != _MARKET_REGISTRY) revert NotMarketRegistry();
        if (marketId == 0 || _markets[marketId].cfg.pool != address(0)) revert MarketBinding(marketId);
        if (pool == address(0) || poolId != bytes32(0) || pool.code.length == 0) revert InvalidPool();
        if (shape.kind != ShapeKind.TickRange) revert InvalidShape();
        (ClMarketConfig memory cfg, uint256 price0, uint256 price1) = _validatePool(pool, integrationData);
        if (!ClPriceMath.isUsableRange(shape.tickLower, shape.tickUpper, cfg.tickSpacing)) revert InvalidShape();
        cfg.tickLower = shape.tickLower;
        cfg.tickUpper = shape.tickUpper;
        cfg.maxLiquidityPerTick = ClPriceMath.maxLiquidityPerTick(cfg.tickSpacing);
        unitDecimals = _storeMarket(marketId, cfg, price0, price1);
        tokens = new address[](TOKEN_COUNT);
        (tokens[0], tokens[1]) = (cfg.token0, cfg.token1);
        // Every call before the event is a view (STATICCALL) of the pool, the factory or a token, so no code can run
        // between the checks and the log.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MarketBound(marketId, pool, bytes32(0), shape.tickLower, shape.tickUpper);
    }

    /// @inheritdoc IAmmIntegration
    /// @custom:spec REQ-AMM-CORE-004
    function marketOf(
        uint256 marketId
    )
        external
        view
        override
        returns (address pool, bytes32 poolId, PositionShape memory shape, address[] memory tokens)
    {
        ClMarketConfig storage cfg = _market(marketId).cfg;
        tokens = new address[](TOKEN_COUNT);
        (tokens[0], tokens[1]) = (cfg.token0, cfg.token1);
        shape = PositionShape({kind: ShapeKind.TickRange, tickLower: cfg.tickLower, tickUpper: cfg.tickUpper});
        return (cfg.pool, bytes32(0), shape, tokens);
    }

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

    /// @inheritdoc IAmmIntegration
    /// @custom:spec REQ-AMM-CORE-009, REQ-AMM-CORE-010, REQ-AMM-CORE-011, REQ-AMM-CORE-012, REQ-AMM-CORE-013
    function capabilities() external pure override returns (IntegrationCapabilities memory) {
        return IntegrationCapabilities({
            poolKeying: PoolKeying.Address,
            feeMode: FeeMode.Separate,
            pricingMode: PricingMode.ClosedForm,
            shapeKind: ShapeKind.TickRange,
            hasTwap: true,
            reentrancyGuarded: true,
            nativeToken: false,
            rateTokens: false
        });
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

    // ─── Risk metadata ───

    /// @inheritdoc IAmmIntegration
    /// @dev `inRange = tickLower <= slot0.tick < tickUpper`, `readSafe = slot0.unlocked`, `poolUnits = liquidity()` in
    /// vault-token units (`⌊liquidity / 10^k⌋`).
    /// The LPVault keeps no unit counter, so `avanaUnits` and `poolShareBps` are 0: Avana's units in a market are
    /// Collateralization's credited total, which the RiskModule reads (`SPEC-CAP-005`, `SPEC-BRK-002`).
    /// `positionUnits` is the named position's live liquidity in vault-token units.
    /// @custom:spec REQ-AMM-CORE-008, REQ-AMM-CORE-013, REQ-AMM-V3-006, SPEC-UNIT-002
    function riskMetadata(
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (RiskMetadata memory meta) {
        Market storage m = _market(marketId);
        ClMarketConfig storage cfg = m.cfg;
        (int24 tick,, bool unlocked) = _slot0(cfg.pool);
        meta.inRange = cfg.tickLower <= tick && tick < cfg.tickUpper;
        meta.readSafe = unlocked;
        meta.poolUnits = _toUnits(m, IClPoolObservations(cfg.pool).liquidity());
        if (positionKey != bytes32(0)) {
            (,,, uint128 live) = _readPosition(positionKey);
            // At most the position's uint128 liquidity.
            // forge-lint: disable-next-line(unsafe-typecast)
            meta.positionUnits = uint128(_toUnits(m, live));
        }
    }

    /// @inheritdoc IAmmIntegration
    /// @dev Harmonic-mean in-range liquidity of `observe([window, 0])` (`OracleLibrary.consult`) in vault-token units
    /// (`⌊liquidity / 10^k⌋`); unavailable for a zero window, a failed `observe` or a zero seconds-per-liquidity
    /// difference.
    /// @custom:spec REQ-AMM-CORE-013, REQ-AMM-V3-006, SPEC-CAP-005, SPEC-UNIT-002
    function riskStatus(
        uint256 marketId,
        uint32 window
    ) external view override returns (RiskStatus memory status) {
        Market storage m = _market(marketId);
        if (window == 0) return status;
        (bool ok,, uint160 splDelta) = _observe(m.cfg.pool, window);
        if (!ok) return status;
        (status.depthUnits, status.depthAvailable) = ClPriceMath.harmonicMeanLiquidity(splDelta, window);
        status.depthUnits = _toUnits(m, status.depthUnits);
    }

    /// @inheritdoc IAmmIntegrationHooks
    /// @custom:spec REQ-AMM-CORE-013, REQ-AMM-CORE-018, REQ-AMM-V3-003, REQ-AMM-V3-006, REQ-VAULT-010
    function checkReadSafe(
        uint256 marketId
    ) external view override {
        _requireUnlocked(_market(marketId).cfg.pool);
    }

    /// @inheritdoc IAmmIntegrationHooks
    /// @dev `SPEC-ORC-010`: `|meanTick - tickRef|` with `tickRef` the tick of the unclamped oracle square-root price.
    /// Unavailable for a zero window, an observation cardinality below `ceil(window / blockTime) + 1`
    /// (`SPEC-ORC-022`) or a failed `observe`.
    /// @custom:spec REQ-AMM-CORE-009, SPEC-ORC-010, SPEC-ORC-022, REQ-ORACLE-046, REQ-ORACLE-103
    function consistencyDeviation(
        uint256 marketId,
        uint32 window,
        uint256[] calldata prices
    ) external view override returns (uint256 deviationBps, bool available) {
        Market storage m = _market(marketId);
        (uint256 p0, uint256 p1) = _prices(prices);
        if (window == 0) return (0, false);
        (, uint16 cardinality,) = _slot0(m.cfg.pool);
        if (cardinality < LPPriceMath.minObservations(window, _blockTime())) return (0, false);
        (bool ok, int56 tickDelta,) = _observe(m.cfg.pool, window);
        if (!ok) return (0, false);
        uint160 sRef = ClPriceMath.oracleSqrtPrice(p0, p1, m.decimals0, m.decimals1);
        int256 diff = int256(ClPriceMath.meanTick(tickDelta, window)) - int256(ClPriceMath.tickAtSqrtRatio(sRef));
        // |diff| is at most 2 * MAX_TICK and the sign is tested first, so neither cast truncates.
        // forge-lint: disable-next-line(unsafe-typecast)
        deviationBps = diff < 0 ? uint256(-diff) : uint256(diff);
        available = true;
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
    /// @custom:spec REQ-AMM-CORE-010
    function wrappedNative() external pure override returns (address) {
        return address(0);
    }

    /// @inheritdoc IAmmIntegrationHooks
    /// @custom:spec REQ-AMM-CORE-014
    function isAllowedPoolHook(
        address hooks
    ) external pure override returns (bool) {
        return hooks == address(0);
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
    /// outside `[1, MAX_ROUTE_ANSWER]`; `k <= MAX_UNIT_EXP` by the bound on `e`.
    function _unitDecimals(
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
        uint8 stored = _poolUnitExp[cfg.pool];
        bool found = true;
        if (stored != 0) k = stored - 1;
        else (found, k) = ClUnitMath.firstBindingExponent(v, cfg.tickSpacing);
        if (found) (found, d) = ClUnitMath.unitDecimals(v, cfg.tickLower, cfg.tickUpper, k);
        if (!found) revert InvalidPool();
    }

    /// @dev Reads the token decimals, finds `d` and the pool's `k` (`_unitDecimals`), writes the market and, at the
    /// pool's first binding, the pool's exponent; returns `d`.
    function _storeMarket(
        uint256 marketId,
        ClMarketConfig memory cfg,
        uint256 price0,
        uint256 price1
    ) private returns (uint8 d) {
        uint8 d0 = _tokenDecimals(cfg.token0);
        uint8 d1 = _tokenDecimals(cfg.token1);
        uint8 k;
        (d, k) = _unitDecimals(cfg, d0, d1, price0, price1);
        Market storage m = _markets[marketId];
        m.cfg = cfg;
        m.decimals0 = d0;
        m.decimals1 = d1;
        m.unitExp = k;
        if (_poolUnitExp[cfg.pool] == 0) _poolUnitExp[cfg.pool] = k + 1;
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
    ) private view returns (bool ok, int56 tickDelta, uint160 splDelta) {
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
