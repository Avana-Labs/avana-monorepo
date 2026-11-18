// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {FeedDef} from "./types/FeedDef.sol";
import {MarketParams} from "./types/MarketParams.sol";

/// @title IParameterStoreViews
/// @notice Risk parameters per market, token, feed and chain, and the oracle configuration each LPOracle reads.
interface IParameterStoreViews {
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
