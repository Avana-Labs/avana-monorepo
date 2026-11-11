// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ILPVaultSwapErrors
/// @notice Errors of LPVaultSwap: caller freeze, lock, account, debt-reserve, price and health checks, caller funding,
/// the `deleverage` flash callback, swap-route and recovery-floor checks, committed-operator registry changes and payout
/// bounds. Every value amount is in base units of the repaid debt asset.
/// @dev No error refers to the MarketRegistry pause state: liquidation and pending settlement never read it. No error
/// refers to the committed-operator registry in `liquidate`: the registry gates no call (REQ-SWAP-001, Q-404).
interface ILPVaultSwapErrors {
    /// @notice The protocol lock is already held.
    /// @param holder The current lock holder.
    /// @custom:spec REQ-SWAP-002, REQ-SWAP-066
    error LockHeld(address holder);

    /// @notice `proxy` is not a valid proxy of the market's vault token (`isValidProxy` is false).
    /// @custom:spec REQ-SWAP-004
    error UnknownProxy();

    /// @notice The market is unknown in the MarketRegistry or its record does not match the vault token's immutables.
    /// @custom:spec REQ-SWAP-004
    error UnknownMarket();

    /// @notice The debt reserve is not a debt reserve the MarketRegistry enabled for the Spoke, or the Spoke reports it
    /// not borrowable.
    /// @param debtReserveId The rejected reserve.
    /// @custom:spec REQ-SWAP-087, REQ-SWAP-095
    error UnknownDebtReserve(uint256 debtReserveId);

    /// @notice `debtToCover` is zero, `debtToCover` or `maxShortfall` is above `type(uint128).max`, or a non-empty
    /// `minAmounts` does not have one entry per pool token.
    /// @custom:spec REQ-SWAP-005
    error InvalidAmount();

    /// @notice The account's health factor is at least 1e18.
    /// @custom:spec REQ-SWAP-006
    error NotLiquidatable();

    /// @notice Hub added shares differ from added assets for the market's vault-token asset.
    /// @custom:spec REQ-SWAP-007, REQ-SWAP-052
    error SharesNotEqualAssets();

    /// @notice The seized market's price (Q-247) is from an unknown source, Cached, Expired, older than its
    /// `liquidationPriceMaxAge`, inside the disagreement pause, or in a disagreement that outlasted
    /// `disagreementPauseMax` (treated as Expired, Q-208).
    /// @custom:spec REQ-SWAP-008, REQ-SWAP-050, REQ-SWAP-071, Q-208
    error StalePrice();

    /// @notice The repaid debt reserve is priced by a source other than the DebtOracle the MarketRegistry records, or its
    /// DebtOracle is not Live within `liquidationPriceMaxAge` (Q-247, Q-248).
    /// @param debtReserveId The reserve whose price failed.
    /// @custom:spec REQ-SWAP-091, REQ-SWAP-096
    error DebtPriceStale(uint256 debtReserveId);

    /// @notice A collateral market of the account is in its grace window and `HF >= graceHealthFactor`.
    /// @custom:spec REQ-SWAP-009, REQ-SWAP-051
    error GraceHealthFactor();

    /// @notice The caller funding `Kf` measured by balance delta is outside `0 < Kf <= debtToCover`, a shortfall pull
    /// delivered a different amount, or a Coverage Spoke `fund` did not lower the balance by exactly the amount funded.
    /// @custom:spec REQ-SWAP-011, REQ-SWAP-070, REQ-SWAP-098, REQ-SWAP-112
    error FundingMismatch();

    /// @notice In `deleverage`, the flash source's premium `phi` on the flash amount `F` fails the exact check
    /// `phi × 1e4 ≤ maxFlashFeeBps × F`.
    /// @custom:spec REQ-SWAP-013, REQ-SWAP-053, REQ-FLASH-002
    error FlashFeeTooHigh();

    /// @notice The flash source borrows from a Hub recorded on the chain: `MarketRegistry.isRecordedHub(LENDER())`.
    /// Checked on every `deleverage`; liquidation takes no flash loan and is unaffected.
    /// @custom:spec REQ-FLASH-005, REQ-SWAP-097, INV-095
    error FlashSourceIsHub();

