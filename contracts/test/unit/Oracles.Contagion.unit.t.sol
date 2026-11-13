// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPOracleCL} from "../../src/oracle/lp-oracle/LPOracleCL.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RealOraclesFixture} from "../utils/fixtures/RealOraclesFixture.sol";
import {OracleFeedMock, ReadMode} from "../utils/mocks/LPOracleMocks.sol";

/// @title OraclesContagionTest
/// @notice The oracles' side of the contagion rule (5.1 `TEST-226`): two collateral markets, each priced by its own
/// real concentrated-liquidity LPOracle on its own real Uniswap v3 pool, and the real USDC DebtOracle. Market B is
/// Cached, then Expired, then disagreeing, and separately the USDC feeds go stale; at each step LPVaultSwap's oracle
/// rules are asked exactly as it asks them. A's seizure stays admitted whatever B's state; B's never is while it
/// fails; a stale USDC refuses only the USDC repayment, never A's seizure repaid in GHO (a fixed price, no DebtOracle).
contract OraclesContagionTest is RealOraclesFixture {
    LPOracleCL internal oracleA;
    OracleFeedMock[6] internal feedsA;
    LPOracleCL internal oracleB;
    OracleFeedMock[6] internal feedsB;
    uint256[2] internal pricesA;
    uint256[2] internal pricesB;

    function setUp() public {
        _deployClMarket(_ethUsdc());
        (oracleA, feedsA, pricesA) = (oracle, _feeds(), [price0, price1]);
        _deployClMarket(_wbtcEth());
        (oracleB, feedsB, pricesB) = (oracle, _feeds(), [price0, price1]);
        _deployUsdcDebtOracle();
    }

    function _feeds() internal view returns (OracleFeedMock[6] memory f) {
        f = [p0Feed, a0Feed, s0Feed, p1Feed, a1Feed, s1Feed];
    }

    /// @dev A new round at the current time on every feed of a market, at its listing prices.
    function _publish(
        OracleFeedMock[6] memory f,
        uint256[2] memory p
    ) internal {
        for (uint256 i = 0; i < 6; ++i) {
            f[i].push(int256(p[i / 3]), block.timestamp);
        }
    }

    function _next(
        uint256 dt
    ) internal {
        vm.warp(block.timestamp + dt);
        vm.roll(block.number + 1 + dt / 12);
    }

    /// @dev A stays fresh: its seizure is admitted, as is the USDC repayment while USDC is fresh.
    function _assertAOpen(
        string memory when
    ) internal {
        assertTrue(_seizable(oracleA), string.concat("A seizable: ", when));
        assertEq(uint8(oracleA.getPriceState().state), uint8(PriceState.Live), string.concat("A Live: ", when));
    }

    // TEST-226 verifies: INV-075, INV-072, REQ-ORACLE-084, REQ-ORACLE-068, Q-247, Q-248, Q-260
    // Sources: 5.1 TEST-226 (LPOracle and DebtOracle part: B Cached, Expired and disagreeing, the USDC feed stale)
    /// @notice B's token1 routes fail: B is Cached and its seizure refused while A's is admitted with USDC repayable;
    /// an hour later B is Expired, A unchanged; B's routes back but its alternate 3 % apart: B's seizure is paused, A
    /// unchanged; B recovers. Then every USDC feed goes stale: the USDC repayment is refused while A's seizure (repaid
    /// in GHO, which needs no DebtOracle) is still admitted, and B's state changes nothing for A throughout.
    function test_TEST_226_failingMarketAndStaleDebtFeedNeverReachTheOtherMarket() public {
        _next(60);
        _publish(feedsA, pricesA);
        _publish(feedsB, pricesB);
        _refreshDebt();
        _assertAOpen("all fresh");
        assertTrue(_seizable(oracleB), "B seizable while fresh");
        assertTrue(_repayable(), "USDC repayable while fresh");
        // B Cached.
        feedsB[3].setMode(feedsB[3].latestRoundData.selector, ReadMode.Revert);
        feedsB[4].setMode(feedsB[4].latestRoundData.selector, ReadMode.Revert);
        assertFalse(_seizable(oracleB), "B Cached: refused");
        assertEq(uint8(oracleB.getPriceState().state), uint8(PriceState.Cached));
        _assertAOpen("B Cached");
        assertTrue(_repayable(), "USDC repayable, B Cached");
        // B Expired.
        _next(3600);
        _publish(feedsA, pricesA);
        _refreshDebt();
        assertEq(uint8(oracleB.getPriceState().state), uint8(PriceState.Expired), "B Expired");
        assertFalse(_seizable(oracleB), "B Expired: refused");
        _assertAOpen("B Expired");
        assertTrue(_repayable(), "USDC repayable, B Expired");
        // B disagreeing.
        feedsB[3].setMode(feedsB[3].latestRoundData.selector, ReadMode.Normal);
        feedsB[4].setMode(feedsB[4].latestRoundData.selector, ReadMode.Normal);
        _next(60);
        _publish(feedsA, pricesA);
        _publish(feedsB, pricesB);
        feedsB[4].push(int256(pricesB[1] * 97 / 100), block.timestamp);
        _refreshDebt();
        assertFalse(_seizable(oracleB), "B disagreeing: refused");
        assertTrue(oracleB.getPriceState().disagreementPauseActive, "B in the disagreement pause");
        _assertAOpen("B disagreeing");
        // USDC stale (every route past its age), B back in agreement.
        feedsB[4].push(int256(pricesB[1]), block.timestamp);
        _next(USDC_AGE + 1);
        _publish(feedsA, pricesA);
        _publish(feedsB, pricesB);
        assertFalse(_repayable(), "stale USDC: the USDC repayment is refused");
        assertTrue(debtOracle.getPriceState().liquidationPaused, "USDC liquidation-paused");
        _assertAOpen("USDC stale");
        assertTrue(_seizable(oracleB), "B fresh again");
        assertGe(debtOracle.latestAnswer(), 1, "the DebtOracle still answers");
        assertGe(oracleB.latestAnswer(), 1, "B still answers");
    }
}
