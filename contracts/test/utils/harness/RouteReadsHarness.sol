// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteReads} from "../../../src/liquidation/settlement-routes/RouteReads.sol";

/// @title RouteReadsHarness
/// @notice External wrappers of the internal `RouteReads` functions, so unit and fuzz suites can call the bounded reads
/// a route's constructor makes.
contract RouteReadsHarness {
    function words(
        address target,
        bytes calldata data,
        bool three
    ) external view returns (bool ok, uint256[3] memory w) {
        return RouteReads.words(target, data, three);
    }

    function addressOf(
        address target,
        bytes calldata data
    ) external view returns (bool ok, address value) {
        return RouteReads.addressOf(target, data);
    }

    function hasFeeSwitch(
        address token
    ) external view returns (bool switchable) {
        return RouteReads.hasFeeSwitch(token);
    }
}
