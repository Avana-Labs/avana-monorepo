// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title FeeOnTransferToken
/// @notice 18-decimal ERC-20 that burns `feeBps` of every transfer, so the recipient receives less than the amount sent.
contract FeeOnTransferToken is ERC20 {
    uint256 public feeBps;

    constructor(
        uint256 feeBps_
    ) ERC20("Fee", "FEE") {
        feeBps = feeBps_;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = value * feeBps / 10_000;
        super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}
