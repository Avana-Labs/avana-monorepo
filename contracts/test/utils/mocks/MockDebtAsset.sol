// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockDebtAsset
/// @notice Plain ERC-20 debt asset with an open mint and chosen decimals: GHO and WETH (18), USDC and USDT (6).
contract MockDebtAsset is ERC20 {
    uint8 internal immutable _DECIMALS;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}