    /// @notice In `deleverage`, after at most `MAX_REPAY_TRANSFERS` repay transfers the flash source holds less than it
    /// owes the lender.
    /// @param balance The flash source's balance of the debt asset.
    /// @param owed `amount + premium`.
    /// @custom:spec REQ-SWAP-122, REQ-SWAP-124
    error FlashRepayShort(uint256 balance, uint256 owed);

    /// @notice `onFlashLoan` was called by an address other than `MARKET_REGISTRY.flashSource()`, outside an active
    /// `deleverage` context (including from inside `liquidate`), or with an asset, amount or context hash other than
    /// the active context's.
    /// @custom:spec REQ-SWAP-013, REQ-SWAP-054
    error InvalidFlashCallback();

    /// @notice `liquidationCall` seized no vault-token units.
    /// @custom:spec REQ-SWAP-017, REQ-SWAP-056
    error NothingSeized();

    /// @notice No usable swap route swapped a pool token other than the debt asset into the debt asset.
    /// @custom:spec REQ-SWAP-022, REQ-SWAP-059, REQ-SWAP-071
    error NoRouteAvailable();

    /// @notice In `deleverage`, the chain's flash source cannot lend the repayment `F` of the debt asset now
    /// (`maxFlashLoan` below it); the borrower retries with fewer units or repays from its own funds.
    /// @param available The flash source's `maxFlashLoan`, base units.
    /// @param requested `F`, base units.
    /// @custom:spec REQ-FLASH-002, REQ-SWAP-099, REQ-SWAP-106, Q-379
    error FlashLiquidityShort(uint256 available, uint256 requested);

    /// @notice Debt asset recovered is below the recovery floor (`minOut` in `liquidate`, with the caller's floor gap
    /// above `maxShortfall`; `minPending` in `settlePending`).
    /// @custom:spec REQ-SWAP-025, REQ-SWAP-060, REQ-SWAP-071, REQ-SWAP-101, SPEC-LIQ-014, SPEC-LIQ-019
    error RecoveryBelowFloor();

    /// @notice Defensive: `Kf + R' < D + A + B` after the caller's shortfall top-up (SPEC-LIQ-010), or the settlement gap
    /// `g = max(0, D + A + B - Kf - R)` exceeds `maxShortfall` (SPEC-LIQ-019). Neither happens while `Kf >= D`, which
    /// holds because Aave pulls `D` out of the `Kf` it was approved for; the check guards against a faulty balance
    /// measurement. There is no settlement budget (Q-397).
    /// @custom:spec SPEC-LIQ-010, SPEC-LIQ-019, REQ-SWAP-029, REQ-SWAP-061, REQ-SWAP-062, REQ-BUDGET-002, REQ-BUDGET-014, Q-261, Q-397, Q-404
    error InsufficientProceeds();

    /// @notice `feeRecipient` in the ParameterStore is the zero address.
    /// @custom:spec REQ-SWAP-028, REQ-SWAP-066
    error InvalidFeeRecipient();

    /// @notice `addKeeper` was called with the zero address or an already registered committed operator, or
    /// `removeKeeper` with an address that is not registered.
    /// @custom:spec REQ-SWAP-033, REQ-SWAP-035
    error InvalidKeeper();

    /// @notice The removal would leave fewer than `KEEPER_FLOOR` active (registered, unfrozen) committed operators.
    /// @param activeAfter Active committed operators after the removal.
    /// @param keeperFloor `KEEPER_FLOOR`.
    /// @custom:spec REQ-SWAP-034, REQ-SWAP-035, REQ-SWAP-065
    error KeeperFloor(uint256 activeAfter, uint256 keeperFloor);

    /// @notice `addKeeper` with `MAX_KEEPERS` (32) committed operators already registered.
    /// @param maxKeepers `MAX_KEEPERS`.
    /// @custom:spec REQ-SWAP-033, Q-400
    error TooManyKeepers(uint256 maxKeepers);

    /// @notice `settlePending` found no stranded vault tokens or no pending-settlement balance for the market.
    /// @custom:spec REQ-SWAP-066, REQ-SWAP-068, Q-201
    error NothingPending();

