// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FlashLiquidatorBase} from "./FlashLiquidatorBase.sol";
import {IOperatorFlashLiquidator} from "./IOperatorFlashLiquidator.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title OperatorFlashLiquidator
/// @notice An operator's own flash liquidation helper: only `SIGNER` calls; `FUNDING_SAFE` pays and receives.
/// @dev A compromised signer can lose at most `MAX_TOP_UP_BPS` of the debt each call actually repaid.
contract OperatorFlashLiquidator is FlashLiquidatorBase, IOperatorFlashLiquidator {
    /// @inheritdoc IOperatorFlashLiquidator
    address public immutable override SIGNER;

    /// @inheritdoc IOperatorFlashLiquidator
    address public immutable override FUNDING_SAFE;

    /// @notice Margin, bps, over the debt repaid that a flash loan may take (a whole-debt quote plus Aave's dust).
    uint256 internal constant DUST_MARGIN_BPS = 500;

    /// @inheritdoc IOperatorFlashLiquidator
    uint256 public immutable override MAX_TOP_UP_BPS;

    /// @notice Fixes the chain's contracts, the operator's signer and funding Safe and the per-call outlay cap.
    /// @param maxTopUpBps Most net outlay and most top-up per call as bps of the debt repaid.
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

    /// @notice `F = 0` is allowed: `FUNDING_SAFE` funds the whole liquidation under the same outlay bound.
    function _zeroLoanAllowed() internal pure override returns (bool allowed) {
        allowed = true;
    }

    function _callerAllowed() internal view override returns (bool allowed) {
        allowed = msg.sender == SIGNER;
    }

    function _payer() internal view override returns (address payer) {
        payer = FUNDING_SAFE;
    }

    function _recipient() internal view override returns (address recipient) {
        recipient = FUNDING_SAFE;
    }

    /// @notice Only `SIGNER` may claim; the credit goes to the funding Safe.
    function _claimRecipient() internal view override returns (address recipient) {
        if (msg.sender != SIGNER) revert NotSigner();
        recipient = FUNDING_SAFE;
    }

    /// @notice The request's `maxTopUp`, capped at `⌊D × MAX_TOP_UP_BPS / 10⁴⌋`.
    function _topUpBound(
        uint256 maxTopUp,
        uint256 debtRepaid
    ) internal view override returns (uint256 bound) {
        bound = Math.min(maxTopUp, Math.mulDiv(debtRepaid, MAX_TOP_UP_BPS, BPS));
    }

    /// @notice Reverts `FlashAmountAboveNeed` if the loan exceeds the debt repaid plus the dust margin.
    function _checkLoanNeed(
        uint256 flashAmount,
        uint256 debtRepaid
    ) internal pure override {
        uint256 need = Math.mulDiv(debtRepaid, BPS + DUST_MARGIN_BPS, BPS, Math.Rounding.Ceil);
        if (flashAmount > need) revert FlashAmountAboveNeed(flashAmount, need);
    }

    /// @notice Reverts `OutlayExceeded` if the Safe's net outlay exceeds `⌊D × MAX_TOP_UP_BPS / 10⁴⌋`.
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
