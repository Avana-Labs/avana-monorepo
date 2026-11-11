// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {FeedDef} from "./types/FeedDef.sol";
import {MarketParams} from "./types/MarketParams.sol";

/// @title IParameterStoreViews
/// @notice Risk parameters per market, token, feed and globally, the liquidation-liveness bounds, and the oracle
/// configuration each LPOracle reads.
/// @dev Every view is `view`, never reverts for a listed market and returns the values in force at the current block.
interface IParameterStoreViews {
    /// @notice Returns a market's parameters.
    /// @param marketId Market identifier.
    /// @return params Stored parameters.
    /// @custom:spec REQ-PSTORE-011
    function getMarketParams(
        uint256 marketId
    ) external view returns (MarketParams memory params);

    /// @notice Feed-agreement tolerance of a token.
    /// @param token Pool token.
    /// @return bps Stored tolerance; no override exists.
    /// @custom:spec REQ-CONFIG-024, REQ-CONFIG-057
    function feedAgreementToleranceBps(
        address token
    ) external view returns (uint16 bps);

    /// @notice Collateral-factor input of a token.
    /// @param token Pool token.
    /// @return bps Collateral factor.
    /// @custom:spec REQ-CONFIG-019, REQ-CONFIG-020
    function tokenCollateralFactorBps(
        address token
    ) external view returns (uint16 bps);

    /// @notice Returns a feed definition.
    /// @param feed Chainlink aggregator proxy.
    /// @return def Stored definition (`decimals == 0` when the feed has none).
    /// @custom:spec REQ-CONFIG-022, REQ-CONFIG-023
    function getFeed(
        address feed
    ) external view returns (FeedDef memory def);

    /// @notice Liveness floor of a market's `slippageAllowanceBps`, stored per market at listing (Structural).
    /// @param marketId Market identifier.
    /// @return bps Floor.
    /// @custom:spec REQ-CONFIG-041, REQ-CONFIG-052, Q-209
    function slippageAllowanceMinBps(
        uint256 marketId
    ) external view returns (uint16 bps);

    /// @notice Lower bound of a token's feed-agreement tolerance over every pair of routes it can have in force:
    /// `max(dP + dA, dS + dA, dP + dS) + feedAgreementMarginBps`, with `d` the summed deviation thresholds of the
    /// recorded primary, alternate and standby routes (the standby can replace either slot at once).
    /// @param token Pool token.
    /// @return bps Lower bound.
    /// @custom:spec REQ-CONFIG-024, REQ-CONFIG-052
    function feedAgreementToleranceMinBps(
        address token
    ) external view returns (uint16 bps);

    /// @notice Oracle configuration of the market priced by `lpOracle`, read by that LPOracle on every evaluation.
    /// @param lpOracle The LPOracle feed proxy.
    /// @return config Routes, configured tolerances, windows, bands and per-feed age limits.
    /// @custom:spec REQ-CONFIG-072, REQ-PSTORE-011, REQ-ORACLE-017, REQ-ORACLE-043
    function getOracleConfig(
        address lpOracle
    ) external view returns (OracleConfig memory config);

    /// @notice The inputs an LPOracle evaluation applies, in one read, as the words of `OracleInputsLayout`: the
    /// market of `lpOracle`, its consistency settings, the band, the timers and the sequencer, and per token of
    /// `tokens` its tolerance, its routes in force, route version and replaced slot as the MarketRegistry returns them
    /// in this call, each leg's feed definition and, when `withSecondSources`, the second source in force with its
    /// feed definition.
    /// @dev The LPOracle passes its own tokens in pool order. A feed that is no market's LPOracle gets `marketId = 0`
    /// and zero words; a failed registry read reverts the call, which the LPOracle reads as a failed configuration.
    /// @param lpOracle The LPOracle feed proxy.
    /// @param tokens The feed's tokens in pool order.
    /// @param withSecondSources Include each token's second source (`getPriceState`, `poke`).
    /// @return words The inputs.
    /// @custom:spec REQ-PSTORE-033, REQ-CONFIG-072, REQ-PSTORE-011, REQ-PSTORE-029, REQ-ORACLE-094
    function getOracleInputs(
        address lpOracle,
        address[] calldata tokens,
        bool withSecondSources
    ) external view returns (uint256[] memory words);

