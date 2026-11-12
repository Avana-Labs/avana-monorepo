// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title HalmosLegacyCurvePool
/// @notice A two-coin legacy Curve pool for the symbolic route checks: `exchange` pulls the whole `dx` of coin `i`,
/// pays a set amount `payOut` of coin `j` (any outcome, a sandwich included) and returns no data, as the Ethereum 3pool
/// does; it records the `min_dy` it was sent.
contract HalmosLegacyCurvePool {
    address internal immutable COIN0;
    address internal immutable COIN1;
    uint256 public payOut;
    uint256 public lastMinDy;

    constructor(
        address coin0,
        address coin1
    ) {
        (COIN0, COIN1) = (coin0, coin1);
    }

    function setPayOut(
        uint256 amount
    ) external {
        payOut = amount;
    }

    function coins(
        uint256 i
    ) external view returns (address) {
        require(i < 2, "index");
        return i == 0 ? COIN0 : COIN1;
    }

    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 minDy
    ) external {
        lastMinDy = minDy;
        IERC20(i == 0 ? COIN0 : COIN1).transferFrom(msg.sender, address(this), dx);
        if (payOut != 0) IERC20(j == 0 ? COIN0 : COIN1).transfer(msg.sender, payOut);
    }
}
