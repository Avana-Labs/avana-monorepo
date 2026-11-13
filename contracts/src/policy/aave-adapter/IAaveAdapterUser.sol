// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionRef} from "../../types/PositionRef.sol";

/// @title IAaveAdapterUser
/// @notice Borrower entry points of the AaveAdapter. Each acquires the Lock first and releases it last, checks
/// `block.timestamp <= deadline`, and acts only on `proxyOf[msg.sender][marketId]` (or `proxyOf[borrower][marketId]`
/// for repay). An account is one PositionProxy bound to one (wallet, CDP Spoke, market); the Spoke is the market's.
/// Positions are named by `PositionRef` (`integrationId`, `positionKey`), never by an AMM-specific token identifier,
/// and token amounts are arrays in the order of the market's `tokens`.
interface IAaveAdapterUser {
    /// @notice Pledges one AMM position into a market, creating the wallet's proxy for that market if needed.
    /// @dev Order: Lock; `DeadlineExpired`; `UnknownMarket` unless the registry's market names a VaultTokenFactory token
    /// whose own market, Spoke and Hub are the record's; `ApplicationPaused` if the market's Hub is Paused with reason
    /// `MintPathSuspect`; `UnknownSpoke` unless its CDP Spoke is approved; `IntegrationMismatch` unless
    /// `position.integrationId` is the market's; on the wallet's first pledge to the market
    /// `ProxyManager.deployProxy(msg.sender, spoke, marketId)` (the ProxyManager refuses a frozen wallet),
    /// `AccountNotEmpty` unless the new proxy's Spoke account has no debt and no collateral, store the binding (wallet,
    /// Spoke, market, vault token, reserve), emit `UserProxyCreated`; `ApplicationFrozen` if Frozen
    /// and `borrowCount == 0`; `requireRescue` under `Paused(General)` or for a frozen caller; `addValidProxy` if not yet
    /// valid; read the backing gap; `Collateralization.pledge(msg.sender, proxy, vaultToken, position.positionKey, requireRescue)` with the market's
    /// vault token from its MarketRegistry record
    /// (custody through the market's LPVault, the integration's exact-shape check, AMMN-RT-01, `RiskModule.checkPledge`
    /// with `minPledgeUsd`, breakers, the 16-record limit and the rescue rule, record); `vaultToken.mint(proxy,
    /// credited)`; through `proxy.execute`, approve exactly `credited` to the Spoke, `spoke.supply(reserveId, credited,
    /// proxy)`, reset the approval to 0, enable the reserve as collateral and assert it enabled (INV-017);
    /// `SupplyIncomplete` unless supplied shares rose by `credited`; `BackingMismatch` unless the backing gap is
    /// unchanged and `totalSupply <= totalCredited + pending.units`; `CollateralAdded`. The wallet approves the market's
    /// LPVault for the position.
    /// @param marketId The market.
    /// @param position The position's AMM integration and key, owned by `msg.sender`.
    /// @param deadline Last valid `block.timestamp`.
    /// @return proxy The wallet's proxy for the market.
    /// @return recordId Collateralization record identifier.
    /// @return credited Credited units minted and supplied.
    /// @custom:spec REQ-ADAPTER-065, REQ-ADAPTER-066, REQ-ADAPTER-068, REQ-ADAPTER-069, REQ-ADAPTER-045, REQ-ADAPTER-046, REQ-ADAPTER-072, REQ-ADAPTER-073, REQ-ADAPTER-077, REQ-ADAPTER-082, REQ-ADAPTER-083, REQ-RISK-057, REQ-RISK-066, Q-223, Q-224, Q-225, Q-230, Q-242, Q-252, Q-257, Q-375, Q-376
    function pledge(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) external returns (address proxy, uint256 recordId, uint128 credited);

