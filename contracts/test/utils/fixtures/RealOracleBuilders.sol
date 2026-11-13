// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracle} from "../../../src/oracle/debt-oracle/IDebtOracle.sol";
import {LPOracleCL} from "../../../src/oracle/lp-oracle/LPOracleCL.sol";
import {DebtOracleFixture} from "./DebtOracleFixture.sol";
import {LPOracleCLFixture} from "./LPOracleCLFixture.sol";

/// @title RealClMarketBuilder
/// @notice Builds the real concentrated-liquidity LPOracle of `LPOracleCLFixture` (USDC/USDT on a real Uniswap v3
/// pool, launch timers, a 1,800 s TWAP) inside its own contract, so a suite built on another fixture can point a
/// market at it. Build it before the suite's own fixture warps forward: the pool's history is written at the fixture's
/// `T0` and earlier.
contract RealClMarketBuilder is LPOracleCLFixture {
    function build() external returns (LPOracleCL) {
        _deployClMarket(_usdcUsdt());
        return oracle;
    }

    /// @notice Publishes the current prices on every feed at `block.timestamp` and writes a pool observation.
    function refresh() external {
        _setPrices(price0, price1);
        _touch(pool);
    }

    /// @notice Publishes `q0`, `q1` on every route and second source at `block.timestamp`.
    function setPrices(
        uint256 q0,
        uint256 q1
    ) external {
        _setPrices(q0, q1);
    }

    /// @notice Publishes `q` on token1's alternate route only, at `block.timestamp`.
    function setAlternate1(
        uint256 q
    ) external {
        a1Feed.push(int256(q), block.timestamp);
    }

    function prices() external view returns (uint256, uint256) {
        return (price0, price1);
    }
}

/// @title RealDebtOracleBuilder
/// @notice Builds the real USDC DebtOracle of `DebtOracleFixture` (UUPS proxy owned by a real AvanaTimelock, primary,
/// two-leg alternate, standby and second source) inside its own contract. Build it before the suite's own fixture
/// warps forward.
contract RealDebtOracleBuilder is DebtOracleFixture {
    function build() external returns (IDebtOracle) {
        _deployDebtOracle();
        return oracle;
    }

    /// @notice A new round on every feed at `block.timestamp` with its current answer.
    function refresh() external {
        _refreshAll();
    }
}
