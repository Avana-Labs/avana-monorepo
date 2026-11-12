// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreLogic} from "../../src/policy/parameter-store/IParameterStoreLogic.sol";
import {PositionProxy} from "../../src/proxy/position-proxy/PositionProxy.sol";
import {ProxyManager} from "../../src/proxy/proxy-manager/ProxyManager.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {FreezeRegistryMock} from "../utils/mocks/ProxyMocks.sol";

/// @notice A candidate that answers every probe with `size` bytes: the first word `head`, zeros after it.
/// `logicConfig()` reverts with the same `size` bytes, so the candidate is no logic contract.
contract OversizedAnswerCandidate {
    uint256 internal immutable _SIZE;
    uint256 internal immutable _HEAD;

    constructor(
        uint256 size,
        uint256 head
    ) {
        (_SIZE, _HEAD) = (size, head);
    }

    fallback() external {
        uint256 size = _SIZE;
        uint256 head = _HEAD;
        bool isLogicConfig = msg.sig == bytes4(keccak256("logicConfig()"));
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(0, head)
            if isLogicConfig { revert(0, size) }
            return(0, size)
        }
    }
}

/// @notice A candidate whose `TIMELOCK()` burns `burn` gas before answering `answer` with one word.
contract HeavyTimelockCandidate {
    address internal immutable _ANSWER;
    uint256 internal immutable _BURN;

    constructor(
        address answer,
        uint256 burn
    ) {
        (_ANSWER, _BURN) = (answer, burn);
    }

    // solhint-disable-next-line func-name-mixedcase
    function TIMELOCK() external view returns (address) {
        uint256 start = gasleft();
        while (start - gasleft() < _BURN) {}
        return _ANSWER;
    }
}

/// @notice The bounded identity probes of `setFeeRecipient` (REQ-CONFIG-056): each probe runs with its own 30,000
/// gas and copies at most one word beyond the answer it accepts, so a candidate answering its probes with a 1 MB
/// buffer costs about what a 32-byte answer costs, an answer is a word only at exactly 32 bytes, every Avana getter the
/// probes read fits the probe gas with a wide margin, and no transaction gas limit lets a starved probe accept an
/// Avana contract.
contract ParameterStoreFeeRecipientGasUnitTest is ParameterStoreFixture {
    /// @dev `PROBE_GAS` of `ParameterStoreAdminRiskLogic`.
    uint256 internal constant PROBE_GAS = 30_000;
    /// @dev The identity probes a candidate with code answers when none matches: `logicConfig()`, `TIMELOCK()`,
    /// `MARKET_REGISTRY()`, `ADAPTER()`, `WALLET()`, `SPOKE()`, `MARKET_ID()`.
    uint256 internal constant PROBES = 7;

    function setUp() public {
        _deployStore(false);
    }

    function _cost(
        address candidate
    ) internal returns (bool ok, uint256 used) {
        vm.prank(address(timelock));
        uint256 g0 = gasleft();
        (ok,) = address(store).call{gas: 5_000_000}(abi.encodeCall(store.setFeeRecipient, (candidate)));
        used = g0 - gasleft();
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_oversizedProbeAnswersDoNotRaiseTheCost() public {
        OversizedAnswerCandidate small = new OversizedAnswerCandidate(32, 0);
        OversizedAnswerCandidate big = new OversizedAnswerCandidate(1_000_000, 0);
        (bool okSmall, uint256 smallCost) = _cost(address(small));
        (bool okBig, uint256 bigCost) = _cost(address(big));
        assertTrue(okSmall, "plain candidate refused");
        assertTrue(okBig, "setter ran out of gas on a large answer");
        // Each probe of the 1 MB candidate runs out inside its own 30,000 gas: at most PROBES x PROBE_GAS more.
        assertLt(bigCost, smallCost + PROBES * PROBE_GAS, "cost grows with the candidate's answer size");
        emit log_named_uint("setFeeRecipient gas, 32-byte answers", smallCost);
        emit log_named_uint("setFeeRecipient gas, 1 MB answers", bigCost);
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_oversizedAnswerHeadedByTheTimelockIsNoWord() public {
        // A word is exactly 32 bytes: a 64-byte or 1 MB answer whose first word is the timelock is no identity, the
        // same as before the bound; only the exact word marks the candidate.
        OversizedAnswerCandidate exact = new OversizedAnswerCandidate(32, uint160(address(timelock)));
        OversizedAnswerCandidate twoWords = new OversizedAnswerCandidate(64, uint160(address(timelock)));
        OversizedAnswerCandidate huge = new OversizedAnswerCandidate(1_000_000, uint160(address(timelock)));
        (bool ok,) = _cost(address(exact));
        assertFalse(ok, "exact timelock word accepted");
        (ok,) = _cost(address(twoWords));
        assertTrue(ok, "two-word answer read as a word");
        (ok,) = _cost(address(huge));
        assertTrue(ok, "1 MB answer read as a word");
        assertEq(store.feeRecipient(), address(huge));
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_avanaGettersFitTheProbeGas() public {
        // Real getters behind their proxies and the logic contracts: each costs well under a third of PROBE_GAS.
        ProxyManager pm = new ProxyManager(makeAddr("adapter"), address(new FreezeRegistryMock()));
        vm.prank(makeAddr("adapter"));
        address proxy = pm.deployProxy(alice, address(spoke), M);
        bytes[6] memory calls = [
            abi.encodeWithSignature("TIMELOCK()"),
            abi.encodeWithSignature("MARKET_REGISTRY()"),
            abi.encodeCall(IParameterStoreLogic.logicConfig, ()),
            abi.encodeWithSignature("ADAPTER()"),
            abi.encodeWithSignature("WALLET()"),
            abi.encodeCall(pm.predictProxy, (alice, address(spoke), M))
        ];
        address[6] memory targets = [address(store), address(store), logics.adminRisk, proxy, proxy, address(pm)];
        for (uint256 i = 0; i < calls.length; ++i) {
            uint256 g0 = gasleft();
            (bool ok, bytes memory ret) = targets[i].staticcall{gas: PROBE_GAS}(calls[i]);
            uint256 used = g0 - gasleft();
            assertTrue(ok && ret.length >= 32, "getter failed within the probe gas");
            assertLt(used, PROBE_GAS / 3, "getter too close to the probe gas");
        }
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_noGasLimitAcceptsAStarvedAvanaCandidate() public {
        // A candidate that answers TIMELOCK() with this chain's timelock after burning 20,000 gas: within the probe
        // gas, so refused; under any transaction gas limit the setter either refuses it or runs out of gas, never
        // records it.
        HeavyTimelockCandidate heavy = new HeavyTimelockCandidate(address(timelock), 20_000);
        bytes memory refused = abi.encodeWithSelector(IParameterStoreErrors.InvalidFeeRecipient.selector, heavy);
        // An out-of-gas failure of the delegated body reaches the caller as OpenZeppelin's `FailedCall()`.
        bytes memory outOfGas = abi.encodeWithSignature("FailedCall()");
        for (uint256 limit = 20_000; limit <= 200_000; limit += 1000) {
            vm.prank(address(timelock));
            (bool ok, bytes memory ret) =
                address(store).call{gas: limit}(abi.encodeCall(store.setFeeRecipient, (address(heavy))));
            assertFalse(ok, "starved probe accepted an Avana candidate");
            assertTrue(
                ret.length == 0 || keccak256(ret) == keccak256(refused) || keccak256(ret) == keccak256(outOfGas),
                "unexpected revert"
            );
        }
        assertEq(store.feeRecipient(), feeRecipient);
    }
}
