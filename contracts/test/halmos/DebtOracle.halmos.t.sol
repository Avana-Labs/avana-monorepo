// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {DebtOracle} from "../../src/oracle/debt-oracle/DebtOracle.sol";
import {IDebtOracleErrors} from "../../src/oracle/debt-oracle/IDebtOracleErrors.sol";
import {DebtOracleInitParams} from "../../src/oracle/debt-oracle/types/DebtOracleInitParams.sol";
import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState, SecondSource, SecondSourceKind} from "../../src/types/OracleTypes.sol";
import {DebtRegistryMock, DebtStoreMock} from "../utils/mocks/DebtOracleConfigMocks.sol";
import {MockAggregator} from "../utils/mocks/MockAggregator.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Test} from "forge-std/Test.sol";

/// @title DebtOracleHalmosTest
/// @notice Symbolic checks of the real DebtOracle behind its proxy, over one-leg primary and alternate routes with
/// symbolic answers within 40 bits (every value the listing bounds admit): the served debt price by state (`SPEC-ORC-018`),
/// the stress rise clamped to [100, 5,000] bps, the served timestamp and legs of the route actually served during a
/// disagreement (`SPEC-ORC-012`, `SPEC-ORC-015`), the restricted setter and the admin-role rule.
/// @dev The only revert any view may produce is `InsufficientGas`; Halmos models `gasleft()` symbolically, so each
/// check accepts that revert and asserts on every other path.
contract DebtOracleHalmosTest is Test {
    address internal constant TIMELOCK = address(0x7111);
    address internal constant ASSET = address(0x7201);
    uint256 internal constant T0 = 1_762_650_000;
    uint256 internal constant A = 99_990_000;
    /// @dev Feed bound of every route: an answer is valid only in (0, MAX_ANSWER).
    uint256 internal constant MAX_ANSWER = 1e12;
    /// @dev The alternate's fixed answer in the `driftingTimestampFollowsPrimaryOrAccepted` checks (0.95).
    uint40 internal constant B_FIXED = 95_000_000;
    /// @dev Agreement bounds at tolerance 225 bps: the alternate disagrees with the primary at `A` for b <= 97,789,731
    /// or b > 102,239,775, and the primary with the alternate at 0.95 for p <= 92,909,535 or p > 97,137,500.
    uint256 internal constant ALT_DRIFT_BELOW = 97_789_731;
    uint256 internal constant ALT_DRIFT_ABOVE = 102_239_775;
    uint256 internal constant PRI_DRIFT_BELOW = 92_909_535;
    uint256 internal constant PRI_DRIFT_ABOVE = 97_137_500;
    /// @dev `DebtOracle._answer` caps the served price at `2^255 − 1` before the `int256` conversion.
    uint256 internal constant INT256_MAX = 2 ** 255 - 1;
    /// @dev Basis points, and the feed agreement and second-source tolerances of `setUp`.
    uint256 internal constant BPS = 10_000;
    uint256 internal constant ROUTE_TOLERANCE_BPS = 225;
    uint256 internal constant SECOND_SOURCE_TOLERANCE_BPS = 100;

    DebtOracle internal oracle;
    DebtRegistryMock internal reg;
    DebtStoreMock internal store;
    MockAggregator internal primary;
    MockAggregator internal alternate;

    function setUp() public {
        vm.warp(T0);
        primary = new MockAggregator(8, int256(A), T0 - 100);
        alternate = new MockAggregator(8, int256(A), T0 - 100);
        MockAggregator second = new MockAggregator(8, int256(A), T0 - 100);
        reg = new DebtRegistryMock();
        store = new DebtStoreMock();
        address[] memory p = new address[](1);
        address[] memory b = new address[](1);
        p[0] = address(primary);
        b[0] = address(alternate);
        reg.list(ASSET, p, b, p);
        store.setFeed(address(primary), 8, 0, 1e12, 86_400, 1800);
        store.setFeed(address(alternate), 8, 0, 1e12, 86_400, 1800);
        store.setFeed(address(second), 8, 0, 1e12, 86_400, 1800);
        store.setTolerance(ASSET, 225);
        store.setStressRise(ASSET, 500);
        store.setSecondSource(
            ASSET,
            SecondSource({
                kind: SecondSourceKind.OracleNetwork,
                source: address(second),
                poolRef: bytes32(0),
                maxAge: 88_200,
                twapWindow: 0,
                toleranceBps: 100
            })
        );
        DebtOracle impl = new DebtOracle(TIMELOCK);
        DebtOracleInitParams memory params = DebtOracleInitParams({
            timelock: TIMELOCK,
            asset: ASSET,
            marketRegistry: address(reg),
            parameterStore: address(store),
            description: "USDC / USD",
            pokeMinGas: 600_000
        });
        oracle = DebtOracle(address(new ERC1967Proxy(address(impl), abi.encodeCall(DebtOracle.initialize, (params)))));
    }

    function _onlyGasRevert(
        bytes memory err
    ) internal pure {
        assert(bytes4(err) == IDebtOracleErrors.InsufficientGas.selector);
    }

    // PROP-074 verifies: SPEC-ORC-018, REQ-ORACLE-093, REQ-ORACLE-005, REQ-ORACLE-008, INV-087, Q-247
    // Sources: 5.2 PROP-074 (DebtOracle half: served >= 1, >= A unless Live, max(p, b, A) in a disagreement), with the
    // alternate at the accepted price and the primary symbolic. Both routes symbolic at once exceeds the run budget;
    // DebtOracleFuzzTest.testFuzz_TEST_219_servedByStateBothRoutes checks that case at 10,000 runs.
    function check_PROP_074_servedDebtPriceAgainstFixedAlternate(
        uint40 pAnswer
    ) public {
        _servedByState(pAnswer, uint40(A));
    }

    // PROP-074 verifies: SPEC-ORC-018, REQ-ORACLE-093, REQ-ORACLE-005, REQ-ORACLE-006, INV-087
    // Sources: the same property with the primary at the accepted price and the alternate symbolic
    function check_PROP_074_servedDebtPriceAgainstFixedPrimary(
        uint40 bAnswer
    ) public {
        _servedByState(uint40(A), bAnswer);
    }

    function _servedByState(
        uint40 pAnswer,
        uint40 bAnswer
    ) internal {
        primary.push(int256(uint256(pAnswer)), T0);
        alternate.push(int256(uint256(bAnswer)), T0);
        uint256 p = pAnswer;
        uint256 b = bAnswer;
        bool pValid = p > 0 && p < 1e12;
        bool bValid = b > 0 && b < 1e12;
        uint256 expected;
        bool live = true;
        if (pValid && bValid) {
            (uint256 lo, uint256 hi) = p < b ? (p, b) : (b, p);
            if ((hi - lo) * 10_000 <= 225 * lo) {
                expected = p;
            } else {
                live = false;
                // One route is A, so the lower route is at most A and the median max(min(p, b), A) is A
                // (`SPEC-ORC-018`).
                expected = A;
            }
        } else if (pValid) {
            expected = p;
        } else if (bValid) {
            expected = b;
        } else {
            live = false;
            expected = A;
        }
        try oracle.latestAnswer() returns (int256 served) {
            assert(served >= 1);
            assert(uint256(served) == expected);
            if (!live) assert(uint256(served) >= A);
        } catch (bytes memory err) {
            _onlyGasRevert(err);
        }
    }

    // PROP-074 verifies: SPEC-ORC-018, REQ-ORACLE-093, REQ-ORACLE-092, INV-087
    // Sources: review DO-03: for every stress rise the store returns, the Expired price is
    // ceil(A x (1e4 + min(max(delta, 100), 5,000)) / 1e4), never above 1.5 x A + 1.
    function check_PROP_074_expiredStressRiseClamped(
        uint16 delta
    ) public {
        store.setStressRise(ASSET, delta);
        vm.warp(T0 + 200_000);
        uint256 d = delta < 100 ? 100 : (delta > 5000 ? 5000 : uint256(delta));
        try oracle.latestAnswer() returns (int256 served) {
            assert(uint256(served) == (A * (10_000 + d) + 9999) / 10_000);
            assert(uint256(served) <= (A * 3) / 2 + 1);
        } catch (bytes memory err) {
            _onlyGasRevert(err);
        }
    }

    // PROP-074 verifies: SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-018, REQ-ORACLE-093
    // Sources: review DO-01, with the alternate symbolic and the primary at A: a disagreement serves the median
    // max(min(p, b), A) with its own timestamp and legs, or the accepted timestamp and no legs when A is served.
    // The alternate's answer is split by branch into three checks whose ranges together are every uint40:
    // `Invalid` (b = 0 or b >= 1e12, outside the feed bounds, so no disagreement), `Below` (0 < b < A) and `Above`
    // (A <= b < 1e12). In each case the route order and validity are fixed, so every comparison deciding the state,
    // the served route and `deviationBps` has one feasible side, and the timestamp and legs asserted are constants:
    // `Below` can only serve A (no legs), `Above` only the primary. The single check with b symbolic over all of
    // uint40 was cancelled at the 6-hour job limit in run 43492412351 with no result. `Below` and `Above` check the
    // drift assertions on every return and leave the revert case to
    // the `driftingTimestampsRevertOnlyForGasAlternate` checks, which prove over every valid b that the call
    // reverts only with `InsufficientGas`. Together they assert what one check with both parts asserts. With both
    // parts, `Below` and `Above` did not finish in 1 hour (run 43742353540); the drift assertions alone finish in
    // about 2 minutes (run 43766285060).
    function check_PROP_074_driftingTimestampFollowsAlternateInvalid(
        uint40 bAnswer
    ) public {
        vm.assume(bAnswer == 0 || bAnswer >= MAX_ANSWER);
        _driftTimestamps(uint40(A), bAnswer, true);
    }

    // PROP-074 verifies: SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-018, REQ-ORACLE-093
    // Sources: `check_PROP_074_driftingTimestampFollowsAlternateInvalid` for 0 < b < A: a disagreement serves A
    // with the accepted timestamp, age limits 0 and no legs. A < 2^32, so a uint32 input holds the whole range and
    // the answer, the divisor of `deviationBps` in this case, is 32 bits wide.
    function check_PROP_074_driftingTimestampFollowsAlternateBelow(
        uint32 bAnswer
    ) public {
        vm.assume(bAnswer > 0 && bAnswer < A);
        _driftTimestamps(uint40(A), uint40(bAnswer), false);
    }

    // PROP-074 verifies: SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-018, REQ-ORACLE-093
    // Sources: `check_PROP_074_driftingTimestampFollowsAlternateInvalid` for A <= b < 1e12: a disagreement serves
    // the primary (the lower route, at A) with its timestamp and legs.
    function check_PROP_074_driftingTimestampFollowsAlternateAbove(
        uint40 bAnswer
    ) public {
        vm.assume(bAnswer >= A && bAnswer < MAX_ANSWER);
        _driftTimestamps(uint40(A), bAnswer, false);
    }

    // PROP-074 verifies: SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-018, REQ-ORACLE-093
    // Sources: review DO-01, with the primary symbolic and the alternate at 0.95: the primary's timestamp when it is
    // served, the accepted timestamp and no legs when A is. Split by branch as the alternate checks, the three ranges
    // together being every uint40: `Invalid` (p = 0 or p >= 1e12), `Below` (0 < p < 0.95) and `Above`
    // (0.95 <= p < 1e12). The lower route is at most 0.95 < A in every case, so a disagreement always serves A.
    // The revert case of `Below` and `Above` is the `driftingTimestampsRevertOnlyForGasPrimaryOrAccepted` checks, as
    // for the alternate checks.
    function check_PROP_074_driftingTimestampFollowsPrimaryOrAcceptedInvalid(
        uint40 pAnswer
    ) public {
        vm.assume(pAnswer == 0 || pAnswer >= MAX_ANSWER);
        _driftTimestamps(pAnswer, B_FIXED, true);
    }

    // PROP-074 verifies: SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-018, REQ-ORACLE-093
    // Sources: `check_PROP_074_driftingTimestampFollowsPrimaryOrAcceptedInvalid` for 0 < p < 0.95, as a uint32 input
    // (95,000,000 < 2^32), as in `check_PROP_074_driftingTimestampFollowsAlternateBelow`.
    function check_PROP_074_driftingTimestampFollowsPrimaryOrAcceptedBelow(
        uint32 pAnswer
    ) public {
        vm.assume(pAnswer > 0 && pAnswer < B_FIXED);
        _driftTimestamps(uint40(pAnswer), B_FIXED, false);
    }

    // PROP-074 verifies: SPEC-ORC-012, SPEC-ORC-015, SPEC-ORC-018, REQ-ORACLE-093
    // Sources: `check_PROP_074_driftingTimestampFollowsPrimaryOrAcceptedInvalid` for 0.95 <= p < 1e12.
    function check_PROP_074_driftingTimestampFollowsPrimaryOrAcceptedAbove(
        uint40 pAnswer
    ) public {
        vm.assume(pAnswer >= B_FIXED && pAnswer < MAX_ANSWER);
        _driftTimestamps(pAnswer, B_FIXED, false);
    }

    // PROP-074 verifies: SPEC-ORC-018, REQ-ORACLE-093
    // Sources: the revert case of `check_PROP_074_driftingTimestampFollowsAlternateBelow` and `...Above`: with the
    // drift checks' routes and timestamps, `getPriceState()` reverts only with `InsufficientGas`. The alternate's valid
    // answers 0 < b < 1e12 are split at the agreement bounds and at the ordering of b and A into four checks:
    // `DriftBelow` (b <= 97,789,731, the largest b with (A − b) × 10⁴ > 225 × b), `AgreeBelow` (b < A), `AgreeAbove`
    // (up to 102,239,775 = A × 10,225 / 10⁴) and `DriftAbove`. The invalid answers (b = 0 or b >= 1e12) are
    // `check_PROP_074_driftingTimestampFollowsAlternateInvalid`, which checks the revert case too, so the five checks
    // cover every uint40. In each range the ordering of p, b and A is fixed, so each check states the results of the
    // code's branchless `Math.min` and `Math.max` terms and of the divisions in its overflow checks as facts the range
    // implies (`_driftRevertOnlyForGas`): they exclude no input. Without them, the drift-below and agreement ranges did
    // not complete within 1 hour with yices (run 43777240448), bitwuzla (run 43806465033) or other solver settings
    // (run 43813498242), nor with the min and max facts alone (run 43821179272); `DriftAbove` completed in 10 minutes
    // with bitwuzla.
    /// @custom:halmos --solver bitwuzla
    function check_PROP_074_driftingTimestampsRevertOnlyForGasAlternateDriftBelow(
        uint32 bAnswer
    ) public {
        vm.assume(bAnswer > 0 && bAnswer <= ALT_DRIFT_BELOW);
        // b < A: min(p, b) = b, and Drifting serves max(b, A) = A.
        _driftRevertOnlyForGas(uint40(A), uint40(bAnswer), bAnswer, true);
    }

    // PROP-074 verifies: SPEC-ORC-018, REQ-ORACLE-093
    // Sources: `check_PROP_074_driftingTimestampsRevertOnlyForGasAlternateDriftBelow` for the agreement range below A.
    /// @custom:halmos --solver bitwuzla
    function check_PROP_074_driftingTimestampsRevertOnlyForGasAlternateAgreeBelow(
        uint32 bAnswer
    ) public {
        vm.assume(bAnswer > ALT_DRIFT_BELOW && bAnswer < A);
        // b < A: min(p, b) = b; the routes agree, so the quote p = A is served.
        _driftRevertOnlyForGas(uint40(A), uint40(bAnswer), bAnswer, false);
    }

    // PROP-074 verifies: SPEC-ORC-018, REQ-ORACLE-093
    // Sources: `check_PROP_074_driftingTimestampsRevertOnlyForGasAlternateDriftBelow` for the agreement range from A.
    /// @custom:halmos --solver bitwuzla
    function check_PROP_074_driftingTimestampsRevertOnlyForGasAlternateAgreeAbove(
        uint32 bAnswer
    ) public {
        vm.assume(bAnswer >= A && bAnswer <= ALT_DRIFT_ABOVE);
        // b >= A: min(p, b) = A (b itself when b = A); the routes agree, so the quote p = A is served.
        _driftRevertOnlyForGas(uint40(A), uint40(bAnswer), A, false);
    }

    // PROP-074 verifies: SPEC-ORC-018, REQ-ORACLE-093
    // Sources: `check_PROP_074_driftingTimestampsRevertOnlyForGasAlternateDriftBelow` above the agreement range.
    /// @custom:halmos --solver bitwuzla
    function check_PROP_074_driftingTimestampsRevertOnlyForGasAlternateDriftAbove(
        uint40 bAnswer
    ) public {
        vm.assume(bAnswer > ALT_DRIFT_ABOVE && bAnswer < MAX_ANSWER);
        _driftRevertOnlyForGasNoFacts(uint40(A), bAnswer);
    }

    // PROP-074 verifies: SPEC-ORC-018, REQ-ORACLE-093
    // Sources: the revert case of `check_PROP_074_driftingTimestampFollowsPrimaryOrAcceptedBelow` and `...Above`,
    // split as the alternate's: `DriftBelow` (p <= 92,909,535, the largest p with (0.95 − p) × 10⁴ > 225 × p),
    // `AgreeBelow` (p < 0.95), `AgreeAbove` (up to 97,137,500 = 0.95 × 10,225 / 10⁴) and `DriftAbove`, with the
    // invalid answers in `check_PROP_074_driftingTimestampFollowsPrimaryOrAcceptedInvalid`. b = 0.95 < A, so a
    // disagreement serves A in both drift ranges.
    /// @custom:halmos --solver bitwuzla
    function check_PROP_074_driftingTimestampsRevertOnlyForGasPrimaryOrAcceptedDriftBelow(
        uint32 pAnswer
    ) public {
        vm.assume(pAnswer > 0 && pAnswer <= PRI_DRIFT_BELOW);
        // p < b: min(p, b) = p, and Drifting serves max(p, A) = A.
        _driftRevertOnlyForGas(uint40(pAnswer), B_FIXED, pAnswer, true);
    }

    // PROP-074 verifies: SPEC-ORC-018, REQ-ORACLE-093
    // Sources: `check_PROP_074_driftingTimestampsRevertOnlyForGasPrimaryOrAcceptedDriftBelow` for the agreement
    // range below 0.95.
    /// @custom:halmos --solver bitwuzla
    function check_PROP_074_driftingTimestampsRevertOnlyForGasPrimaryOrAcceptedAgreeBelow(
        uint32 pAnswer
    ) public {
        vm.assume(pAnswer > PRI_DRIFT_BELOW && pAnswer < B_FIXED);
        // p < b: min(p, b) = p; the routes agree, so the quote p is served.
        _driftRevertOnlyForGas(uint40(pAnswer), B_FIXED, pAnswer, false);
    }

    // PROP-074 verifies: SPEC-ORC-018, REQ-ORACLE-093
    // Sources: `check_PROP_074_driftingTimestampsRevertOnlyForGasPrimaryOrAcceptedDriftBelow` for the agreement
    // range from 0.95.
    /// @custom:halmos --solver bitwuzla
    function check_PROP_074_driftingTimestampsRevertOnlyForGasPrimaryOrAcceptedAgreeAbove(
        uint32 pAnswer
    ) public {
        vm.assume(pAnswer >= B_FIXED && pAnswer <= PRI_DRIFT_ABOVE);
        // p >= b: min(p, b) = b (p itself when p = b); the routes agree, so the quote p is served.
        _driftRevertOnlyForGas(uint40(pAnswer), B_FIXED, B_FIXED, false);
    }

    // PROP-074 verifies: SPEC-ORC-018, REQ-ORACLE-093
    // Sources: `check_PROP_074_driftingTimestampsRevertOnlyForGasPrimaryOrAcceptedDriftBelow` above the agreement
    // range.
    /// @custom:halmos --solver bitwuzla
    function check_PROP_074_driftingTimestampsRevertOnlyForGasPrimaryOrAcceptedDriftAbove(
        uint40 pAnswer
    ) public {
        vm.assume(pAnswer > PRI_DRIFT_ABOVE && pAnswer < MAX_ANSWER);
        // p > b: min(p, b) = b, and Drifting serves max(b, A) = A.
        _driftRevertOnlyForGas(pAnswer, B_FIXED, B_FIXED, true);
    }

    /// @dev With the drift checks' routes and timestamps, `getPriceState()` reverts only with `InsufficientGas`, with
    /// the results of the code's arithmetic stated as facts on the terms it computes, in the form Halmos builds them.
    /// Halmos models `mul` of two symbolic values, and `div` by anything but a constant 0, 1 or power of two, as
    /// uninterpreted functions; a non-gas revert guarded by such a term is then satisfiable in the abstract query, and
    /// the refined query with 256-bit `bvmul`/`bvudiv` is what ran past the budget (dumped queries of run 43828867901).
    /// The facts:
    /// - `min(p, b) = low` and the Drifting price `max(max(low, low), A) = A`, as OpenZeppelin's branchless
    ///   `b ^ ([condition] × (a ^ b))`; the caller's range fixes the ordering of p, b and A, and low <= A in every
    ///   range. Both served prices, A and the quote p, below 2^40, are unchanged by the `min` with `2^255 − 1` in
    ///   `DebtOracle._answer`. Both hold whatever the state: Halmos also follows the state branch that the range makes
    ///   infeasible, and its query needs them as much as the feasible one's. The DebtOracle build multiplies the condition and the xor
    ///   in either order depending on the call site, and Halmos does not treat its uninterpreted `mul` as commutative,
    ///   so each fact is stated for both orders, at each level of nesting.
    /// - `x / x = 1` for each route answer x > 0: the overflow check of `a * 10 ** 0` in `LPPriceMath.normalizeAnswer`
    ///   (`checked_mul(x, y)` tests `div(x × y, x) = y`).
    /// - For the routes (tolerance 225 bps) and for the quote against the second source at A (100 bps), with `lo`,
    ///   `hi` the lower and higher value and `d = hi − lo`: `(10⁴ × d) / d = 10⁴` (d > 0) and `(tol × lo) / tol = lo`,
    ///   the overflow checks of `(hi − lo) * BPS` and `toleranceBps * lo` in `LPPriceMath._withinTolerance` and
    ///   `deviationBps`.
    /// - Whether the routes disagree (`drifting`), on the code's term `10⁴ × (hi − lo) > 225 × lo`: the caller's range
    ///   lies on one side of the agreement bounds. Halmos follows both sides of that branch when the 1 ms branching
    ///   query does not decide it, and the infeasible side's query ran past the budget in the agreement ranges.
    /// Every value is below 2^40, so no product wraps and each fact holds for every input of the caller's range: the
    /// assumptions exclude no input.
    function _driftRevertOnlyForGas(
        uint40 pAnswer,
        uint40 bAnswer,
        uint256 low,
        bool drifting
    ) internal {
        uint256 p = pAnswer;
        uint256 b = bAnswer;
        uint256[2] memory lows = _mins(p, b, low);
        for (uint256 i = 0; i < 2; ++i) {
            uint256[2] memory inner = _maxs(lows[i], lows[i], low);
            for (uint256 j = 0; j < 2; ++j) {
                uint256[2] memory served = _maxs(inner[j], A, A);
                _mins(served[0], INT256_MAX, A);
                _mins(served[1], INT256_MAX, A);
            }
        }
        _mins(p, INT256_MAX, p);
        vm.assume(_div(p, p) == 1);
        vm.assume(_div(b, b) == 1);
        _toleranceFacts(p, b, ROUTE_TOLERANCE_BPS);
        vm.assume(_outsideTolerance(p, b, ROUTE_TOLERANCE_BPS) == drifting);
        _toleranceFacts(p, A, SECOND_SOURCE_TOLERANCE_BPS);
        _driftRevertOnlyForGasNoFacts(pAnswer, bAnswer);
    }

    /// @dev The overflow-check facts of `LPPriceMath._withinTolerance(x, y, tol)` and `deviationBps(x, y)`, see
    /// `_driftRevertOnlyForGas`.
    function _toleranceFacts(
        uint256 x,
        uint256 y,
        uint256 tol
    ) internal pure {
        (uint256 lo, uint256 hi) = x < y ? (x, y) : (y, x);
        uint256 d = hi - lo;
        vm.assume(d == 0 || _div(_mul(d, BPS), d) == BPS);
        vm.assume(_div(_mul(tol, lo), tol) == lo);
    }

    /// @dev `!LPPriceMath._withinTolerance(x, y, tol)` for valid values, on the code's terms
    /// (`(hi − lo) * BPS > uint256(toleranceBps) * lo`).
    function _outsideTolerance(
        uint256 x,
        uint256 y,
        uint256 tol
    ) internal pure returns (bool out) {
        (uint256 lo, uint256 hi) = x < y ? (x, y) : (y, x);
        assembly ("memory-safe") {
            out := gt(mul(sub(hi, lo), BPS), mul(tol, lo))
        }
    }

    /// @dev OpenZeppelin's `Math.min(a, b)`, `b ^ ([a < b] × (a ^ b))`, with the operands of `mul` in each order;
    /// assumes both equal `v` and returns them.
    function _mins(
        uint256 a,
        uint256 b,
        uint256 v
    ) internal pure returns (uint256[2] memory r) {
        uint256 r0;
        uint256 r1;
        assembly ("memory-safe") {
            r0 := xor(b, mul(lt(a, b), xor(a, b)))
            r1 := xor(b, mul(xor(a, b), lt(a, b)))
        }
        vm.assume(r0 == v);
        vm.assume(r1 == v);
        r = [r0, r1];
    }

    /// @dev OpenZeppelin's `Math.max(a, b)`, `b ^ ([a > b] × (a ^ b))`, as `_mins`.
    function _maxs(
        uint256 a,
        uint256 b,
        uint256 v
    ) internal pure returns (uint256[2] memory r) {
        uint256 r0;
        uint256 r1;
        assembly ("memory-safe") {
            r0 := xor(b, mul(gt(a, b), xor(a, b)))
            r1 := xor(b, mul(xor(a, b), gt(a, b)))
        }
        vm.assume(r0 == v);
        vm.assume(r1 == v);
        r = [r0, r1];
    }

    /// @dev EVM `mul`, unchecked.
    function _mul(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := mul(a, b)
        }
    }

    /// @dev EVM `div`, unchecked.
    function _div(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256 r) {
        assembly ("memory-safe") {
            r := div(a, b)
        }
    }

    /// @dev `getPriceState()` reverts only with `InsufficientGas`, with no stated facts.
    function _driftRevertOnlyForGasNoFacts(
        uint40 pAnswer,
        uint40 bAnswer
    ) internal {
        _driftPush(pAnswer, bAnswer);
        try oracle.getPriceState() returns (DebtPriceView memory) {}
        catch (bytes memory err) {
            _onlyGasRevert(err);
        }
    }

    /// @dev Primary at `T0 - 80`, alternate at `T0 - 50`, accepted `A` at `T0 - 100`.
    function _driftPush(
        uint40 pAnswer,
        uint40 bAnswer
    ) internal {
        primary.push(int256(uint256(pAnswer)), T0 - 80);
        alternate.push(int256(uint256(bAnswer)), T0 - 50);
    }

    /// @dev The drift assertions on every return of `getPriceState()`; with `revertChecked`, also that it reverts
    /// only with `InsufficientGas` (otherwise a revert is checked by a `driftingTimestampsRevertOnlyForGas` check).
    function _driftTimestamps(
        uint40 pAnswer,
        uint40 bAnswer,
        bool revertChecked
    ) internal {
        _driftPush(pAnswer, bAnswer);
        try oracle.getPriceState() returns (DebtPriceView memory v) {
            if (v.state == PriceState.Drifting) {
                uint256 p = pAnswer;
                uint256 b = bAnswer;
                uint256 counted = p < b ? p : b;
                if (A > counted) {
                    assert(v.servedUpdatedAt == T0 - 100);
                    assert(v.legFeeds[0] == address(0));
                    assert(v.borrowPriceMaxAge == 0 && v.liquidationPriceMaxAge == 0);
                } else if (b == counted) {
                    assert(v.servedUpdatedAt == T0 - 50);
                    assert(v.legFeeds[0] == address(alternate));
                } else {
                    assert(v.servedUpdatedAt == T0 - 80);
                    assert(v.legFeeds[0] == address(primary));
                }
            }
        } catch (bytes memory err) {
            if (revertChecked) _onlyGasRevert(err);
        }
    }

    // PROP-034 verifies: REQ-ORACLE-098, REQ-ORACLE-038, Q-226, Q-228
    // Sources: 5.2 PROP-034 (debtSetPokeMinGasNeedsApplicationAdmin)
    function check_PROP_034_setPokeMinGasNeedsApplicationAdmin(
        address caller,
        uint32 value
    ) public {
        vm.prank(caller);
        try oracle.setPokeMinGas(value) {
            assert(caller == TIMELOCK);
            assert(value >= 600_000 && value <= 2_000_000);
            assert(oracle.pokeMinGas() == value);
        } catch {
            assert(oracle.pokeMinGas() == 600_000);
        }
    }

    // PROP-070 verifies: REQ-ORACLE-097, INV-084, Q-259
    // Sources: 5.2 PROP-070 (adminRolesOnlyTimelock, preserved by grantRole)
    function check_PROP_070_adminRolesOnlyTimelock(
        address caller,
        bytes32 role,
        address account
    ) public {
        vm.prank(caller);
        try oracle.grantRole(role, account) {} catch {}
        bytes32 admin = AvanaRoles.APPLICATION_ADMIN;
        assert(!oracle.hasRole(bytes32(0), account) || account == TIMELOCK);
        assert(!oracle.hasRole(admin, account) || account == TIMELOCK);
    }
}
