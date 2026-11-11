// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IFlashSource
/// @notice The chain's source of flash liquidity for `deleverage` (repay with collateral): lends LPVaultSwap the debt
/// asset itself for the duration of one call. A liquidation never calls it: `liquidate` is funded by its caller, and a
/// caller without the debt asset borrows through the flash liquidation helper (REQ-SWAP-012, Q-404).
/// @dev One implementation per chain, replaceable through the chain's timelock (`MarketRegistry.setFlashSource`);
/// LPVaultSwap reads its address from `MarketRegistry.flashSource()` and the implementation reads `maxFlashFeeBps()`
/// from the ParameterStore before each loan. The launch implementation (AaveV3FlashSource) calls the Aave V3 Pool `flashLoan` with one asset and
/// `interestRateModes = [0]` on Ethereum and on Base; Aave V4 has no flash loans. With the ACLManager
/// `FLASH_BORROWER` role the premium is 0; without it the source quotes `ceil(amount * FLASHLOAN_PREMIUM_TOTAL / 1e4)`
/// and the V3.4 Pool charges half-up (`percentMul`), never above the quote, so the ceiling quote is the binding gate.
/// Example: 2,000,000 USDC at 5 bps without the role: premium = 1,000 USDC; with the role: 0. The flash source may not
/// borrow from any Hub registered on the chain: borrowing from the liquidated market's Hub would draw on the liquidity
/// the liquidation is restoring. Every implementation reports through `LENDER()` the pool or Hub that holds the
/// liquidity it lends (the Aave V3 Pool at launch; for a flash Spoke on an Aave V4 Hub, that Hub, not the Spoke), and
/// the source is refused when `MarketRegistry.isRecordedHub(LENDER())`, both in `setFlashSource` and by LPVaultSwap on
/// every `deleverage` (AMMN N1, Q-386). When `maxFlashLoan` is below the repayment, `deleverage` reverts and the borrower
/// repays from its own funds.
/// Amounts are measured by balance delta: with a debt asset that charges a transfer fee, the lender's transfer arrives
/// short, so the source forwards what it measured and LPVaultSwap books what it measured; such an asset trips the
/// `ISSUER` debt breaker, which stops new borrows while liquidations and repays continue (AMMN N2b, REQ-SWAP-123).
/// @custom:spec REQ-FLASH-001, REQ-FLASH-002, REQ-FLASH-003, REQ-FLASH-004, REQ-FLASH-005, REQ-FLASH-006, INV-095, Q-373
interface IFlashSource {
    /// @notice The caller is not LPVaultSwap.
    error NotLPVaultSwap();

    /// @notice A loan of this source is already open: `flashLoan` was called again from inside `onFlashLoan`.
    /// @custom:spec REQ-FLASH-001
    error FlashLoanActive();

    /// @notice A constructor address is `address(0)`.
    /// @custom:spec REQ-FLASH-001
    error ZeroAddress();

    /// @notice `amount` exceeds the lender's available liquidity, or the reserve is paused, inactive or not
    /// flash-loanable.
    /// @param available `maxFlashLoan(asset)`.
    error InsufficientFlashLiquidity(uint256 available);

    /// @notice The premium fails the exact check `premium * 1e4 <= maxFlashFeeBps * amount`.
    /// @param premium Premium the lender would charge.
    /// @param maxPremium `floor(maxFlashFeeBps * amount / 1e4)`, the largest premium that passes the check, in the debt
    /// asset's base units.
    error FlashFeeTooHigh(uint256 premium, uint256 maxPremium);

    /// @notice The lender is the Hub of the Spoke being liquidated.
    error FlashSourceIsHub();

    /// @notice A callback arrived from an address other than the lender, with another initiator, more than one asset,
    /// or outside an active flash context.
    error InvalidFlashCallback();

    /// @notice After `onFlashLoan`, the source holds less of the asset than the lender is owed.
    /// @param balance The source's balance of the asset.
    /// @param owed `amount + premium`.
    /// @custom:spec REQ-FLASH-003, REQ-SWAP-122
    error FlashRepayShort(uint256 balance, uint256 owed);

    /// @notice A flash loan was taken and repaid.
    /// @param asset Debt asset.
    /// @param amount Amount lent.
    /// @param premium Premium paid.
    event FlashLoanServed(address indexed asset, uint256 amount, uint256 premium);

