// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashLiquidator} from "./IFlashLiquidator.sol";

/// @title IOperatorFlashLiquidator
/// @notice The operator variant of the flash liquidation helper: bound to one signer and one funding Safe.
/// @dev Refuses every caller except `SIGNER` (`NotSigner`); pulls the inventory `debtToCover - F`, the shortfall budget
/// `maxShortfall` and every top-up only from `FUNDING_SAFE` (which approves the helper for the debt asset); pays the net
/// payout and every market token only to `FUNDING_SAFE`; claims its escrowed credits only to `FUNDING_SAFE`. With `D`
/// the debt LPVaultSwap repaid in the call, it refuses a loan `F > ceil(D * (1e4 + LENS_DUST_MARGIN_BPS) / 1e4)`
/// (`FlashAmountAboveNeed`), bounds each top-up by `floor(D * MAX_TOP_UP_BPS / 1e4)` as well as `maxTopUp`, and
/// refuses a call whose net outlay from the Safe (inventory, shortfall budget and top-up, less the payout) exceeds
/// `floor(D * MAX_TOP_UP_BPS / 1e4)` (`OutlayExceeded`). A compromised signer key can only start liquidations that pay
/// the operator's own Safe and can make it lose at most `MAX_TOP_UP_BPS` of the debt each call actually repaid. The
/// operator registers this helper's address, or its signer's address when it calls `liquidate` directly, as its
/// committed operator (REQ-SWAP-033). Example: with `MAX_TOP_UP_BPS = 100`, a liquidation repaying `D = 1,950` USDC can
/// cost the Safe at most 19.5 USDC net and borrow at most 2,047.5 USDC, whatever `debtToCover`, `F` or `maxTopUp` the
/// signer sends.
/// @custom:spec REQ-HELPER-001, REQ-HELPER-007, REQ-HELPER-011, Q-219, Q-381, Q-404
interface IOperatorFlashLiquidator is IFlashLiquidator {
    /// @notice The only address allowed to call `flashLiquidate` and `claimEscrowed` (immutable).
    /// @return signer Address.
    /// @custom:spec REQ-HELPER-011
    function SIGNER() external view returns (address signer);

    /// @notice The operator's funding Safe: payer of inventory and top-ups and recipient of every payout (immutable).
    /// @return safe Address.
    /// @custom:spec REQ-HELPER-011
    function FUNDING_SAFE() external view returns (address safe);

    /// @notice Most net outlay of the Safe, and most top-up, per call as bps of the debt repaid (immutable, at most
    /// 10^4).
    /// @return bps Basis points.
    /// @custom:spec REQ-HELPER-001, REQ-HELPER-007, REQ-HELPER-011
    function MAX_TOP_UP_BPS() external view returns (uint256 bps);
}