    /// @notice Borrow age limit of a Chainlink feed: `feedHeartbeat + heartbeatMargin` when `setFeed` writes it, lower
    /// only after a tightening, never above the feed's `feedMaxAge`. Example: the USDC/USD feed on Ethereum with a
    /// heartbeat of 82,800 s and a margin of 1,800 s has a limit of 84,600 s.
    /// @param feed Chainlink aggregator proxy.
    /// @return age Seconds.
    /// @custom:spec REQ-CONFIG-023, REQ-HUB-104, SPEC-ORC-019, Q-182, Q-322
    function borrowPriceMaxAge(
        address feed
    ) external view returns (uint32 age);

    /// @notice Liquidation age limit of a Chainlink feed: always `feedHeartbeat + heartbeatMargin` (`SPEC-ORC-019`).
    /// @param feed Chainlink aggregator proxy.
    /// @return age Seconds.
    /// @custom:spec REQ-CONFIG-023, REQ-HUB-104, Q-182
    function liquidationPriceMaxAge(
        address feed
    ) external view returns (uint32 age);

    /// @notice A market's optional hard health-factor floor after a borrow or a withdrawal that leaves debt.
    /// @dev 0 means off, the default and the launch value: those operations then need only Aave's HF 1.00 and the
    /// caller's `minHealthFactor`. When set, within [1e18, 1.25e18]. The Lens previews a recommended borrow at
    /// HF 1.10 either way (Q-398).
    /// @param marketId Market identifier.
    /// @return value WAD, 0 when off.
    /// @custom:spec REQ-CONFIG-049, REQ-PSTORE-031, Q-229, Q-398
    function hardHealthFloor(
        uint256 marketId
    ) external view returns (uint256 value);

    /// @notice Duration of the Cached state measured from the first failed read.
    /// @return value Seconds.
    /// @custom:spec SPEC-ORC-013
    function cachedWindow() external view returns (uint32 value);

    /// @notice Maximum liquidation pause while routes disagree.
    /// @return value Seconds.
    /// @custom:spec REQ-ORACLE-022, REQ-ORACLE-023
    function disagreementPauseMax() external view returns (uint32 value);

    /// @notice Lower USD band level.
    /// @return value 8 decimals per 1 USD at peg.
    /// @custom:spec SPEC-ORC-011
    function usdBandLow() external view returns (uint256 value);

    /// @notice Upper USD band level.
    /// @return value 8 decimals per 1 USD at peg.
    /// @custom:spec SPEC-ORC-011
    function usdBandHigh() external view returns (uint256 value);

    /// @notice Recovery grace length.
    /// @return value Seconds.
    /// @custom:spec REQ-ORACLE-034
    function graceDuration() external view returns (uint32 value);

    /// @notice Health factor below which accounts may be liquidated during grace.
    /// @return value WAD.
    /// @custom:spec REQ-SWAP-009
    function graceHealthFactor() external view returns (uint256 value);

    /// @notice Most flash premium the chain's IFlashSource may charge, as bps of the amount lent, for any debt asset.
    /// @dev The flash source checks `phi × 1e4 ≤ maxFlashFeeBps × F` before every loan, with `phi` the premium and `F`
    /// the amount lent, both in base units; the check is exact, with no division and no rounding. Example: the Aave V3
    /// Pool premium is 5 bps; with `maxFlashFeeBps = 10`, a 100,000 USDC loan has `phi = 50` USDC and `50e6 × 1e4 =
    /// 5e11 ≤ 10 × 100,000e6 = 1e12`, so it passes; a premium above 100 USDC fails. The bound keeps a governance change
    /// of the lender's premium from eating the liquidation surplus that funds keepers and Avana's fee.
    /// @return value bps.
    /// @custom:spec REQ-SWAP-012, REQ-PSTORE-024, REQ-FLASH-002
    function maxFlashFeeBps() external view returns (uint16 value);

    /// @notice Avana's share of realized liquidation surplus.
    /// @return value bps.
    /// @custom:spec SPEC-LIQ-009
    function avanaFeeShareBps() external view returns (uint16 value);

    /// @notice Recipient of Avana's share.
    /// @return recipient Address.
    /// @custom:spec REQ-SWAP-028
    function feeRecipient() external view returns (address recipient);

