// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "../../liquidation/lp-vault-swap/types/LPVaultSwapTypes.sol";

/// @title IFlashLiquidator
/// @notice Flash liquidation helper: borrows the debt asset from Aave V3 and runs `LPVaultSwap.liquidate` in the loan.
/// @dev Immutable, no owner; holds no funds or allowances between transactions.
interface IFlashLiquidator {
    /// @notice Liquidates through `LPVaultSwap.liquidate`, funded by a flash loan of the debt asset.
    /// @dev The context is cleared last, so reentry during the payout reverts `ContextActive`.
    /// @return payout Net debt asset paid to the recipient.
    function flashLiquidate(
        FlashLiquidationRequest calldata request
    ) external returns (uint256 payout);

    /// @notice Aave V3 `flashLoan` callback: runs the liquidation and approves the Pool for exactly `F + premium`.
    /// @dev Reverts `InvalidFlashCallback` unless the call matches the open, unused context.
    /// @param initiator The `flashLoan` caller; must be this helper.
    /// @param params `abi.encode(LiquidationParams)`, bound to the context by hash.
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external returns (bool success);

    /// @notice Claims the helper's whole PayoutEscrow credit of `token` to the variant's claim recipient.
    /// @dev Reverts `ContextActive` while a `flashLiquidate` context is open.
    function claimEscrowed(
        address token
    ) external returns (uint256 amount);

    /// @notice What the Pool can lend of `asset` now; 0 unless the reserve is active, unpaused and flash-enabled.
    function maxFlashLoan(
        address asset
    ) external view returns (uint256 available);

    /// @notice The premium the Pool charges this helper for `amount` of `asset`, rounded up.
    /// @dev 0 while the helper holds `FLASH_BORROWER` on the Pool's ACLManager.
    function flashPremium(
        address asset,
        uint256 amount
    ) external view returns (uint256 premium);

    /// @notice The chain's Aave V3 Pool, the lender of every debt asset.
    function POOL() external view returns (address pool);

    /// @notice The chain's LPVaultSwap.
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice The chain's MarketRegistry.
    function MARKET_REGISTRY() external view returns (address registry);

    /// @notice The chain's ParameterStore.
    function PARAMETER_STORE() external view returns (address store);

    /// @notice A constructor address is `address(0)`.
    error ZeroAddress();

    /// @notice The operator variant's `MAX_TOP_UP_BPS` exceeds 10^4.
    error InvalidTopUpBps(uint256 bps);

    /// @notice The Pool is a Hub recorded on the chain.
    error FlashSourceIsHub();

    /// @notice A context of this helper is already open (nesting or reentry).
    error ContextActive();

    /// @notice The operator variant was called by an address other than `SIGNER`.
    error NotSigner();

    /// @notice The flash amount or the request's bounds are out of range.
    error InvalidFlashAmount();

    /// @notice The Pool cannot lend the flash amount now.
    /// @param available `maxFlashLoan(asset)`.
    error InsufficientFlashLiquidity(uint256 available);

    /// @notice The callback does not match the open context, or the Pool returned without running it.
    error InvalidFlashCallback();

    /// @notice The premium the Pool charges exceeds the caller's `maxPremium`.
    error PremiumTooHigh(uint256 premium, uint256 maxPremium);

    /// @notice The premium exceeds `maxFlashFeeBps` of the amount.
    /// @param maxPremium `floor(maxFlashFeeBps * amount / 1e4)`.
    error FlashFeeTooHigh(uint256 premium, uint256 maxPremium);

    /// @notice The top-up needed to repay `F + premium` exceeds its bound.
    error TopUpExceeded(uint256 topUp, uint256 bound);

    /// @notice The operator variant's loan exceeds what the liquidation needed.
    /// @param need The largest loan allowed.
    error FlashAmountAboveNeed(uint256 flashAmount, uint256 need);

    /// @notice The operator variant's Safe would lose more than `MAX_TOP_UP_BPS` of the debt repaid.
    /// @param outlay What the Safe would lose net.
    /// @param bound `floor(D * MAX_TOP_UP_BPS / 1e4)`.
    error OutlayExceeded(uint256 outlay, uint256 bound);

    /// @notice The public helper's `claimEscrowed` found `feeRecipient` unset in the ParameterStore.
    error InvalidFeeRecipient();

    /// @notice The net payout is below the request's `minPayout`.
    error PayoutTooLow(uint256 payout, uint256 minPayout);

    /// @notice Emitted after `flashLoan` returns and the payout is sent.
    /// @param caller `msg.sender` of `flashLiquidate`.
    /// @param recipient The payout recipient.
    /// @param asset The debt asset borrowed and repaid.
    /// @param flashAmount `F`.
    /// @param premium The premium the Pool charged.
    /// @param keeperOut What LPVaultSwap paid the helper.
    /// @param topUp What the helper pulled from its payer to repay the Pool (0 when none).
    /// @param payout The net payout sent to the recipient.
    event FlashLiquidated(
        address indexed caller,
        address indexed recipient,
        address indexed asset,
        uint256 flashAmount,
        uint256 premium,
        uint256 keeperOut,
        uint256 topUp,
        uint256 payout
    );
}

/// @notice Arguments of a flash liquidation helper's `flashLiquidate`.
/// @dev Amounts are in base units of the debt asset. The helper takes no route, recipient, lender or calldata from it.
struct FlashLiquidationRequest {
    // Passed unchanged to LPVaultSwap.liquidate.
    LiquidationParams params;
    // F, the amount borrowed; 0 (no loan) only in the operator variant.
    uint256 flashAmount;
    // Most premium accepted on F.
    uint256 maxPremium;
    // Most debt asset pulled from the payer to repay the loan.
    uint256 maxTopUp;
    // Smallest net payout after the loan and premium are repaid.
    uint256 minPayout;
}
