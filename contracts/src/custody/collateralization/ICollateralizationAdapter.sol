// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title ICollateralizationAdapter
/// @notice Pledge, release, partial removal, re-credit and deleverage release of backing records, called by the
/// AaveAdapter while it holds the lock.
/// @dev Every function reverts with `NotAdapter` unless `msg.sender == ADAPTER` and with `LockNotHeld` unless
/// `LOCK.holder() == ADAPTER`. Collateralization trusts the Adapter for the `depositor`, `proxy`, `units` and
/// `requireRescue` arguments and still enforces, whatever the Adapter passes, that the depositor is neither an LPVault
/// nor Collateralization, the position comes from its owner through the market's own LPVault, `credited` equals the
/// units read after custody, a re-credit adds exactly the live units above `credited`, one record exists per
/// `(integrationId, positionKey)`, an account-market holds at most `MAX_RECORDS_PER_ACCOUNT_MARKET` = 16 open records,
/// a record changes only for the proxy named in it, and the position and a partial removal's principal go only to the
/// depositor of record. None of these functions verifies the Adapter's mint or burn: the Adapter checks that the
/// market's backing gap `totalCredited + pending.units - totalSupply` is unchanged across its whole call
/// (`SPEC-BACK-009`). Every function after `pledge` names the record by `positionKey` in the market's integration
/// (`vaultToken.integrationId()`); markets are named by vault token, never by an upgradeable registry lookup, because
/// the ledger is immutable. `minAmounts` arrays are in pool order with the market's token count (`LengthMismatch`).
/// @custom:spec REQ-VAULT-006, REQ-VAULT-068, REQ-VAULT-086, REQ-COLL-005, REQ-COLL-007, Q-223, Q-224, Q-257, Q-369
interface ICollateralizationAdapter {
    /// @notice Has the market's LPVault validate and take custody of a position, books the RiskModule's charge,
    /// writes the backing record and returns the units the Adapter must mint.
    /// @dev Order: caller and lock; vault token valid (`InvalidVaultToken`: registered in `VAULT_TOKEN_FACTORY`,
    /// `collateralization() == this`, `adapter() == ADAPTER`, `lpVaultSwap() == LP_VAULT_SWAP`, its `integration()`
    /// equal to the factory's registered LPVault for its `integrationId()`); `depositor` is neither the market's
    /// LPVault nor this contract (`InvalidDepositor`); `vaultToken.isValidProxy(proxy)` (`UnknownProxy`); the proxy
    /// holds no records of another market (`ProxyMarketMismatch`); no open record for `(integrationId, positionKey)` (`AlreadyPledged`); fewer than 16 open
    /// records for `(proxy, vaultToken)` (`TooManyRecords`); `checkReadSafe(marketId)` (`PoolLocked`);
    /// `units = LPVault.receivePosition(marketId, depositor, positionKey)`, which enforces ownership, pool and exact
    /// shape (`RangeMismatch`, AMMN-RT-01) and returns the units read after custody (`ZeroUnits` at 0,
    /// `LiquidityAboveBound` above `type(uint120).max`); `LPVault.marketOfPosition(positionKey) == marketId`
    /// (`ShapeMismatch`); `poke()` on `vaultToken.lpOracle()`; `RISK_MODULE.checkPledge(depositor, proxy,
    /// marketId, integrationId, positionKey, units, counters, requireRescue)` with `marketId = vaultToken.marketId()`
    /// and the Hub-keyed counters passed as arguments (its revert data propagates unchanged), returning
    /// `PledgeCharge{usdCharge, sliceUsd, rescue, rescueUnits}`; charge check `0 < usdCharge < 2^64`,
    /// `sliceUsd <= usdCharge`, `rescueUnits <= units` and `rescueUnits == units` when `rescue` (`InvalidCharge`); record (`SPEC-BACK-014`),
    /// largest-first list insertion (`SPEC-BACK-006`), totals and counters (`SPEC-BACK-004`); `CollateralPledged`.
    /// Reads no pause state, breaker or freeze; mints nothing.
    /// @param depositor The wallet that called `Adapter.pledge`; becomes the depositor of record.
    /// @param proxy The depositor's PositionProxy for (`vaultToken.spoke()`, this market), registered in `vaultToken`.
    /// @param vaultToken The market's vault token.
    /// @param positionKey Key of the position in the market's AMM integration.
    /// @param requireRescue True when only a rescue top-up may pass; passed unchanged to `checkPledge`.
    /// @return recordId The new record ID (starts at 1, never reused).
    /// @return credited Credited units, the vault-token units the Adapter mints.
    /// @custom:spec REQ-VAULT-007, REQ-VAULT-008, REQ-VAULT-009, REQ-VAULT-010, REQ-VAULT-011, REQ-VAULT-012, REQ-VAULT-013, REQ-VAULT-014, REQ-VAULT-015, REQ-VAULT-016, REQ-VAULT-017, REQ-VAULT-018, REQ-VAULT-019, REQ-VAULT-020, REQ-VAULT-021, REQ-VAULT-022, REQ-VAULT-023, REQ-VAULT-024, REQ-VAULT-025, REQ-VAULT-026, REQ-VAULT-027, REQ-VAULT-034, REQ-VAULT-035, REQ-VAULT-042, REQ-VAULT-100, REQ-VAULT-109, REQ-VAULT-111, REQ-VAULT-144, REQ-COLL-003, REQ-COLL-006, REQ-COLL-010, REQ-COLL-013, REQ-COLL-016, REQ-COLL-019, REQ-AMM-CORE-005, SPEC-BACK-001, SPEC-BACK-002, SPEC-BACK-003, SPEC-BACK-004, SPEC-BACK-006, SPEC-BACK-014, DEP-006, DEP-007, DEP-008, DEP-009, DEP-010, DEP-011, DEP-012, DEP-F-027, Q-230, Q-252, Q-253, Q-258, Q-369
    function pledge(
        address depositor,
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        bool requireRescue
    ) external returns (uint256 recordId, uint128 credited);

