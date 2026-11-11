// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPPriceMath} from "../../src/oracle/lp-oracle/LPPriceMath.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LPPriceMathHarness} from "../utils/harness/LPPriceMathHarness.sol";
import {DifferentialTest} from "./utils/DifferentialTest.sol";

/// @title LPPriceMathDifferentialTest
/// @notice FFI differential fuzzing of LPPriceMath against the exact Python reference (integers and fractions only):
/// every floor, ceiling, comparison, validity bound and saturation of `SPEC-ORC-001` … `SPEC-ORC-023` that the library
/// implements agrees with the formula written from the spec text, inside the listing bounds and well outside them.
/// @dev Run with `FOUNDRY_PROFILE=differential forge test`. Inputs are drawn wider than the launch values: signed
/// answers over the whole `int256` range, decimals up to 90 (the `f > 85` and `d > 77` branches), amounts across
/// `2^128`, prices from 0 to above `MAX_ROUTE_ANSWER`, vectors of 0 to 9 entries with unequal lengths, and `q != p`
/// for the debt price. Signed values cross FFI as their two's-complement words.
contract LPPriceMathDifferentialTest is DifferentialTest {
    uint256 internal constant MAX_ROUTE = 1e12;
    uint256 internal constant SAT = type(uint256).max;

    LPPriceMathHarness internal m;

    function setUp() public {
        m = new LPPriceMathHarness();
    }

    // TEST-037 verifies: SPEC-ORC-001, REQ-ORACLE-012, REQ-ORACLE-002
    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_TEST_037_normalizeAnswerMatchesReference(
        int256 answer,
        uint8 decimals
    ) public {
        if (decimals % 2 == 0) answer = int256(bound(uint256(answer < 0 ? -(answer + 1) : answer), 0, 2 ** 128));
        decimals = uint8(bound(decimals, 0, 90));
        assertEq(m.normalizeAnswer(answer, decimals), _one("normalizeAnswer", _a2(_word(answer), decimals)), "n");
    }

    // TEST-037 verifies: SPEC-ORC-002, REQ-ORACLE-012
    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_TEST_037_routeValueMatchesReference(
        int256 aA,
        uint8 fA,
        int256 aB,
        uint8 fB
    ) public {
        if (fA % 3 != 0) {
            aA = int256(bound(uint256(aA < 0 ? -(aA + 1) : aA), 1, 2 ** 128 - 1));
            aB = int256(bound(uint256(aB < 0 ? -(aB + 1) : aB), 1, 2 ** 128 - 1));
        }
        fA = uint8(bound(fA, 0, 60));
        fB = uint8(bound(fB, 0, 60));
        uint256[] memory args = _args(_word(aA), fA, _word(aB), fB);
        assertEq(m.routeValue2(aA, fA, aB, fB), _one("routeValue2", args), "r");
    }

    // TEST-037 verifies: SPEC-ORC-003, SPEC-ORC-020, REQ-ORACLE-042
    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_TEST_037_agreementMatchesReference(
        uint256 p,
        uint256 b,
        uint16 t,
        bool wide
    ) public {
        if (!wide) {
            p = bound(p, 0, MAX_ROUTE + 2);
            // Half the runs put b within a few hundred bps of p, where the edge of the tolerance is.
            b = t % 2 == 0 ? bound(b, 0, MAX_ROUTE + 2) : bound(b, p - p / 30, p + p / 30);
        }
        t = uint16(bound(t, 0, 1000));
        uint256[] memory args = new uint256[](3);
        (args[0], args[1], args[2]) = (p, b, t);
        assertEq(m.routesAgree(p, b, t) ? 1 : 0, _one("routesAgree", args), "agree");
        assertEq(m.secondSourceAgrees(true, p, b, t) ? 1 : 0, _one("routesAgree", args), "second source");
        assertFalse(m.secondSourceAgrees(false, p, b, t), "an invalid second source never confirms");
        assertEq(m.deviationBps(p, b), _one("deviationBps", _a2(p, b)), "deviation");
    }

    // TEST-037 verifies: SPEC-ORC-004, SPEC-ORC-008, REQ-ORACLE-012, REQ-ORACLE-103
    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_TEST_037_lpPriceMatchesReference(
        uint256 seed,
        uint256 n,
        bool malformed
    ) public {
        n = bound(n, 0, 9);
        (uint256 na, uint256 nv, uint256 nd) = (n, n, n);
        if (malformed) {
            uint256 h0 = uint256(keccak256(abi.encode(seed)));
            (na, nv, nd) = (h0 % 10, (h0 >> 8) % 10, (h0 >> 16) % 10);
        } else {
            n = bound(n, 2, 8);
            (na, nv, nd) = (n, n, n);
        }
        uint256[] memory a = new uint256[](na);
        uint256[] memory v = new uint256[](nv);
        uint8[] memory d = new uint8[](nd);
        uint256[] memory args = new uint256[](3 + na + nv + nd);
        (args[0], args[1], args[2]) = (na, nv, nd);
        for (uint256 i = 0; i < 9; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            bool stable = h >> 247 & 1 == 1;
            if (i < na) {
                a[i] = malformed && h % 5 == 0 ? 2 ** 128 + (h >> 8) % 7 : (h & type(uint128).max) >> (h >> 248 & 127);
                args[3 + i] = a[i];
            }
            if (i < nv) {
                uint256 q = malformed && h % 7 == 0
                    ? (h % 2 == 0 ? 0 : MAX_ROUTE + 1)
                    : 1 + (h >> 128 & 0xffffffffffff) % MAX_ROUTE;
                v[i] = m.valuationPrice(q, stable);
                assertEq(v[i], _one("valuationPrice", _a2(q, stable ? 1 : 0)), "v");
                args[3 + na + i] = v[i];
            }
            if (i < nd) {
                d[i] = uint8((h >> 200) % (malformed ? 81 : 37));
                args[3 + na + nv + i] = d[i];
            }
        }
        (bool valid, uint256 price8) = m.lpPrice(a, v, d);
        (uint256 eValid, uint256 ePrice) = abi.decode(_reference("lpPrice", args), (uint256, uint256));
        assertEq(valid ? 1 : 0, eValid, "valid");
        assertEq(price8, ePrice, "price8");
    }

    // TEST-037 verifies: SPEC-ORC-011, REQ-ORACLE-103
    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_TEST_037_usdBandMatchesReference(
        uint256 seed,
        uint256 n,
        uint256 low,
        uint256 high,
        bool malformed
    ) public {
        n = bound(n, 2, 8);
        uint256 nv = malformed ? bound(seed, 0, 9) : n;
        low = bound(low, 0, 2e8);
        high = seed % 5 == 0 ? SAT : bound(high, low, 2e8);
        (uint256[] memory q, uint256[] memory v, uint256[] memory args) = _bandInputs(seed, n, nv, malformed);
        (args[0], args[1], args[2], args[3]) = (n, nv, low, high);
        _checkBand(q, v, low, high, abi.decode(_reference("inUsdBand", args), (uint256[6])));
    }

    /// @dev Quotes between $0.80 and $1.20 or anywhere up to MAX_ROUTE_ANSWER, out of bounds now and then when
    /// malformed; the valuation prices are the capped quotes. `args` leaves its first four words to the caller.
    function _bandInputs(
        uint256 seed,
        uint256 n,
        uint256 nv,
        bool malformed
    ) internal view returns (uint256[] memory q, uint256[] memory v, uint256[] memory args) {
        q = new uint256[](n);
        v = new uint256[](nv);
        args = new uint256[](4 + n + nv);
        for (uint256 i = 0; i < n || i < nv; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            uint256 x = h & 1 == 0 ? 80_000_000 + (h >> 8) % 40_000_001 : 1 + (h >> 8) % MAX_ROUTE;
            if (malformed && h % 6 == 0) x = h % 12 == 0 ? 0 : MAX_ROUTE + 1;
            if (i < n) (q[i], args[4 + i]) = (x, x);
            if (i < nv) {
                v[i] = m.valuationPrice(x, true);
                args[4 + n + i] = v[i];
            }
        }
    }

    /// @dev `e` = (valid, inBand, product of q, product of v, low power, high power) from the reference.
    function _checkBand(
        uint256[] memory q,
        uint256[] memory v,
        uint256 low,
        uint256 high,
        uint256[6] memory e
    ) internal view {
        (bool valid, bool inBand) = m.inUsdBand(q, v, low, high);
        assertEq(valid ? 1 : 0, e[0], "valid");
        assertEq(inBand ? 1 : 0, e[1], "band");
        if (e[0] == 1) {
            assertEq(m.fixedPointProduct(q), e[2], "product of quotes");
            assertEq(m.fixedPointProduct(v), e[3], "product of valuation prices");
            assertEq(m.fixedPointPower(low, q.length), e[4], "low power");
            assertEq(m.fixedPointPower(high, q.length), e[5], "high power (saturated for the sentinel)");
        }
    }

    // TEST-037 verifies: SPEC-ORC-011, REQ-ORACLE-042
    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_TEST_037_usdLevelMatchesReference(
        uint256 seed,
        uint256 n
    ) public {
        n = bound(n, 0, 9);
        uint256[] memory q = new uint256[](n);
        uint256[] memory args = new uint256[](1 + n);
        args[0] = n;
        for (uint256 i = 0; i < n; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            q[i] = h % 3 == 0 ? 1 + (h >> 8) % MAX_ROUTE : 80_000_000 + (h >> 8) % 40_000_001;
            if (h % 17 == 0) q[i] = 0;
            args[1 + i] = q[i];
        }
        assertEq(m.usdLevel(q), _one("usdLevel", args), "usdLevel");
    }

    // TEST-037 verifies: SPEC-ORC-017, SPEC-ORC-018, INV-087
    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_TEST_037_servedPricesMatchReference(
        uint8 stateRaw,
        bool disagreeing,
        uint256 x,
        uint256 y,
        uint256 accepted,
        uint256 seed
    ) public {
        uint256 state = bound(stateRaw, 0, 3);
        x = bound(x, 0, MAX_ROUTE);
        y = bound(y, 0, MAX_ROUTE);
        accepted = seed % 9 == 0 ? SAT - seed % 3 : bound(accepted, 0, MAX_ROUTE);
        uint256[] memory args = new uint256[](5);
        (args[0], args[1], args[2], args[3], args[4]) = (state, disagreeing ? 1 : 0, x, y, accepted);
        assertEq(m.servedPrice(PriceState(state), disagreeing, x, y, accepted), _one("servedPrice", args), "LP");
        // Debt: q, p and b drawn independently, so a mix-up of the quote and the primary is visible.
        uint256 h = uint256(keccak256(abi.encode(seed)));
        uint256 q = h % MAX_ROUTE;
        uint256 rise = seed % 7 == 0 ? SAT - seed % 5 : (h >> 64) % 20_000;
        args = new uint256[](6);
        (args[0], args[1], args[2], args[3], args[4], args[5]) = (state, q, x, y, accepted, rise);
        assertEq(m.debtServedPrice(PriceState(state), q, x, y, accepted, rise), _one("debtServedPrice", args), "debt");
    }

    // TEST-037 verifies: SPEC-ORC-012, SPEC-ORC-015, REQ-ORACLE-090
    /// forge-config: differential.fuzz.runs = 512
    function testFuzz_TEST_037_ageLimitsAndTimestampMatchReference(
        uint256 seed,
        uint256 n,
        bool failed
    ) public {
        n = bound(n, 0, 8);
        LPPriceMath.LegAge[] memory legs = new LPPriceMath.LegAge[](n);
        uint64[] memory t = new uint64[](n);
        uint256[] memory args = new uint256[](2 + 4 * n);
        uint256[] memory targs = new uint256[](2 + n);
        (args[0], args[1]) = (n, failed ? 1 : 0);
        (targs[0], targs[1]) = (failed ? 1 : 0, seed % 2 ** 64);
        for (uint256 i = 0; i < n; ++i) {
            uint256 h = uint256(keccak256(abi.encode(seed, i)));
            legs[i] = LPPriceMath.LegAge(
                uint64(1_700_000_000 + h % 200_000), uint32(h >> 64), uint32(h >> 96), h >> 128 & 1 == 1
            );
            t[i] = legs[i].updatedAt;
            targs[2 + i] = t[i];
            (args[2 + 4 * i], args[3 + 4 * i], args[4 + 4 * i], args[5 + 4 * i]) =
            (legs[i].updatedAt, legs[i].borrowPriceMaxAge, legs[i].liquidationPriceMaxAge, legs[i].onAlternate ? 1 : 0);
        }
        // (borrowMaxAge, liquidationMaxAge) come back as two words, the encoding of the reference's two integers.
        (, bytes memory limits) = address(m).staticcall(abi.encodeCall(m.ageLimits, (legs, failed)));
        assertEq(limits, _reference("ageLimits", args), "borrow and liquidation limits");
        assertEq(m.servedTimestamp(t, failed, uint64(seed % 2 ** 64)), _one("servedTimestamp", targs), "timestamp");
    }

    // TEST-037 verifies: SPEC-ORC-021, REQ-ORACLE-099
    /// forge-config: differential.fuzz.runs = 256
    function testFuzz_TEST_037_sequencerMatchesReference(
        bool hasFeed,
        bool readOk,
        int256 answer,
        uint256 startedAt,
        uint256 nowTs,
        uint32 grace
    ) public {
        if (startedAt % 2 == 0) answer = bound(answer, -2, 3);
        startedAt = bound(startedAt, 0, type(uint64).max);
        nowTs = bound(nowTs, 0, type(uint64).max);
        uint256[] memory args = new uint256[](6);
        (args[0], args[1], args[2], args[3], args[4], args[5]) =
        (hasFeed ? 1 : 0, readOk ? 1 : 0, _word(answer), startedAt, nowTs, grace);
        // The five booleans come back as five words, the same encoding as the reference's five integers.
        (bool ok, bytes memory got) =
            address(m).staticcall(abi.encodeCall(m.sequencerStatus, (hasFeed, readOk, answer, startedAt, nowTs, grace)));
        assertTrue(ok, "never reverts");
        assertEq(got, _reference("sequencerStatus", args), "up, down, unknown, inGrace, ready");
    }

    // TEST-037 verifies: SPEC-ORC-022, SPEC-ORC-023
    /// forge-config: differential.fuzz.runs = 256
    function testFuzz_TEST_037_bufferAndGasMatchReference(
        uint256 window,
        uint256 blockTime,
        uint256 callGas,
        uint256 worstCase
    ) public {
        if (window % 2 == 0) {
            window = bound(window, 0, 7 days);
            blockTime = bound(blockTime, 0, 60);
            callGas = bound(callGas, 0, 30_000_000);
            worstCase = bound(worstCase, 0, 30_000_000);
        }
        assertEq(m.minObservations(window, blockTime), _one("minObservations", _a2(window, blockTime)), "k");
        uint256[] memory args = new uint256[](1);
        args[0] = callGas;
        assertEq(m.gasForCall(callGas), _one("gasForCall", args), "gas");
        assertEq(m.pokeMinGasFloor(worstCase, callGas), _one("pokeMinGasFloor", _a2(worstCase, callGas)), "floor");
    }

    function _one(
        string memory function_,
        uint256[] memory args
    ) internal returns (uint256) {
        return abi.decode(_reference(function_, args), (uint256));
    }

    function _a2(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](2);
        (out[0], out[1]) = (a, b);
    }

    /// @dev The two's-complement word of a signed value, as it crosses FFI.
    function _word(
        int256 x
    ) internal pure returns (uint256) {
        return uint256(x);
    }
}
