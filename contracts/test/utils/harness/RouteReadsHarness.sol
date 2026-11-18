// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RouteMath} from "../../../src/liquidation/settlement-routes/RouteMath.sol";

/// @title RouteReadsHarness
/// @notice External wrappers of the internal `RouteMath` functions, so unit and fuzz suites can call the bounded reads
/// a route's constructor makes.
contract RouteReadsHarness {
    function words(
        address target,
        bytes calldata data,
        bool three
    ) external view returns (bool ok, uint256[3] memory w) {
        return RouteMath.words(target, data, three);
    }

    function addressOf(
        address target,
        bytes calldata data
    ) external view returns (bool ok, address value) {
        return RouteMath.addressOf(target, data);
    }

    function hasFeeSwitch(
        address token
    ) external view returns (bool switchable) {
        return RouteMath.hasFeeSwitch(token);
    }
}