    /// @notice Reconciles the account-market, debits a record's credited units after the Adapter burned them, closes
    /// the record and has the LPVault return the whole position to its depositor.
    /// @dev The record is `recordIdOf(vaultToken.integrationId(), positionKey)`. Open record (`RecordNotFound`);
    /// `record.proxy == proxy` (`NotRecordProxy`); record's market is
    /// `vaultToken` (`InvalidVaultToken`). Reconciles first with supplied shares
    /// `Spoke.getUserSuppliedShares(reserveId, proxy) + units` (`SPEC-BACK-011`; skipped while Hub added assets differ
    /// from added shares), then requires `units == record.credited > 0` (`UnitsMismatch`). Releases exposure per
    /// `SPEC-BACK-005`, subtracts `units` from the totals, closes the record and only then calls
    /// `LPVault.returnPosition(positionKey)`. Reads no health factor, debt, price, pause or policy. Emits
    /// `CollateralReleased`.
    /// @custom:spec REQ-VAULT-033, REQ-VAULT-036, REQ-VAULT-043, REQ-VAULT-069, REQ-VAULT-070, REQ-VAULT-071, REQ-VAULT-072, REQ-VAULT-073, REQ-VAULT-102, REQ-VAULT-113, REQ-VAULT-118, REQ-VAULT-119, REQ-VAULT-130, REQ-VAULT-131, REQ-VAULT-140, REQ-VAULT-143, REQ-COLL-007, SPEC-BACK-005, SPEC-BACK-011, INV-045, Q-201
    function release(
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        uint256 units
    ) external;

    /// @notice Reconciles the account-market, debits part of a record after the Adapter burned it, and has the LPVault
    /// release that principal to the depositor of record with per-token minimums; the position stays in custody.
    /// @dev Open record, proxy and market checks as `release`; `checkReadSafe` (`PoolLocked`). Reconciles, then
    /// requires `units > 0` (`UnitsMismatch`) and `units < record.credited` (`PartialRemovalTooLarge`). Debits in
    /// place, releases exposure (`SPEC-BACK-005`), caps rescue units (`SPEC-BACK-014`), subtracts from the totals,
    /// emits `RecordReduced`, then calls `LPVault.releaseToDepositor(positionKey, units, minAmounts)`. Reads no pause
    /// state, breaker, freeze, price or policy: with debt the Adapter runs the RiskModule's checks around the call.
    /// @return remaining Credited units left on the record.
    /// @return amounts Raw principal per token the depositor received, pool order.
    /// @custom:spec REQ-COLL-014, REQ-COLL-020, REQ-COLL-023, REQ-VAULT-010, REQ-VAULT-031, REQ-VAULT-032, REQ-VAULT-036, REQ-VAULT-043, REQ-VAULT-088, REQ-VAULT-131, REQ-VAULT-140, REQ-AMM-CORE-007, SPEC-BACK-005, SPEC-BACK-011, SPEC-BACK-014, Q-254, Q-271
    function releasePartial(
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint128 remaining, uint256[] memory amounts);

