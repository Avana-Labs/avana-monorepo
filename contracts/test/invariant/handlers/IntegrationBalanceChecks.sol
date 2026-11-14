// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationResult} from "../../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IFlashLiquidatorEvents} from "../../../src/periphery/flash-liquidator/IFlashLiquidatorEvents.sol";
import {FlashLiquidationRequest} from "../../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev The debt asset held by every address a liquidation can move it between (direct or through the helper).
struct Held {
    uint256 caller;
    uint256 lvs;
    uint256 hub;
    uint256 fee;
    uint256 feeEscrowed;
    uint256 wallet;
    uint256 walletEscrowed;
    uint256 escrow;
    uint256 sources;
    uint256 parked;
    // The flash lender's aToken (the helper's loan and premium) and the helper with its PayoutEscrow credit.
    uint256 lender;
    uint256 helper;
    uint256 helperEscrowed;
}

/// @title IntegrationBalanceChecks
/// @notice TEST-104 on balances for IntegrationHandler: pure comparisons of the debt-asset holdings before and after
/// one liquidation, direct or through the public flash liquidation helper. External functions, so the library is
/// deployed on its own and linked: the handler stays within EIP-170 with its steering and liveness checks.
library IntegrationBalanceChecks {
    /// @notice A direct liquidation: the debt asset that left the caller and the sources (the LPVault and the route
    /// pools) equals what reached the Hub, the fee recipient and the borrower (paid or escrowed) and Collateralization
    /// (pool tokens of a reconcile, held for `settlePending`); LPVaultSwap's balance is unchanged, the escrow rose by
    /// exactly the escrowed credit, and the flash lender and the helper are untouched (`conserved`). The result's `D`,
    /// `A`, `B`, `R` and the caller's net equal those changes (`reported`).
    function direct(
        Held memory b,
        Held memory a,
        LiquidationResult memory r
    ) external pure returns (bool conserved, bool reported) {
        int256 callerIn = int256(b.caller) - int256(a.caller);
        int256 parked = int256(a.parked) - int256(b.parked);
        int256 recovered = int256(b.sources) - int256(a.sources) - parked;
        int256 toHub = int256(a.hub) - int256(b.hub);
        int256 toFee = int256(a.fee + a.feeEscrowed) - int256(b.fee + b.feeEscrowed);
        int256 toBorrower = int256(a.wallet + a.walletEscrowed) - int256(b.wallet + b.walletEscrowed);
        int256 escrowed = int256(a.feeEscrowed + a.walletEscrowed) - int256(b.feeEscrowed + b.walletEscrowed);
        conserved = callerIn + recovered == toHub + toFee + toBorrower && a.lvs == b.lvs && parked >= 0
            && int256(a.escrow) - int256(b.escrow) == escrowed && a.lender == b.lender && a.helper == b.helper
            && a.helperEscrowed == b.helperEscrowed;
        reported = toHub == int256(r.debtRepaid) && toFee == int256(r.avanaFee)
            && toBorrower == int256(r.borrowerSurplus) && recovered == int256(r.recovered)
            && -callerIn == int256(r.keeperOut) - int256(r.callerFunds) - int256(r.shortfall);
    }

    /// @notice A liquidation through the public helper: the debt asset that left the caller (prefund and top-up, less
    /// the payout) and the sources equals what reached the Hub, the fee recipient, the borrower, Collateralization and
    /// the flash lender (the premium); the helper and LPVaultSwap end where they started (a helper credit left in the
    /// PayoutEscrow counts as held by the caller's side) (`conserved`). `FlashLiquidated` reports the premium the
    /// lender kept, the payout the caller received and the top-up it paid (`reported`).
    function viaHelper(
        Held memory b,
        Held memory a,
        FlashLiquidationRequest memory q,
        uint256 payout,
        Vm.Log[] memory logs,
        address helper
    ) external pure returns (bool conserved, bool reported) {
        int256 callerIn = int256(b.caller) - int256(a.caller);
        int256 toLender = int256(a.lender) - int256(b.lender);
        conserved = _helperConserved(b, a, callerIn, toLender);
        (bool found, uint256 premium, uint256 topUp, uint256 reportedPayout) = _flashLiquidated(logs, helper);
        uint256 prefund = q.params.debtToCover - q.flashAmount + q.params.maxShortfall;
        reported = found && reportedPayout == payout && int256(premium) == toLender && premium <= q.maxPremium
            && topUp <= q.maxTopUp && callerIn == int256(prefund + topUp) - int256(payout);
    }

    function _helperConserved(
        Held memory b,
        Held memory a,
        int256 callerIn,
        int256 toLender
    ) private pure returns (bool) {
        int256 parked = int256(a.parked) - int256(b.parked);
        int256 recovered = int256(b.sources) - int256(a.sources) - parked;
        int256 toHub = int256(a.hub) - int256(b.hub);
        int256 toFee = int256(a.fee + a.feeEscrowed) - int256(b.fee + b.feeEscrowed);
        int256 toBorrower = int256(a.wallet + a.walletEscrowed) - int256(b.wallet + b.walletEscrowed);
        int256 toHelper = int256(a.helperEscrowed) - int256(b.helperEscrowed);
        int256 escrowed = int256(a.feeEscrowed + a.walletEscrowed + a.helperEscrowed)
            - int256(b.feeEscrowed + b.walletEscrowed + b.helperEscrowed);
        return callerIn + recovered == toHub + toFee + toBorrower + toLender + toHelper && a.lvs == b.lvs
            && a.helper == b.helper && parked >= 0 && toLender >= 0 && toHelper >= 0
            && int256(a.escrow) - int256(b.escrow) == escrowed;
    }

    /// @dev The premium, top-up and payout of the helper's `FlashLiquidated` event in `logs`.
    function _flashLiquidated(
        Vm.Log[] memory logs,
        address helper
    ) private pure returns (bool found, uint256 premium, uint256 topUp, uint256 payout) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == helper && logs[i].topics.length != 0
                    && logs[i].topics[0] == IFlashLiquidatorEvents.FlashLiquidated.selector
            ) {
                (, premium,, topUp, payout) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                return (true, premium, topUp, payout);
            }
        }
    }
}
