// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestToken
/// @notice ERC-20 with chosen decimals for test networks (anvil, Tenderly, Sepolia): the stand-in for USDC, USDT, GHO,
/// WETH, WBTC and the other pool and debt assets of the local world. Only the minter (the world deployer, who funds the
/// scenario actors) can mint. Never deployed on Ethereum or Base.
contract TestToken is ERC20 {
    uint8 private immutable _DECIMALS;
    address public immutable MINTER;

    error NotMinter();

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address minter
    ) ERC20(name_, symbol_) {
        _DECIMALS = decimals_;
        MINTER = minter;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        if (msg.sender != MINTER) revert NotMinter();
        _mint(to, amount);
    }
}
