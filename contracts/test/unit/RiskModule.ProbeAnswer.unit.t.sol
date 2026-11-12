// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {IssuerProbe} from "../../src/policy/market-registry/types/IssuerProbe.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {RiskModuleConstants} from "../../src/policy/risk-module/RiskModuleConstants.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {RiskModuleMathHarness} from "../utils/harness/RiskModuleMathHarness.sol";

/// @title RiskModuleProbeAnswerBase
/// @notice The length rule of SPEC-BRK-003 on each read of an issuer probe of the GHO debt asset: an answer that is
/// not exactly one 32-byte word trips `ISSUER`, whatever its first word, and an oversized answer costs the read no
/// more than a short one. Each concrete suite lists GHO with one probe kind.
abstract contract RiskModuleProbeAnswerBase is RiskModuleFixture {
    bytes4 internal constant PAUSED = bytes4(keccak256("paused()"));
    bytes4 internal constant FEE_RATE = bytes4(keccak256("basisPointsRate()"));
    uint256 internal constant ONE_MB = 1 << 20;

    function setUp() public {
        _deployRiskWorld();
        _debt(1.5e18, 1000);
    }

    /// @dev The selectors the suite's probe kind reads.
    function _reads() internal pure virtual returns (bytes4[] memory sels);

    function _debtReasons() internal view returns (uint32) {
        return riskModule.liveDebtBreakerReasons(address(spoke), GHO_RESERVE);
    }

    /// @dev Answers `sel` with `answer` and every other read of the kind with a clear one-word 0.
    function _answer(
        bytes4 sel,
        bytes memory answer
    ) internal {
        vm.clearMockedCalls();
        bytes4[] memory sels = _reads();
        for (uint256 i = 0; i < sels.length; ++i) {
            vm.mockCall(address(tGho), abi.encodePacked(sels[i]), sels[i] == sel ? answer : abi.encode(uint256(0)));
        }
    }

    /// @dev Gas of one `liveDebtBreakerReasons` call, which runs the probe, and its result. Measured in a fresh call
    /// frame (`measureProbe`), so the test's own memory, grown by building a 1 MB answer, does not price the call.
    function _measured() internal view returns (uint256 used, uint32 reasons) {
        (used, reasons) = this.measureProbe();
    }

    /// @notice External entry of `_measured`, run in its own frame with fresh memory.
    function measureProbe() external view returns (uint256 used, uint32 reasons) {
        uint256 before = gasleft();
        reasons = _debtReasons();
        used = before - gasleft();
    }

    function _expectBorrowTripped() internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtBreakerTripped.selector, address(spoke), GHO_RESERVE, BreakerReasons.ISSUER
            )
        );
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }

    // TEST-228 verifies: SPEC-BRK-003, REQ-RISK-065
    /// @notice A one-word 0 on every read is clear and the borrow passes: the length rule refuses no well-formed
    /// answer. Fails if the probe requires anything but exactly 32 bytes.
    function test_TEST_228_oneWordZeroAnswerIsClear() public {
        bytes4[] memory sels = _reads();
        for (uint256 i = 0; i < sels.length; ++i) {
            _answer(sels[i], abi.encode(uint256(0)));
            assertEq(_debtReasons(), 0);
            riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        }
    }

    // TEST-228 verifies: SPEC-BRK-003, REQ-RISK-065
    /// @notice A 64-byte answer whose first word is 0 (not paused, zero fee) trips `ISSUER` and blocks the borrow, and
    /// so do 33- and 31-byte answers. Fails on the code that read the first word of a longer answer (the 64- and
    /// 33-byte cases read as clear).
    function test_TEST_228_answerNotOneWordTrips() public {
        bytes4[] memory sels = _reads();
        for (uint256 i = 0; i < sels.length; ++i) {
            _answer(sels[i], abi.encode(uint256(0), uint256(0)));
            assertEq(_debtReasons(), BreakerReasons.ISSUER, "64 bytes, first word 0");
            _expectBorrowTripped();
            _answer(sels[i], abi.encodePacked(uint256(0), uint8(0)));
            assertEq(_debtReasons(), BreakerReasons.ISSUER, "33 bytes");
            _answer(sels[i], abi.encodePacked(bytes31(0)));
            assertEq(_debtReasons(), BreakerReasons.ISSUER, "31 bytes");
        }
        vm.clearMockedCalls();
        assertEq(_debtReasons(), 0);
    }

    // TEST-228 verifies: SPEC-BRK-003, REQ-RISK-089
    /// @notice A 1 MB answer of zeros trips `ISSUER`, and the probe costs no more gas than with a tripping one-word
    /// answer: at most 32 bytes are copied whatever the answer's length. Fails on the code that read the first word
    /// of a longer answer (the 1 MB of zeros read as clear).
    function test_TEST_228_oversizedAnswerTripsAtBoundedCost() public {
        bytes memory huge = new bytes(ONE_MB);
        bytes4[] memory sels = _reads();
        for (uint256 i = 0; i < sels.length; ++i) {
            _answer(sels[i], abi.encode(uint256(1)));
            // Warm every account and slot the probe path touches, so both measurements see the same access costs.
            _debtReasons();
            (uint256 shortGas, uint32 shortReasons) = _measured();
            assertEq(shortReasons, BreakerReasons.ISSUER);
            _answer(sels[i], huge);
            (uint256 hugeGas, uint32 hugeReasons) = _measured();
            assertEq(hugeReasons, BreakerReasons.ISSUER, "1 MB of zeros");
            emit log_named_uint("probe call gas, tripping one-word answer", shortGas);
            emit log_named_uint("probe call gas, 1 MB answer", hugeGas);
            assertLe(hugeGas, shortGas, "an oversized answer costs no more than a short one");
            _expectBorrowTripped();
        }
    }

    // TEST-228 verifies: SPEC-BRK-003, REQ-RISK-089
    /// @notice The same rule on real EVM answers rather than mocked ones: GHO's code is replaced by code returning
    /// `n` zero bytes. 32 bytes is clear; 64 bytes trips; 1 MB cannot be built within `ISSUER_PROBE_GAS` (its memory
    /// alone costs about 2.2 M gas), so the probe runs out of gas and trips, and the call costs at most the probe gas
    /// more than a one-word answer. The 64-byte case fails on the code that read the first word of a longer answer.
    function test_TEST_228_realAnswerLengths() public {
        bytes memory original = address(tGho).code;
        // PUSH1 0x20 PUSH1 0 RETURN: 32 zero bytes.
        vm.etch(address(tGho), hex"60206000f3");
        _debtReasons();
        (uint256 wordGas, uint32 reasons) = _measured();
        assertEq(reasons, 0, "32 bytes of 0");
        // PUSH1 0x40 PUSH1 0 RETURN: 64 zero bytes.
        vm.etch(address(tGho), hex"60406000f3");
        assertEq(_debtReasons(), BreakerReasons.ISSUER, "64 bytes of 0");
        // PUSH3 0x100000 PUSH1 0 RETURN: 1 MB of zero bytes.
        vm.etch(address(tGho), hex"621000006000f3");
        uint256 hugeGas;
        (hugeGas, reasons) = _measured();
        assertEq(reasons, BreakerReasons.ISSUER, "1 MB");
        emit log_named_uint("probe call gas, real 32-byte answer", wordGas);
        emit log_named_uint("probe call gas, real 1 MB answer", hugeGas);
        assertLe(hugeGas, wordGas + _reads().length * RiskModuleConstants.ISSUER_PROBE_GAS);
        vm.etch(address(tGho), original);
        assertEq(_debtReasons(), 0);
    }
}

