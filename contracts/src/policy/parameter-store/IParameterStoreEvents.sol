// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreEvents
/// @notice Events of the ParameterStore. `caller` and `by` are `msg.sender`.
interface IParameterStoreEvents {
    /// @notice A token's second source in force changed between the recorded source and the standby.
    /// @param standby True when the standby is now in force.
    /// @param by The caller (a guardian, or the timelock when restoring).
    event SecondSourceSwitched(address indexed token, bool standby, address by);

    /// @notice A tighten setter succeeded.
    /// @param scope marketId, token, feed, `keccak256(spoke, debtReserveId)` or zero for a global parameter.
    /// @param caller `msg.sender`: the timelock, or the `APPLICATION_RISK_STEWARD` holder for a tightening.
    event ParameterTightened(bytes32 name, bytes32 scope, uint256 oldValue, uint256 newValue, address caller);

    /// @notice A loosen setter succeeded.
    /// @param scope Scope as in `ParameterTightened`.
    event ParameterLoosened(bytes32 name, bytes32 scope, uint256 oldValue, uint256 newValue, address caller);

    /// @notice A structural or initial setter succeeded.
    /// @param scope Scope as in `ParameterTightened`.
    event ParameterSet(bytes32 name, bytes32 scope, uint256 oldValue, uint256 newValue);

    /// @notice A cap tighten setter lowered a cap.
    /// @param capKind Cap name (for example "marketUsdCap").
    /// @param scope marketId, token address or zero for a global cap.
    event CapTightened(bytes32 capKind, bytes32 scope, uint256 oldValue, uint256 newValue, address caller);

    /// @notice A cap loosen or initial-cap setter raised or wrote a cap.
    /// @param scope marketId, token address or zero for a global cap.
    event CapLoosened(bytes32 capKind, bytes32 scope, uint256 oldValue, uint256 newValue, address caller);

    /// @notice `setStressFloorUsd` or `setInitialMarketCaps` wrote the stress floor.
    /// @param oldValue Previous floor, 8-decimal USD per whole vault token.
    /// @param newValue New floor, 8-decimal USD per whole vault token.
    event StressFloorSet(uint256 marketId, uint256 oldValue, uint256 newValue);

    /// @notice A feed definition was added or changed.
    /// @param maxAnswer Pinned maxAnswer: `min(aggregator().maxAnswer(), maxAnswerCap)`.
    /// @param feedHeartbeat Heartbeat, seconds.
    /// @param heartbeatMargin Freshness margin, seconds.
    /// @param feedMaxAge Maximum valid-answer age, seconds.
    /// @param borrowPriceMaxAge Borrow age limit, seconds.
    /// @param liquidationPriceMaxAge Liquidation age limit, seconds.
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
    /// @param token Pool token sold.
    /// @param debtAsset Debt asset bought.
    /// @param kind 0 primary, 1 backup.
    /// @param oldValue Previous threshold, base units of `debtAsset`.
    /// @param newValue New threshold, base units of `debtAsset`.
    event RouteDepthThresholdSet(
        uint256 indexed marketId, address token, address debtAsset, uint8 kind, uint256 oldValue, uint256 newValue
    );

    /// @notice A market's `minPledgeUsd` changed.
    /// @param oldValue Previous minimum, 8-decimal USD.
    /// @param newValue New minimum, 8-decimal USD.
    event MinPledgeUsdSet(uint256 indexed marketId, uint256 oldValue, uint256 newValue);

    /// @notice A debt asset's settlement parameters changed.
    /// @param floorRoundingAllowance New allowance, base units.
    event DebtAssetParamsSet(address indexed asset, uint256 floorRoundingAllowance);
}
