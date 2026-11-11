// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";

/// @notice Review PoCs for the DebtOracle (contract 9).
contract DebtOracleReviewTest is DebtOracleFixture {
    function setUp() public {
        _deployDebtOracle();
    }

    /// @dev Measurement: SPEC-ORC-023 defines W_poke with "every recovery lookup taken through the phase rule". The
    /// unit test takes the phase path on one leg only; here all four legs start a new phase.
    function test_measure_pokeWithEveryLegOnThePhasePath() public {
        MockAggregator pA = new MockAggregator(18, USDC_ETH, T0 - 100);
        MockAggregator pB = new MockAggregator(8, ETH_USD, T0 - 100);
        store.setFeed(address(pA), 18, 0, 1e18, 86_400, 1800);
        store.setFeed(address(pB), 8, 0, 1e12, 3600, 1800);
        reg.setRoutes(usdc, _route2(address(pA), address(pB)), _route2(address(aEth), address(ethUsd)));
        MockAggregator seq = new MockAggregator(0, 0, T0 - 50_000);
        store.setSequencer(address(seq), 3600);
        _poke();
        uint256 back = T0 + 200_000;
        vm.warp(back);
        pA.pushNewPhase(USDC_ETH, back, address(new MockAggregator(18, USDC_ETH, T0 - 50)));
        pB.pushNewPhase(ETH_USD, back, address(new MockAggregator(8, ETH_USD, T0 - 50)));
        aEth.pushNewPhase(USDC_ETH, back, address(new MockAggregator(18, USDC_ETH, T0 - 50)));
        ethUsd.pushNewPhase(ETH_USD, back, address(new MockAggregator(8, ETH_USD, T0 - 50)));
        _refresh(second);
        uint256 before = gasleft();
        oracle.poke{gas: (uint256(MIN_GAS) * 64) / 63 + 10_000}();
        emit log_named_uint("poke gas, four legs on the phase path (mocks)", before - gasleft());
        assertTrue(oracle.getPriceState().inGrace);
    }

    // ─── DO-01: a disagreement serves one route's value with the other route's timestamp and age limits ───

    /// @notice Primary USDC/USD 0.9999 from round T0 - 100 (valid for 88,200 s); alternate USDC/ETH x ETH/USD at
    /// 1.03 published now. The routes disagree (300 bps > T = 225), the served price is max(p, b, A) = b, but
    /// `servedUpdatedAt`, the age limits, the leg report and `latestRoundData().updatedAt` all come from the primary,
    /// whose value is not served.
    function test_POC_DO01_disagreementServesAlternateUnderPrimaryTimestamp() public {
        vm.warp(T0 + 50_000);
        aEth.push(343_333_333_333_334, block.timestamp); // route = 103,000,000
        ethUsd.republish(block.timestamp);
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Drifting));
        assertEq(v.alternateValue, 103_000_000);
        assertEq(uint256(v.answer), 103_000_000, "served = max(p, b, A) = the alternate");
        assertEq(v.servedUpdatedAt, T0 - 100, "but timestamped with the primary's round");
        assertEq(v.legFeeds[0], address(pUsd), "and reported on the primary's leg");
        assertEq(v.borrowPriceMaxAge, 88_200, "age limit of the primary leg");
        (,, uint256 startedAt, uint256 updatedAt,) = oracle.latestRoundData();
        assertEq(updatedAt, T0 - 100);
        assertEq(startedAt, T0 - 100);
        assertTrue(v.liquidationPaused && !v.borrowAllowed, "no gate reads it while Drifting");
    }

    // ─── DO-02: INV-098 says liquidation is never gated by the sequencer feed ───

    /// @notice REQ-ORACLE-099 / SPEC-ORC-021 (implemented): sequencer down sets `liquidationPaused` on a Live debt
    /// price. INV-098: "repay, debt-free exits, fee collection, pending settlement and liquidation are never gated by
    /// the feed".
    function test_POC_DO02_sequencerDownPausesDebtRepaymentInLiquidation() public {
        MockAggregator seq = new MockAggregator(0, 1, T0 - 10); // answer 1 = down
        store.setSequencer(address(seq), 3600);
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertTrue(v.liquidationPaused, "Live, yet LPVaultSwap may not repay this reserve");
        assertTrue(v.reasons & (1 << 17) != 0);
    }

    // ─── DO-03: the stress rise is not clamped to its 5,000 bps bound ───

    /// @notice SPEC-ORC-018: "100 <= delta <= 5,000 ... the Expired value never exceeds 1.5 x A + 1". The library
    /// clamps only the lower bound, so the property rests on the ParameterStore setter alone; a store value of
    /// 65,535 bps serves 7.55 x A for every account with this debt.
    function test_POC_DO03_stressRiseAboveBoundIsServed() public {
        store.setStressRise(usdc, type(uint16).max);
        vm.warp(T0 + 200_000); // both routes stale since T0 + 88,101; Cached window over
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Expired));
        uint256 a = 99_990_000;
        assertEq(uint256(v.answer), (a * 75_535 + 9999) / 10_000);
        assertGt(uint256(v.answer), (a * 3) / 2 + 1, "above the 1.5 x A + 1 bound of SPEC-ORC-018");
    }

    /// @dev Measurement: cold gas of one `latestAnswer()` (the AaveOracle's read) with a one-leg primary, a two-leg
    /// alternate, a sequencer feed and a second source (mocks).
    function test_measure_latestAnswerColdGas() public {
        MockAggregator seq = new MockAggregator(0, 0, T0 - 50_000);
        store.setSequencer(address(seq), 3600);
        uint256 g = gasleft();
        oracle.latestAnswer();
        emit log_named_uint("latestAnswer gas (cold, mocks)", g - gasleft());
    }
}
