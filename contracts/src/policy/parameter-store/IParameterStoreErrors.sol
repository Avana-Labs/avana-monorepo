// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreErrors
/// @notice Errors of the ParameterStore.
interface IParameterStoreErrors {
    /// @notice `useStandbySecondSource` found no recorded standby for the token.
    error NoStandby(address token);

    /// @notice `useStandbySecondSource` found the standby already in force.
    error StandbyActive(address token);

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

    /// @notice The market's LPOracle rejected a new oracle configuration.
    /// @param failedChecks Bitmap returned by `LPOracle.checkConfig`.
    error OracleConfigRejected(address lpOracle, uint256 failedChecks);

    /// @notice A loosening moves its parameter further than one step.
    /// @param key `keccak256(abi.encode(name, scope))` of the parameter.
    error LoosenStepTooLarge(bytes32 key);

    /// @notice The parameter was loosened less than `normalDelay` ago.
    /// @param key `keccak256(abi.encode(name, scope))` of the parameter.
    /// @param nextAt First timestamp at which the parameter can be loosened again, seconds.
    error LoosenTooSoon(bytes32 key, uint256 nextAt);

    /// @notice A grant of `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` to an account other than `TIMELOCK`.
    error AdminRoleOnlyTimelock(bytes32 role, address account);

    /// @notice The Hub is not recorded in the MarketRegistry.
    error UnknownHub(address hub);

    /// @notice The CDP Spoke is not approved in the MarketRegistry.
    error UnknownSpoke(address spoke);

    /// @notice A logic contract was called directly instead of by the ParameterStore's delegatecall.
    error NotDelegated();
}
