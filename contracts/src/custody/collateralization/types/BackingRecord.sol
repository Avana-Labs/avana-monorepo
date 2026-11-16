// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice One backing record per pledged position, packed into 5 storage slots.
/// @dev Slot layout: (1) `positionKey`; (2) `depositor`, `integrationId`, `marketId`, `inList`; (3) `proxy`,
/// `pledgedAt`, `lastDebitedAt`, `windowedBps`; (4) `credited`, `originalUnits`; (5) `rescueUnits`, `originalUsdCharge`,
/// `currentUsdCharge`. Against an unpacked layout of 10 slots (8 fields plus 2 list links), each pledge writes 5 fewer
/// fresh slots, about 110k gas (AMMN-GAS-15). The record is stored under its record ID, and
/// `recordIdOf(integrationId, positionKey)` maps a position to its open record; `marketId` is
/// the MarketRegistry identifier (assigned sequentially, below 2^32). The seizure list of a (PositionProxy, market) is a
/// separate array of at most `MAX_RECORDS_PER_ACCOUNT_MARKET` = 16 keys, so the record carries no list links.
/// Fields: `depositor` (the wallet the LPVault took the position from; receives fees, a partial removal's principal
/// and the position); `proxy` (the depositor's PositionProxy for this market's CDP Spoke); `credited` (credited
/// units, decreased by seizure, reconciliation, partial-removal and deleverage debits, increased only by a re-credit);
/// `originalUnits` and `originalUsdCharge` (the basis of `SPEC-BACK-005`, set at pledge and rebased only by a
/// re-credit per `SPEC-BACK-013`); `currentUsdCharge` (USD, 8 decimals, still booked); `pledgedAt`;
/// `lastDebitedAt` (last seizure or reconciliation debit, 0 if none); `inList` (true while `credited > 0`);
/// `rescueUnits` (units admitted through the slice or a rescue exemption, never above `credited`, `SPEC-BACK-014`);
/// `windowedBps` (the share of `currentUsdCharge`, in basis points rounded down, that was charged to the market's
/// pledge-speed window: 10,000 for a pledge charged in full, 0 for a rescue top-up, which the window never charges;
/// an exit credits the window only this share of the charge it releases, `REQ-RISK-095`).
/// USD charges are `uint64` (8 decimals): the bound 1.8e19 is 184 billion USD per record, above every cap. A record
/// exists while `depositor != address(0)`; closing deletes it.
/// @custom:spec REQ-VAULT-016, REQ-VAULT-030, REQ-VAULT-031, REQ-VAULT-007, REQ-COLL-016, REQ-AMM-CORE-001, SPEC-BACK-005, SPEC-BACK-013, SPEC-BACK-014, REQ-RISK-095, Q-369
struct BackingRecord {
    bytes32 positionKey;
    address depositor;
    uint32 integrationId;
    uint32 marketId;
    bool inList;
    address proxy;
    uint40 pledgedAt;
    uint40 lastDebitedAt;
    uint16 windowedBps;
    uint128 credited;
    uint128 originalUnits;
    uint128 rescueUnits;
    uint64 originalUsdCharge;
    uint64 currentUsdCharge;
}
