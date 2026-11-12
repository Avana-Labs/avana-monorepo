// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../src/amm/IAmmIntegration.sol";
import {PoolKeying} from "../../src/amm/types/PoolKeying.sol";
import {UniswapV3Integration} from "../../src/amm/uniswap-v3/UniswapV3Integration.sol";
import {ICollateralizationViews} from "../../src/custody/collateralization/ICollateralizationViews.sol";
import {ILPVault} from "../../src/custody/lp-vault/ILPVault.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {IVaultTokenFactory} from "../../src/vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {VaultTokenFactoryFixture} from "../utils/fixtures/VaultTokenFactoryFixture.sol";
import {MockNFPM, MockV3Factory} from "../utils/mocks/UniswapV3Mocks.sol";

/// @notice An LPVault whose answer to each getter is programmed: the correct answer by default, or a revert, a short
/// answer, a long answer (the correct answer followed by a word), a 1 MB answer headed by the correct answer, or a
/// 1 MB revert.
contract ProgrammableLPVault {
    enum Mode {
        Exact,
        Revert,
        Short,
        Long,
        Oversized,
        OversizedRevert,
        Word
    }

    uint256 internal constant HUGE = 1_000_000;

    mapping(bytes4 selector => bytes answer) internal _answers;
    mapping(bytes4 selector => Mode) internal _modes;
    mapping(bytes4 selector => uint256) internal _words;

    function setAnswer(
        bytes4 selector,
        bytes memory answer
    ) external {
        _answers[selector] = answer;
    }

    function setMode(
        bytes4 selector,
        Mode mode
    ) external {
        _modes[selector] = mode;
    }

    /// @dev For `Mode.Word`: a single 32-byte word in place of the answer.
    function setWord(
        bytes4 selector,
        uint256 word
    ) external {
        _modes[selector] = Mode.Word;
        _words[selector] = word;
    }

    fallback(
        bytes calldata data
    ) external returns (bytes memory) {
        bytes4 sel = bytes4(data[:4]);
        bytes memory answer = _answers[sel];
        Mode mode = _modes[sel];
        if (mode == Mode.Revert) revert("programmed");
        if (mode == Mode.Short) {
            // One byte shorter than the answer.
            // solhint-disable-next-line no-inline-assembly
            assembly {
                mstore(answer, sub(mload(answer), 1))
            }
            return answer;
        }
        if (mode == Mode.Long) return bytes.concat(answer, bytes32(uint256(1)));
        if (mode == Mode.Word) return abi.encode(_words[sel]);
        if (mode == Mode.Oversized || mode == Mode.OversizedRevert) {
            bool rev = mode == Mode.OversizedRevert;
            // solhint-disable-next-line no-inline-assembly
            assembly {
                let n := mload(answer)
                for { let i := 0 } lt(i, n) { i := add(i, 0x20) } { mstore(i, mload(add(add(answer, 0x20), i))) }
                if rev { revert(0, HUGE) }
                return(0, HUGE)
            }
        }
        return answer;
    }
}

