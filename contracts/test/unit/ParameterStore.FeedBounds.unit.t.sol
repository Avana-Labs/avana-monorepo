// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";

/// @notice A Chainlink proxy that is its own aggregator and answers `minAnswer()` and `maxAnswer()` with any raw word,
/// a revert or a short answer, whatever the `int192` type of the real getters.
contract RawBoundsAggregator {
    uint8 public decimals;
    uint256 public minWord;
    uint256 public maxWord;
    // 0: one word; 1: revert; 2: a short answer; 3: two words.
    uint256 public minMode;

    function set(
        uint8 d,
        uint256 lo,
        uint256 hi,
        uint256 mode
    ) external {
        (decimals, minWord, maxWord, minMode) = (d, lo, hi, mode);
    }

    function aggregator() external view returns (address) {
        return address(this);
    }

    function minAnswer() external view returns (bytes32) {
        uint256 mode = minMode;
        uint256 w = minWord;
        require(mode != 1, "minAnswer");
        // solhint-disable-next-line no-inline-assembly
        assembly {
            mstore(0, w)
            mstore(0x20, 1)
            if eq(mode, 2) { return(0, 31) }
            if eq(mode, 3) { return(0, 64) }
            return(0, 32)
        }
    }

    function maxAnswer() external view returns (uint256) {
        return maxWord;
    }
}

/// @notice REQ-CONFIG-022: `setFeed` reads the aggregator's `minAnswer` and `maxAnswer` as raw words and bounds both
/// by `type(int192).max`, the aggregator's own type, with a named `InvalidFeed`; a word above it (a large or a
/// negative value), a reverting or a short read are refused by name; the normalised minimum is checked on the bounded
/// value at every decimals count.
contract ParameterStoreFeedBoundsUnitTest is ParameterStoreFixture {
    uint256 internal constant I192_MAX = uint256(int256(type(int192).max));
    RawBoundsAggregator internal f;

    function setUp() public {
        _deployStore(false);
        f = new RawBoundsAggregator();
    }

    function _set() internal returns (bool ok, bytes memory ret) {
        vm.prank(address(timelock));
        (ok, ret) = address(store).call(abi.encodeCall(store.setFeed, (address(f), _feedDef(3600, 600))));
    }

    function _invalid(
        bytes32 check
    ) internal view returns (bytes memory) {
        return abi.encodeWithSelector(IParameterStoreErrors.InvalidFeed.selector, address(f), check);
    }

    // TEST-250 verifies: REQ-CONFIG-022, Q-191
    function test_TEST_250_largeMinimumBelowEightDecimalsRefusedByName() public {
        // Decimals below 8 scale the minimum up: a minimum just above the int192 range is refused by name, at every
        // decimals count from 1 to 7, never by an ABI decoding error or an overflow.
        for (uint8 d = 1; d < 8; ++d) {
            f.set(d, I192_MAX + 1, I192_MAX, 0);
            (bool ok, bytes memory ret) = _set();
            assertFalse(ok);
            assertEq(ret, _invalid("minAnswer"));
            f.set(d, type(uint256).max / 10 ** (8 - d) + 1, I192_MAX, 0);
            (ok, ret) = _set();
            assertFalse(ok);
            assertEq(ret, _invalid("minAnswer"));
            // The largest minimum in range is pinned: 2^191 - 1 times 10^(8-d) does not overflow.
            f.set(d, I192_MAX - 1, I192_MAX, 0);
            (ok,) = _set();
            assertTrue(ok, "largest int192 minimum refused");
            assertEq(store.getFeed(address(f)).minAnswer, int256(I192_MAX - 1));
        }
    }

    // TEST-250 verifies: REQ-CONFIG-022, REQ-ORACLE-049
    function test_TEST_250_maximumAboveTheInt192RangeRefusedByName() public {
        f.set(8, 1e6, I192_MAX + 1, 0);
        (bool ok, bytes memory ret) = _set();
        assertFalse(ok);
        assertEq(ret, _invalid("maxAnswer"));
        // A negative int192, sign-extended to a word above the range.
        f.set(8, 1e6, uint256(int256(-1)), 0);
        (ok, ret) = _set();
        assertFalse(ok);
        assertEq(ret, _invalid("maxAnswer"));
        // At the bound: pinned (no cap below it).
        f.set(8, 1e6, I192_MAX, 0);
        (ok,) = _set();
        assertTrue(ok);
        assertEq(store.getFeed(address(f)).maxAnswer, int256(I192_MAX));
    }

    // TEST-250 verifies: REQ-CONFIG-022
    function test_TEST_250_negativeMinimumWordRefusedByName() public {
        f.set(8, uint256(int256(-1)), 1e12, 0);
        (bool ok, bytes memory ret) = _set();
        assertFalse(ok);
        assertEq(ret, _invalid("minAnswer"));
    }

    // TEST-250 verifies: REQ-CONFIG-022
    function test_TEST_250_failedOrShortMinimumReadRefusedByName() public {
        f.set(8, 1e6, 1e12, 1);
        (bool ok, bytes memory ret) = _set();
        assertFalse(ok);
        assertEq(ret, _invalid("minAnswer"));
        f.set(8, 1e6, 1e12, 2);
        (ok, ret) = _set();
        assertFalse(ok);
        assertEq(ret, _invalid("minAnswer"));
        // A longer answer is read by its first word, as Solidity's own decoding reads it.
        f.set(8, 1e6, 1e12, 3);
        (ok,) = _set();
        assertTrue(ok);
        assertEq(store.getFeed(address(f)).minAnswer, 1e6);
    }
}
