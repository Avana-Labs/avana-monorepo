// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveAdapterErrors
/// @notice Errors of the AaveAdapter's call bounds, pause gate and backing checks. RiskModule, Collateralization,
/// proxy, Spoke, Hub and token errors propagate unchanged.
interface IAaveAdapterErrors {
    /// @notice A pledge or re-credit by an account with no debt, or a borrow, while the market's home Hub is Frozen.
    /// @custom:spec REQ-ADAPTER-045, REQ-ADAPTER-072, BOR-F-018, Q-227, Q-254
    error ApplicationFrozen();

    /// @notice A borrow or withdraw-with-debt or removal with debt while the market's home Hub (or, for a borrow, the
    /// debt reserve's funding Hub) is Paused, or a pledge, top-up, re-credit or repay with collateral while that Hub is
    /// Paused with reason `MintPathSuspect`. Pause scope is per Hub, so a pause of one Hub stops no other Hub's
    /// markets (AMMN-FLOW-19).
    /// @custom:spec REQ-ADAPTER-046, REQ-ADAPTER-073, REQ-ADAPTER-083, BOR-F-018, WDR-F-020, Q-227, Q-252
    error ApplicationPaused();

    /// @notice `block.timestamp > deadline`.
    /// @param deadline The expired deadline.
    /// @custom:spec REQ-PROXY-058, BOR-F-003, REP-F-003, WDR-F-003
    error DeadlineExpired(uint256 deadline);

    /// @notice `expectedNonce` differs from the proxy's stored borrow nonce.
    /// @param currentNonce The stored nonce.
    /// @param expectedNonce The nonce the wallet signed for.
    /// @custom:spec REQ-PROXY-015, REQ-PROXY-059, BOR-F-004
    error BadNonce(uint256 currentNonce, uint256 expectedNonce);

    /// @notice An amount or units argument is 0, or a partial repay with debt has `maxRepaySpend == 0`.
    /// @custom:spec REQ-PROXY-016, REQ-PROXY-060, BOR-F-005, REP-F-005, WDR-F-006
    error ZeroAmount();

    /// @notice The borrow receiver is refused by the receiver rule.
    /// @param receiver The rejected receiver.
    /// @custom:spec REQ-PROXY-017, REQ-PROXY-061, BOR-F-006
    error InvalidReceiver(address receiver);

    /// @notice The wallet has no proxy for the market.
    /// @param wallet The wallet (the caller, or `borrower` for repay).
    /// @param marketId The market.
    /// @custom:spec REQ-ADAPTER-066, REQ-PROXY-057, BOR-F-002, REP-F-011, WDR-F-002
    error NoProxy(address wallet, uint256 marketId);

    /// @notice The market's CDP Spoke is not approved in the MarketRegistry.
    /// @param spoke The market's Spoke.
    /// @custom:spec REQ-ADAPTER-065, REQ-ADAPTER-077
    error UnknownSpoke(address spoke);

    /// @notice The debt reserve is not approved for the account's CDP Spoke.
    /// @param spoke The CDP Spoke.
    /// @param reserveId The rejected reserve.
    /// @custom:spec REQ-ADAPTER-067, REQ-PROXY-062, BOR-F-005, REP-F-013
    error UnknownDebtReserve(address spoke, uint256 reserveId);

    /// @notice The market is not registered with an approved CDP Spoke, or a vault token is not the market's.
    /// @param marketId The rejected market.
    /// @custom:spec REQ-ADAPTER-065, REQ-ADAPTER-070, REQ-PROXY-062, WDR-F-004
    error UnknownMarket(uint256 marketId);

    /// @notice The AMM integration named in a `PositionRef` is not the market's integration.
    /// @param marketId The market.
    /// @param integrationId The rejected integration.
    /// @custom:spec REQ-ADAPTER-065, Q-376
    error IntegrationMismatch(uint256 marketId, uint32 integrationId);

    /// @notice `burnSeized` was called by an address other than LPVaultSwap or while LPVaultSwap does not hold the Lock,
    /// or a deleverage callback by an address other than LPVaultSwap or while the Adapter does not hold the Lock.
    /// @custom:spec REQ-ADAPTER-070, REQ-ADAPTER-081, REQ-ADAPTER-092, REQ-PROXY-075
    error NotLPVaultSwap();

    /// @notice The Lock is held when an entry point starts.
    /// @dev Raised by the Lock's `acquire` and propagated; declared here so the app decodes it from the Adapter ABI.
    /// @param holder The current holder.
    /// @custom:spec REQ-PROXY-048, REQ-PROXY-076, BOR-F-001, REP-F-001, WDR-F-001
    error LockHeld(address holder);

