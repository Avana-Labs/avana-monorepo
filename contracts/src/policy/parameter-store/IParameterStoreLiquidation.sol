// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreLiquidation
/// @notice Liquidation-liveness and settlement parameters: the liveness check of each (market, debt reserve) pair, the
/// caller shortfall bound, each debt asset's stress rise, and each CDP Spoke's expected
/// Aave liquidation configuration.
/// @dev Setters require `APPLICATION_ADMIN` through the timelock; `tighten…` at the short delay (12 hours) or at once by
/// `APPLICATION_RISK_STEWARD`, every other
/// setter at the normal delay. Views are `view`, never revert, and return 0 (or false where stated) for an unknown key.
/// Every allowed value keeps liquidation feasible for every (active market, enabled debt reserve) pair; exits never
/// read these values.
interface IParameterStoreLiquidation {
    /// @notice Whether liquidation of `marketId` against `debtReserveId` stays feasible: the smallest liquidation bonus
    /// covers the swap slippage into the debt asset and the flash premium,
    /// `minLB × (10⁴ − slippageAllowanceMinBps(m)) ≥ 10⁴ × (10⁴ + maxFlashFeeBps)`.
    /// @dev Units: bps on both sides, integers, exact (no rounding beyond `minLB`'s floor). `minLB = 10⁴ +
    /// ⌊(maxLiquidationBonus − 10⁴) × liquidationBonusFactor / 10⁴⌋` from the Spoke's `getLiquidationConfig()` and the
    /// latest dynamic key of the market's reserve, resolved through the market's home Hub, so it also answers for a
    /// market not yet activated. The debt asset is flash-borrowed itself, so there is no second swap leg: every pool
    /// token is swapped once, straight into the debt asset, and the only extra cost is the flash premium. The check
    /// guards against a configuration where a liquidator that receives the bonus still cannot repay the flash loan,
    /// which would leave the position unliquidatable. Example: `maxLiquidationBonus = 10,500`, factor 10⁴ gives
    /// `minLB = 10,500`; with `slippageAllowanceMinBps = 50` and `maxFlashFeeBps = 10`, `10,500 × 9,950 = 104,475,000
    /// ≥ 10⁴ × 10,010 = 100,100,000`, so it holds; at `slippageAllowanceMinBps = 500` the left side is 99,750,000 and it
    /// fails. False when the market, its reserve or the debt reserve is unknown, or the key's `maxLiquidationBonus` is
    /// below 10⁴. Checked by: the liquidation-liveness Z3 model of REQ-PSTORE-021.
    /// @param spoke CDP Spoke of the market.
    /// @param marketId Market identifier.
    /// @param debtReserveId Debt reserve identifier.
    /// @return holds True when the inequality holds.
    /// @custom:spec REQ-PSTORE-021, Q-261, Q-379
    function liquidationLivenessHolds(
        address spoke,
        uint256 marketId,
        uint256 debtReserveId
    ) external view returns (bool holds);

    /// @notice Largest per-leg slippage raise a caller shortfall top-up can buy (SPEC-LIQ-019).
    /// @return value bps; launch 1,000, within [0, 5,000].
    /// @custom:spec REQ-PSTORE-018, Q-251
    function maxShortfallBps() external view returns (uint16 value);

    /// @notice Lowers `maxShortfallBps`. Short delay; `NotStricter` unless strictly lower. Emits `ParameterTightened`.
    /// @param value New bound, bps.
    /// @custom:spec REQ-PSTORE-018, REQ-CONFIG-049, REQ-CONFIG-051
    function tightenMaxShortfallBps(
        uint16 value
    ) external;

    /// @notice Raises `maxShortfallBps`. Normal delay; `NotLooser` unless strictly higher. Emits `ParameterLoosened`.
    /// @param value New bound, bps.
    /// @custom:spec REQ-PSTORE-018, REQ-CONFIG-049, REQ-CONFIG-053
    function loosenMaxShortfallBps(
        uint16 value
    ) external;

    /// @notice Stress rise of a debt asset without a fixed-price source: the DebtOracle serves `⌈accepted × (10⁴ + rise) / 10⁴⌉` once
    /// Expired.
    /// @param asset Debt asset.
    /// @return value bps within [100, 5,000]; 0 for an asset with no value written.
    /// @custom:spec REQ-PSTORE-020, Q-247, Q-248
    function debtStressRiseBps(
        address asset
    ) external view returns (uint16 value);

    /// @notice Raises a debt asset's `debtStressRiseBps` (stale debt counts at a higher price); the listing batch writes
    /// the first value with it, from 0.
    /// @dev Short delay; `NotStricter` unless strictly higher, `OutOfBounds` outside [100, 5,000], `TokenNotListed`
    /// unless the asset is a listed MarketRegistry token. The first write marks the asset as one with a DebtOracle,
    /// which reads only an oracle-network second source, so it also reverts `OutOfBounds` while the asset's recorded
    /// or standby second source is a `PoolTwap`. Emits `ParameterTightened`.
    /// @param asset Debt asset.
    /// @param value New rise, bps.
    /// @custom:spec REQ-PSTORE-020, REQ-CONFIG-049, REQ-CONFIG-051
    function tightenDebtStressRiseBps(
        address asset,
        uint16 value
    ) external;

    /// @notice Lowers a debt asset's `debtStressRiseBps`. Normal delay; `NotLooser` unless strictly lower and
    /// `OutOfBounds` below 100. Emits `ParameterLoosened`.
    /// @param asset Debt asset.
    /// @param value New rise, bps.
    /// @custom:spec REQ-PSTORE-020, REQ-CONFIG-049, REQ-CONFIG-053
    function loosenDebtStressRiseBps(
        address asset,
        uint16 value
    ) external;

    /// @notice Target health factor Avana's sizing assumes for a CDP Spoke; the drift check compares the Spoke's
    /// `LiquidationConfig.targetHealthFactor` with it.
    /// @param spoke CDP Spoke.
    /// @return value WAD (0 for a Spoke with no value written).
    /// @custom:spec REQ-PSTORE-022, Q-185, Q-270
    function aaveTargetHealthFactor(
        address spoke
    ) external view returns (uint256 value);

    /// @notice Minimum liquidation bonus Avana's sizing assumes for a CDP Spoke; the drift check and activation
    /// require `minLB − 10⁴` of every market reserve's latest key to be at least it.
    /// @param spoke CDP Spoke.
    /// @return value bps (0 for a Spoke with no value written).
    /// @custom:spec REQ-PSTORE-022, Q-179, Q-270
    function minLiquidationBonus(
        address spoke
    ) external view returns (uint16 value);

    /// @notice Writes a CDP Spoke's expected Aave liquidation configuration, in either direction.
    /// @dev Normal delay. Reverts `UnknownSpoke` unless the MarketRegistry approves the Spoke and `OutOfBounds` unless
    /// `1e18 < targetHealthFactor` and `200 ≤ minLiquidationBonusBps < 10,000`. Emits `ParameterSet` twice.
    /// @param spoke CDP Spoke.
    /// @param targetHealthFactor Expected `targetHealthFactor`, WAD.
    /// @param minLiquidationBonusBps Expected minimum bonus, bps.
    /// @custom:spec REQ-PSTORE-022, REQ-CONFIG-049, REQ-CONFIG-054
    function setLiquidationExpectations(
        address spoke,
        uint256 targetHealthFactor,
        uint16 minLiquidationBonusBps
    ) external;
}
