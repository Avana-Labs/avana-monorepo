// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskModuleHandler} from "../invariant/handlers/RiskModuleHandler.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleHandlerLegsUnitTest
/// @notice Replays the withdraw calls of the shrunk sequences that failed `invariant_TEST_095_noGateBypassed` in
/// contracts run 43653564553 (commit `48864ef`, ci shard 9/30 and the deep campaign) and run 43692185561 (commit
/// `adc7673`, ci shard 9/30, seed 0x6af96a6f). In each the fuzzer first called the handler's `setLegs` setup helper with
/// leg feeds 0; then `withdraw(2)`, `withdraw(3235)` or `withdraw(31200000000000000000000000000)` opened every gate and
/// closed the stale-feed gate by warping past the feed age. The RiskModule skips a leg whose feed is address 0 (an
/// unused second leg, 2.7 step (5)), so its pre-check passed while the handler counted the gate closed. The handler now
/// takes the legs in its constructor and has no setter; with the market's own feeds the stale-feed gate refuses both
/// pre-checks.
contract RiskModuleHandlerLegsUnitTest is RiskModuleFixture {
    RiskModuleHandler internal handler;

    function setUp() public {
        _deployRiskWorld();
        _debt(1.5e18, 1000);
        handler = new RiskModuleHandler(
            RiskModuleHandler.World({
                rm: riskModule,
                registry: registry,
                spoke: rSpoke,
                oracle: oracle,
                swap: swap,
                usdt: tUsdt,
                proxy: address(proxy),
                marketId: mid,
                vtReserve: VT_RESERVE,
                debtReserve: GHO_RESERVE,
                feedAge: FEED_AGE,
                legTokens: [address(usdc), address(usdt)],
                legFeeds: [feedUsdc, feedUsdt],
                governor: governor
            })
        );
    }

    function test_TEST_095_openGatesPass() public {
        // A seed whose mode opens every gate and closes none (keccak(seed) % 4 == 1).
        uint256 seed;
        while (uint256(keccak256(abi.encode(seed))) % 4 != 1) ++seed;
        handler.withdraw(seed);
        assertEq(handler.withdrawals(), 1, "the pre-check with every gate open was refused");
        assertEq(handler.violations(), 0, "a pre-check passed with a gate closed");
    }
}
