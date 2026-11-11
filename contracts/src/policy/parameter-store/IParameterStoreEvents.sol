// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreEvents
/// @notice Events of the ParameterStore: parameter, cap, stress-floor, feed, depth-threshold, `minPledgeUsd`, buy
/// slippage changes. `caller` and `by` are `msg.sender`: the timelock, the risk steward for a tighten setter or
/// `setAvanaFeeShareBps`, or a pause guardian for `useStandbySecondSource`.
interface IParameterStoreEvents {
    /// @notice A token's second source in force changed between the recorded source and the standby.
    /// @param token The token.
    /// @param standby True when the standby is now in force.
    /// @param by The caller (a guardian, or the timelock when restoring).
    /// @custom:spec REQ-PSTORE-029
    event SecondSourceSwitched(address indexed token, bool standby, address by);

    /// @notice A tighten setter succeeded.
    /// @param name Parameter name.
    /// @param scope marketId, token, feed, `keccak256(spoke, debtReserveId)` or zero for a global parameter.
    /// @param oldValue Previous value.
    /// @param newValue New value.
    /// @param caller `msg.sender`: the timelock, or the `APPLICATION_RISK_STEWARD` holder for a tightening.
    /// @custom:spec REQ-CONFIG-051
    event ParameterTightened(bytes32 name, bytes32 scope, uint256 oldValue, uint256 newValue, address caller);

    /// @notice A loosen setter succeeded.
    /// @param name Parameter name.
    /// @param scope Scope as in `ParameterTightened`.
    /// @param oldValue Previous value.
    /// @param newValue New value.
    /// @param caller The timelock.
    /// @custom:spec REQ-CONFIG-053
    event ParameterLoosened(bytes32 name, bytes32 scope, uint256 oldValue, uint256 newValue, address caller);

    /// @notice A structural or initial setter succeeded.
    /// @param name Parameter name.
    /// @param scope Scope as in `ParameterTightened`.
    /// @param oldValue Previous value.
    /// @param newValue New value.
    /// @custom:spec REQ-CONFIG-054, REQ-PSTORE-004
    event ParameterSet(bytes32 name, bytes32 scope, uint256 oldValue, uint256 newValue);

    /// @notice A cap tighten setter lowered a cap.
    /// @param capKind Cap name (for example "marketUsdCap").
    /// @param scope marketId, token address or zero for a global cap.
    /// @param oldValue Previous value.
    /// @param newValue New value.
    /// @param caller `msg.sender`: the timelock, or the `APPLICATION_RISK_STEWARD` holder for a tightening.
    /// @custom:spec REQ-RISK-042
    event CapTightened(bytes32 capKind, bytes32 scope, uint256 oldValue, uint256 newValue, address caller);

    /// @notice A cap loosen or initial-cap setter raised or wrote a cap.
    /// @param capKind Cap name.
    /// @param scope marketId, token address or zero for a global cap.
    /// @param oldValue Previous value.
    /// @param newValue New value.
    /// @param caller The timelock.
    /// @custom:spec REQ-RISK-041, REQ-RISK-043
    event CapLoosened(bytes32 capKind, bytes32 scope, uint256 oldValue, uint256 newValue, address caller);

    /// @notice `setStressFloorUsd` or `setInitialMarketCaps` wrote the stress floor.
    /// @param marketId Market identifier.
    /// @param oldValue Previous floor, 8-decimal USD per whole vault token.
    /// @param newValue New floor, 8-decimal USD per whole vault token.
    /// @custom:spec REQ-RISK-045
    event StressFloorSet(uint256 marketId, uint256 oldValue, uint256 newValue);

    /// @notice A feed definition was added or changed.
    /// @param feed Chainlink aggregator proxy.
    /// @param decimals Pinned decimals.
    /// @param minAnswer Pinned minAnswer.
    /// @param maxAnswer Pinned maxAnswer: `min(aggregator().maxAnswer(), maxAnswerCap)`.
    /// @param feedHeartbeat Heartbeat, seconds.
    /// @param heartbeatMargin Freshness margin, seconds (at most `MAX_HEARTBEAT_MARGIN`, 3,600).
    /// @param feedMaxAge Maximum valid-answer age, seconds.
    /// @param feedDeviationThresholdBps Deviation threshold, bps.
    /// @param heartbeatDriftBps Heartbeat drift, bps.
    /// @param borrowPriceMaxAge Borrow age limit, seconds.
    /// @param liquidationPriceMaxAge Liquidation age limit, seconds.
    /// @custom:spec REQ-CONFIG-022, REQ-CONFIG-023
    event FeedConfigured(
        address feed,
        uint8 decimals,
        int256 minAnswer,
        int256 maxAnswer,
        uint32 feedHeartbeat,
        uint16 heartbeatMargin,
        uint32 feedMaxAge,
        uint16 feedDeviationThresholdBps,
        uint16 heartbeatDriftBps,
        uint32 borrowPriceMaxAge,
        uint32 liquidationPriceMaxAge
    );

    /// @notice A swap-route slot's depth threshold changed.
    /// @param marketId Market identifier.
    /// @param token Pool token sold.
    /// @param debtAsset Debt asset bought.
    /// @param kind 0 primary, 1 backup.
    /// @param oldValue Previous threshold, 8-decimal USD.
    /// @param newValue New threshold, 8-decimal USD.
    /// @custom:spec REQ-CONFIG-070, REQ-PSTORE-007, Q-379
    event RouteDepthThresholdSet(
        uint256 indexed marketId, address token, address debtAsset, uint8 kind, uint256 oldValue, uint256 newValue
    );

    /// @notice A market's `minPledgeUsd` changed.
    /// @param marketId Market identifier.
    /// @param oldValue Previous minimum, 8-decimal USD.
    /// @param newValue New minimum, 8-decimal USD.
    /// @custom:spec REQ-PSTORE-005
    event MinPledgeUsdSet(uint256 indexed marketId, uint256 oldValue, uint256 newValue);

    /// @notice A debt asset's settlement parameters changed.
    /// @param asset Debt asset.
    /// @param floorRoundingAllowance New allowance, base units.
    /// @custom:spec REQ-PSTORE-006, Q-380
    event DebtAssetParamsSet(address indexed asset, uint256 floorRoundingAllowance);
}