    /// @notice Margin added to the feed-agreement lower bound.
    /// @return value bps.
    /// @custom:spec REQ-CONFIG-024
    function feedAgreementMarginBps() external view returns (uint16 value);

    /// @notice Allowance subtracted from the recovery floor of a liquidation repaid in `asset`.
    /// @param asset Debt asset.
    /// @return value Base units of `asset`.
    /// @custom:spec SPEC-LIQ-005, Q-380
    function floorRoundingAllowance(
        address asset
    ) external view returns (uint256 value);

    /// @notice Liveness bound: lowest allowed `graceHealthFactor` (implementation constant).
    /// @return value WAD.
    /// @custom:spec REQ-CONFIG-052
    function graceHealthFactorMin() external view returns (uint256 value);

    /// @notice Liveness bound: highest allowed `graceDuration` (implementation constant).
    /// @return value Seconds.
    /// @custom:spec REQ-CONFIG-052
    function graceDurationMax() external view returns (uint32 value);

    /// @notice Liveness bound: lowest allowed `consistencyToleranceBps` (implementation constant, 10).
    /// @return value Bps.
    /// @custom:spec REQ-CONFIG-052
    function consistencyToleranceMinBps() external view returns (uint16 value);

    /// @notice Upper bound of every feed's `heartbeatMargin` (implementation constant).
    /// @return value 3,600 seconds.
    /// @custom:spec REQ-CONFIG-023, SPEC-ORC-019, Q-322
    function MAX_HEARTBEAT_MARGIN() external pure returns (uint32 value);

    /// @notice Independent second price source in force for a pool token or a debt asset with a DebtOracle: the
    /// standby while `onStandby(token)`, else the recorded source.
    /// @param token The token.
    /// @return source The configured source (`kind == None` when unset).
    /// @custom:spec REQ-PSTORE-028, REQ-ORACLE-100, SPEC-ORC-020, Q-323
    function secondSource(
        address token
    ) external view returns (SecondSource memory source);

    /// @notice Reviewed standby second source of a token (`kind == None` when unset).
    /// @param token The token.
    /// @return source The standby.
    /// @custom:spec REQ-PSTORE-029, EMG-103
    function standbySecondSource(
        address token
    ) external view returns (SecondSource memory source);

    /// @notice Whether the token's standby second source is in force.
    /// @param token The token.
    /// @return active True after `useStandbySecondSource` and before `restoreSecondSource`.
    /// @custom:spec REQ-PSTORE-029
    function onStandby(
        address token
    ) external view returns (bool active);

    /// @notice Timestamp of the last loosening of a step-limited parameter.
    /// @param paramKey `keccak256(abi.encode(name, scope))`, with `name` and `scope` as in `ParameterLoosened`.
    /// @return at Seconds (0 if never loosened).
    /// @custom:spec REQ-PSTORE-017, Q-246
    function lastLoosenedAt(
        bytes32 paramKey
    ) external view returns (uint64 at);

    /// @notice Largest decrease of a market's `hardHealthFloor` in one loosening (implementation constant).
    /// @return value 0.03e18 (WAD).
    /// @custom:spec REQ-PSTORE-017, Q-246
    function LOOSEN_HEALTH_FACTOR_STEP() external pure returns (uint256 value);

    /// @notice Largest ratio of a USD cap after one loosening to the cap before it (implementation constant).
    /// @return value 15,000 bps (1.5 times).
    /// @custom:spec REQ-PSTORE-017, Q-246
    function LOOSEN_CAP_STEP_BPS() external pure returns (uint16 value);

    /// @notice Largest increase of `slippageAllowanceBps` in one loosening
    /// (implementation constant).
    /// @return value 25 bps.
    /// @custom:spec REQ-PSTORE-017, Q-246
    function LOOSEN_SLIPPAGE_STEP_BPS() external pure returns (uint16 value);

    /// @notice The Avana timelock, the only holder of `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` (implementation
    /// immutable); its `normalDelay()` spaces loosenings.
    /// @return timelock Address.
    /// @custom:spec REQ-PSTORE-001, REQ-PSTORE-017, Q-259
    function TIMELOCK() external view returns (address timelock);
}