/// @title VaultTokenFactoryBoundedReadsUnitTest
/// @notice The bounded getter reads of `registerIntegration` (REQ-VTOKEN-044, REQ-VTOKEN-049): every getter of the
/// LPVault and of Collateralization is read with its own 30,000 gas and at most one word beyond the answer copied; a
/// revert, a short answer, a long answer, a 1 MB answer and a 1 MB revert each fail with `InvalidIntegration`; an
/// address word above 160 bits and enum words outside their range fail the same way; and a 1 MB answer costs about
/// what a wrong 32-byte answer costs.
contract VaultTokenFactoryBoundedReadsUnitTest is VaultTokenFactoryFixture {
    /// @dev `READ_GAS` of `VaultTokenFactory`.
    uint256 internal constant READ_GAS = 30_000;

    ProgrammableLPVault internal vault;
    bytes4[7] internal getters;

    function setUp() public {
        _deployFactory();
        vault = new ProgrammableLPVault();
        getters = [
            IAmmIntegration.INTEGRATION_ID.selector,
            IAmmIntegration.AMM_PROTOCOL.selector,
            ILPVault.COLLATERALIZATION.selector,
            ILPVault.LOCK.selector,
            ILPVault.TIMELOCK.selector,
            ILPVault.MARKET_REGISTRY.selector,
            IAmmIntegration.capabilities.selector
        ];
        vault.setAnswer(getters[0], abi.encode(uint256(SLIPSTREAM_ID)));
        vault.setAnswer(getters[1], abi.encode(AERODROME_SLIPSTREAM));
        vault.setAnswer(getters[2], abi.encode(address(collateralization)));
        vault.setAnswer(getters[3], abi.encode(lock));
        vault.setAnswer(getters[4], abi.encode(address(timelock)));
        vault.setAnswer(getters[5], abi.encode(address(marketRegistry)));
        vault.setAnswer(
            getters[6], abi.encode(uint256(PoolKeying.Address), 0, 0, uint256(ShapeKind.TickRange), 1, 0, 0, 0)
        );
    }

    function _register(
        address lpVault
    ) internal returns (bool ok, bytes memory ret, uint256 used) {
        vm.prank(address(timelock));
        uint256 g0 = gasleft();
        (ok, ret) = address(factory).call{gas: 5_000_000}(
            abi.encodeCall(factory.registerIntegration, (SLIPSTREAM_ID, lpVault))
        );
        used = g0 - gasleft();
    }

    function _refused(
        string memory why
    ) internal returns (uint256 used) {
        bool ok;
        bytes memory ret;
        (ok, ret, used) = _register(address(vault));
        assertFalse(ok, why);
        assertEq(ret, abi.encodeWithSelector(IVaultTokenFactory.InvalidIntegration.selector), why);
    }

    // TEST-024 verifies: REQ-VTOKEN-044, REQ-VTOKEN-049
    function test_TEST_024_everyMalformedGetterAnswerIsRefused() public {
        ProgrammableLPVault.Mode[5] memory bad = [
            ProgrammableLPVault.Mode.Revert,
            ProgrammableLPVault.Mode.Short,
            ProgrammableLPVault.Mode.Long,
            ProgrammableLPVault.Mode.Oversized,
            ProgrammableLPVault.Mode.OversizedRevert
        ];
        for (uint256 g = 0; g < getters.length; ++g) {
            for (uint256 b = 0; b < bad.length; ++b) {
                vault.setMode(getters[g], bad[b]);
                _refused("malformed getter answer accepted");
            }
            vault.setMode(getters[g], ProgrammableLPVault.Mode.Exact);
        }
        (bool ok,,) = _register(address(vault));
        assertTrue(ok, "exact answers refused");
        assertEq(factory.lpVaultOf(SLIPSTREAM_ID), address(vault));
    }

    // TEST-024 verifies: REQ-VTOKEN-044
    function test_TEST_024_collateralizationGettersAreBoundedToo() public {
        // Collateralization answering its own getters with 1 MB, a long or a short answer fails every registration.
        ProgrammableLPVault coll = new ProgrammableLPVault();
        coll.setAnswer(ICollateralizationViews.ADAPTER.selector, abi.encode(adapter));
        coll.setAnswer(ICollateralizationViews.LP_VAULT_SWAP.selector, abi.encode(address(lpVaultSwap)));
        coll.setAnswer(ICollateralizationViews.LOCK.selector, abi.encode(lock));
        IVaultTokenFactory f = IVaultTokenFactory(
            deployCode(
                "VaultTokenFactory.sol:VaultTokenFactory",
                abi.encode(adapter, address(lpVaultSwap), address(coll), address(timelock), address(marketRegistry))
            )
        );
        coll.setAnswer(ICollateralizationViews.VAULT_TOKEN_FACTORY.selector, abi.encode(address(f)));
        vault.setAnswer(getters[2], abi.encode(address(coll)));
        bytes4[4] memory sels = [
            ICollateralizationViews.VAULT_TOKEN_FACTORY.selector,
            ICollateralizationViews.ADAPTER.selector,
            ICollateralizationViews.LP_VAULT_SWAP.selector,
            ICollateralizationViews.LOCK.selector
        ];
        ProgrammableLPVault.Mode[3] memory bad =
            [ProgrammableLPVault.Mode.Oversized, ProgrammableLPVault.Mode.Long, ProgrammableLPVault.Mode.Short];
        for (uint256 i = 0; i < sels.length; ++i) {
            for (uint256 b = 0; b < bad.length; ++b) {
                coll.setMode(sels[i], bad[b]);
                vm.prank(address(timelock));
                vm.expectRevert(IVaultTokenFactory.InvalidIntegration.selector);
                f.registerIntegration(SLIPSTREAM_ID, address(vault));
            }
            coll.setMode(sels[i], ProgrammableLPVault.Mode.Exact);
        }
        vm.prank(address(timelock));
        f.registerIntegration(SLIPSTREAM_ID, address(vault));
        assertEq(f.lpVaultOf(SLIPSTREAM_ID), address(vault));
    }

    // TEST-024 verifies: REQ-VTOKEN-044, REQ-VTOKEN-049
    function test_TEST_024_wordsAreRangeCheckedNotOnlyLengthChecked() public {
        // A 32-byte word naming the right address with a bit above 160 is no address.
        uint256 dirty = uint256(uint160(address(collateralization))) | (uint256(1) << 160);
        for (uint256 g = 2; g < 6; ++g) {
            vault.setWord(getters[g], dirty);
            _refused("address word above 160 bits accepted");
            vault.setMode(getters[g], ProgrammableLPVault.Mode.Exact);
        }
        // The integration identifier must be exactly the one registered; the protocol must be non-zero.
        vault.setWord(getters[0], uint256(SLIPSTREAM_ID) | (uint256(1) << 32));
        _refused("identifier with high bits accepted");
        vault.setMode(getters[0], ProgrammableLPVault.Mode.Exact);
        vault.setWord(getters[1], 0);
        _refused("zero protocol accepted");
        vault.setMode(getters[1], ProgrammableLPVault.Mode.Exact);
        // capabilities(): keying and shape kind inside their enums, shape kind never None.
        uint256[3] memory badKeying = [uint256(2), 3, type(uint256).max];
        for (uint256 i = 0; i < badKeying.length; ++i) {
            vault.setAnswer(getters[6], abi.encode(badKeying[i], 0, 0, uint256(ShapeKind.TickRange), 1, 0, 0, 0));
            _refused("keying outside its enum accepted");
        }
        uint256[3] memory badKind = [uint256(ShapeKind.None), 3, type(uint256).max];
        for (uint256 i = 0; i < badKind.length; ++i) {
            vault.setAnswer(getters[6], abi.encode(uint256(PoolKeying.Address), 0, 0, badKind[i], 1, 0, 0, 0));
            _refused("shape kind outside its range accepted");
        }
    }

    // TEST-024 verifies: REQ-VTOKEN-044
    function test_TEST_024_oversizedAnswerCostsAboutAWrongWord() public {
        // The first read, INTEGRATION_ID(), answers a wrong word or a 1 MB buffer: both refused, and the 1 MB answer
        // costs at most the read's own gas more.
        vault.setWord(getters[0], uint256(V3_ID));
        uint256 wordCost = _refused("wrong identifier accepted");
        vault.setMode(getters[0], ProgrammableLPVault.Mode.Oversized);
        uint256 hugeCost = _refused("1 MB answer accepted");
        assertLt(hugeCost, wordCost + READ_GAS, "cost grows with the answer size");
        // A 1 MB capabilities() answer, read last, the same.
        vault.setMode(getters[0], ProgrammableLPVault.Mode.Exact);
        vault.setMode(getters[6], ProgrammableLPVault.Mode.Short);
        uint256 shortCapsCost = _refused("short capabilities accepted");
        vault.setMode(getters[6], ProgrammableLPVault.Mode.Oversized);
        uint256 hugeCapsCost = _refused("1 MB capabilities accepted");
        assertLt(hugeCapsCost, shortCapsCost + READ_GAS, "capabilities cost grows with the answer size");
        emit log_named_uint("registerIntegration gas, wrong 32-byte INTEGRATION_ID", wordCost);
        emit log_named_uint("registerIntegration gas, 1 MB INTEGRATION_ID", hugeCost);
        emit log_named_uint("registerIntegration gas, short capabilities", shortCapsCost);
        emit log_named_uint("registerIntegration gas, 1 MB capabilities", hugeCapsCost);
    }

    // TEST-024 verifies: REQ-VTOKEN-044, REQ-AMM-CORE-001
    function test_TEST_024_realIntegrationRegistersWithinTheReadGas() public {
        // The real Uniswap v3 integration answers every getter with exactly the bytes the factory accepts, each read
        // far below the read gas, and registers.
        MockV3Factory v3Factory = new MockV3Factory();
        UniswapV3Integration real = new UniswapV3Integration(
            SLIPSTREAM_ID,
            address(collateralization),
            address(marketRegistry),
            lock,
            address(timelock),
            address(new MockNFPM(address(v3Factory))),
            address(v3Factory)
        );
        for (uint256 i = 0; i < getters.length; ++i) {
            uint256 g0 = gasleft();
            (bool ok, bytes memory ret) = address(real).staticcall{gas: READ_GAS}(abi.encodeWithSelector(getters[i]));
            uint256 used = g0 - gasleft();
            assertTrue(ok, "getter failed within the read gas");
            assertEq(ret.length, i == 6 ? 256 : 32, "answer length");
            assertLt(used, READ_GAS / 3, "getter too close to the read gas");
        }
        (bool registered,,) = _register(address(real));
        assertTrue(registered, "real integration refused");
        assertEq(factory.lpVaultOf(SLIPSTREAM_ID), address(real));
    }
}
