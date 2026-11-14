// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDaoDeficitOffset} from "../../src/coverage/dao-deficit-offset/IDaoDeficitOffset.sol";
import {DaoDeficitOffsetFixture} from "../utils/fixtures/DaoDeficitOffsetFixture.sol";

/// @title DaoDeficitOffsetLossOrderFuzzTest
/// @notice TEST-298 loss order under fuzzed balances, deficits, call limits and accrued interest on the real local Aave V4
/// Hub (`SPEC-FLR-006`): the Avana Umbrella pays `c_A = min(m_A, ⌈deficit⌉, F_A)`; the DAO offset pays only once the
/// Avana Umbrella's balance is zero, then `c_D = min(m_D, ⌈deficit⌉ − c_A, F_D)` with `F_D` read at its own call; the
/// residual `⌈deficit⌉ − c_A − c_D` stays recorded; and an Avana Umbrella that covers its whole balance is left with
/// exactly zero, so dust never holds the offset back.
contract DaoDeficitOffsetLossOrderFuzzTest is DaoDeficitOffsetFixture {
    function setUp() public {
        _deployLayers();
    }

    // TEST-298 verifies: REQ-FLR-048, REQ-FLR-049, REQ-FLR-019, REQ-FLR-027, SPEC-FLR-006, SPEC-FLR-001, INV-100, Q-410
    // Sources: 5.1 TEST-298, MATH-AR-51h, MATH-AR-51i
    /// @notice For any extra funding of either layer, any deficit, any `maxAmount` on each call and any interest
    /// accrued first, the offset is refused exactly while the Avana Umbrella holds funds, and the amounts follow
    /// `SPEC-FLR-006`.
    function testFuzz_TEST_298_lossOrder(
        uint256 extraA,
        uint256 extraD,
        uint256 lost,
        uint256 maxA,
        uint256 maxD,
        uint256 ordinaryDebt,
        uint256 elapsed
    ) public {
        extraA = bound(extraA, 0, 200_000) * 1e18;
        extraD = bound(extraD, 0, 200_000) * 1e18;
        if (extraA > 0) _fund(ghoCoverage, gho, avanaLabs, extraA);
        if (extraD > 0) _fund(ghoOffset, gho, daoTreasury, extraD);
        ordinaryDebt = bound(ordinaryDebt, 0, 1_000_000e18);
        if (ordinaryDebt > 0) _draw(ghoAssetId, aave.cdpSpoke, ordinaryDebt);
        vm.warp(block.timestamp + bound(elapsed, 0, 730 days));
        lost = bound(lost, 1e18, 800_000e18);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, lost);

        uint256 owed = _deficitUnits(ghoAssetId, aave.cdpSpoke);
        uint256 fA = ghoCoverage.fundedBalance();
        maxA = bound(maxA, 1, 2 * owed);
        uint256 cA = _coverWith(ghoCoverage, aave.cdpSpoke, maxA);
        assertEq(cA, _min(_min(maxA, owed), fA), "c_A = min(m_A, deficit, F_A)");
        uint256 leftA = ghoCoverage.fundedBalance();
        uint256 owedAfterA = owed - cA;

        if (owedAfterA == 0) return;
        maxD = bound(maxD, 1, 2 * owedAfterA);
        // F_D is read at the offset's own call: the first layer's share burn, rounded up, can lift the share price.
        uint256 fD = ghoOffset.fundedBalance();
        if (leftA != 0) {
            vm.prank(coverageCaller);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IDaoDeficitOffset.FirstLossLayerNotExhausted.selector, address(ghoCoverage), leftA
                )
            );
            ghoOffset.coverDeficit(aave.cdpSpoke, maxD);
            assertEq(ghoOffset.fundedBalance(), fD, "offset untouched while the Avana layer holds funds");
            return;
        }
        uint256 cD = _coverWith(ghoOffset, aave.cdpSpoke, maxD);
        assertEq(cD, _min(_min(maxD, owedAfterA), fD), "c_D = min(m_D, deficit - c_A, F_D)");
        assertEq(_deficitUnits(ghoAssetId, aave.cdpSpoke), owed - cA - cD, "residual = deficit - c_A - c_D");
        assertEq(ghoCoverage.totalCovered(), cA, "Avana totalCovered");
        assertEq(ghoOffset.totalCovered(), cD, "DAO totalCovered");
    }

    // TEST-298 verifies: REQ-FLR-048, REQ-FLR-031, SPEC-FLR-001, SPEC-FLR-002, INV-100, Q-410
    // Sources: 5.1 TEST-298, MATH-AR-51j
    /// @notice With any interest accrued (share price at or above 1), an Avana Umbrella that covers a deficit at least
    /// its balance keeps no share and no balance, so the offset is never held back by rounding dust.
    function testFuzz_TEST_298_exhaustedLayerIsZero(
        uint256 extraA,
        uint256 ordinaryDebt,
        uint256 elapsed,
        uint256 overshoot
    ) public {
        extraA = bound(extraA, 0, 300_000e18);
        if (extraA > 0) _fund(ghoCoverage, gho, avanaLabs, extraA);
        ordinaryDebt = bound(ordinaryDebt, 1e18, 1_000_000e18);
        _draw(ghoAssetId, aave.cdpSpoke, ordinaryDebt);
        vm.warp(block.timestamp + bound(elapsed, 1, 730 days));
        uint256 fA = ghoCoverage.fundedBalance();
        uint256 lost = fA + bound(overshoot, 1, 100_000e18);
        if (lost > hub.getAssetLiquidity(ghoAssetId)) lost = hub.getAssetLiquidity(ghoAssetId);
        vm.assume(lost >= fA);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, lost);
        fA = ghoCoverage.fundedBalance();
        vm.assume(_deficitUnits(ghoAssetId, aave.cdpSpoke) >= fA);

        assertEq(_coverWith(ghoCoverage, aave.cdpSpoke, type(uint256).max), fA, "covers its whole balance");
        assertEq(ghoCoverage.fundedShares(), 0, "every share burned");
        assertEq(ghoCoverage.fundedBalance(), 0, "balance exactly zero");
        uint256 rest = _deficitUnits(ghoAssetId, aave.cdpSpoke);
        if (rest > 0) {
            uint256 fD = ghoOffset.fundedBalance();
            uint256 cD = _coverWith(ghoOffset, aave.cdpSpoke, type(uint256).max);
            assertEq(cD, _min(rest, fD), "offset proceeds with min(rest, F_D)");
        }
    }

    // TEST-298 verifies: REQ-FLR-048, REQ-FLR-050, REQ-FLR-036, SPEC-FLR-006, INV-100, Q-410
    // Sources: 5.1 TEST-298, MATH-AR-51h
    /// @notice For any deficit, any extra Avana funding and either state of the Avana Umbrella's Hub `active` flag, the
    /// offset is refused exactly when the Umbrella is active and holds funds; otherwise it pays `min(d, F_D)`.
    function testFuzz_TEST_298_refusedExactlyWhileLayerActiveAndFunded(
        bool active,
        uint256 extraA,
        uint256 lost
    ) public {
        extraA = bound(extraA, 0, 200_000) * 1e18;
        if (extraA > 0) _fund(ghoCoverage, gho, avanaLabs, extraA);
        lost = bound(lost, 1e18, 400_000e18);
        _reportDeficit(ghoAssetId, aave.cdpSpoke, lost);
        if (!active) _setActive(ghoAssetId, address(ghoCoverage), false);
        uint256 fA = ghoCoverage.fundedBalance();
        uint256 fD = ghoOffset.fundedBalance();
        uint256 d = _deficitUnits(ghoAssetId, aave.cdpSpoke);
        if (active && fA != 0) {
            vm.prank(coverageCaller);
            vm.expectRevert(
                abi.encodeWithSelector(IDaoDeficitOffset.FirstLossLayerNotExhausted.selector, address(ghoCoverage), fA)
            );
            ghoOffset.coverDeficit(aave.cdpSpoke, type(uint256).max);
            assertEq(ghoOffset.fundedBalance(), fD, "offset untouched");
        } else {
            assertEq(_coverWith(ghoOffset, aave.cdpSpoke, type(uint256).max), _min(d, fD), "offset pays");
            assertEq(ghoCoverage.fundedBalance(), fA, "Umbrella untouched");
        }
    }

    function _min(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
