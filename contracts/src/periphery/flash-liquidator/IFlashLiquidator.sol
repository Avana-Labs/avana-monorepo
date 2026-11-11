// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashLiquidatorErrors} from "./IFlashLiquidatorErrors.sol";
import {IFlashLiquidatorEvents} from "./IFlashLiquidatorEvents.sol";
import {FlashLiquidationRequest} from "./types/FlashLiquidationRequest.sol";

/// @title IFlashLiquidator
/// @notice The flash liquidation helper: lets a caller that holds no debt asset liquidate an Avana account. It
/// flash-borrows the debt asset, from the chain's GHO flash minter for GHO where the chain has one and from the chain's
/// Aave V3 Pool for every other asset, calls `LPVaultSwap.liquidate` inside the lender's callback, repays the lender
/// from the payout (pulling a bounded top-up from its payer when the payout falls short), enforces the caller's net
/// `minPayout`, and pays the net payout only after the loan returns. One public instance per chain serves every
/// caller; an operator may deploy its own instance of the operator variant (`IOperatorFlashLiquidator`).
/// @dev Periphery, outside the audited core, at `src/periphery/flash-liquidator/`. Immutable, with no owner, admin role,
/// upgrade path, setter, sweep, rescue or arbitrary-call function; it holds no funds or allowances between
/// transactions. Immutables: `POOL` (the chain's Aave V3 Pool), `GHO_FLASH_MINTER` (the chain's GHO flash minter, or
/// `address(0)` where GHO has none), `LP_VAULT_SWAP`, `MARKET_REGISTRY` (debt asset of the reserve, the Hub check) and
/// `PARAMETER_STORE` (`maxFlashFeeBps`, `feeRecipient`); neither lender is ever a Hub recorded on the chain. The Pool's
/// `flashLoan` is used, not `flashLoanSimple`, because only `flashLoan` waives the premium for an address holding
/// `FLASH_BORROWER`. Each callback binds the lender, the initiator, the asset, the amount, the caller's premium bound
/// and a single-use transient context, not only a hash of the calldata. LPVaultSwap sees the helper as an ordinary
/// caller: it checks its address freeze (the public helper is never frozen, REQ-MREG-020), pulls `debtToCover` and
/// any floor shortfall from it and pays `keeperOut` to it; a freeze of the helper's own caller cannot stop that caller
/// (REQ-SWAP-105). Example: a 1,950 USDC loan at 5 bps (premium 0.975 USDC) funds a liquidation that pays the helper
/// 2,020.8 USDC; the helper repays 1,950.975 USDC and pays its caller 69.825 USDC.
/// @custom:spec REQ-HELPER-001, REQ-HELPER-002, REQ-HELPER-004, REQ-HELPER-006, REQ-HELPER-010, REQ-HELPER-012, REQ-HELPER-015, REQ-SWAP-012, REQ-SWAP-105, REQ-MREG-020, Q-334, Q-404
interface IFlashLiquidator is IFlashLiquidatorErrors, IFlashLiquidatorEvents {
    /// @notice Liquidates through `LPVaultSwap.liquidate`, funded by a flash loan of the debt asset.
    /// @dev In order: reverts `ContextActive` while a context is open; in the operator variant `NotSigner` unless
    /// `msg.sender == SIGNER`; `InvalidFlashAmount` unless `0 < F <= params.debtToCover` and both `params.debtToCover`
    /// and `params.maxShortfall` are at most `2^128 - 1`; reads the debt asset `T` of `params.debtReserveId` from the
    /// MarketRegistry and its lender (the GHO flash minter for GHO where one is set, else the Pool, REQ-HELPER-015);
    /// `FlashSourceIsHub` if that lender is a recorded Hub; `InsufficientFlashLiquidity` if `F > maxFlashLoan(T)`;
    /// `FlashFeeTooHigh` unless `flashPremium(T, F) * 1e4 <= maxFlashFeeBps * F` (SPEC-LIQ-015, before the loan).
    /// Records the single-use transient context (lender, initiator, `T`, `F`, `maxPremium`, `maxTopUp`, the hash of
    /// `abi.encode(params)`, payer, recipient), pulls `debtToCover - F + params.maxShortfall` from the payer when
    /// positive, borrows `F` (`POOL.flashLoan(this, [T], [F], [0], this, abi.encode(params), 0)` or
    /// `GHO_FLASH_MINTER.flashLoan(this, T, F, abi.encode(params))`) and requires the callback to have run
    /// (`InvalidFlashCallback`). Then computes `payout` as the rise of its `T` balance over the whole call (a fall reverts
    /// `PayoutTooLow(0, minPayout)`), reverts `PayoutTooLow(payout, minPayout)` below `request.minPayout`, in the
    /// operator variant reverts `OutlayExceeded` when the Safe's net outlay exceeds `floor(D * MAX_TOP_UP_BPS / 1e4)`,
    /// sends `payout` and every market token it received (route residues and dust legs) to the recipient, leaves no
    /// allowance, emits `FlashLiquidated` and clears the context last, so a call re-entered during the payout reverts
    /// `ContextActive`. The payer and recipient are `msg.sender` for the public helper and `FUNDING_SAFE` for the
    /// operator variant. Example: the SPEC-LIQ-019 floor case, `X = F = 12,000` USDC with `maxShortfall = 200` USDC:
    /// the helper pulls 200 USDC, LPVaultSwap pulls 12,000 and then the 123.373998 USDC floor gap, and the payout is
    /// `12,297.373998 + 76.626002 - 12,006 = 368` USDC.
    /// @param request The liquidation parameters, the loan, the premium and top-up bounds and the net minimum payout.
    /// @return payout Net debt asset paid to the recipient.
    /// @custom:spec REQ-HELPER-002, REQ-HELPER-003, REQ-HELPER-004, REQ-HELPER-008, REQ-HELPER-010, REQ-HELPER-011, REQ-HELPER-013, REQ-HELPER-014, REQ-HELPER-015, SPEC-LIQ-015, SPEC-LIQ-019, Q-345, Q-404
    function flashLiquidate(
        FlashLiquidationRequest calldata request
    ) external returns (uint256 payout);