    /// @notice Borrows `amount` of an approved debt asset on the caller's account for a market and sends it to
    /// `receiver`.
    /// @dev Order: Lock; `DeadlineExpired`; `ZeroAmount`; `ApplicationFrozen` / `ApplicationPaused` unless the market's
    /// Hub and the debt reserve's funding Hub are both None; `NoProxy`; `UnknownDebtReserve` unless approved on the
    /// proxy's Spoke; `InvalidReceiver` (REQ-PROXY-017); `AddressIsFrozen` for a frozen caller or receiver; `BadNonce`,
    /// then `borrowNonce[proxy] += 1`; `RiskModule.preBorrowCheck(proxy, debtReserveId, amount)` (pokes and every gate
    /// over the market and every debt reserve, breakers; no minimum debt, `Q-381`; errors propagate);
    /// `Collateralization.markIndebted(proxy)` (sets the indebted mark, moves no charge, Q-396); through `proxy.execute`, `spoke.borrow(debtReserveId, amount, proxy)` then `asset.transfer(receiver, amount)`, with
    /// `UnitsMismatch` unless the proxy's balance delta equals `amount` and ends at its start;
    /// `RiskModule.postHealthCheck(proxy, minHealthFactor)` (rescue-excluded `hfEx >= max(1e18,
    /// hardHealthFloor(marketId), minHealthFactor)`, the hard floor 0 = off by default, Q-398); `Borrowed`. Any revert undoes the nonce, the pokes and the
    /// transfer. No batch, no pledge-and-borrow.
    /// @param marketId The account's market.
    /// @param debtReserveId Approved debt reserve of the market's CDP Spoke.
    /// @param amount Amount in the asset's base units.
    /// @param receiver Recipient of the borrowed asset.
    /// @param deadline Last valid `block.timestamp`.
    /// @param minHealthFactor Caller's minimum health factor after the borrow, WAD; 0 for none.
    /// @param expectedNonce Must equal `borrowNonce(proxy)`.
    /// @return drawn Amount drawn and forwarded, equal to `amount`.
    /// @custom:spec REQ-PROXY-015, REQ-PROXY-016, REQ-PROXY-017, REQ-PROXY-018, REQ-PROXY-019, REQ-PROXY-020, REQ-PROXY-021, REQ-PROXY-022, REQ-PROXY-023, REQ-PROXY-024, REQ-PROXY-025, REQ-PROXY-026, REQ-PROXY-079, REQ-ADAPTER-067, SPEC-PROXY-001, SPEC-PROXY-002, SPEC-PROXY-004, SPEC-PROXY-006, REQ-ADAPTER-082, REQ-RISK-065, REQ-RISK-068, BOR-001, BOR-002, BOR-003, BOR-004, BOR-005, BOR-006, BOR-007, BOR-010, BOR-011, BOR-014, BOR-015, BOR-016, BOR-017, Q-106, Q-229, Q-233, Q-241, Q-242, Q-253, Q-376, Q-380
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
    /// @dev Any caller; the payer is `msg.sender` and approves the Adapter. Order: Lock; `DeadlineExpired`; `NoProxy`;
    /// `D = spoke.getUserTotalDebt(debtReserveId, proxy)` (no MarketRegistry check: the Spoke repays only reserves it
    /// lends); partial: `ZeroAmount` if `maxRepaySpend == 0`; `D == 0` returns 0 with no transfer and no event;
    /// repay-all: `RepayExceedsMax` if `D > maxRepaySpend`, else `x = maxRepaySpend`; partial `x = min(maxRepaySpend,
    /// D)`; `safeTransferFrom(msg.sender, proxy, x)`, `received` = the proxy's balance delta (`UnitsMismatch` if 0 or
    /// above `x`); through `proxy.execute`, approve exactly `received`, `spoke.repay(debtReserveId, received, proxy)`,
    /// reset the approval, return `received - spent` to the payer when non-zero (Aave takes at most the debt);
    /// repay-all: `DebtRemaining` unless the reserve's debt is 0; `Repaid`; when the reserve's debt is 0 after the
    /// repay, `Collateralization.markDebtFree(proxy)`, which clears the indebted mark only at `borrowCount == 0`
    /// (REQ-PROXY-032). Never reads the MarketRegistry, the pause
    /// state, the address freeze, a breaker, the RiskModule, a price or a parameter: the binding (Spoke, vault token,
    /// reserve) comes from the Adapter's own storage written at proxy creation.
    /// @param borrower The wallet whose account is repaid.
    /// @param marketId The account's market.
    /// @param debtReserveId The debt reserve repaid.
    /// @param maxRepaySpend Most the payer allows to be pulled, base units.
    /// @param repayAll True to clear the reserve's whole debt or revert.
    /// @param deadline Last valid `block.timestamp`.
    /// @return spent Amount consumed by `Spoke.repay`.
    /// @custom:spec REQ-PROXY-027, REQ-PROXY-028, REQ-PROXY-029, REQ-PROXY-030, REQ-PROXY-031, REQ-PROXY-032, REQ-PROXY-083, REQ-PROXY-084, REQ-ADAPTER-047, REQ-ADAPTER-085, REQ-ADAPTER-086, SPEC-PROXY-003, SPEC-PROXY-007, REP-001, REP-002, REP-003, REP-004, REP-005, REP-006, REP-010, REP-011, REP-012, INV-043, Q-180, Q-212, Q-227, Q-231, Q-260, Q-269, Q-271, Q-375
    function repay(
        address borrower,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 maxRepaySpend,
        bool repayAll,
        uint256 deadline
    ) external returns (uint256 spent);