/// @title RiskModuleProbeAnswerPausedUnitTest
/// @notice The length rule on the `PausedFlag` read, `paused()`.
contract RiskModuleProbeAnswerPausedUnitTest is RiskModuleProbeAnswerBase {
    function _ghoIssuerProbe() internal pure override returns (IssuerProbe) {
        return IssuerProbe.PausedFlag;
    }

    function _reads() internal pure override returns (bytes4[] memory sels) {
        sels = new bytes4[](1);
        sels[0] = PAUSED;
    }

    // TEST-221 verifies: SPEC-BRK-003, REQ-RISK-089
    /// @notice The exact-length read itself: ok only for a call that returned exactly 32 bytes, the word 0 otherwise,
    /// and the gas floor of REQ-RISK-089 before the call (35,477 for a 30,000-gas probe).
    function test_TEST_221_probeWordReadsExactlyOneWord() public {
        RiskModuleMathHarness h = new RiskModuleMathHarness();
        address token = address(tGho);
        vm.mockCall(token, abi.encodePacked(PAUSED), abi.encode(uint256(7)));
        (bool ok, uint256 word) = h.probeWord{gas: 100_000}(token, 30_000, PAUSED);
        assertTrue(ok);
        assertEq(word, 7);
        vm.mockCall(token, abi.encodePacked(PAUSED), abi.encode(uint256(7), uint256(0)));
        (ok, word) = h.probeWord{gas: 100_000}(token, 30_000, PAUSED);
        assertFalse(ok);
        assertEq(word, 0);
        vm.mockCallRevert(token, abi.encodePacked(PAUSED), abi.encode(uint256(0)));
        (ok, word) = h.probeWord{gas: 100_000}(token, 30_000, PAUSED);
        assertFalse(ok);
        (ok, word) = h.probeWord{gas: 100_000}(makeAddr("noCode"), 30_000, PAUSED);
        assertFalse(ok);
        vm.expectPartialRevert(IRiskModuleErrors.InsufficientGas.selector);
        h.probeWord{gas: 34_000}(token, 30_000, PAUSED);
    }

    // TEST-221 verifies: SPEC-BRK-003
    /// @notice For any answer length up to 4 KB and any first word, the read is ok exactly when the length is 32, and
    /// then returns that word.
    function testFuzz_TEST_221_probeWordOkOnlyAtThirtyTwoBytes(
        uint16 rawLength,
        uint256 first
    ) public {
        uint256 length = bound(rawLength, 0, 4096);
        bytes memory answer = new bytes(length);
        if (length >= 32) {
            // solhint-disable-next-line no-inline-assembly
            assembly ("memory-safe") {
                mstore(add(answer, 0x20), first)
            }
        }
        RiskModuleMathHarness h = new RiskModuleMathHarness();
        vm.mockCall(address(tGho), abi.encodePacked(PAUSED), answer);
        (bool ok, uint256 word) = h.probeWord{gas: 100_000}(address(tGho), 30_000, PAUSED);
        assertEq(ok, length == 32);
        assertEq(word, length == 32 ? first : 0);
    }
}

/// @title RiskModuleProbeAnswerFeeRateUnitTest
/// @notice The length rule on the `UsdtFeeRate` read, `basisPointsRate()`.
contract RiskModuleProbeAnswerFeeRateUnitTest is RiskModuleProbeAnswerBase {
    function _ghoIssuerProbe() internal pure override returns (IssuerProbe) {
        return IssuerProbe.UsdtFeeRate;
    }

    function _reads() internal pure override returns (bytes4[] memory sels) {
        sels = new bytes4[](1);
        sels[0] = FEE_RATE;
    }
}

/// @title RiskModuleProbeAnswerCombinedUnitTest
/// @notice The length rule on each of the two reads of `UsdtFeeRateAndPaused`, the other read answering a clear
/// one-word 0.
contract RiskModuleProbeAnswerCombinedUnitTest is RiskModuleProbeAnswerBase {
    function _ghoIssuerProbe() internal pure override returns (IssuerProbe) {
        return IssuerProbe.UsdtFeeRateAndPaused;
    }

    function _reads() internal pure override returns (bytes4[] memory sels) {
        sels = new bytes4[](2);
        (sels[0], sels[1]) = (PAUSED, FEE_RATE);
    }
}
