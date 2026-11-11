// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreErrors
/// @notice Errors of the ParameterStore: direction, hard bounds, liquidation-liveness bounds, loosening steps, scope,
/// feed and LPOracle configuration checks, the fee recipient, the cap and stress-floor checks, admin-role grants and a
/// direct call to a logic contract.
interface IParameterStoreErrors {
    /// @notice `useStandbySecondSource` found no recorded standby for the token.
    /// @param token The token.
    /// @custom:spec REQ-PSTORE-029
    error NoStandby(address token);

    /// @notice `useStandbySecondSource` found the standby already in force.
    /// @param token The token.
    /// @custom:spec REQ-PSTORE-029
    error StandbyActive(address token);

    /// @notice A tighten value is not strictly safer than the current value.
    /// @custom:spec REQ-CONFIG-051, REQ-CONFIG-067, REQ-RISK-042
    error NotStricter();

    /// @notice A loosen value is not strictly looser than the current value.
    /// @custom:spec REQ-CONFIG-067, REQ-RISK-043
    error NotLooser();

    /// @notice A value is outside the hard-coded bounds of the implementation.
    /// @custom:spec REQ-CONFIG-050, REQ-CONFIG-067, REQ-RISK-044
    error OutOfBounds();

    /// @notice A value crosses a liquidation-liveness bound, including the two-leg inequality and the buy-slippage floor.
    /// @custom:spec REQ-CONFIG-052, REQ-CONFIG-067, REQ-PSTORE-015, REQ-PSTORE-021
    error LivenessBound();

    /// @notice The fee recipient is the zero address, an Avana contract, the Hub or a PositionProxy.
    /// @param recipient Rejected address.
    /// @custom:spec REQ-CONFIG-056
    error InvalidFeeRecipient(address recipient);

    /// @notice The market is unknown to the MarketRegistry.
    /// @param marketId Market identifier.
    /// @custom:spec REQ-PSTORE-011
    error UnknownMarket(uint256 marketId);

    /// @notice The token is not listed in the MarketRegistry.
    /// @param token Token address.
    /// @custom:spec REQ-PSTORE-012
    error TokenNotListed(address token);

    /// @notice The feed has no definition.
    /// @param feed Chainlink aggregator proxy.
    /// @custom:spec REQ-PSTORE-009
    error UnknownFeed(address feed);

    /// @notice A feed definition failed a check (normalised minimum below 1, or the age ordering).
    /// @param feed Chainlink aggregator proxy.
    /// @param check Name of the failed check.
    /// @custom:spec REQ-CONFIG-022, REQ-CONFIG-023
    error InvalidFeed(address feed, bytes32 check);

    /// @notice The debt reserve is not enabled in the MarketRegistry.
    /// @param spoke CDP Spoke.
    /// @param debtReserveId Debt reserve identifier.
    /// @custom:spec REQ-PSTORE-006
    error UnknownDebtReserve(address spoke, uint256 debtReserveId);

    /// @notice An initial setter targeted a market that is not `Registered` or a token that already has a cap.
    /// @custom:spec REQ-RISK-041, REQ-PSTORE-004, REQ-PSTORE-012
    error NotInListing();

    /// @notice The Hub `addCap` would no longer satisfy SPEC-CAP-006 with the new value.
    /// @custom:spec REQ-RISK-044, REQ-RISK-045, SPEC-CAP-006
    error AddCapTooSmall();

    /// @notice The stress floor can be raised only while the market's vault-token supply is 0.
    /// @param marketId Market identifier.
    /// @custom:spec REQ-RISK-045
    error SupplyNotZero(uint256 marketId);

    /// @notice The market's LPOracle rejected a new oracle configuration.
    /// @param lpOracle The LPOracle feed.
    /// @param failedChecks Bitmap returned by `LPOracle.checkConfig`.
    /// @custom:spec REQ-PSTORE-009, REQ-PSTORE-013, REQ-ORACLE-077
    error OracleConfigRejected(address lpOracle, uint256 failedChecks);

    /// @notice A loosening moves its parameter further than one step: `hardHealthFloor` down by more than
    /// 0.03e18, a USD cap above 1.5 times its current value, or `slippageAllowanceBps` up by more than 25 bps.
    /// @param key `keccak256(abi.encode(name, scope))` of the parameter.
    /// @custom:spec REQ-PSTORE-017, Q-246
    error LoosenStepTooLarge(bytes32 key);

    /// @notice The parameter was loosened less than `normalDelay` ago.
    /// @param key `keccak256(abi.encode(name, scope))` of the parameter.
    /// @param nextAt First timestamp at which the parameter can be loosened again, seconds.
    /// @custom:spec REQ-PSTORE-017, Q-246
    error LoosenTooSoon(bytes32 key, uint256 nextAt);

    /// @notice A grant of `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` to an account other than `TIMELOCK`.
    /// @param role Role being granted.
    /// @param account Rejected grantee.
    /// @custom:spec REQ-PSTORE-001, Q-259
    error AdminRoleOnlyTimelock(bytes32 role, address account);

    /// @notice The Hub is not recorded in the MarketRegistry.
    /// @param hub The Hub a Hub-scoped setter named.
    /// @custom:spec REQ-RISK-044, REQ-PSTORE-026
    error UnknownHub(address hub);

    /// @notice The CDP Spoke is not approved in the MarketRegistry.
    /// @param spoke CDP Spoke.
    /// @custom:spec REQ-PSTORE-022
    error UnknownSpoke(address spoke);

    /// @notice A logic contract was called directly instead of by the ParameterStore's delegatecall.
    /// @custom:spec REQ-PSTORE-001
    error NotDelegated();
}