    /// @notice Withdraws one record's units, burns them and returns the whole position to its depositor of record.
    /// @dev Order: Lock; `DeadlineExpired`; `NoProxy`; `ZeroAmount`; `IntegrationMismatch` unless
    /// `position.integrationId` is the bound market's (from the Adapter's own binding, no MarketRegistry read); debt-free
    /// iff `spoke.getUserAccountData(proxy).borrowCount == 0`. Debt-free: no MarketRegistry read, no RiskModule call.
    /// With debt: `ApplicationPaused` if the market's Hub is Paused, `AddressIsFrozen` for a frozen caller, then
    /// `RiskModule.preWithdrawCheck(proxy)`. Then through `proxy.execute`, `spoke.withdraw(reserveId, units, proxy)`
    /// with `UnitsMismatch` unless both the returned amount and the balance rise equal `units`, and the collateral
    /// cleanup; `vaultToken.burn(proxy, units)`; `Collateralization.release(proxy, vaultToken, position.positionKey, units)`
    /// (reconcile, `units ==` credited, debit, position return through the market's LPVault); with debt
    /// `RiskModule.postHealthCheck(proxy, minHealthFactor)` (after the debit, so the record's rescue units are not
    /// excluded twice); backing-gap check (`BackingMismatch`); `CollateralWithdrawn`. One position per call.
    /// @param marketId The account's market.
    /// @param position The record's position.
    /// @param units The record's credited units after reconcile (`Collateralization.previewRelease`).
    /// @param deadline Last valid `block.timestamp`.
    /// @param minHealthFactor Caller's minimum health factor after a with-debt withdrawal, WAD.
    /// @custom:spec REQ-PROXY-033, REQ-PROXY-034, REQ-PROXY-035, REQ-PROXY-036, REQ-PROXY-037, REQ-PROXY-038, REQ-PROXY-039, REQ-ADAPTER-069, REQ-ADAPTER-047, REQ-ADAPTER-082, REQ-ADAPTER-086, SPEC-PROXY-001, SPEC-PROXY-005, SPEC-PROXY-008, WDR-001, WDR-002, WDR-003, WDR-004, WDR-005, WDR-006, WDR-007, WDR-011, WDR-012, WDR-013, WDR-018, INV-045, Q-201, Q-224, Q-227, Q-234, Q-242, Q-257, Q-260, Q-375, Q-376
    function withdraw(
        uint256 marketId,
        PositionRef calldata position,
        uint256 units,
        uint256 deadline,
        uint256 minHealthFactor
    ) external;

