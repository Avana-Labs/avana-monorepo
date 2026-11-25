// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title HelperReenterer
/// @notice Token-hook target that re-enters a flash liquidation helper once a watched account's balance of a token has
/// risen above a threshold, that is from inside the payout transfer, and records whether the reentrant call succeeded
/// and the revert data. It never reverts itself, so the outer transfer completes and the test reads the outcome.
contract HelperReenterer {
    address public target;
    bytes public data;
    IERC20 public token;
    address public watched;
    uint256 public threshold;
    bool public fired;
    bool public succeeded;
    bytes public returned;

    function arm(
        address target_,
        bytes calldata data_,
        IERC20 token_,
        address watched_,
        uint256 threshold_
    ) external {
        target = target_;
        data = data_;
        token = token_;
        watched = watched_;
        threshold = threshold_;
    }

    function poke() external {
        if (fired || token.balanceOf(watched) <= threshold) return;
        fired = true;
        (succeeded, returned) = target.call(data);
    }
}
