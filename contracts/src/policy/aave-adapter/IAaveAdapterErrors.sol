// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveAdapterErrors
/// @notice Errors of the AaveAdapter; RiskModule, Collateralization, Spoke and token errors propagate unchanged.
interface IAaveAdapterErrors {
    /// @notice A pledge or re-credit by an account with no debt, or a borrow, while the market's home Hub is Frozen.
    error ApplicationFrozen();

    /// @notice Action blocked by the pause state of the market's Hub or the debt reserve's funding Hub.
    error ApplicationPaused();

    /// @notice `block.timestamp > deadline`.
    error DeadlineExpired(uint256 deadline);

    /// @notice `expectedNonce` differs from the proxy's stored borrow nonce.
    error BadNonce(uint256 currentNonce, uint256 expectedNonce);

    /// @notice An amount or units argument is 0, or a partial repay with debt has `maxRepaySpend == 0`.
    error ZeroAmount();

    /// @notice The borrow receiver is refused by the receiver rule.
    error InvalidReceiver(address receiver);

    /// @notice The wallet has no proxy for the market.
    error NoProxy(address wallet, uint256 marketId);

    /// @notice The market's CDP Spoke is not approved in the MarketRegistry.
    error UnknownSpoke(address spoke);

    /// @notice The debt reserve is not approved for the account's CDP Spoke.
    error UnknownDebtReserve(address spoke, uint256 reserveId);

    /// @notice The market is not registered with an approved CDP Spoke, or a vault token is not the market's.
    error UnknownMarket(uint256 marketId);

    /// @notice The AMM integration named in a `PositionRef` is not the market's integration.
    error IntegrationMismatch(uint256 marketId, uint32 integrationId);

    /// @notice A settlement step was called by an address other than LPVaultSwap, or without the expected Lock holder.
    error NotLPVaultSwap();

    /// @notice The Lock is held when an entry point starts.
    /// @dev Raised by the Lock and propagated; declared here so the app can decode it from the Adapter ABI.
    error LockHeld(address holder);

    /// @notice A repay-all found debt above `maxRepaySpend`; nothing moved.
    error RepayExceedsMax(uint256 debt, uint256 maxRepaySpend);

    /// @notice Debt remains in a reserve after a repay-all, or before the withdrawal of `repayAllAndWithdraw`.
    error DebtRemaining(uint256 reserveId, uint256 debt);

    /// @notice An amount the Adapter verifies differs from the expected one (borrow drawn, repay funds received).
    error UnitsMismatch(uint256 expected, uint256 actual);

    /// @notice The vault token's supply exceeds credited plus pending units, or the market's backing gap changed.
    error BackingMismatch(uint256 totalSupply, uint256 totalCredited, uint256 pendingUnits);

    /// @notice The proxy's supplied shares did not rise by exactly the credited units in a pledge.
    error SupplyIncomplete();

    /// @notice Repay arrays differ in length, or a minimum-amount array's length is not the market's token count.
    error LengthMismatch();

    /// @notice `initialize` was called with a zero timelock.
    error ZeroAddress();

    /// @notice A frozen address tried new activity, as caller or as a borrow receiver.
    error AddressIsFrozen(address account);

    /// @notice `repayWithCollateral` named a debt reserve in which the account owes nothing.
    error NothingToRepay(uint256 debtReserveId);

    /// @notice A repay with collateral left debt and a health factor below `max(before, minHealthFactor)`.
    error HealthFactorNotImproved(uint256 before, uint256 afterCall);

    /// @notice A repay with collateral paid the calling wallet less debt asset than its `minAssetOut`.
    /// @param assetOut Debt asset LPVaultSwap paid the wallet, base units.
    error AssetOutBelowMinimum(uint256 assetOut, uint256 minAssetOut);

    /// @notice A deleverage callback outside its open session, out of order or repeated.
    error NoDeleverageSession();

    /// @notice `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` granted to an address other than `TIMELOCK`.
    error AdminRoleOnlyTimelock(bytes32 role, address account);

    /// @notice A balance measured around a `proxy.execute` step moved by other than the expected amount.
    error BalanceDeltaMismatch();

    /// @notice After a supply the Spoke does not report the vault-token reserve enabled as collateral.
    error CollateralNotEnabled(uint256 reserveId);

    /// @notice A proxy created by this pledge already has debt or collateral on its Spoke account.
    error AccountNotEmpty(address proxy);

    /// @notice A logic contract of the Adapter was called directly instead of by the Adapter's `delegatecall`.
    error NotDelegated();

    /// @notice An implementation was built with a logic contract of another kind or built with other immutables.
    error InvalidLogic(address logic);

    /// @notice A repay reached the RiskModule's speed credit with too little gas for its stipend.
    /// @param required `SPEED_CREDIT_FLOOR`.
    error InsufficientGas(uint256 gasLeft, uint256 required);
}