    /// @notice Aave V3 `flashLoan` callback: runs the liquidation while the loan is open and leaves the Pool approved
    /// for exactly `F + premium`.
    /// @dev Reverts `InvalidFlashCallback` unless a context is active and unused, its lender is `POOL` and
    /// `msg.sender == POOL`, `initiator == address(this)`, each array has length 1, `assets[0]` and `amounts[0]` equal
    /// the context's `T` and `F`, and `keccak256(params)` equals the context's hash; `PremiumTooHigh` if
    /// `premiums[0] > maxPremium`; `FlashFeeTooHigh` unless `premiums[0] * 1e4 <= maxFlashFeeBps * F`. Marks the
    /// context used before any external call, then runs the liquidation and the repayment of REQ-HELPER-006 and -007
    /// and returns true.
    /// @param assets The borrowed asset, length 1.
    /// @param amounts The borrowed amount, length 1.
    /// @param premiums The premium the Pool charges, length 1.
    /// @param initiator The `flashLoan` caller; must be this helper.
    /// @param params `abi.encode(LiquidationParams)`, bound to the context by hash.
    /// @return success Always true when it returns.
    /// @custom:spec REQ-HELPER-005, REQ-HELPER-006, REQ-HELPER-007, REQ-HELPER-013, SPEC-LIQ-015, Q-045, Q-404
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool success);

    /// @notice ERC-3156 callback of the GHO flash minter: runs the liquidation while the loan is open and leaves the
    /// minter approved for exactly `F + fee`.
    /// @dev Reverts `InvalidFlashCallback` unless a context is active and unused, `GHO_FLASH_MINTER` is set, the
    /// context's lender is `GHO_FLASH_MINTER` and `msg.sender` is it, `initiator == address(this)`, `token` and `amount`
    /// equal the context's `T` and `F`, and `keccak256(data)` equals the context's hash; `PremiumTooHigh` if
    /// `fee > maxPremium`; `FlashFeeTooHigh` unless `fee * 1e4 <= maxFlashFeeBps * F`. Marks the context used before
    /// any external call, runs the liquidation and the repayment of REQ-HELPER-006 and -007, and returns
    /// `keccak256("ERC3156FlashBorrower.onFlashLoan")`; the minter then pulls `F + fee` and burns `F`.
    /// @param initiator The `flashLoan` caller; must be this helper.
    /// @param token The minted token, GHO.
    /// @param amount The minted amount.
    /// @param fee The fee the minter charges.
    /// @param data `abi.encode(LiquidationParams)`, bound to the context by hash.
    /// @return magic `keccak256("ERC3156FlashBorrower.onFlashLoan")`.
    /// @custom:spec REQ-HELPER-005, REQ-HELPER-006, REQ-HELPER-007, REQ-HELPER-013, REQ-HELPER-015, SPEC-LIQ-015
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32 magic);

    /// @notice Claims the helper's PayoutEscrow credit of `token` (a residue or dust leg LPVaultSwap could not deliver
    /// to it) to the variant's claim recipient.
    /// @dev Public helper: callable by anyone, pays `feeRecipient` read from the ParameterStore (as LPVaultSwap reads
    /// it), reverting `InvalidFeeRecipient` while it is unset. Operator variant: `SIGNER` only (`NotSigner`), pays
    /// `FUNDING_SAFE`. The escrow is the one LPVaultSwap credits (`LP_VAULT_SWAP.PAYOUT_ESCROW()`); it reverts
    /// `NothingToClaim` for a zero credit and `LockHeld` while the Lock is held.
    /// @param token The credited token.
    /// @return amount Amount claimed.
    /// @custom:spec REQ-HELPER-010, REQ-HELPER-011
    function claimEscrowed(
        address token
    ) external returns (uint256 amount);

    /// @notice What the lender of `asset` can lend now.
    /// @dev For GHO with `GHO_FLASH_MINTER` set: the minter's `maxFlashLoan(GHO)` (bucket capacity less level).
    /// Otherwise 0 unless the Pool's reserve is active, not paused and flash-enabled, else
    /// `min(asset.balanceOf(aToken), getVirtualUnderlyingBalance(asset))`.
    /// @param asset The debt asset.
    /// @return available Base units.
    /// @custom:spec REQ-HELPER-009
    function maxFlashLoan(
        address asset
    ) external view returns (uint256 available);

    /// @notice The premium the lender of `asset` charges this helper for `amount`, quoted from above.
    /// @dev For GHO with `GHO_FLASH_MINTER` set: the minter's `flashFee(GHO, amount)` read live (the helper is its
    /// `msg.sender`, so it is the fee the helper's own loan is charged in the same block). Otherwise 0 while the helper
    /// holds `FLASH_BORROWER` on the Pool's ACLManager, else `ceil(amount * FLASHLOAN_PREMIUM_TOTAL / 1e4)`, which the
    /// Pool's half-up charge never exceeds. Example: 1,950 USDC at 5 bps without the role quotes 975,000; with it, 0.
    /// @param asset The debt asset.
    /// @param amount The loan amount, base units.
    /// @return premium Base units.
    /// @custom:spec REQ-HELPER-009
    function flashPremium(
        address asset,
        uint256 amount
    ) external view returns (uint256 premium);

    /// @notice The chain's Aave V3 Pool, the lender of every asset except GHO where a GHO flash minter is set
    /// (immutable).
    /// @return pool Address.
    /// @custom:spec REQ-HELPER-001, REQ-HELPER-002
    function POOL() external view returns (address pool);

    /// @notice The chain's LPVaultSwap (immutable).
    /// @return lpVaultSwap Address.
    /// @custom:spec REQ-HELPER-001
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice The chain's GHO flash minter, the lender of GHO, or `address(0)` on a chain whose GHO has none (immutable).
    /// @return minter Address.
    /// @custom:spec REQ-HELPER-001, REQ-HELPER-015
    function GHO_FLASH_MINTER() external view returns (address minter);

    /// @notice The chain's MarketRegistry (immutable), read for the debt asset and the Hub check.
    /// @return registry Address.
    /// @custom:spec REQ-HELPER-001, REQ-HELPER-002
    function MARKET_REGISTRY() external view returns (address registry);

    /// @notice The chain's ParameterStore (immutable), read for `maxFlashFeeBps` and, by the public helper's
    /// `claimEscrowed`, `feeRecipient`.
    /// @return store Address.
    /// @custom:spec REQ-HELPER-001, REQ-HELPER-005
    function PARAMETER_STORE() external view returns (address store);
}
