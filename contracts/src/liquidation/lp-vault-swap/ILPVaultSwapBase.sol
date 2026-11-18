// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SettlementReport} from "../../types/PositionTypes.sol";

/// @title ILPVaultSwapBase
/// @notice Errors and events of LPVaultSwap, shared with its contracts.
interface ILPVaultSwapBase {
    error LockHeld(address holder);

    /// @notice `proxy` is not a valid proxy of the market's vault token (`isValidProxy` is false).
    error UnknownProxy();

    /// @notice The market is unknown in the MarketRegistry or its record does not match the vault token's immutables.
    error UnknownMarket();

    /// @notice The debt reserve is not one the MarketRegistry enabled for the Spoke.
    error UnknownDebtReserve(uint256 debtReserveId);

    /// @notice A zero or above-uint128 `debtToCover`, an above-uint128 `maxShortfall`, or a wrong-length `minAmounts`.
    error InvalidAmount();

    error NotLiquidatable();

    /// @notice Hub added shares differ from added assets for the market's vault-token asset.
    error SharesNotEqualAssets();

    /// @notice The seized market's price is not fresh, Live and agreeing enough to liquidate on.
    error StalePrice();

    /// @notice The repaid debt reserve is not priced by its recorded DebtOracle, or that price is not Live and fresh.
    error DebtPriceStale(uint256 debtReserveId);

    /// @notice A measured funding, shortfall or First-Loss Reserve transfer moved the wrong amount.
    error FundingMismatch();

    /// @notice In `deleverage`, the flash premium is above `maxFlashFeeBps` of the flash amount.
    error FlashFeeTooHigh();

    error FlashSourceIsHub();

    /// @notice In `deleverage`, the flash source holds less than it owes after `MAX_REPAY_TRANSFERS` transfers.
    error FlashRepayShort(uint256 balance, uint256 owed);

    /// @notice `onFlashLoan` was not called by the flash source within an active `deleverage` with its context.
    error InvalidFlashCallback();

    error NothingSeized();

    /// @notice No usable swap route swapped a pool token other than the debt asset into the debt asset.
    error NoRouteAvailable();

    error FlashLiquidityShort(uint256 available, uint256 requested);

    error RecoveryBelowFloor();

    /// @notice Defensive: the funds held do not cover the debt repaid, the fee and the borrower surplus.
    error InsufficientProceeds();

    error InvalidFeeRecipient();

    /// @notice `addKeeper` got zero or a registered operator, or `removeKeeper` an unregistered one.
    error InvalidKeeper();

    /// @notice The removal would leave fewer than `KEEPER_FLOOR` committed operators.
    error KeeperFloor(uint256 activeAfter, uint256 keeperFloor);

    error TooManyKeepers(uint256 maxKeepers);

    /// @notice `settlePending` found no stranded vault tokens or no pending-settlement balance for the market.
    error NothingPending();

    error DeadlineExpired(uint256 deadline);

    error PayoutTooLow(uint256 keeperOut, uint256 minPayout);

    /// @notice `gasleft()` before a gas-limited escrowable payout transfer is below the required headroom.
    error InsufficientGas(uint256 gasLeft, uint256 required);

    /// @notice The repayment a `deleverage` can make is 0 or below the borrower's `minDebtRepaid`.
    error DeleverageTooSmall(uint256 repayable, uint256 minDebtRepaid);

    /// @notice The unwind and swaps in `deleverage` do not cover the flash loan plus its premium.
    error DeleverageShortfall(uint256 recovered, uint256 owed);

    /// @notice `deleverage` was not called by the AaveAdapter while it holds the lock.
    error NotAdapter();

    /// @notice A grant of `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` to an account other than the AvanaTimelock.
    error AdminRoleOnlyTimelock(bytes32 role, address account);

    /// @notice A collateral, vault-token or released-token price used to value a seizure or a leg is 0.
    error ZeroCollateralPrice();

    /// @notice The price of the debt asset (or of the pending-settlement asset) used as the quote of a valuation is 0.
    error ZeroDebtPrice();

    error InvalidDecimals(uint8 decimals);

    error InvalidFeeShare(uint256 feeShareBps);

    error ZeroAddress();

    /// @notice A logic contract passed to the implementation's constructor reports another kind or other immutables.
    error InvalidLogic();

    error NotDelegated();

    event LiquidationSettled(
        address indexed caller, address indexed proxy, uint256 indexed marketId, SettlementReport report
    );

    /// @notice Emitted when a liquidation's borrower surplus was paid to the borrower's wallet or escrowed for it.
    /// @param amount Surplus paid, less any part the First-Loss Reserve took.
    event BorrowerSurplusPaid(
        address indexed proxy, address indexed wallet, address indexed debtAsset, uint256 amount, bool escrowed
    );

    /// @notice Emitted when an underwater or deficit liquidation paid borrower surplus into the First-Loss Reserve.
    /// @param amount The part of the surplus the reserve took.
    /// @param shares The reserve's Hub shares `fund` reported.
    event DeficitSurplusFunded(
        address indexed proxy,
        address indexed firstLossReserve,
        address indexed debtAsset,
        uint256 amount,
        uint256 shares
    );

    /// @notice Emitted when `deleverage` took and repaid a flash loan of the debt asset.
    event FlashLoanUsed(
        uint256 indexed marketId, address indexed flashSource, address indexed asset, uint256 amount, uint256 premium
    );

    /// @notice Emitted when a primary swap-route call reverted and the backup was tried.
    event RouteFailed(uint256 indexed marketId, address indexed token, address route, bytes4 errorSelector);

    /// @notice Emitted when route residue or a dust leg was sent to the caller of `liquidate`, or escrowed for it.
    event ResidueReturned(address indexed caller, address indexed token, uint256 amount, bool escrowed);

    event KeeperAdded(address indexed keeper);

    event KeeperRemoved(address indexed keeper);

    /// @param minPending Floor `added` had to meet.
    /// @param routeUsed Swap route used per pool token: 0 none, 1 primary, 2 backup.
    /// @param funded `added` plus the prior carry passed to `fund`, or 0 when the amount was carried.
    /// @param carried The carry of the settlement asset after the call (0 after a funding).
    event PendingSettlementForwarded(
        address indexed caller,
        uint256 indexed marketId,
        address vaultToken,
        uint256 units,
        uint256[] amounts,
        address indexed debtAsset,
        uint256 added,
        uint256 minPending,
        address firstLossReserve,
        uint8[] routeUsed,
        uint256 funded,
        uint256 carried
    );

    event Deleveraged(
        address indexed proxy,
        uint256 indexed marketId,
        uint256 indexed debtReserveId,
        uint128 units,
        uint256 debtRepaid,
        uint256 recovered,
        uint256 flashPremium,
        uint256 debtAssetOut
    );
}