    /// @notice Lends `amount` of `asset` to LPVaultSwap, calls its `onFlashLoan`, and repays the lender.
    /// @dev Before the loan: `msg.sender == LP_VAULT_SWAP` (`NotLPVaultSwap`); no loan of this source open
    /// (`FlashLoanActive`); `LENDER() != spokeHub`
    /// (`FlashSourceIsHub`; LPVaultSwap has already refused a source whose lender is any recorded Hub); `amount <= maxFlashLoan(asset)` (`InsufficientFlashLiquidity`); with `phi =
    /// flashPremium(asset, amount)` and `maxFlashFeeBps` from the ParameterStore, the exact check `phi * 1e4 <=
    /// maxFlashFeeBps * amount`, with no division and so no rounding (`FlashFeeTooHigh`). Sets a transient context
    /// `(asset, amount, keccak256(context))`, calls the lender, and in the lender's callback checks `msg.sender ==
    /// LENDER`, `initiator == address(this)`, one asset and the active context (`InvalidFlashCallback`) and re-checks
    /// the charged premium against `maxFlashFeeBps` (`FlashFeeTooHigh`); transfers `r1`, the rise of its balance of the
    /// asset over the snapshot taken before calling the lender (`r1 = amount` unless the asset charges a transfer fee),
    /// to LPVaultSwap, calls `onFlashLoan`, requires the magic value and its own balance
    /// of the asset to be at least `owed = amount + premium` (`FlashRepayShort(balance, owed)`; LPVaultSwap repays by
    /// balance delta, REQ-SWAP-122), approves the lender for exactly `amount + premium`,
    /// and after the lender returns requires that the callback ran (`InvalidFlashCallback`), clears the context, sets
    /// any allowance the lender left back to 0 and emits `FlashLoanServed`. A balance held before the loan (a donation)
    /// is never forwarded; it stays and counts toward the next repayment, since LPVaultSwap tops the source up to `owed`
    /// by balance delta.
    /// @param asset Debt asset of the liquidation.
    /// @param amount Amount to lend, base units.
    /// @param spokeHub Hub of the Spoke being liquidated.
    /// @param context Opaque context passed back to `onFlashLoan`.
    /// @return premium Premium paid.
    /// @custom:spec REQ-FLASH-001, REQ-FLASH-002, REQ-FLASH-003, REQ-FLASH-004, REQ-FLASH-005
    function flashLoan(
        address asset,
        uint256 amount,
        address spokeHub,
        bytes calldata context
    ) external returns (uint256 premium);

    /// @notice Returns the most the lender can lend of `asset` now.
    /// @dev Aave V3: 0 when the reserve is inactive, paused or not flash-loan enabled; otherwise the smaller of the asset
    /// balance of the reserve's aToken and the Pool's `getVirtualUnderlyingBalance(asset)` (V3.1+ virtual accounting: a
    /// direct transfer to the aToken is not lendable). A frozen reserve can still be flash-loaned.
    /// @custom:spec REQ-FLASH-002
    function maxFlashLoan(
        address asset
    ) external view returns (uint256 available);

    /// @notice Returns the source's quote of the premium the lender charges on `amount` of `asset`, never below the
    /// charge.
    /// @dev Read from the lender at each call (Aave V3: 0 for a `FLASH_BORROWER`, else
    /// `ceil(amount * FLASHLOAN_PREMIUM_TOTAL / 1e4)`; the V3.4 Pool charges half-up, at most this quote).
    /// @custom:spec REQ-FLASH-002
    function flashPremium(
        address asset,
        uint256 amount
    ) external view returns (uint256 premium);

    /// @notice Returns the pool or Hub the loan draws from, never an intermediate contract: the chain's Aave V3 Pool
    /// for the launch implementation; for a flash Spoke on an Aave V4 Hub, that Hub, not the Spoke.
    /// @dev `MarketRegistry.setFlashSource` reverts `InvalidRoute` and LPVaultSwap reverts `FlashSourceIsHub` on every
    /// flash call when `MarketRegistry.isRecordedHub(LENDER())`.
    /// @return lender Constructor immutable.
    /// @custom:spec REQ-FLASH-001, REQ-FLASH-005, REQ-FLASH-006, INV-095, Q-386
    function LENDER() external view returns (address lender);

    /// @notice Returns LPVaultSwap, the only borrower.
    /// @return lpVaultSwap Constructor immutable.
    /// @custom:spec REQ-FLASH-003
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Returns the ParameterStore that holds `maxFlashFeeBps`.
    /// @return parameterStore Constructor immutable.
    /// @custom:spec REQ-FLASH-002
    function PARAMETER_STORE() external view returns (address parameterStore);
}
