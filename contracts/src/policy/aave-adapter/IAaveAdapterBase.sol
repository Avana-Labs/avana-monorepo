// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAaveAdapterBase
/// @notice Errors and events of AaveAdapter, shared with its contracts.
interface IAaveAdapterBase {
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

    /// @notice The wallet's proxy for a market was created and bound.
    event UserProxyCreated(address indexed wallet, address indexed spoke, uint256 indexed marketId, address proxy);

    /// @notice A position was pledged, credited, minted and supplied as collateral.
    event CollateralAdded(
        address indexed wallet,
        uint256 indexed marketId,
        address indexed vaultToken,
        address proxy,
        uint256 recordId,
        uint32 integrationId,
        bytes32 positionKey,
        uint128 units
    );

    /// @notice A debt asset was borrowed and sent to `receiver`.
    /// @param healthFactorAfter Health factor after the borrow, WAD.
    event Borrowed(
        address indexed wallet,
        uint256 indexed marketId,
        uint256 indexed debtReserveId,
        address receiver,
        uint256 amount,
        uint256 nonce,
        uint256 healthFactorAfter
    );

    /// @notice A payer repaid one debt reserve of a borrower's account.
    /// @dev Emitted only when funds moved; `payer != borrower` marks a third-party repay.
    /// @param spent Amount consumed by `Spoke.repay`, base units.
    event Repaid(
        address indexed payer,
        address indexed borrower,
        uint256 indexed marketId,
        uint256 debtReserveId,
        uint256 spent,
        uint256 debtAfter,
        bool repayAll
    );

    /// @notice A record's units were withdrawn and burned and its position returned to the depositor.
    /// @param healthFactorAfter Health factor after the withdrawal, WAD; `type(uint256).max` when debt-free.
    event CollateralWithdrawn(
        address indexed wallet,
        uint256 indexed marketId,
        address indexed vaultToken,
        bytes32 positionKey,
        uint256 units,
        bool withDebt,
        uint256 healthFactorAfter
    );

    event SeizedUnitsBurned(uint256 indexed marketId, address indexed vaultToken, uint256 units);

    /// @notice Units added to a pledged position were credited, minted and supplied.
    event CollateralRecredited(
        address indexed wallet,
        uint256 indexed marketId,
        address indexed vaultToken,
        uint256 recordId,
        bytes32 positionKey,
        uint128 added,
        uint128 rescueUnits
    );

    /// @notice Part of a record's units was removed and its principal paid to the depositor of record.
    /// @param amounts Raw amount of each pool token paid, market token order.
    /// @param healthFactorAfter Rescue-excluded health factor after the call, WAD; `type(uint256).max` when debt-free.
    event CollateralReduced(
        address indexed wallet,
        uint256 indexed marketId,
        address indexed vaultToken,
        bytes32 positionKey,
        uint128 units,
        uint256[] amounts,
        bool withDebt,
        uint256 healthFactorAfter
    );

    /// @notice A debt reserve was repaid with units released from a record.
    /// @param healthFactorBefore Aave health factor before, WAD.
    /// @param healthFactorAfter Aave health factor after, WAD; `type(uint256).max` when debt-free.
    event RepaidWithCollateral(
        address indexed wallet,
        uint256 indexed marketId,
        address indexed vaultToken,
        bytes32 positionKey,
        uint128 units,
        uint256 debtReserveId,
        uint256 debtRepaid,
        uint256 debtAssetToWallet,
        uint256 healthFactorBefore,
        uint256 healthFactorAfter
    );

    /// @notice Vault-token units were supplied to the Spoke for a proxy.
    event CollateralSupplied(address indexed proxy, uint256 indexed marketId, uint256 units, uint256 shares);

    /// @notice The vault-token reserve was disabled as collateral for a proxy whose supply reached 0.
    event CollateralDisabled(address indexed proxy, uint256 reserveId);
}
