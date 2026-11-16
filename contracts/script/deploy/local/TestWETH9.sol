// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {TestToken} from "./TestToken.sol";

/// @title TestWETH9
/// @notice The test networks' WETH: a `TestToken` the minter can mint, with WETH9's `deposit`, `withdraw` and `receive`,
/// which the Uniswap v4 PositionManager's `WRAP` and `UNWRAP` call. Only ether deposited here can be withdrawn. Never
/// deployed on Ethereum or Base.
contract TestWETH9 is TestToken {
    constructor(
        address minter
    ) TestToken("Test WETH", "WETH", 18, minter) {}

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(
        uint256 amount
    ) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");
    }
}