    /// @notice Reconciles the account-market and credits the live units a depositor added to a pledged position as a
    /// top-up of exactly that amount; returns the units the Adapter must mint.
    /// @dev Vault token valid; open record with matching market, `record.proxy == proxy` (`NotRecordProxy`) and
    /// `record.depositor == depositor` (`NotDepositor`); `checkReadSafe`. Reconciles; when `topUp` is non-empty, calls
    /// `LPVault.topUpPosition(positionKey, depositor, topUp)` first, which adds LP units to a fungible-share position
    /// (Uniswap v2, Curve, Balancer) and reverts `TopUpNotSupported` for an NFT integration, whose units are added
    /// through the AMM protocol's own `increaseLiquidity` (REQ-COLL-037); then `added = LPVault.unitsOf(key) -
    /// credited` (`NothingToRecredit` at 0 credited units or `added == 0`; `LiquidityAboveBound` above
    /// `type(uint120).max`); `poke()`; `checkPledge(..., added, counters, requireRescue)`; charge checks as `pledge`;
    /// rebases `originalUnits = credited + added`, `originalUsdCharge = currentUsdCharge = currentUsdCharge +
    /// usdCharge` (`SPEC-BACK-013`); books totals, counters and rescue units; emits `RecordRecredited`. The record
    /// keeps its place in the seizure list and does not count again against the 16-record limit.
    /// @param topUp Integration-encoded LP amount the LPVault pulls from the depositor; empty for an NFT integration.
    /// @return added Units credited, the vault-token units the Adapter mints.
    /// @return rescueUnits Rescue units booked by this call.
    /// @custom:spec REQ-COLL-015, REQ-COLL-016, REQ-COLL-021, REQ-COLL-022, REQ-COLL-037, REQ-AMM-CORE-011, REQ-VAULT-024, REQ-VAULT-030, REQ-VAULT-042, REQ-VAULT-074, REQ-VAULT-077, REQ-VAULT-131, SPEC-BACK-004, SPEC-BACK-010, SPEC-BACK-013, SPEC-BACK-014, DEP-021, DEP-022, DEP-023, Q-254
    function recredit(
        address depositor,
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        bytes calldata topUp,
        bool requireRescue
    ) external returns (uint128 added, uint128 rescueUnits);

    /// @notice Reconciles the account-market, debits a record by the units the Adapter burned inside a repay with
    /// collateral, and has the LPVault unwind them to LPVaultSwap; closes the record and returns the position when
    /// nothing stays credited.
    /// @dev Open record, proxy and market checks as `release`; `checkReadSafe`. Reconciles, then requires
    /// `0 < units <= record.credited` (`UnitsMismatch`). Debits, releases exposure, caps rescue units, subtracts from
    /// the totals, closes the record when `credited` reaches 0, emits `RecordReduced` (and `CollateralReleased` when
    /// closed), then calls `LPVault.unwind(positionKey, units, minAmounts, LP_VAULT_SWAP)` and, when closed,
    /// `LPVault.returnPosition(positionKey)`. Reads no pause state, breaker, freeze, price or policy.
    /// @return amounts Raw principal per token unwound to LPVaultSwap, pool order.
    /// @return closed True when the record closed and the position returned to its depositor.
    /// @custom:spec REQ-COLL-017, REQ-VAULT-010, REQ-VAULT-031, REQ-VAULT-032, REQ-VAULT-036, REQ-VAULT-074, REQ-VAULT-131, REQ-AMM-CORE-007, SPEC-BACK-005, SPEC-BACK-014, Q-255
    function releaseForDeleverage(
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts, bool closed);
}
