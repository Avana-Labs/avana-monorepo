// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../custody/lp-vault/ILPVault.sol";
import {LPPriceMath} from "../../oracle/LPPriceMath.sol";
import {AmmConstants} from "../../types/AmmConstants.sol";
import {PositionShape, ShapeKind} from "../../types/PositionTypes.sol";
import {
    ClMarketConfig,
    FeeMode,
    IntegrationCapabilities,
    PoolKeying,
    PricingMode,
    RiskMetadata,
    RiskStatus
} from "../types/AmmTypes.sol";
import {ClLPVaultCustody} from "./ClLPVaultCustody.sol";
import {ClLPVaultMarkets} from "./ClLPVaultMarkets.sol";
import {ClPriceMath} from "./ClPriceMath.sol";
import {IClPoolObservations} from "./IClPoolObservations.sol";
import {IClPositionManager} from "./IClPositionManager.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ClNfpmLPVault
/// @notice LPVault layer shared by NonfungiblePositionManager protocols with address-keyed pools.
// Events report the position manager's return values, so they follow the call; emitters run only under the Lock.
// forge-lint: disable-start(reentrancy-events)
abstract contract ClNfpmLPVault is ClLPVaultCustody, ClLPVaultMarkets {
    /// @dev The position's pool via the pinned factory (address(0) when none), ticks and live liquidity.
    function _readPoolPosition(
        bytes32 positionKey
    ) internal view virtual returns (address pool, int24 tickLower, int24 tickUpper, uint128 liquidity);

    function _slot0(
        address pool
    ) internal view virtual returns (int24 tick, uint16 observationCardinality, bool unlocked);

    /// @dev Validates a pool against the pinned factory and returns its configuration and listing prices.
    function _validatePool(
        address pool,
        bytes calldata integrationData
    ) internal view virtual returns (ClMarketConfig memory cfg, uint256 price0, uint256 price1);

    function _readPosition(
        bytes32 positionKey
    ) internal view override returns (bytes32 poolRef, int24 tickLower, int24 tickUpper, uint128 liquidity) {
        address pool;
        (pool, tickLower, tickUpper, liquidity) = _readPoolPosition(positionKey);
        poolRef = bytes32(uint256(uint160(pool)));
    }

    function _requireReadSafe(
        Market storage market
    ) internal view override {
        (,, bool unlocked) = _slot0(market.cfg.pool);
        if (!unlocked) revert PoolLocked();
    }

    /// @dev `decreaseLiquidity`, then `collect` capped at exactly the removed amounts; owed fees stay with the NFT.
    function _removePrincipal(
        Market storage,
        bytes32 positionKey,
        uint128 liquidity,
        uint256[] calldata minAmounts,
        address recipient,
        address
    ) internal override returns (uint256[] memory amounts) {
        IClPositionManager manager = _manager(positionKey);
        uint256 tokenId = _tokenId(positionKey);
        (uint256 a0, uint256 a1) = manager.decreaseLiquidity(
            IClPositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: minAmounts[0],
                amount1Min: minAmounts[1],
                deadline: block.timestamp
            })
        );
        if (a0 < minAmounts[0]) revert BelowMinimum(0, a0, minAmounts[0]);
        if (a1 < minAmounts[1]) revert BelowMinimum(1, a1, minAmounts[1]);
        if (a0 != 0 || a1 != 0) {
            // Capped at exactly (a0, a1), which the position now owes, so it collects exactly them.
            // forge-lint: disable-start(unused-return)
            manager.collect(
                IClPositionManager.CollectParams({
                    tokenId: tokenId,
                    recipient: recipient,
                    amount0Max: SafeCast.toUint128(a0),
                    amount1Max: SafeCast.toUint128(a1)
                })
            );
            // forge-lint: disable-end(unused-return)
        }
        amounts = _pair(a0, a1);
    }

    function _collectAll(
        Market storage,
        bytes32 positionKey,
        address depositor
    ) internal override returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _manager(positionKey)
            .collect(
                IClPositionManager.CollectParams({
                    tokenId: _tokenId(positionKey),
                    recipient: depositor,
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max
                })
            );
    }

    /// @inheritdoc ILPVault
    /// @dev Refuses `marketId == 0`, which means "not in custody" in `marketOfPosition`.
    function bindMarket(
        uint256 marketId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape,
        bytes calldata integrationData
    ) external override returns (address[] memory tokens, uint8 unitDecimals) {
        if (msg.sender != _MARKET_REGISTRY) revert NotMarketRegistry();
        if (marketId == 0 || _markets[marketId].poolRef != bytes32(0)) revert MarketBinding(marketId);
        if (pool == address(0) || poolId != bytes32(0) || pool.code.length == 0) revert InvalidPool();
        if (shape.kind != ShapeKind.TickRange) revert InvalidShape();
        (ClMarketConfig memory cfg, uint256 price0, uint256 price1) = _validatePool(pool, integrationData);
        if (!ClPriceMath.isUsableRange(shape.tickLower, shape.tickUpper, cfg.tickSpacing)) revert InvalidShape();
        cfg.tickLower = shape.tickLower;
        cfg.tickUpper = shape.tickUpper;
        cfg.maxLiquidityPerTick = ClPriceMath.maxLiquidityPerTick(cfg.tickSpacing);
        unitDecimals = _storeMarket(marketId, bytes32(uint256(uint160(pool))), cfg, price0, price1);
        tokens = new address[](TOKEN_COUNT);
        (tokens[0], tokens[1]) = (cfg.token0, cfg.token1);
        // Every call before the event is a view, so no code can run between the checks and the log.
        // forge-lint: disable-next-line(reentrancy-events)
        emit MarketBound(marketId, pool, bytes32(0), shape.tickLower, shape.tickUpper);
    }

    /// @inheritdoc ILPVault
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

    /// @inheritdoc ILPVault
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

    /// @inheritdoc ILPVault
    function maxRecordsPerAccountMarket() external pure override returns (uint256) {
        return AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET;
    }

    /// @inheritdoc ILPVault
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

    /// @inheritdoc ILPVault
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

    /// @inheritdoc ILPVault
    function checkReadSafe(
        uint256 marketId
    ) external view override {
        _requireReadSafe(_market(marketId));
    }

    /// @inheritdoc ILPVault
    /// @dev Measured against the unclamped oracle tick.
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

    /// @inheritdoc ILPVault
    function wrappedNative() external pure override returns (address) {
        return address(0);
    }

    /// @inheritdoc ILPVault
    function isAllowedPoolHook(
        address hooks
    ) external pure override returns (bool) {
        return hooks == address(0);
    }
}
// forge-lint: disable-end(reentrancy-events)
