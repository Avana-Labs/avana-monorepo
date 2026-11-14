// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SettlementReport} from "../../types/SettlementReport.sol";

/// @title ILPVaultSwapEvents
/// @notice Events of LPVaultSwap: liquidations settled in the debt asset, borrower surplus deliveries, swap-route
/// failures and residue, committed-operator registry changes, forwarded pending settlements and repays with collateral
/// (the only flash-funded path). Every value
/// amount is in base units of the repaid debt asset; every token amount array is in raw units of each pool token, in
/// the market's token order.
interface ILPVaultSwapEvents {
    /// @notice Emitted when a liquidation completes.
    /// @param caller The caller (`msg.sender`), any address; a flash liquidation helper when one was used.
    /// @param proxy The liquidated PositionProxy.
    /// @param marketId The collateral market.
    /// @param report Settlement figures in the debt asset: debt repaid, unwound amounts, caller funding, route mode and
    /// swap routes used, caller shortfall top-up, surplus, Avana fee, keeper reward, keeper payout and borrower surplus.
    /// @custom:spec REQ-SWAP-026, REQ-SWAP-072, REQ-SWAP-075, Q-076, Q-213, Q-216, Q-379, Q-404
    event LiquidationSettled(
        address indexed caller, address indexed proxy, uint256 indexed marketId, SettlementReport report
    );

    /// @notice Emitted when a liquidation's borrower surplus `B > 0` was delivered to the borrower's wallet or, after a
    /// failed gas-limited transfer, deposited in the PayoutEscrow credited to it.
    /// @param proxy The liquidated PositionProxy.
    /// @param wallet The borrower's wallet (`AaveAdapter.walletOf(proxy)`).
    /// @param debtAsset The debt asset paid.
    /// @param amount `B`, base units.
    /// @param escrowed True when the amount went to the PayoutEscrow.
    /// @custom:spec REQ-SWAP-026, REQ-SWAP-027, REQ-SWAP-076, LIQ-085, Q-337
    event BorrowerSurplusPaid(
        address indexed proxy, address indexed wallet, address indexed debtAsset, uint256 amount, bool escrowed
    );

    /// @notice Emitted when `deleverage` took and repaid a flash loan of the debt asset through the chain's
    /// IFlashSource; a liquidation never emits it.
    /// @param marketId The collateral market.
    /// @param flashSource The IFlashSource used.
    /// @param asset The debt asset lent.
    /// @param amount F, base units.
    /// @param premium phi, base units; satisfies `phi × 1e4 ≤ maxFlashFeeBps × F`.
    /// @custom:spec REQ-SWAP-013, REQ-SWAP-106, Q-379
    event FlashLoanUsed(
        uint256 indexed marketId, address indexed flashSource, address indexed asset, uint256 amount, uint256 premium
    );

    /// @notice Emitted when a primary swap-route call reverted and the backup was tried.
    /// @param marketId The collateral market.
    /// @param token The pool token being swapped.
    /// @param route The primary swap route.
    /// @param errorSelector First four bytes of the revert data.
    /// @custom:spec REQ-SWAP-058, Q-379
    event RouteFailed(uint256 indexed marketId, address indexed token, address route, bytes4 errorSelector);

    /// @notice Emitted when unswapped route tokens or a dust leg were sent to the caller of `liquidate`, or escrowed for
    /// it after a failed gas-limited transfer.
    /// @param caller The caller.
    /// @param token The returned token.
    /// @param amount Amount returned (never 0: a zero residue is skipped).
    /// @param escrowed True when the amount went to the PayoutEscrow credited to the caller.
    /// @custom:spec REQ-SWAP-024, REQ-SWAP-076, REQ-SWAP-077, REQ-SWAP-121
    event ResidueReturned(address indexed caller, address indexed token, uint256 amount, bool escrowed);

    /// @notice Emitted when a committed operator is registered.
    /// @param keeper The operator.
    /// @custom:spec REQ-SWAP-033
    event KeeperAdded(address indexed keeper);

    /// @notice Emitted when a committed operator is removed.
    /// @param keeper The operator.
    /// @custom:spec REQ-SWAP-035
    event KeeperRemoved(address indexed keeper);

    /// @notice Emitted when `settlePending` completes: stranded vault tokens burned through the AaveAdapter, the
    /// released pool tokens swapped into the market's settlement asset, and that asset added to the First-Loss Reserve of the
    /// market's (funding Hub, settlement asset), or carried while it is worth less than one Hub share.
    /// @param caller The caller (any address).
    /// @param marketId The market.
    /// @param vaultToken The market's vault token.
    /// @param units Vault-token units settled and burned (`x`).
    /// @param amounts Raw amount of each pool token released by Collateralization.
    /// @param debtAsset The debt asset recovered.
    /// @param added `R`, settlement asset this call recovered.
    /// @param minPending Floor `R` had to meet (SPEC-LIQ-014), debt-asset base units.
    /// @param firstLossReserve `MarketRegistry.firstLossReserveOf(fundingHub, debtAsset)`.
    /// @param routeUsed Swap route used per pool token: 0 none, 1 primary, 2 backup.
    /// @param funded `Rt = R + carry` passed to `fund`, or 0 when the amount was carried.
    /// @param carried The carry of the settlement asset after the call (0 after a funding).
    /// @custom:spec REQ-SWAP-066, REQ-SWAP-070, SPEC-LIQ-014, Q-201, Q-211, Q-236, Q-379
    event PendingSettlementForwarded(
        address indexed caller,
        uint256 indexed marketId,
        address vaultToken,
        uint256 units,
        uint256[] amounts,
        address indexed debtAsset,
        uint256 added,
        uint256 minPending,
        address firstLossReserve,
        uint8[] routeUsed,
        uint256 funded,
        uint256 carried
    );

    /// @notice Emitted when `deleverage` completes.
    /// @param proxy The borrower's PositionProxy.
    /// @param marketId The market of the released record.
    /// @param debtReserveId The debt reserve repaid.
    /// @param units Vault-token units released.
    /// @param debtRepaid Debt reduction, debt-asset base units.
    /// @param recovered `R`, debt asset from the unwind and the swaps.
    /// @param flashPremium `phi`, debt-asset base units.
    /// @param debtAssetOut Debt asset sent to the borrower's wallet.
    /// @custom:spec REQ-SWAP-106, SPEC-LIQ-020, Q-255, Q-379
    event Deleveraged(
        address indexed proxy,
        uint256 indexed marketId,
        uint256 indexed debtReserveId,
        uint128 units,
        uint256 debtRepaid,
        uint256 recovered,
        uint256 flashPremium,
        uint256 debtAssetOut
    );
}
