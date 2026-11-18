// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAggregatorV3} from "../interfaces/external/chainlink/IAggregatorV3.sol";
import {IParameterStore} from "../policy/parameter-store/IParameterStore.sol";
import {FeedDef} from "../policy/parameter-store/types/ParameterStoreTypes.sol";
import {LPPriceMath} from "./LPPriceMath.sol";

/// @title ChainlinkPrice
/// @notice Reads a debt reserve's Chainlink price source, the same feed Aave reads, with the feed's borrow and
/// liquidation age limits from the ParameterStore.
library ChainlinkPrice {
    struct Reading {
        // 8 decimals; 0 when the answer is zero or below.
        uint256 price8;
        uint256 updatedAt;
        // A valid answer, not from the future, within `borrowPriceMaxAge`.
        bool borrowFresh;
        // A valid answer within `liquidationPriceMaxAge`.
        bool liquidationFresh;
    }

    function read(
        address feed,
        address parameterStore
    ) internal view returns (Reading memory r) {
        // forge-lint: disable-next-line(calls-loop)
        FeedDef memory d = IParameterStore(parameterStore).getFeed(feed);
        // forge-lint: disable-next-line(calls-loop, unused-return)
        (, int256 raw,, uint256 at,) = IAggregatorV3(feed).latestRoundData();
        r.price8 = LPPriceMath.normalizeAnswer(raw, d.decimals);
        r.updatedAt = at;
        r.borrowFresh = r.price8 != 0 && LPPriceMath.borrowFresh(at, d.borrowPriceMaxAge);
        r.liquidationFresh = r.price8 != 0 && LPPriceMath.liquidationFresh(at, d.liquidationPriceMaxAge);
    }
}
