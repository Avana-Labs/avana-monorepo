// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionRef} from "../../types/PositionRef.sol";

/// @title IAaveAdapterUser
/// @notice Borrower entry points; each takes the Lock and acts only on the caller's proxy (the borrower's, for repay).
interface IAaveAdapterUser {
    /// @notice Pledges one AMM position into a market, creating the wallet's proxy for that market if needed.
    /// @dev Blocked while the market's Hub is Paused with reason `MintPathSuspect`.
    function pledge(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) external returns (address proxy, uint256 recordId, uint128 credited);

    /// @notice Borrows `amount` of an approved debt asset on the caller's account and sends it to `receiver`.
    /// @dev Consumes `expectedNonce`; reverts while either Hub is paused or frozen, or caller or receiver is frozen.
    /// @param minHealthFactor Caller's minimum health factor after the borrow, WAD; 0 for none.
    function borrow(
        uint256 marketId,
        uint256 debtReserveId,
        uint256 amount,
        address receiver,
        uint256 deadline,
        uint256 minHealthFactor,
        uint256 expectedNonce
    ) external returns (uint256 drawn);

    /// @notice Repays one debt reserve of `borrower`'s account for a market with the caller's funds.
    /// @dev Any caller pays; reads no MarketRegistry, pause or price, so repay always works.
    /// @param maxRepaySpend Most the payer allows to be pulled, base units.
    /// @param repayAll True to clear the reserve's whole debt or revert.
    function repay(
        address borrower,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 maxRepaySpend,
        bool repayAll,
        uint256 deadline
    ) external returns (uint256 spent);

    /// @notice Withdraws one record's units, burns them and returns the whole position to its depositor of record.
    /// @param units The record's credited units after reconcile.
    /// @param minHealthFactor Caller's minimum health factor after a with-debt withdrawal, WAD.
    function withdraw(
        uint256 marketId,
        PositionRef calldata position,
        uint256 units,
        uint256 deadline,
        uint256 minHealthFactor
    ) external;

    /// @notice Repays every named debt reserve in full, then makes a debt-free withdrawal of one record.
    /// @dev Reverts `DebtRemaining` if any debt reserve of the account is still borrowed.
    /// @param units The record's credited units after reconcile.
    /// @param maxRepaySpends Cap for each listed reserve, base units of its asset.
    function repayAllAndWithdraw(
        uint256 marketId,
        PositionRef calldata position,
        uint256 units,
        uint256[] calldata debtReserveIds,
        uint256[] calldata maxRepaySpends,
        uint256 deadline
    ) external;

    /// @notice Returns the position of a record at 0 credited units to its depositor of record.
    /// @dev Depositor of record only.
    function releaseZeroCredit(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) external;

    /// @notice Collects fees a custodied position earned and pays them to the depositor of record.
    /// @dev Depositor of record only. Reverts `FeesRolledIn` for AMM protocols that roll fees into the position.
    /// @return fees Fees paid to the depositor, raw units of each pool token in the market's token order.
    function collectFees(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) external returns (uint256[] memory fees);

    /// @notice Clears a proxy's stale indebted mark once its Spoke account has no debt.
    function refreshDebtMark(
        address proxy
    ) external;
}
