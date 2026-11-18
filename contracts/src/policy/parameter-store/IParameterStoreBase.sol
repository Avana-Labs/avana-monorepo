// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreBase
/// @notice Errors and events of ParameterStore, shared with its contracts.
interface IParameterStoreBase {
    /// @notice A tighten value is not strictly safer than the current value.
    error NotStricter();

    /// @notice A loosen value is not strictly looser than the current value.
    error NotLooser();

    /// @notice A value is outside the hard-coded bounds of the implementation.
    error OutOfBounds();

    /// @notice A value crosses a liquidation-liveness bound.
    error LivenessBound();

    /// @notice The fee recipient is the zero address, an Avana contract, the Hub or a PositionProxy.
    error InvalidFeeRecipient(address recipient);

    /// @notice The market is unknown to the MarketRegistry.
    error UnknownMarket(uint256 marketId);

    /// @notice The token is not listed in the MarketRegistry.
    error TokenNotListed(address token);

    /// @notice The feed has no definition.
    error UnknownFeed(address feed);

    /// @notice A feed definition failed a check (normalised minimum below 1, or the age ordering).
    error InvalidFeed(address feed, bytes32 check);

    /// @notice The debt reserve is not enabled in the MarketRegistry.
    error UnknownDebtReserve(address spoke, uint256 debtReserveId);

    /// @notice An initial setter targeted a market that is not `Registered` or a token that already has a cap.
    error NotInListing();

    /// @notice The Hub `addCap` would be too small for the new value.
    error AddCapTooSmall();

    /// @notice The stress floor can be raised only while the market's vault-token supply is 0.
    error SupplyNotZero(uint256 marketId);

    /// @notice A loosening moves its parameter further than one step.
    /// @param key `keccak256(abi.encode(name, scope))` of the parameter.
    error LoosenStepTooLarge(bytes32 key);

    /// @notice The parameter was loosened less than `LOOSEN_SPACING` (5 days) ago.
    /// @param key `keccak256(abi.encode(name, scope))` of the parameter.
    /// @param nextAt First timestamp at which the parameter can be loosened again, seconds.
    error LoosenTooSoon(bytes32 key, uint256 nextAt);

    /// @notice The Hub is not recorded in the MarketRegistry.
    error UnknownHub(address hub);

    /// @notice A logic contract was called directly instead of by the ParameterStore's delegatecall.
    error NotDelegated();

    /// @notice A tighten setter succeeded.
    /// @param scope marketId, token, feed, `keccak256(spoke, debtReserveId)` or zero for a global parameter.
    /// @param caller `msg.sender`: the governance Safe, or the risk steward for a tightening.
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