    /// @notice A repay-all found debt above `maxRepaySpend`; nothing moved.
    /// @param debt Live debt of the reserve, base units.
    /// @param maxRepaySpend The payer's cap, base units.
    /// @custom:spec REQ-PROXY-028, REQ-PROXY-070, REP-F-006, SPEC-PROXY-003
    error RepayExceedsMax(uint256 debt, uint256 maxRepaySpend);

    /// @notice Debt remains in a reserve after a repay-all, or before the withdrawal of `repayAllAndWithdraw`.
    /// @param reserveId The debt reserve.
    /// @param debt Remaining debt, base units.
    /// @custom:spec REQ-PROXY-031, REQ-PROXY-071, REQ-ADAPTER-071, REP-F-010, WDR-F-021
    error DebtRemaining(uint256 reserveId, uint256 debt);

    /// @notice An amount the Adapter verifies differs from the expected one (borrow drawn, repay funds received).
    /// @param expected The expected amount.
    /// @param actual The measured amount.
    /// @custom:spec REQ-PROXY-021, REQ-PROXY-029, REQ-PROXY-072, BOR-F-011, REP-F-009
    error UnitsMismatch(uint256 expected, uint256 actual);

    /// @notice After a pledge, withdrawal, partial removal, re-credit or repay with collateral, the vault token's supply
    /// exceeds credited plus pending units, or the market's backing gap changed across the call.
    /// @param totalSupply The vault token's total supply.
    /// @param totalCredited Collateralization's total credited units.
    /// @param pendingUnits Collateralization's pending-settlement units.
    /// @custom:spec REQ-ADAPTER-069, REQ-ADAPTER-075, SPEC-PROXY-008, WDR-F-016, INV-001, INV-080, Q-257
    error BackingMismatch(uint256 totalSupply, uint256 totalCredited, uint256 pendingUnits);

    /// @notice The proxy's supplied shares did not rise by exactly the credited units in a pledge.
    /// @custom:spec REQ-ADAPTER-068, REQ-PROXY-072
    error SupplyIncomplete();

    /// @notice `debtReserveIds` and `maxRepaySpends` differ in length, or a minimum-amount array's length is not the
    /// market's token count.
    /// @custom:spec REQ-ADAPTER-071, REQ-ADAPTER-076, WDR-F-021
    error LengthMismatch();

    /// @notice `initialize` was called with a zero timelock.
    /// @custom:spec REQ-ADAPTER-074
    error ZeroAddress();

    /// @notice A frozen address tried new activity: as caller of a borrow, withdraw-with-debt, removal with debt or
    /// repay with collateral, or as a borrow receiver.
    /// @param account The frozen address.
    /// @custom:spec REQ-ADAPTER-082, REQ-ADAPTER-087, BOR-016, Q-242
    error AddressIsFrozen(address account);

    /// @notice `repayWithCollateral` named a debt reserve in which the account owes nothing.
    /// @param debtReserveId The debt reserve.
    /// @custom:spec REQ-ADAPTER-080, REQ-ADAPTER-091, REP-F-013, Q-255
    error NothingToRepay(uint256 debtReserveId);

    /// @notice After a repay with collateral that leaves debt, Aave's health factor is below `max(before, minHealthFactor)`.
    /// @param before Health factor before the call, WAD.
    /// @param afterCall Health factor after the call, WAD.
    /// @custom:spec REQ-ADAPTER-080, REQ-ADAPTER-091, SPEC-PROXY-009, REP-F-021, Q-255
    error HealthFactorNotImproved(uint256 before, uint256 afterCall);

    /// @notice A deleverage callback outside an open session, with other arguments, or a second time; or a session that
    /// closed without both steps.
    /// @custom:spec REQ-ADAPTER-081, REQ-ADAPTER-092, Q-255
    error NoDeleverageSession();

    /// @notice `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` granted to an address other than `TIMELOCK`.
    /// @param role The role.
    /// @param account The rejected grantee.
    /// @custom:spec REQ-ADAPTER-084, REQ-ADAPTER-093, Q-259
    error AdminRoleOnlyTimelock(bytes32 role, address account);

    /// @notice A balance measured around a `proxy.execute` step moved by other than the expected amount.
    /// @custom:spec REQ-PROXY-042, REQ-PROXY-087, REQ-PROXY-088, REQ-PROXY-089, REQ-ADAPTER-007
    error BalanceDeltaMismatch();

    /// @notice After a supply the Spoke does not report the vault-token reserve enabled as collateral.
    /// @param reserveId The vault-token reserve.
    /// @custom:spec REQ-PROXY-043, REQ-PROXY-095
    error CollateralNotEnabled(uint256 reserveId);
}
