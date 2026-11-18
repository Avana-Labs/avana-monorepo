// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig, SecondSource} from "../../types/OracleTypes.sol";
import {IParameterStoreBase} from "./IParameterStoreBase.sol";
import {IParameterStoreListing} from "./IParameterStoreListing.sol";
import {IParameterStoreLoosen} from "./IParameterStoreLoosen.sol";
import {IParameterStoreTighten} from "./IParameterStoreTighten.sol";
import {
    DebtReserveParams,
    FeedDef,
    GlobalParams,
    MarketParams,
    MarketSpeedLimits,
    SpeedLimit
} from "./types/ParameterStoreTypes.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title IParameterStore
/// @notice Every Avana risk parameter of one chain, with its hard bounds, liveness bounds and change direction.
/// @dev UUPS proxy; only the timelock can upgrade it. Holds no funds.
interface IParameterStore is
    IAccessControl,
    IParameterStoreBase,
    IParameterStoreTighten,
    IParameterStoreLoosen,
    IParameterStoreListing
{
    /// @notice Initializes the proxy storage.
    /// @dev Grants the admin roles to `timelock`; reverts `AdminRoleOnlyTimelock` unless `timelock == TIMELOCK`.
    /// @param initialPoolShareMaxBps Initial maximum Avana share of pool liquidity, bps.
    function initialize(
        address timelock,
        GlobalParams calldata params,
        uint16 initialPoolShareMaxBps
    ) external;

    /// @notice Sets a feed's `borrowPriceMaxAge` in either direction.
    /// @dev Reverts `OutOfBounds` unless `0 < value <= feedMaxAge`.
    /// @param value New age limit, seconds.
    function setBorrowPriceMaxAge(
        address feed,
        uint32 value
    ) external;

    /// @notice Sets a market's `consistencyToleranceBps` in either direction.
    /// @dev Reverts `LivenessBound` below `consistencyToleranceMinBps`.
    /// @param value New tolerance, bps of the fair price.
    function setConsistencyToleranceBps(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Sets a token's `feedAgreementToleranceBps` in either direction.
    /// @dev Never below `feedAgreementToleranceMinBps(token)`.
    function setFeedAgreementToleranceBps(
        address token,
        uint16 value
    ) external;

    /// @notice Sets a market's `poolRiskFactor` in either direction.
    /// @param value New factor, bps.
    function setPoolRiskFactor(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Sets `avanaFeeShareBps` in either direction.
    /// @dev Also callable by `APPLICATION_RISK_STEWARD`; a rise reverts `OutOfBounds` unless the fee bound holds.
    function setAvanaFeeShareBps(
        uint16 value
    ) external;

    /// @notice Sets `feeRecipient`.
    /// @dev Reverts `InvalidFeeRecipient` for the zero address, an Avana contract, a Hub, a Spoke or a PositionProxy.
    function setFeeRecipient(
        address recipient
    ) external;

    /// @notice Sets `maxFlashFeeBps`.
    /// @dev A raise reverts `LivenessBound` unless liquidation liveness holds for every live market.
    function setMaxFlashFeeBps(
        uint16 value
    ) external;

    /// @notice Lowers `maxFlashFeeBps` (short delay, or at once by `APPLICATION_RISK_STEWARD`).
    /// @dev A lower ceiling can move liquidations to the caller-funded path, never stop them.
    function tightenMaxFlashFeeBps(
        uint16 value
    ) external;

    /// @notice Sets a token's second price source for borrow and withdraw-with-debt, and its standby.
    /// @dev The standby may be empty; it reverts `OutOfBounds` when it shares a feed or pool with `src` or the routes.
    /// @param standby The standby either guardian can put in force with `useStandbySecondSource`.
    function setSecondSource(
        address token,
        SecondSource calldata src,
        SecondSource calldata standby
    ) external;

    /// @notice Puts the token's standby second source in force at once.
    /// @dev `APPLICATION_PAUSE_GUARDIAN` only, the one function outside `APPLICATION_ADMIN`.
    function useStandbySecondSource(
        address token
    ) external;

    /// @notice Returns the token to its recorded second source.
    /// @dev Timelock only, so a guardian cannot switch back to a source that failed. No-op when not on standby.
    function restoreSecondSource(
        address token
    ) external;

    /// @notice Sets `cachedWindow`.
    /// @param value New window, seconds.
    function setCachedWindow(
        uint32 value
    ) external;

    /// @notice Sets `disagreementPauseMax`.
    /// @dev Reverts `LivenessBound` above its bound.
    /// @param value New maximum, seconds.
    function setDisagreementPauseMax(
        uint32 value
    ) external;

    /// @notice Sets a market's `twapWindow` (a change to price computation).
    /// @dev Requires the pool's time-weighted read over the new window to succeed.
    /// @param value New window, seconds.
    function setTwapWindow(
        uint256 marketId,
        uint32 value
    ) external;

    /// @notice Sets the USD band.
    /// @dev Requires `low < 1e8 < high`.
    /// @param low Lower level, 8 decimals per 1 USD at peg.
    /// @param high Upper level, 8 decimals per 1 USD at peg.
    function setUsdBand(
        uint256 low,
        uint256 high
    ) external;

    /// @notice Sets a feed's `liquidationPriceMaxAge`.
    /// @dev Reverts `LivenessBound` below the feed's `feedHeartbeat`.
    /// @param value New age limit, seconds.
    function setLiquidationPriceMaxAge(
        address feed,
        uint32 value
    ) external;

    /// @notice Sets a feed's `feedMaxAge`, the maximum age of a valid answer in LPOracle state evaluation.
    /// @dev Reverts `OutOfBounds` unless `value == feedHeartbeat + heartbeatMargin`.
    /// @param value New maximum age, seconds.
    function setFeedMaxAge(
        address feed,
        uint32 value
    ) external;

    /// @notice Sets `graceDuration`.
    /// @dev At most `graceDurationMax`.
    /// @param value New duration, seconds.
    function setGraceDuration(
        uint32 value
    ) external;

    /// @notice Sets `graceHealthFactor`.
    /// @dev `graceHealthFactorMin <= value < 1e18`.
    /// @param value New health factor, WAD.
    function setGraceHealthFactor(
        uint256 value
    ) external;

    /// @notice Sets `feedAgreementMarginBps`.
    /// @dev Every token's tolerance must stay at or above its lower bound.
    function setFeedAgreementMarginBps(
        uint16 value
    ) external;

    /// @notice Sets a market's `slippageAllowanceMinBps`.
    /// @dev A raise on a live market reverts `LivenessBound` unless liquidation liveness still holds.
    function setSlippageAllowanceMinBps(
        uint256 marketId,
        uint16 value
    ) external;

    /// @notice Sets a token's collateral-factor input (`tokenCollateralFactorBps`).
    function setTokenCollateralFactorBps(
        address token,
        uint16 value
    ) external;

    /// @notice Changes a market's stress floor.
    /// @dev Raising reverts `SupplyNotZero` unless the market's vault-token supply is 0.
    /// @param value New floor, 8-decimal USD per whole vault token.
    function setStressFloorUsd(
        uint256 marketId,
        uint256 value
    ) external;

    /// @notice Hub deficit of a debt asset above which the deficit freeze trips.
    /// @return value Asset base units; 0 when none is written.
    function breakerDeficitMax(
        address hub,
        address asset
    ) external view returns (uint256 value);

    /// @notice Seconds of healthy observations before a temporary gate reopens after its last breach.
    function gateRecoverySeconds() external view returns (uint64 value);

    /// @notice Raises `gateRecoverySeconds` (a temporary gate stays closed longer).
    function tightenGateRecoverySeconds(
        uint64 value
    ) external;

    /// @notice Lowers `gateRecoverySeconds`.
    function loosenGateRecoverySeconds(
        uint64 value
    ) external;

    /// @notice Lowers a debt asset's `breakerDeficitMax(hub, asset)` (more sensitive).
    /// @dev Reverts `UnknownHub` unless the MarketRegistry records `hub`.
    /// @param value New maximum, asset base units.
    function tightenBreakerDeficitMax(
        address hub,
        address asset,
        uint256 value
    ) external;

    /// @notice Raises a debt asset's `breakerDeficitMax(hub, asset)`.
    /// @dev Reverts `OutOfBounds` above the `firstLossReserveMinimum()` of a matching debt reserve.
    /// @param value New maximum, asset base units.
    function loosenBreakerDeficitMax(
        address hub,
        address asset,
        uint256 value
    ) external;

    /// @notice The sequencer-uptime check changed.
    /// @param feed New feed, `address(0)` on a chain with no sequencer.
    /// @param gracePeriod New grace period, seconds.
    event SequencerSet(address feed, uint32 gracePeriod);

    /// @notice The sequencer feed failed its check.
    error InvalidSequencerFeed(address feed);

    /// @notice Sets the sequencer-uptime feed and the grace period after a restart.
    /// @dev On a chain with no sequencer, `feed` must be `address(0)` and `gracePeriod` 0.
    /// @param gracePeriod Seconds after restart.
    function setSequencer(
        address feed,
        uint32 gracePeriod
    ) external;

    /// @notice The chain's sequencer-uptime feed and grace period.
    /// @return feed The feed, `address(0)` when the chain has none.
    /// @return gracePeriod Seconds.
    function sequencer() external view returns (address feed, uint32 gracePeriod);

    /// @notice Seconds per block on this chain, an implementation immutable.
    function CHAIN_BLOCK_TIME() external view returns (uint32 value);

    /// @notice Minimum observation-buffer length a market's pool must hold for its consistency window.
    /// @dev `ceil(twapWindow / CHAIN_BLOCK_TIME) + 1`, or 0 when `twapWindow == 0`.
    function twapMinObservations(
        uint256 marketId
    ) external view returns (uint16 count);

    /// @notice Heartbeat margin of a feed, written by `setFeed` with the rest of its `FeedDef`.
    /// @return margin Seconds.
    function heartbeatMargin(
        address feed
    ) external view returns (uint32 margin);

    /// @notice First-loss coverage ratio agreed in the funding ARFC.
    /// @return value bps within [0, 10,000]; 0 until `setCoverageRatioBps` writes it.
    function coverageRatioBps() external view returns (uint16 value);

    /// @notice Sets `coverageRatioBps`, in either direction.
    /// @dev Reverts `OutOfBounds` above 10,000.
    function setCoverageRatioBps(
        uint16 value
    ) external;

    /// @notice Whether the smallest liquidation bonus covers the slippage floor and the flash premium.
    /// @dev False when the market, its reserve or the debt reserve is unknown.
    function liquidationLivenessHolds(
        address spoke,
        uint256 marketId,
        uint256 debtReserveId
    ) external view returns (bool holds);

    /// @notice Largest per-leg slippage raise a caller shortfall top-up can buy.
    function maxShortfallBps() external view returns (uint16 value);

    /// @notice Lowers `maxShortfallBps`.
    function tightenMaxShortfallBps(
        uint16 value
    ) external;

    /// @notice Raises `maxShortfallBps`.
    function loosenMaxShortfallBps(
        uint16 value
    ) external;

    /// @notice Stress rise the DebtOracle applies to a debt asset's accepted price once it has expired.
    /// @return value bps; 0 when none is written.
    function debtStressRiseBps(
        address asset
    ) external view returns (uint16 value);

    /// @notice Raises a debt asset's `debtStressRiseBps`; the listing batch writes the first value with it.
    /// @dev Reverts `OutOfBounds` while the asset's recorded or standby second source is a `PoolTwap`.
    function tightenDebtStressRiseBps(
        address asset,
        uint16 value
    ) external;

    /// @notice Lowers a debt asset's `debtStressRiseBps`.
    function loosenDebtStressRiseBps(
        address asset,
        uint16 value
    ) external;

    /// @notice Target health factor Avana's sizing assumes for a CDP Spoke.
    /// @return value WAD (0 for a Spoke with no value written).
    function aaveTargetHealthFactor(
        address spoke
    ) external view returns (uint256 value);

    /// @notice Minimum liquidation bonus Avana's sizing assumes for a CDP Spoke.
    /// @return value bps (0 for a Spoke with no value written).
    function minLiquidationBonus(
        address spoke
    ) external view returns (uint16 value);

    /// @notice Writes a CDP Spoke's expected Aave liquidation configuration, in either direction.
    /// @dev Reverts `UnknownSpoke` unless the MarketRegistry approves the Spoke.
    /// @param targetHealthFactor Expected `targetHealthFactor`, WAD.
    function setLiquidationExpectations(
        address spoke,
        uint256 targetHealthFactor,
        uint16 minLiquidationBonusBps
    ) external;

    /// @notice Regular pledge budget of a market.
    /// @return value 8-decimal USD.
    function marketUsdCap(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Rescue top-up budget of a market.
    /// @return value 8-decimal USD.
    function topUpSliceUsd(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Stress floor of a market.
    /// @return value 8-decimal USD per whole vault token.
    function stressFloorUsd(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Aggregate exposure cap of an underlying token across every market of a Hub on the chain.
    /// @return value 8-decimal USD.
    function tokenUsdCap(
        address hub,
        address token
    ) external view returns (uint256 value);

    /// @notice Chain default of the maximum Avana share of a pool's liquidity; 10,000 bps means off.
    function poolShareMaxBps() external view returns (uint16 value);

    /// @notice Minimum value of one pledge into a market; the RiskModule reverts `BelowMinPledge` below it.
    /// @return value 8-decimal USD.
    function minPledgeUsd(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Settlement parameters of one debt asset.
    /// @return p Rounding allowance, base units of `asset` (zeros for an unknown asset).
    function debtAssetParams(
        address asset
    ) external view returns (DebtReserveParams memory p);

    /// @notice Smallest input a swap-route slot must absorb within the slippage allowance to count as usable.
    /// @param token Pool token sold.
    /// @param debtAsset Debt asset bought.
    /// @param kind 0 primary, 1 backup.
    /// @return value Base units of `debtAsset` (0 for an unknown slot).
    function routeDepthThreshold(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view returns (uint256 value);

    /// @notice MarketRegistry fixed proxy address (implementation immutable).
    function MARKET_REGISTRY() external view returns (address registry);

    /// @notice Pool-share cap of one pool: the pool's override when one is set, otherwise `poolShareMaxBps()`.
    /// @dev Never above the chain default.
    /// @param poolKey `keccak256(abi.encode(integrationId, pool, poolId))`, as in `poolUnits(poolKey)`.
    function poolShareMaxBpsOf(
        bytes32 poolKey
    ) external view returns (uint16 value);

    /// @notice A market's speed limits changed.
    event MarketSpeedLimitsSet(
        uint256 indexed marketId, MarketSpeedLimits oldLimits, MarketSpeedLimits newLimits, bool tightened
    );

    /// @notice A (funding Hub, debt asset)'s borrow-speed limit changed.
    event DebtSpeedLimitSet(
        address indexed hub, address indexed asset, SpeedLimit oldLimit, SpeedLimit newLimit, bool tightened
    );

    /// @notice A market's speed limits.
    function marketSpeedLimits(
        uint256 marketId
    ) external view returns (MarketSpeedLimits memory limits);

    /// @notice A (funding Hub, debt asset)'s borrow-speed limit, in base units of the asset.
    function debtSpeedLimit(
        address hub,
        address asset
    ) external view returns (SpeedLimit memory limit);

    /// @notice Tightens a market's speed limits: no field looser, one strictly tighter.
    function tightenMarketSpeedLimits(
        uint256 marketId,
        MarketSpeedLimits calldata limits
    ) external;

    /// @notice Loosens a market's speed limits, or writes the first value: no field tighter, one strictly looser.
    function loosenMarketSpeedLimits(
        uint256 marketId,
        MarketSpeedLimits calldata limits
    ) external;

    /// @notice Tightens a (funding Hub, debt asset)'s borrow-speed limit: no field looser, one strictly tighter.
    function tightenDebtSpeedLimit(
        address hub,
        address asset,
        SpeedLimit calldata limit
    ) external;

    /// @notice Loosens a (funding Hub, debt asset)'s borrow-speed limit, or writes the first value.
    /// @dev Reverts `UnknownDebtReserve` when no approved debt reserve draws `asset` from `hub`.
    function loosenDebtSpeedLimit(
        address hub,
        address asset,
        SpeedLimit calldata limit
    ) external;

    /// @notice Returns a market's parameters.
    function getMarketParams(
        uint256 marketId
    ) external view returns (MarketParams memory params);

    /// @notice Feed-agreement tolerance of a token.
    function feedAgreementToleranceBps(
        address token
    ) external view returns (uint16 bps);

    /// @notice Collateral-factor input of a token.
    function tokenCollateralFactorBps(
        address token
    ) external view returns (uint16 bps);

    /// @notice Returns a feed definition.
    function getFeed(
        address feed
    ) external view returns (FeedDef memory def);

    /// @notice Liveness floor of a market's `slippageAllowanceBps`.
    function slippageAllowanceMinBps(
        uint256 marketId
    ) external view returns (uint16 bps);

    /// @notice Lower bound of a token's feed-agreement tolerance over every pair of routes it can have in force.
    function feedAgreementToleranceMinBps(
        address token
    ) external view returns (uint16 bps);

    /// @notice Oracle configuration of the market priced by `lpOracle`, read by that LPOracle on every evaluation.
    function getOracleConfig(
        address lpOracle
    ) external view returns (OracleConfig memory config);

    /// @notice Every input of one LPOracle evaluation in one read, laid out as in `OracleInputsLayout`.
    /// @dev A feed that is no market's LPOracle gets `marketId = 0`; a failed registry read reverts.
    /// @param tokens The feed's tokens in pool order.
    /// @param withSecondSources Include each token's second source (`getPriceState`, `poke`).
    function getOracleInputs(
        address lpOracle,
        address[] calldata tokens,
        bool withSecondSources
    ) external view returns (uint256[] memory words);

    /// @notice Borrow age limit of a Chainlink feed, never above its `feedMaxAge`.
    /// @return age Seconds.
    function borrowPriceMaxAge(
        address feed
    ) external view returns (uint32 age);

    /// @notice Liquidation age limit of a Chainlink feed: `feedHeartbeat + heartbeatMargin`.
    /// @return age Seconds.
    function liquidationPriceMaxAge(
        address feed
    ) external view returns (uint32 age);

    /// @notice A market's optional hard health-factor floor after a borrow or a withdrawal that leaves debt.
    /// @return value WAD, 0 when off.
    function hardHealthFloor(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Duration of the Cached state measured from the first failed read.
    /// @return value Seconds.
    function cachedWindow() external view returns (uint32 value);

    /// @notice Maximum liquidation pause while routes disagree.
    /// @return value Seconds.
    function disagreementPauseMax() external view returns (uint32 value);

    /// @notice Lower USD band level.
    /// @return value 8 decimals per 1 USD at peg.
    function usdBandLow() external view returns (uint256 value);

    /// @notice Upper USD band level.
    /// @return value 8 decimals per 1 USD at peg.
    function usdBandHigh() external view returns (uint256 value);

    /// @notice Recovery grace length.
    /// @return value Seconds.
    function graceDuration() external view returns (uint32 value);

    /// @notice Health factor below which accounts may be liquidated during grace.
    /// @return value WAD.
    function graceHealthFactor() external view returns (uint256 value);

    /// @notice Most flash premium the chain's IFlashSource may charge, as bps of the amount lent.
    function maxFlashFeeBps() external view returns (uint16 value);

    /// @notice Avana's share of realized liquidation surplus.
    function avanaFeeShareBps() external view returns (uint16 value);

    /// @notice Recipient of Avana's share.
    function feeRecipient() external view returns (address recipient);

    /// @notice Margin added to the feed-agreement lower bound.
    function feedAgreementMarginBps() external view returns (uint16 value);

    /// @notice Allowance subtracted from the recovery floor of a liquidation repaid in `asset`.
    /// @return value Base units of `asset`.
    function floorRoundingAllowance(
        address asset
    ) external view returns (uint256 value);

    /// @notice Liveness bound: lowest allowed `graceHealthFactor` (implementation constant).
    /// @return value WAD.
    function graceHealthFactorMin() external view returns (uint256 value);

    /// @notice Liveness bound: highest allowed `graceDuration` (implementation constant).
    /// @return value Seconds.
    function graceDurationMax() external view returns (uint32 value);

    /// @notice Liveness bound: lowest allowed `consistencyToleranceBps` (implementation constant).
    function consistencyToleranceMinBps() external view returns (uint16 value);

    /// @notice Upper bound of every feed's `heartbeatMargin` (implementation constant).
    /// @return value Seconds.
    function MAX_HEARTBEAT_MARGIN() external pure returns (uint32 value);

    /// @notice Second price source in force for a token: the standby while `onStandby(token)`, else the recorded one.
    function secondSource(
        address token
    ) external view returns (SecondSource memory source);

    /// @notice Reviewed standby second source of a token (`kind == None` when unset).
    function standbySecondSource(
        address token
    ) external view returns (SecondSource memory source);

    /// @notice Whether the token's standby second source is in force.
    /// @return active True after `useStandbySecondSource` and before `restoreSecondSource`.
    function onStandby(
        address token
    ) external view returns (bool active);

    /// @notice Timestamp of the last loosening of a step-limited parameter.
    /// @param paramKey `keccak256(abi.encode(name, scope))`, with `name` and `scope` as in `ParameterLoosened`.
    /// @return at Seconds (0 if never loosened).
    function lastLoosenedAt(
        bytes32 paramKey
    ) external view returns (uint64 at);

    /// @notice Largest decrease of a market's `hardHealthFloor` in one loosening (implementation constant).
    /// @return value WAD.
    function LOOSEN_HEALTH_FACTOR_STEP() external pure returns (uint256 value);

    /// @notice Largest ratio of a USD cap after one loosening to the cap before it (implementation constant).
    function LOOSEN_CAP_STEP_BPS() external pure returns (uint16 value);

    /// @notice Largest increase of `slippageAllowanceBps` in one loosening (implementation constant).
    function LOOSEN_SLIPPAGE_STEP_BPS() external pure returns (uint16 value);

    /// @notice The Avana timelock, the only holder of `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`.
    function TIMELOCK() external view returns (address timelock);
}
