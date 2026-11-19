// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStore} from "avana/policy/parameter-store/IParameterStore.sol";
import {FlashLiquidatorBase} from "./FlashLiquidatorBase.sol";

/// @title FlashLiquidator
/// @notice The chain's public flash liquidation helper: anyone may call it, and it pulls funds only from its caller and
/// pays only its caller.
/// @dev Escrow credit no caller can be matched to goes to `feeRecipient` through `claimEscrowed`.
contract FlashLiquidator is FlashLiquidatorBase {
    /// @notice Fixes the chain's Aave V3 Pool, LPVaultSwap, MarketRegistry and ParameterStore.
    constructor(
        address pool,
        address lpVaultSwap,
        address marketRegistry,
        address parameterStore
    ) FlashLiquidatorBase(pool, lpVaultSwap, marketRegistry, parameterStore) {}

    /// @notice The public helper always takes a loan; a caller funding the whole repayment calls `liquidate` itself.
    function _zeroLoanAllowed() internal pure override returns (bool allowed) {
        allowed = false;
    }

    /// @notice Any caller may use the public helper.
    function _callerAllowed() internal pure override returns (bool allowed) {
        allowed = true;
    }

    /// @notice The caller pays its own inventory, shortfall budget and top-ups.
    function _payer() internal view override returns (address payer) {
        payer = msg.sender;
    }

    /// @notice The caller receives its own payout.
    function _recipient() internal view override returns (address recipient) {
        recipient = msg.sender;
    }

    /// @notice Anyone may claim; the credit goes to `feeRecipient`.
    /// @dev Reverts `InvalidFeeRecipient` while `feeRecipient` is unset.
    function _claimRecipient() internal view override returns (address recipient) {
        recipient = IParameterStore(PARAMETER_STORE).feeRecipient();
        if (recipient == address(0)) revert InvalidFeeRecipient();
    }

    /// @notice The request's `maxTopUp` alone bounds the top-up.
    function _topUpBound(
        uint256 maxTopUp,
        uint256 /* debtRepaid */
    ) internal pure override returns (uint256 bound) {
        bound = maxTopUp;
    }

    /// @notice The public caller sizes its own loan and pays its premium: no bound.
    // No loan-size bound in the public helper.
    // forge-lint: disable-next-item(empty-block)
    function _checkLoanNeed(
        uint256, /* flashAmount */
        uint256 /* debtRepaid */
    ) internal pure override {}

    /// @notice The public caller risks only its own funds: no bound beyond `maxTopUp` and `minPayout`.
    // No outlay bound in the public helper: the caller funds and keeps the result.
    // forge-lint: disable-next-item(empty-block)
    function _checkOutlay(
        uint256, /* outlay */
        uint256, /* payout */
        uint256 /* debtRepaid */
    ) internal pure override {}
}
