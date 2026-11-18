// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountView, RecordView} from "./types/LensTypes.sol";

/// @title ILensAccount
/// @notice Account views of the Lens: proxy address, account state, records and escrowed payouts.
interface ILensAccount {
    /// @notice Returns a wallet's proxy address for a market and whether it is deployed.
    /// @dev The ProxyManager is immutable, so the predicted and stored addresses always agree.
    function predictProxy(
        address wallet,
        uint256 marketId
    ) external view returns (address proxy, bool deployed);

    /// @notice Returns a wallet's account view for one market (one PositionProxy).
    function getAccount(
        address wallet,
        uint256 marketId
    ) external view returns (AccountView memory account);

    /// @notice Returns `getAccount(wallet, m)` for each market `m` of `marketIds`, in order.
    function getAccounts(
        address wallet,
        uint256[] calldata marketIds
    ) external view returns (AccountView[] memory accounts);

    /// @notice Returns one page of an account's records in Collateralization's seizure-list order.
    /// @dev Empty for `limit == 0` or an `offset` past the end; reverts `LimitTooHigh` above `LENS_MAX_PAGE`.
    /// @param proxy The account's proxy (`UnknownProxy` if the AaveAdapter did not create it).
    function getRecords(
        address proxy,
        uint256 offset,
        uint256 limit
    ) external view returns (RecordView[] memory records);

    /// @notice Returns an account's unclaimed PayoutEscrow payouts, one per requested token.
    /// @param account The credited account: a borrower wallet, a keeper or `feeRecipient`.
    /// @return amounts Credits, token base units, in the order of `tokens`.
    function getEscrowClaimable(
        address account,
        address[] calldata tokens
    ) external view returns (uint256[] memory amounts);
}
