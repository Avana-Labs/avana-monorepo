// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountView} from "./types/AccountView.sol";
import {RecordView} from "./types/RecordView.sol";

/// @title ILensAccount
/// @notice Account views of the Lens: proxy address, account positions with reconciliation shortfalls, an
/// account-market's records, and payouts held by the payout escrow.
interface ILensAccount {
    /// @notice Returns a wallet's proxy address for a market and whether it is deployed.
    /// @dev The ProxyManager is immutable, so the predicted and stored addresses always agree.
    /// @param wallet The wallet.
    /// @param marketId The market.
    /// @return proxy `PROXY_MANAGER.predictProxy(wallet, spoke, marketId)` with the market's CDP Spoke.
    /// @return deployed `ADAPTER.proxyOf(wallet, marketId) != address(0)`.
    /// @custom:spec REQ-LENS-008, Q-268, Q-375
    function predictProxy(
        address wallet,
        uint256 marketId
    ) external view returns (address proxy, bool deployed);

    /// @notice Returns a wallet's account view for one market (one PositionProxy).
    /// @dev Loops once over the Spoke's enabled debt reserves; never loops over records.
    /// @param wallet The wallet.
    /// @param marketId The market.
    /// @return account Proxy, nonce, Aave account data, debt per approved debt reserve, gate status, per-market
    /// positions, breaker reasons, rescue units and whether the wallet is frozen.
    /// @custom:spec REQ-LENS-009, REQ-LENS-010, Q-234, Q-241, Q-242, Q-253
    function getAccount(
        address wallet,
        uint256 marketId
    ) external view returns (AccountView memory account);

    /// @notice Returns one page of an account's records (at most 16) in Collateralization's seizure-list order.
    /// @dev Read with `Collateralization.getAccountRecords(proxy, vaultToken, offset, limit)`
    /// with the vault token of the proxy's market; zero-credit records are not in
    /// the list. Returns an empty array for `limit == 0` or an `offset` beyond the last record; fails with
    /// `LimitTooHigh` above `LENS_MAX_PAGE`.
    /// @param proxy The account's proxy; its market is the proxy's `MARKET_ID()`.
    /// @param offset Position of the first record returned.
    /// @param limit Maximum number of records.
    /// @return records The page.
    /// @custom:spec REQ-LENS-011, REQ-LENS-023, REQ-LENS-024
    function getRecords(
        address proxy,
        uint256 offset,
        uint256 limit
    ) external view returns (RecordView[] memory records);

    /// @notice Returns an account's unclaimed payouts held by the PayoutEscrow (the payout escrow), one per requested
    /// token.
    /// @dev `amounts[i] = PAYOUT_ESCROW.claimable(tokens[i], account)` in that token's base units, in the order of
    /// `tokens`. The caller passes the tokens it wants (debt assets, and pool tokens for route residue); the Lens does not
    /// enumerate tokens, so the call is bounded by `tokens.length`. Example: after a liquidation whose 1,627,460 raw
    /// USDC surplus transfer to `account` failed and was escrowed, `[USDC, USDT]` returns `[1,627,460, 0]`.
    /// @param account The credited account: a borrower wallet, a keeper or `feeRecipient`.
    /// @param tokens Tokens to read.
    /// @return amounts Credits, token base units, in the order of `tokens`.
    /// @custom:spec REQ-LENS-027, REQ-ESCROW-006, Q-214, Q-401
    function getEscrowClaimable(
        address account,
        address[] calldata tokens
    ) external view returns (uint256[] memory amounts);
}
