// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {GasCalibration} from "../utils/GasCalibration.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";

/// @title RiskModulePokeBreakersGasTest
/// @notice Gas of the permissionless `RiskModule.pokeBreakers(marketId)` (`REQ-RISK-091`), the keeper's `g_PB`, on the
/// real stack (`RealStackFlows`): every Avana and Aave V4 contract real, each market a real LPOracleCL over a real
/// Uniswap v3 USDC/USDT pool of one of the four standard fee tiers (each further market a narrower tick range of one of
/// them), listed, routed and activated as the listing payloads do it, as in `MarketCountGasTest`. The CDP Spoke has
/// two debt reserves: GHO (fixed price, not poked) and USDC (its real DebtOracle, poked). Each poke is of market 1 by
/// Avana's keeper, and each figure is its own transaction (`isolate = true`, `GasCalibration._txGas`: intrinsic gas
/// included, every account and slot cold at its first access, as for any keeper transaction). At 1, 16 and 32 markets
/// on the Spoke (the `CONFIG_DRIFT` condition walks every market of the Spoke) four settings are measured:
/// - `cold`: the first poke after every feed published a new round at the same answer, so the LPOracle and DebtOracle
///   pokes inside take the new rounds and write; no breaker condition holds, nothing is recorded.
/// - `warm`: the same poke one block later with nothing changed (the steady state of a quiet block): the oracle pokes
///   and the conditions read, nothing is written but the event. This is what the keeper simulates every block; it sends
///   only when the result is non-zero.
/// - `breach`: USDC's second source 5 % below its routes (tolerance 1 %), so the LPOracle refuses borrowing and the
///   `ORACLE` condition holds; the first poke of the episode stores both oracles' `disagreeSince` and the registry's
///   first `lastBreachAt` of the market (zero to non-zero writes). This is the poke the keeper sends.
/// - `breachRepeat`: the next block with the condition still holding: `lastBreachAt` rewritten (non-zero to non-zero).
/// Recorded with `vm.snapshotValue` (group `PokeBreakers`) and checked against half the per-transaction gas limit.
/// @dev Every market here shares USDC and USDT and their one-leg routes, so the figures are a lower bound for a market
/// of distinct tokens on two-leg routes; the worst-case oracle pokes alone are in `PokeFloor.json`.
/// forge-config: default.isolate = true
contract RiskModulePokeBreakersGasTest is RealStackFlows, GasCalibration {
    IClPool[] internal pools;
    /// @dev Tick spacings by which `_fullRange` narrows the range of the market being listed (0: the full range).
    int24 internal inset;

    function setUp() public {
        _setUpFullStack();
        // The four standard Uniswap v3 fee tiers of USDC/USDT, created and aged as in `MarketCountGasTest`.
        (ClTestToken t0, ClTestToken t1) = address(usdc) < address(usdt) ? (usdc, usdt) : (usdt, usdc);
        pools.push(poolA);
        pools.push(poolB);
        pools.push(_createPool(t0, t1, 3000, 1e8, 1e8, 151, 1e15));
        pools.push(_createPool(t0, t1, 10_000, 1e8, 1e8, 151, 1e15));
        _touch(pools[2]);
        _touch(pools[3]);
        vm.warp(block.timestamp + 7200);
        vm.roll(block.number + 7200 / BLOCK_TIME);
        _refreshFeeds();
        usdcOracle.poke();
    }

    /// @dev Market `i` (from 0) is pool `i % 4` on its full range narrowed by `i / 4` tick spacings at each end.
    function _fullRange(
        IClPool p
    ) internal view override returns (int24 lower, int24 upper) {
        (lower, upper) = super._fullRange(p);
        int24 d = inset * p.tickSpacing();
        (lower, upper) = (lower + d, upper - d);
    }

    struct Row {
        uint256 cold;
        uint256 warm;
        uint256 breach;
        uint256 breachRepeat;
    }

    function _nextBlock() internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + BLOCK_TIME);
    }

    function _poke() internal returns (uint256) {
        return _txGas(keeper, address(riskModule), abi.encodeCall(IRiskModuleChecks.pokeBreakers, (1)));
    }

    function _lastBreach() internal view returns (uint64 at) {
        (, at) = registry.marketBreaker(1);
    }

    function _measure(
        uint256 n
    ) internal returns (Row memory r) {
        // Cold: every feed publishes a new round in a new block.
        vm.pauseGasMetering();
        _nextBlock();
        _refreshFeeds();
        vm.resumeGasMetering();
        r.cold = _poke();
        assertEq(_lastBreach(), 0, "no condition holds");
        // Warm: the next block, nothing changed.
        _nextBlock();
        r.warm = _poke();
        assertEq(_lastBreach(), 0, "still no condition");
        // Breach and its repeat, then the state before them restored.
        uint256 snap = vm.snapshotState();
        _nextBlock();
        feedsOf[address(usdc)][3].push(0.95e8, block.timestamp);
        r.breach = _poke();
        assertFalse(
            ILPOracle(address(mkt[1].oracle)).getPriceState().borrowAllowed, "the second source blocks borrowing"
        );
        assertEq(_lastBreach(), block.timestamp, "the ORACLE breach recorded");
        _nextBlock();
        r.breachRepeat = _poke();
        assertEq(_lastBreach(), block.timestamp, "the breach time rewritten");
        vm.revertToStateAndDelete(snap);

        string memory k = vm.toString(n);
        vm.snapshotValue("PokeBreakers", string.concat("pokeBreakers_cold_", k), r.cold);
        vm.snapshotValue("PokeBreakers", string.concat("pokeBreakers_warm_", k), r.warm);
        vm.snapshotValue("PokeBreakers", string.concat("pokeBreakers_breach_", k), r.breach);
        vm.snapshotValue("PokeBreakers", string.concat("pokeBreakers_breachRepeat_", k), r.breachRepeat);
        emit log_named_uint(string.concat("markets ", k, ": pokeBreakers cold (new rounds)"), r.cold);
        emit log_named_uint(string.concat("markets ", k, ": pokeBreakers warm (nothing changed)"), r.warm);
        emit log_named_uint(string.concat("markets ", k, ": pokeBreakers breach (first)"), r.breach);
        emit log_named_uint(string.concat("markets ", k, ": pokeBreakers breach (repeat)"), r.breachRepeat);
        assertLe(r.breach, TX_GAS_CAP / 2, "within half the per-transaction gas limit");
    }

    // TEST-337 verifies: REQ-RISK-091, SPEC-BRK-007, REQ-ORACLE-037
    /// @notice Gas of `pokeBreakers` of one market, cold, warm, on a breach and on its repeat, at 1, 16 and 32 markets.
    function test_TEST_337_pokeBreakersGas() public {
        uint256[3] memory at = [uint256(1), 16, 32];
        Row[3] memory rows;
        uint256 next = 0;
        for (uint256 i = 0; i < at[2]; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            inset = int24(int256(i / 4));
            // Listing 32 real markets is far beyond the test's gas limit; only the measured calls are metered.
            vm.pauseGasMetering();
            _addMarket(pools[i % 4]);
            vm.resumeGasMetering();
            inset = 0;
            if (next < 3 && registry.marketCount() == at[next]) {
                vm.pauseGasMetering();
                _pokeAll();
                vm.resumeGasMetering();
                rows[next] = _measure(at[next]);
                ++next;
            }
        }
        assertEq(next, 3, "every checkpoint measured");
        emit log_named_uint("pokeBreakers warm: gas per market", (rows[2].warm - rows[0].warm) / 31);
        for (uint256 i = 0; i < 3; ++i) {
            assertGt(rows[i].breach, rows[i].warm, "a breach costs more than a quiet poke");
        }
        assertGt(rows[2].warm, rows[0].warm, "the drift walk grows with the market count");
    }
}
