// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {IParameterStoreEvents} from "../../src/policy/parameter-store/IParameterStoreEvents.sol";
import {ProxyManager} from "../../src/proxy/proxy-manager/ProxyManager.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {MockProxyManager} from "../utils/mocks/ParameterStoreMocks.sol";
import {FreezeRegistryMock} from "../utils/mocks/ProxyMocks.sol";

/// @notice A fee-recipient candidate whose answer to each selector is programmed: a fixed return blob, or a revert.
contract ProgrammableCandidate {
    mapping(bytes4 selector => bytes answer) internal _answers;
    mapping(bytes4 selector => bool) internal _reverts;

    function program(
        bytes4 selector,
        bytes memory answer,
        bool reverts
    ) external {
        _answers[selector] = answer;
        _reverts[selector] = reverts;
    }

    fallback(
        bytes calldata data
    ) external returns (bytes memory) {
        bytes4 sel = bytes4(data[:4]);
        require(!_reverts[sel], "programmed revert");
        return _answers[sel];
    }
}

/// @notice `setFeeRecipient` (REQ-CONFIG-056) against candidates that answer the store's identity probes
/// (`logicConfig()`, `TIMELOCK()`, `MARKET_REGISTRY()`, `ADAPTER()`, `WALLET()`, `SPOKE()`, `MARKET_ID()`) with a
/// revert, nothing, a short answer, a long answer or the exact word: only an exact 32-byte word naming an Avana
/// address, or any answer to `logicConfig()`, marks the candidate as an Avana contract; a revert or a malformed
/// answer to a probe is not an identity and never blocks the setter.
contract ParameterStoreFeeRecipientUnitTest is ParameterStoreFixture {
    bytes4 internal constant LOGIC_CONFIG = bytes4(keccak256("logicConfig()"));
    bytes4 internal constant TIMELOCK_SEL = bytes4(keccak256("TIMELOCK()"));
    bytes4 internal constant REGISTRY_SEL = bytes4(keccak256("MARKET_REGISTRY()"));
    bytes4 internal constant ADAPTER_SEL = bytes4(keccak256("ADAPTER()"));
    bytes4 internal constant WALLET_SEL = bytes4(keccak256("WALLET()"));
    bytes4 internal constant SPOKE_SEL = bytes4(keccak256("SPOKE()"));
    bytes4 internal constant MARKET_ID_SEL = bytes4(keccak256("MARKET_ID()"));

    ProgrammableCandidate internal c;

    function setUp() public {
        _deployStore(false);
        c = new ProgrammableCandidate();
    }

    function _set(
        address r
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(address(timelock));
        (ok, ret) = address(store).call(abi.encodeCall(store.setFeeRecipient, (r)));
    }

    function _refused(
        address r
    ) internal {
        (bool ok, bytes memory ret) = _set(r);
        assertFalse(ok, "Avana contract accepted as fee recipient");
        assertEq(ret, abi.encodeWithSelector(IParameterStoreErrors.InvalidFeeRecipient.selector, r));
    }

    function _accepted(
        address r
    ) internal {
        (bool ok,) = _set(r);
        assertTrue(ok, "plain contract refused");
        assertEq(store.feeRecipient(), r);
    }

    // ─── Identity probes answered exactly ───

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_exactTimelockWordIsAvana() public {
        c.program(TIMELOCK_SEL, abi.encode(address(timelock)), false);
        _refused(address(c));
        // Another timelock's address is not this chain's.
        c.program(TIMELOCK_SEL, abi.encode(makeAddr("otherTimelock")), false);
        _accepted(address(c));
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_exactRegistryWordIsAvana() public {
        c.program(REGISTRY_SEL, abi.encode(address(registry)), false);
        _refused(address(c));
        c.program(REGISTRY_SEL, abi.encode(makeAddr("otherRegistry")), false);
        _accepted(address(c));
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_anyLogicConfigAnswerIsAvana() public {
        // logicConfig() is answered by every logic contract and implementation: one word or more marks the candidate.
        c.program(LOGIC_CONFIG, abi.encode(uint256(0)), false);
        _refused(address(c));
        c.program(LOGIC_CONFIG, abi.encode(bytes32("kind"), address(1), address(2), uint32(12), false), false);
        _refused(address(c));
        // Shorter than a word, or a revert, is no answer.
        c.program(LOGIC_CONFIG, hex"0102", false);
        _accepted(address(c));
        c.program(LOGIC_CONFIG, abi.encode(uint256(1)), true);
        _accepted(address(c));
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_adapterWordMarksAPositionProxy() public {
        c.program(ADAPTER_SEL, abi.encode(registry.AAVE_ADAPTER()), false);
        _refused(address(c));
        c.program(ADAPTER_SEL, abi.encode(makeAddr("otherAdapter")), false);
        _accepted(address(c));
    }

    // ─── Reverting and malformed probes are not identities ───

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_revertingProbesAreAccepted() public {
        bytes4[7] memory sels =
            [LOGIC_CONFIG, TIMELOCK_SEL, REGISTRY_SEL, ADAPTER_SEL, WALLET_SEL, SPOKE_SEL, MARKET_ID_SEL];
        for (uint256 i = 0; i < sels.length; ++i) {
            c.program(sels[i], abi.encode(address(timelock)), true);
        }
        _accepted(address(c));
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_shortAndEmptyAnswersAreNoWord() public {
        c.program(TIMELOCK_SEL, hex"", false);
        c.program(REGISTRY_SEL, abi.encodePacked(uint128(uint160(address(registry)))), false);
        c.program(ADAPTER_SEL, abi.encodePacked(bytes20(registry.AAVE_ADAPTER())), false);
        _accepted(address(c));
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_longAnswersOfOtherAddressesAreAccepted() public {
        bytes memory blob = abi.encode(makeAddr("x"), makeAddr("y"), uint256(7));
        c.program(TIMELOCK_SEL, blob, false);
        c.program(REGISTRY_SEL, blob, false);
        c.program(ADAPTER_SEL, blob, false);
        c.program(WALLET_SEL, blob, false);
        c.program(SPOKE_SEL, blob, false);
        _accepted(address(c));
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_proxyBindingsNeedWordsInAddressRange() public {
        MockProxyManager pm = new MockProxyManager();
        registry.setProxyManager(address(pm));
        // Bindings whose words are not addresses are never passed to the ProxyManager.
        c.program(WALLET_SEL, abi.encode(uint256(1) << 160), false);
        c.program(SPOKE_SEL, abi.encode(address(spoke)), false);
        c.program(MARKET_ID_SEL, abi.encode(M), false);
        pm.setPrediction(address(0), address(spoke), M, address(c));
        _accepted(address(c));
        // A zero wallet or Spoke word is no binding either.
        c.program(WALLET_SEL, abi.encode(address(0)), false);
        _accepted(address(c));
        c.program(WALLET_SEL, abi.encode(alice), false);
        c.program(SPOKE_SEL, abi.encode(address(0)), false);
        pm.setPrediction(alice, address(0), M, address(c));
        _accepted(address(c));
        // Valid bindings the ProxyManager maps to the candidate's own address: a PositionProxy.
        c.program(SPOKE_SEL, abi.encode(address(spoke)), false);
        pm.setPrediction(alice, address(spoke), M, address(c));
        _refused(address(c));
        // The same bindings mapped elsewhere: not this proxy.
        pm.setPrediction(alice, address(spoke), M + 1, address(c));
        _accepted(address(c));
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_realPositionProxyRefusedThroughPredictProxy() public {
        // A real ProxyManager and a real PositionProxy it deployed, bound to an adapter other than the registry's
        // AaveAdapter: only the predictProxy branch can recognise it.
        address otherAdapter = makeAddr("otherAdapter");
        assertTrue(otherAdapter != registry.AAVE_ADAPTER());
        ProxyManager pm = new ProxyManager(otherAdapter, address(new FreezeRegistryMock()));
        vm.prank(otherAdapter);
        address proxy = pm.deployProxy(alice, address(spoke), M);
        // Recorded as the chain's ProxyManager: its prediction maps the proxy's bindings to the proxy itself.
        registry.setProxyManager(address(pm));
        _refused(proxy);
        // Another ProxyManager's prediction of the same bindings is another address: not a proxy of this chain.
        registry.setProxyManager(address(new ProxyManager(otherAdapter, address(new FreezeRegistryMock()))));
        _accepted(proxy);
    }

    // ─── Event and plain accounts ───

    // TEST-062 verifies: REQ-CONFIG-056, REQ-PSTORE-010
    function test_TEST_062_plainAccountsAndTheEvent() public {
        _tl();
        vm.expectEmit(address(store));
        emit IParameterStoreEvents.ParameterSet("feeRecipient", bytes32(0), uint160(feeRecipient), uint160(alice));
        store.setFeeRecipient(alice);
        // An account with no code is never probed and is accepted.
        _accepted(makeAddr("treasurySafeNotYetDeployed"));
        // Recorded registry addresses are refused whatever their code.
        _refused(registry.PROXY_MANAGER());
        _refused(registry.LP_VAULT_SWAP());
        _refused(registry.VAULT_TOKEN_FACTORY());
        _refused(registry.RISK_MODULE());
        _refused(registry.LOCK());
        _refused(registry.PAYOUT_ESCROW());
        _refused(registry.COLLATERALIZATION());
        _refused(address(spoke));
        _refused(address(registry));
    }
}
