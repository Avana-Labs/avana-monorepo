// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreViews} from "../../policy/parameter-store/IParameterStoreViews.sol";
import {FlashLiquidatorBase} from "./FlashLiquidatorBase.sol";

/// @title FlashLiquidator
/// @notice The chain's public flash liquidation helper (2.11 `REQ-HELPER-010`): anyone may call it, and it pulls the
/// inventory, the shortfall budget and every top-up only from its caller and pays the net payout and every market token
/// only to its caller.
/// @dev One instance per chain, named in the deployment manifest and in the MarketRegistry as `FLASH_LIQUIDATOR`, so
/// the address freeze refuses it (`REQ-MREG-020`). A residue LPVaultSwap could not deliver to it (a market token whose
/// issuer blocks the helper's address, while its caller could still receive) stays credited to it in the PayoutEscrow;
/// anyone may call `claimEscrowed`, which sends that credit to `feeRecipient`, read from the ParameterStore as
/// LPVaultSwap reads it, because the helper cannot tell which caller a pooled credit came from. A debt asset whose
/// issuer blocks the helper stops only liquidations through the helper: LPVaultSwap's payment of `keeperOut` to it
/// reverts, and callers fund `liquidate` themselves. It is never a committed operator.
/// @custom:spec REQ-HELPER-001, REQ-HELPER-010, REQ-SWAP-105, Q-242, Q-404
contract FlashLiquidator is FlashLiquidatorBase {
    /// @notice Fixes the chain's Aave V3 Pool, LPVaultSwap, MarketRegistry and ParameterStore.
    /// @param pool The chain's Aave V3 Pool, the lender of every debt asset.
    /// @param lpVaultSwap The chain's LPVaultSwap.
    /// @param marketRegistry The chain's MarketRegistry.
    /// @param parameterStore The chain's ParameterStore.
    /// @custom:spec REQ-HELPER-001, REQ-HELPER-002, REQ-HELPER-015
    constructor(
        address pool,
        address lpVaultSwap,
        address marketRegistry,
        address parameterStore
    ) FlashLiquidatorBase(pool, lpVaultSwap, marketRegistry, parameterStore) {}

    /// @notice The public helper always takes a loan: `F = 0` reverts `InvalidFlashAmount`, since a caller funding the
    /// whole repayment calls `LPVaultSwap.liquidate` itself.
    /// @return allowed Always false.
    /// @custom:spec REQ-HELPER-003, REQ-HELPER-013
    function _zeroLoanAllowed() internal pure override returns (bool allowed) {
        allowed = false;
    }

    /// @notice Any caller may use the public helper.
    /// @return allowed Always true.
    /// @custom:spec REQ-HELPER-010
    function _callerAllowed() internal pure override returns (bool allowed) {
        allowed = true;
    }

    /// @notice The caller pays its own inventory, shortfall budget and top-ups.
    /// @return payer `msg.sender`.
    /// @custom:spec REQ-HELPER-004, REQ-HELPER-010
    function _payer() internal view override returns (address payer) {
        payer = msg.sender;
    }

    /// @notice The caller receives its own payout.
    /// @return recipient `msg.sender`.
    /// @custom:spec REQ-HELPER-004, REQ-HELPER-010
    function _recipient() internal view override returns (address recipient) {
        recipient = msg.sender;
    }

    /// @notice Anyone may claim; the credit goes to `feeRecipient`.
    /// @dev Reverts `InvalidFeeRecipient` while `feeRecipient` is `address(0)`, as LPVaultSwap does (`REQ-SWAP-028`).
    /// @return recipient `ParameterStore.feeRecipient()`.
    /// @custom:spec REQ-HELPER-010
    function _claimRecipient() internal view override returns (address recipient) {
        recipient = IParameterStoreViews(PARAMETER_STORE).feeRecipient();
        if (recipient == address(0)) revert InvalidFeeRecipient();
    }

    /// @notice The request's `maxTopUp` alone bounds the top-up.
    /// @param maxTopUp The request's bound.
    /// @return bound `maxTopUp`.
    /// @custom:spec REQ-HELPER-007
    function _topUpBound(
        uint256 maxTopUp,
        uint256 /* debtRepaid */
    ) internal pure override returns (uint256 bound) {
        bound = maxTopUp;
    }

    /// @notice The public caller sizes its own loan and pays its premium: no bound.
    /// @custom:spec REQ-HELPER-007, REQ-HELPER-010
    // The public helper has no loan-size bound: anyone may borrow what the liquidation needs (REQ-HELPER-007).
    // forge-lint: disable-next-item(empty-block)
    function _checkLoanNeed(
        uint256, /* flashAmount */
        uint256 /* debtRepaid */
    ) internal pure override {}

    /// @notice The public caller risks only its own funds: no bound beyond `maxTopUp` and `minPayout`.
    /// @custom:spec REQ-HELPER-008, REQ-HELPER-010
    // The public helper has no outlay bound: the caller funds and keeps the result (REQ-HELPER-010).
    // forge-lint: disable-next-item(empty-block)
    function _checkOutlay(
        uint256, /* outlay */
        uint256, /* payout */
        uint256 /* debtRepaid */
    ) internal pure override {}
}
