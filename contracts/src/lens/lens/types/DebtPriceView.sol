// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../../types/PriceState.sol";

/// @notice Price report of one debt reserve.
/// @dev `source` is `AaveOracle.getReserveSource(debtReserveId)`; `price` is the served `getReservePrice(debtReserveId)`
/// (USD, 8 decimals); `fixedPrice` comes from the reserve's `DebtReserveDef`. For a DebtOracle source `state`,
/// `acceptedPrice` and `updatedAt` (original source timestamp of the accepted round) come from the DebtOracle,
/// `age = timestamp - updatedAt`, `borrowFresh = state Live && age <= borrowPriceMaxAge(feed)`,
/// `liquidationFresh = state Live && age <= liquidationPriceMaxAge(feed)` with ParameterStore values of the same call,
/// and `stressPriced = price > acceptedPrice` (higher route during a disagreement, accepted price raised by
/// `debtStressRiseBps` once Expired). For a fixed-price source (such as GHO)
/// `state` is Live, `acceptedPrice = price`, `updatedAt = timestamp`, `age = 0`, both flags are true and `stressPriced`
/// is false. `blockNumber` and `timestamp` are the
/// block read (REQ-LENS-005).
/// @custom:spec REQ-LENS-030, REQ-LENS-005, Q-247, Q-248
struct DebtPriceView {
    uint256 blockNumber;
    uint256 timestamp;
    uint256 debtReserveId;
    address source;
    uint256 price;
    PriceState state;
    uint256 acceptedPrice;
    uint256 updatedAt;
    uint256 age;
    bool fixedPrice;
    bool borrowFresh;
    bool liquidationFresh;
    bool stressPriced;
}
