// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVault} from "../../../src/custody/lp-vault/ILPVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice A Chainlink feed with a settable answer and round time.
contract BandTestFeed {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(
        uint8 decimals_,
        int256 answer_
    ) {
        decimals = decimals_;
        set(answer_);
    }

    function set(
        int256 answer_
    ) public {
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice An ERC-20 with chosen decimals.
contract BandTestToken is ERC20 {
    uint8 internal immutable _DECIMALS;

    constructor(
        string memory symbol,
        uint8 decimals_
    ) ERC20(symbol, symbol) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }
}

/// @notice Serves `getMarket` as the LPVault would after `listMarket`.
contract BandTestVault {
    mapping(uint256 => ILPVault.Market) internal _markets;

    function setMarket(
        uint256 marketId,
        address token0,
        address token1,
        int24 bandLower,
        int24 bandUpper
    ) external {
        _markets[marketId] = ILPVault.Market({
            pool: bytes32(uint256(0xB001)),
            token0: token0,
            token1: token1,
            bandLower: bandLower,
            bandUpper: bandUpper,
            totalCredit: 0
        });
    }

    function getMarket(
        uint256 marketId
    ) external view returns (ILPVault.Market memory) {
        return _markets[marketId];
    }
}
