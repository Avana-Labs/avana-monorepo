// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LensConstants} from "../../lens/lens/LensConstants.sol";
import {FlashLiquidatorBase} from "./FlashLiquidatorBase.sol";
import {IOperatorFlashLiquidator} from "./IOperatorFlashLiquidator.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OperatorFlashLiquidator
/// @notice An operator's own flash liquidation helper (2.11 `REQ-HELPER-011`), bound to one signer and one funding
/// Safe: only `SIGNER` may call; the inventory `X − F`, the shortfall budget and every top-up come only from
/// `FUNDING_SAFE`, and the payout, every market token and every claimed credit go only to it. With `D` the debt
/// LPVaultSwap repaid in the call, the loan is at most `⌈D × (10⁴ + LENS_DUST_MARGIN_BPS) / 10⁴⌉`, and the Safe's net
/// outlay (what left it less the payout) and each top-up are at most `⌊D × MAX_TOP_UP_BPS / 10⁴⌋`. A request with
/// `F = 0` takes no loan: the Safe funds `X + maxShortfall`, `liquidate` runs directly, nothing is owed, and the same
/// `minPayout` and outlay bounds apply to the result.
/// @dev A compromised signer key can only start liquidations that pay the Safe, and loses at most `MAX_TOP_UP_BPS` of
/// the debt each call actually repaid, whatever `debtToCover`, `F`, `maxShortfall` or `maxTopUp` it sends: the bound is
/// on the measured outcome, not on a signer-chosen input. Example: `MAX_TOP_UP_BPS = 100` and a liquidation repaying
/// `D = 1,950` USDC: the loan is at most 2,047.5 USDC and the Safe loses at most 19.5 USDC net. The escrow
/// `claimEscrowed` claims from is the one LPVaultSwap credits (`LP_VAULT_SWAP.PAYOUT_ESCROW()`).
/// @custom:spec REQ-HELPER-001, REQ-HELPER-007, REQ-HELPER-010, REQ-HELPER-011, Q-219, Q-381, Q-404
contract OperatorFlashLiquidator is FlashLiquidatorBase, IOperatorFlashLiquidator {
    /// @inheritdoc IOperatorFlashLiquidator
    address public immutable override SIGNER;

    /// @inheritdoc IOperatorFlashLiquidator
    address public immutable override FUNDING_SAFE;

    /// @inheritdoc IOperatorFlashLiquidator
    uint256 public immutable override MAX_TOP_UP_BPS;

    /// @notice Fixes the chain's contracts, the operator's signer and funding Safe and the per-call outlay cap.
    /// @dev Reverts `ZeroAddress` for any zero address, `FlashSourceIsHub` if the Pool is a recorded Hub and
    /// `InvalidTopUpBps` unless `maxTopUpBps ≤ 10⁴`.
    /// @param pool The chain's Aave V3 Pool, the lender of every debt asset.
    /// @param lpVaultSwap The chain's LPVaultSwap.
    /// @param marketRegistry The chain's MarketRegistry.
    /// @param parameterStore The chain's ParameterStore.
    /// @param signer The only caller.
    /// @param fundingSafe Payer of inventory, shortfall budgets and top-ups and recipient of every payout.
    /// @param maxTopUpBps Most net outlay and most top-up per call as bps of the debt repaid.
    /// @custom:spec REQ-HELPER-001, REQ-HELPER-002, REQ-HELPER-011, REQ-HELPER-015
    constructor(
        address pool,
        address lpVaultSwap,
        address marketRegistry,
        address parameterStore,
        address signer,
        address fundingSafe,
        uint256 maxTopUpBps
    ) FlashLiquidatorBase(pool, lpVaultSwap, marketRegistry, parameterStore) {
        if (signer == address(0) || fundingSafe == address(0)) revert ZeroAddress();
        if (maxTopUpBps > BPS) revert InvalidTopUpBps(maxTopUpBps);
        SIGNER = signer;
        FUNDING_SAFE = fundingSafe;
        MAX_TOP_UP_BPS = maxTopUpBps;
    }

    /// @notice The operator helper accepts `F = 0` (REQ-HELPER-003): no loan is taken and `FUNDING_SAFE` funds `X` and the
    /// shortfall budget, so a liquidation with no flash liquidity (a paused or empty reserve, a changed Pool) stays on
    /// the committed-operator path under the same outlay bound.
    /// @return allowed Always true.
    /// @custom:spec REQ-HELPER-003, REQ-HELPER-011
    function _zeroLoanAllowed() internal pure override returns (bool allowed) {
        allowed = true;
    }

    /// @notice Only `SIGNER` may call.
    /// @return allowed `msg.sender == SIGNER`.
    /// @custom:spec REQ-HELPER-003, REQ-HELPER-011, REQ-HELPER-013
    function _callerAllowed() internal view override returns (bool allowed) {
        allowed = msg.sender == SIGNER;
    }

    /// @notice The funding Safe pays the inventory, the shortfall budget and every top-up.
    /// @return payer `FUNDING_SAFE`.
    /// @custom:spec REQ-HELPER-004, REQ-HELPER-011
    function _payer() internal view override returns (address payer) {
        payer = FUNDING_SAFE;
    }

    /// @notice The funding Safe receives the payout and every market token.
    /// @return recipient `FUNDING_SAFE`.
    /// @custom:spec REQ-HELPER-004, REQ-HELPER-011
    function _recipient() internal view override returns (address recipient) {
        recipient = FUNDING_SAFE;
    }

    /// @notice Only `SIGNER` may claim; the credit goes to the funding Safe.
    /// @return recipient `FUNDING_SAFE`.
    /// @custom:spec REQ-HELPER-011
    function _claimRecipient() internal view override returns (address recipient) {
        if (msg.sender != SIGNER) revert NotSigner();
        recipient = FUNDING_SAFE;
    }

    /// @notice The request's `maxTopUp`, capped at `⌊D × MAX_TOP_UP_BPS / 10⁴⌋`.
    /// @param maxTopUp The request's bound.
    /// @param debtRepaid `D`.
    /// @return bound `min(maxTopUp, ⌊D × MAX_TOP_UP_BPS / 10⁴⌋)`.
    /// @custom:spec REQ-HELPER-007, REQ-HELPER-011
    function _topUpBound(
        uint256 maxTopUp,
        uint256 debtRepaid
    ) internal view override returns (uint256 bound) {
        bound = Math.min(maxTopUp, Math.mulDiv(debtRepaid, MAX_TOP_UP_BPS, BPS));
    }

    /// @notice Reverts `FlashAmountAboveNeed` if `F > ⌈D × (10⁴ + LENS_DUST_MARGIN_BPS) / 10⁴⌉`: the loan never exceeds
    /// the debt repaid plus the margin the Lens adds to a whole-debt quote (`REQ-SWAP-005`), so the premium on loan the
    /// liquidation did not use is bounded too.
    /// @param flashAmount `F`.
    /// @param debtRepaid `D`.
    /// @custom:spec REQ-HELPER-011
    function _checkLoanNeed(
        uint256 flashAmount,
        uint256 debtRepaid
    ) internal pure override {
        uint256 need = Math.mulDiv(debtRepaid, BPS + LensConstants.LENS_DUST_MARGIN_BPS, BPS, Math.Rounding.Ceil);
        if (flashAmount > need) revert FlashAmountAboveNeed(flashAmount, need);
    }

    /// @notice Reverts `OutlayExceeded` if the Safe's net outlay `outlay − payout` exceeds `⌊D × MAX_TOP_UP_BPS / 10⁴⌋`.
    /// @param outlay The inventory, shortfall budget and top-up pulled from the Safe.
    /// @param payout The payout returned to it.
    /// @param debtRepaid `D`.
    /// @custom:spec REQ-HELPER-011
    function _checkOutlay(
        uint256 outlay,
        uint256 payout,
        uint256 debtRepaid
    ) internal view override {
        if (outlay <= payout) return;
        uint256 bound = Math.mulDiv(debtRepaid, MAX_TOP_UP_BPS, BPS);
        if (outlay - payout > bound) revert OutlayExceeded(outlay - payout, bound);
    }
}
