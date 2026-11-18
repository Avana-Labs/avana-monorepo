// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PriceState} from "../../../types/OracleTypes.sol";

/// @notice Price report of one debt reserve.
/// @dev Prices USD 8 decimals; freshness flags follow execution's rules.
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
