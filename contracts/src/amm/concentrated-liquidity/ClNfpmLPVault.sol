// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPPriceMath} from "../../oracle/lp-oracle/LPPriceMath.sol";
import {AmmConstants} from "../../types/AmmConstants.sol";
import {PositionShape} from "../../types/PositionShape.sol";
import {ShapeKind} from "../../types/ShapeKind.sol";
import {IAmmIntegration} from "../IAmmIntegration.sol";
import {IAmmIntegrationHooks} from "../IAmmIntegrationHooks.sol";
import {ClMarketConfig} from "../types/ClMarketConfig.sol";
import {FeeMode} from "../types/FeeMode.sol";
import {IntegrationCapabilities} from "../types/IntegrationCapabilities.sol";
import {PoolKeying} from "../types/PoolKeying.sol";
import {PricingMode} from "../types/PricingMode.sol";
import {RiskMetadata} from "../types/RiskMetadata.sol";
import {RiskStatus} from "../types/RiskStatus.sol";
import {ClLPVaultCustody} from "./ClLPVaultCustody.sol";
import {ClLPVaultMarkets} from "./ClLPVaultMarkets.sol";
import {ClPriceMath} from "./ClPriceMath.sol";
import {IClPoolObservations} from "./IClPoolObservations.sol";
import {IClPositionManager} from "./IClPositionManager.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ClNfpmLPVault
/// @notice The layer of the concentrated-liquidity LPVault shared by the AMM protocols whose positions live in a
/// NonfungiblePositionManager and whose pools are contracts with their own `slot0` lock and `observe` buffer (Uniswap v3
/// on Ethereum, Aerodrome Slipstream on Base): address-keyed binding, `decreaseLiquidity` plus a principal-capped
/// `collect`, an uncapped `collect` for fees, the `slot0().unlocked` read guard, and risk metadata, depth and the
/// consistency read from the pool itself.
/// @dev Each integration supplies the pool's `slot0` layout (`_slot0`), the listing check against its factory
/// (`_validatePool`) and the position read through its manager (`_readPoolPosition`).
/// @custom:spec REQ-AMM-CORE-003, REQ-AMM-CORE-004, REQ-AMM-CORE-013, REQ-AMM-V3-002, REQ-AMM-V3-003, REQ-AMM-V3-004, REQ-AMM-V3-006, REQ-AMM-SLIP-003, SPEC-BACK-001, SPEC-BACK-008
// The removal events report what the position manager's own calls returned; see `ClLPVaultCustody`.
// forge-lint: disable-start(reentrancy-events)
abstract contract ClNfpmLPVault is ClLPVaultCustody, ClLPVaultMarkets {
    // ─── Integration hooks ───

    /// @dev The position's pool, derived through the pinned factory from the position's own fields (address(0) when
    /// the factory has none), its ticks and its live liquidity, read from the position manager.
    function _readPoolPosition(
        bytes32 positionKey
    ) internal view virtual returns (address pool, int24 tickLower, int24 tickUpper, uint128 liquidity);

    /// @dev The pool's current tick, observation cardinality and reentrancy flag, decoded with the AMM protocol's own
    /// `slot0` layout.
    function _slot0(
        address pool
    ) internal view virtual returns (int24 tick, uint16 observationCardinality, bool unlocked);

    /// @dev Validates a pool against the pinned factory at listing and returns its configuration (pool, position
    /// manager, factory, tokens, fee, tick spacing) and the listing valuation prices decoded from `integrationData`;
    /// reverts `InvalidPool` for anything else.
    function _validatePool(
        address pool,
        bytes calldata integrationData
    ) internal view virtual returns (ClMarketConfig memory cfg, uint256 price0, uint256 price1);

    // ─── Base hooks ───

    /// @dev The pool address as the pool reference.
    function _readPosition(
        bytes32 positionKey
    ) internal view override returns (bytes32 poolRef, int24 tickLower, int24 tickUpper, uint128 liquidity) {
        address pool;
        (pool, tickLower, tickUpper, liquidity) = _readPoolPosition(positionKey);
        poolRef = bytes32(uint256(uint160(pool)));
    }

    /// @dev `PoolLocked` while `slot0().unlocked` is false.
    /// @custom:spec REQ-AMM-V3-003, REQ-AMM-CORE-018, REQ-VAULT-010
    function _requireReadSafe(
        Market storage market
    ) internal view override {
        (,, bool unlocked) = _slot0(market.cfg.pool);
        if (!unlocked) revert PoolLocked();
    }

    /// @dev `decreaseLiquidity` with the given minimums, then `collect` capped at exactly the amounts it returned
    /// (`SPEC-BACK-008`), skipped when both are 0, back to back inside one call under the Lock; every owed fee stays
    /// with the NFT, so `depositor` receives nothing here.
    /// @custom:spec SPEC-BACK-008, REQ-AMM-V3-004, REQ-VAULT-057, REQ-VAULT-058
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
            // The collect is capped at exactly (a0, a1), which the position owes after the removal, so it collects
            // exactly them (SPEC-BACK-008); the reported amounts are the removal's.
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

    /// @dev One `collect` with both caps at `type(uint128).max` to `depositor`, and nothing else on the position
    /// manager.
    /// @custom:spec REQ-VAULT-064, REQ-VAULT-065, FEE-001
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

    /// @inheritdoc IAmmIntegration
    /// @dev The global bound of 16: a Uniswap v3 or Slipstream removal is one NFPM decrease and one collect.
    /// @custom:spec REQ-AMM-CORE-020
    function maxRecordsPerAccountMarket() external pure override returns (uint256) {
        return AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET;
    }

    // ─── Risk metadata and hooks ───

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
        _requireReadSafe(_market(marketId));
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
}
// forge-lint: disable-end(reentrancy-events)