    /// @notice `block.timestamp > deadline` at the start of `liquidate`; checked first, before the lock is acquired and
    /// before any external call.
    /// @param deadline The caller's deadline.
    /// @custom:spec REQ-SWAP-074, REQ-SWAP-078, Q-216
    error DeadlineExpired(uint256 deadline);

    /// @notice The caller's payout `keeperOut` in the debt asset (SPEC-LIQ-010), which includes its returned funding,
    /// is below `minPayout`.
    /// @param keeperOut The computed payout, base units.
    /// @param minPayout The caller's minimum, base units.
    /// @custom:spec REQ-SWAP-075, REQ-SWAP-079, Q-216, Q-345
    error PayoutTooLow(uint256 keeperOut, uint256 minPayout);

    /// @notice `gasleft()` before a gas-limited escrowable payout transfer (Avana's fee, the borrower surplus, a residue
    /// or dust leg) is below
    /// `required = ceil(PAYOUT_TRANSFER_GAS * 64 / 63) + 10,000` (111,588 at 100,000).
    /// @param gasLeft `gasleft()` at the check.
    /// @param required The required headroom.
    /// @custom:spec REQ-SWAP-076, REQ-SWAP-083, REQ-SWAP-104, REQ-SWAP-114, Q-214, Q-241
    error InsufficientGas(uint256 gasLeft, uint256 required);

    /// @notice The caller of `liquidate`, or the address passed to `addKeeper`, is frozen in the MarketRegistry. The
    /// freeze binds `msg.sender` only: a caller that goes through the public flash liquidation helper reaches
    /// LPVaultSwap as the helper (REQ-SWAP-105).
    /// @param account The frozen address.
    /// @custom:spec REQ-SWAP-105, REQ-SWAP-107, REQ-SWAP-109, REQ-SWAP-117, Q-242
    error AddressIsFrozen(address account);

    /// @notice The repayment a `deleverage` can make is 0 or below the borrower's `minDebtRepaid`.
    /// @param repayable Repayment SPEC-LIQ-020 allows, debt-asset base units.
    /// @param minDebtRepaid The borrower's minimum.
    /// @custom:spec REQ-SWAP-106, REQ-SWAP-116, SPEC-LIQ-020, Q-255
    error DeleverageTooSmall(uint256 repayable, uint256 minDebtRepaid);

    /// @notice The unwind and swaps in `deleverage` do not cover the flash loan plus its premium.
    /// @param recovered `R`, base units.
    /// @param owed `F + phi`, base units.
    /// @custom:spec REQ-SWAP-106, REQ-SWAP-116, SPEC-LIQ-020, Q-255
    error DeleverageShortfall(uint256 recovered, uint256 owed);

    /// @notice `deleverage` was called by an address other than the AaveAdapter, or without the AaveAdapter holding the
    /// lock.
    /// @custom:spec REQ-SWAP-106, REQ-SWAP-116, Q-255
    error NotAdapter();

    /// @notice A grant of `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` to an account other than the AvanaTimelock.
    /// @param role The role.
    /// @param account The rejected grantee.
    /// @custom:spec REQ-SWAP-040, REQ-ACCESS-153, Q-259
    error AdminRoleOnlyTimelock(bytes32 role, address account);

    /// @notice A collateral, vault-token or released-token price used to value a seizure or a leg is 0.
    /// @custom:spec SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-014, SPEC-LIQ-018
    error ZeroCollateralPrice();

    /// @notice The price of the debt asset (or of the pending-settlement asset) used as the quote of a valuation is 0.
    /// @custom:spec SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-014, SPEC-LIQ-018
    error ZeroDebtPrice();

    /// @notice A token's decimals exceed 36, the most a valuation accepts.
    /// @param decimals The rejected decimals.
    /// @custom:spec SPEC-LIQ-004
    error InvalidDecimals(uint8 decimals);

    /// @notice `avanaFeeShareBps` exceeds 10^4.
    /// @param feeShareBps The rejected share, bps.
    /// @custom:spec SPEC-LIQ-009
    error InvalidFeeShare(uint256 feeShareBps);
}