    /// @notice Repays every named debt reserve in full, requires every debt reserve of the account at 0, then makes a
    /// debt-free withdrawal of one record, in one call.
    /// @dev `LengthMismatch` unless the arrays have equal length. One Lock acquisition. For each listed reserve the
    /// repay steps run with `msg.sender` as payer and borrower and `repayAll = true` under its own cap, refunding the
    /// unused part; then, if `borrowCount > 0`, `DebtRemaining(r, d)` for the first reserve the Spoke reports borrowed;
    /// then `Collateralization.markDebtFree(proxy)` and the debt-free branch of `withdraw`. Reads no MarketRegistry state and calls no RiskModule function.
    /// @param marketId The account's market.
    /// @param position The record's position.
    /// @param units The record's credited units after reconcile.
    /// @param debtReserveIds Debt reserves to repay in full.
    /// @param maxRepaySpends Cap for each listed reserve, base units of its asset.
    /// @param deadline Last valid `block.timestamp`.
    /// @custom:spec REQ-ADAPTER-071, REQ-ADAPTER-076, REQ-ADAPTER-047, REQ-PROXY-071, REQ-ADAPTER-085, REQ-ADAPTER-086, WDR-024, Q-029, Q-180, Q-234, Q-260, Q-269, Q-376
    function repayAllAndWithdraw(
        uint256 marketId,
        PositionRef calldata position,
        uint256 units,
        uint256[] calldata debtReserveIds,
        uint256[] calldata maxRepaySpends,
        uint256 deadline
    ) external;

    /// @notice Returns the position of a record at 0 credited units to its depositor of record.
    /// @dev Depositor of record only (Collateralization checks `NotDepositor`). Order: Lock; `DeadlineExpired`;
    /// `NoProxy` unless the caller has an account for the market; `IntegrationMismatch`;
    /// `Collateralization.releaseZeroCredit(msg.sender, vaultToken, position.positionKey)` with that account's vault token
    /// (open record at 0 credited units, position returned through the market's LPVault). Mints, burns and supplies
    /// nothing; reads no MarketRegistry state, pause, freeze, breaker or price. The Adapter is the outer entry point
    /// because Collateralization is not a Lock member (Q-377).
    /// @param marketId The record's market.
    /// @param position The record's position.
    /// @param deadline Last valid `block.timestamp`.
    /// @custom:spec REQ-ADAPTER-047, REQ-ADAPTER-086, Q-201, Q-377
    function releaseZeroCredit(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) external;

    /// @notice Collects the fees a custodied position has earned, for an AMM protocol that keeps fees apart from the
    /// position, and pays them to the depositor of record.
    /// @dev Depositor of record only (Collateralization checks `NotDepositor`). Order: Lock; `DeadlineExpired`;
    /// `NoProxy` unless the caller has an account for the market; `IntegrationMismatch`;
    /// `Collateralization.collectFees(msg.sender, vaultToken, position.positionKey)` with that account's vault token, which
    /// calls the market's LPVault `collectFees` (open record, fees only, principal untouched, paid to the depositor). For an AMM protocol whose fees are rolled into
    /// the position (Uniswap v2, Curve, Balancer) the LPVault reverts with `FeesRolledIn`. Reads no MarketRegistry state,
    /// pause, freeze, breaker or price.
    /// @param marketId The record's market.
    /// @param position The record's position.
    /// @param deadline Last valid `block.timestamp`.
    /// @return fees Fees paid to the depositor, raw units of each pool token in the market's token order.
    /// @custom:spec REQ-ADAPTER-047, REQ-ADAPTER-086, Q-376, Q-377
    function collectFees(
        uint256 marketId,
        PositionRef calldata position,
        uint256 deadline
    ) external returns (uint256[] memory fees);

    /// @notice Clears a proxy's stale indebted mark once its Spoke account has no debt, so `closeMarket` is never
    /// blocked by an account whose last debt left in a call whose Spoke read failed, or without any Avana call (an
    /// outside liquidator's dust liquidation).
    /// @dev Anyone. Order: Lock; `Collateralization.markDebtFree(proxy)` (which reads `borrowCount` on the proxy's
    /// Spoke, changes nothing for an unmarked or still indebted account, and reverts `InsufficientGas` on a starved
    /// read); release. Moves no asset and reads no MarketRegistry state, pause, freeze, breaker or price, so it works in
    /// every market state, Offboarding included.
    /// @param proxy The account's PositionProxy.
    /// @custom:spec REQ-COLL-040, Q-355
    function refreshDebtMark(
        address proxy
    ) external;
}
