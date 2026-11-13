// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title FixedPriceSource
/// @notice Test-network stand-in for Aave's fixed GHO price source: an 8-decimal Aave price source that always answers
/// $1.00. GHO's debt reserve uses a fixed price (`DebtReserveDef.fixedPrice`), which the MarketRegistry accepts from
/// any 8-decimal source with a positive answer (`REQ-MREG-008`). Listed as a stand-in in `deployments/README.md`.
contract FixedPriceSource {
    int256 internal constant PRICE = 1e8;

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function description() external pure returns (string memory) {
        return "GHO / USD fixed";
    }

    function latestAnswer() external pure returns (int256) {
        return PRICE;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, PRICE, block.timestamp, block.timestamp, 1);
    }
}
