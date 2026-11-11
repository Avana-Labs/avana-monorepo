// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtPriceView} from "../../src/oracle/debt-oracle/types/DebtPriceView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {DebtOracleFixture} from "../utils/fixtures/DebtOracleFixture.sol";

/// @title DebtOracleDecodingUnitTest
/// @notice The strict decoding of every configuration word the DebtOracle reads (REQ-ORACLE-092 (1): a word that does
/// not fit its ABI type is a failed read, and a failed configuration read fails the asset closed). Each read is
/// replaced by raw ABI words: the control answer decodes and keeps the asset Live; each single malformed word, each
/// wrong offset or count and each truncated or padded answer fails the asset (CONFIG_UNAVAILABLE, Cached at the
/// accepted price) or, for the second source, only withholds the borrow confirmation.
contract DebtOracleDecodingUnitTest is DebtOracleFixture {
    uint256 internal constant R_CONFIG = 1 << 2;
    uint256 internal constant R_SECOND_SOURCE = 1 << 19;

    function setUp() public {
        _deployDebtOracle();
        vm.warp(T0 + 10);
    }

    // ─── activePriceRoutes (MarketRegistry) ───

    function _routes(
        uint256[] memory w
    ) internal {
        vm.mockCall(address(reg), abi.encodeWithSignature("activePriceRoutes(address)", usdc), _pack(w));
    }

    /// @dev `[96, 160, slot, 1, pUsd, 2, aEth, ethUsd]`: a one-leg primary and a two-leg alternate.
    function _goodRoutes() internal view returns (uint256[] memory w) {
        w = new uint256[](8);
        (w[0], w[1], w[2], w[3], w[4]) = (96, 160, 0, 1, uint256(uint160(address(pUsd))));
        (w[5], w[6], w[7]) = (2, uint256(uint160(address(aEth))), uint256(uint160(address(ethUsd))));
    }

    // TEST-219 verifies: REQ-ORACLE-092, REQ-ORACLE-094, REQ-ORACLE-017, REQ-ORACLE-069
    // Sources: 2.10 REQ-ORACLE-092 (1) (a word that does not fit its ABI type is a failed read)
    /// @notice The control encoding of the routes in force keeps the asset Live; a wrong first offset, a slot above 2,
    /// a primary of 0 or 3 legs, a wrong second offset, an alternate of 0 or 3 legs, a feed word with bit 160 set, a
    /// trailing word and a non-word-aligned answer each fail the asset closed.
    function test_TEST_219_routeWordsDecodeStrictly() public {
        _routes(_goodRoutes());
        _assertLive("control");
        uint256[] memory w;
        w = _goodRoutes();
        w[0] = 64;
        _routes(w);
        _assertFailed("first offset");
        w = _goodRoutes();
        w[2] = 3;
        _routes(w);
        _assertFailed("slot above Alternate");
        w = _goodRoutes();
        w[3] = 0;
        _routes(w);
        _assertFailed("primary of 0 legs");
        w = _goodRoutes();
        w[3] = 3;
        _routes(w);
        _assertFailed("primary of 3 legs");
        w = _goodRoutes();
        w[1] = 192;
        _routes(w);
        _assertFailed("second offset");
        w = _goodRoutes();
        w[5] = 0;
        _routes(w);
        _assertFailed("alternate of 0 legs");
        w = _goodRoutes();
        w[5] = 3;
        _routes(w);
        _assertFailed("alternate of 3 legs");
        w = _goodRoutes();
        w[4] |= uint256(1) << 160;
        _routes(w);
        _assertFailed("dirty feed word");
        uint256[] memory longer = new uint256[](9);
        w = _goodRoutes();
        for (uint256 i = 0; i < 8; ++i) {
            longer[i] = w[i];
        }
        _routes(longer);
        _assertFailed("a trailing word");
        vm.mockCall(
            address(reg),
            abi.encodeWithSignature("activePriceRoutes(address)", usdc),
            bytes.concat(_pack(_goodRoutes()), hex"00")
        );
        _assertFailed("not word-aligned");
    }

    // TEST-219 verifies: REQ-ORACLE-092, REQ-ORACLE-094
    /// @notice The largest admitted answer, two legs on each route (nine words, 288 bytes), decodes; the replaced slot
    /// it reports (Alternate) raises the ON_STANDBY reason.
    function test_TEST_219_nineWordRouteAnswerDecodes() public {
        uint256[] memory w = new uint256[](9);
        (w[0], w[1], w[2], w[3]) = (96, 192, 2, 2);
        (w[4], w[5]) = (uint256(uint160(address(aEth))), uint256(uint160(address(ethUsd))));
        (w[6], w[7], w[8]) = (2, uint256(uint160(address(aEth))), uint256(uint160(address(ethUsd))));
        _routes(w);
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Live), "two two-leg routes");
        assertEq(uint8(v.replaced), uint8(RouteSlot.Alternate));
        assertEq(v.reasons & (1 << 16), 1 << 16, "ON_STANDBY");
        assertEq(v.primaryValue, 99_990_000);
    }

    // ─── getToken (MarketRegistry) ───

    // TEST-219 verifies: REQ-ORACLE-092, REQ-ORACLE-017, REQ-ORACLE-091
    // Sources: 2.10 REQ-ORACLE-091 (the asset must be listed)
    /// @notice `getToken` must answer the struct offset 32 and `listed = 1`: a listed word of 2, an offset of 64 or a
    /// single word fail the asset.
    function test_TEST_219_listedWordDecodesStrictly() public {
        bytes memory call = abi.encodeWithSignature("getToken(address)", usdc);
        vm.mockCall(address(reg), call, abi.encode(uint256(32), uint256(1)));
        _assertLive("control");
        vm.mockCall(address(reg), call, abi.encode(uint256(32), uint256(2)));
        _assertFailed("listed word 2");
        vm.mockCall(address(reg), call, abi.encode(uint256(64), uint256(1)));
        _assertFailed("offset 64");
        vm.mockCall(address(reg), call, abi.encode(uint256(32)));
        _assertFailed("one word");
    }

    // ─── getFeed (ParameterStore) ───

    function _feedWords() internal pure returns (uint256[] memory w) {
        w = new uint256[](11);
        (w[0], w[1], w[2], w[3], w[4], w[5]) = (8, 0, 1e12, 86_400, 1800, 88_200);
        (w[6], w[7], w[8], w[9], w[10]) = (25, 0, 88_200, 88_200, 0);
    }

    // TEST-219 verifies: REQ-ORACLE-092, REQ-ORACLE-049, REQ-ORACLE-017
    // Sources: 2.10 REQ-ORACLE-092 (1)
    /// @notice A feed record decodes only with decimals in `[1, 255]`, the four age words within `uint32` and the two
    /// basis-point words within `uint16`: each word one above its type, decimals 0, and a nine-word answer fail the
    /// asset; the control record and each word at its type's maximum decode.
    function test_TEST_219_feedRecordWordsDecodeStrictly() public {
        bytes memory call = abi.encodeWithSignature("getFeed(address)", address(pUsd));
        vm.mockCall(address(store), call, _pack(_feedWords()));
        _assertLive("control");
        uint256[9] memory idx = [uint256(0), 0, 3, 4, 5, 6, 7, 8, 9];
        uint256[9] memory bad = [uint256(0), 256, 1 << 32, 1 << 32, 1 << 32, 1 << 16, 1 << 16, 1 << 32, 1 << 32];
        for (uint256 k = 0; k < idx.length; ++k) {
            uint256[] memory w = _feedWords();
            w[idx[k]] = bad[k];
            vm.mockCall(address(store), call, _pack(w));
            _assertFailed("feed word out of its type");
        }
        uint256[] memory nine = new uint256[](9);
        uint256[] memory good = _feedWords();
        for (uint256 i = 0; i < 9; ++i) {
            nine[i] = good[i];
        }
        vm.mockCall(address(store), call, _pack(nine));
        _assertFailed("nine words");
        uint256[] memory edge = _feedWords();
        (edge[6], edge[7]) = (type(uint16).max, type(uint16).max);
        (edge[5], edge[8], edge[9]) = (type(uint32).max, type(uint32).max, type(uint32).max);
        vm.mockCall(address(store), call, _pack(edge));
        _assertLive("each word at its maximum");
    }

    // ─── secondSource (ParameterStore) ───

    function _secondWords() internal view returns (uint256[] memory w) {
        w = new uint256[](6);
        (w[0], w[1], w[2], w[3], w[4], w[5]) = (1, uint256(uint160(address(second))), 0, 88_200, 0, 100);
    }

    // TEST-276 verifies: REQ-ORACLE-100, REQ-ORACLE-092, SPEC-ORC-020
    // Sources: 2.10 REQ-ORACLE-100 (only a usable OracleNetwork source confirms; a failed read blocks borrowing only)
    /// @notice The control second-source record confirms; a kind other than OracleNetwork, a source word with bit 160
    /// set, a `maxAge` above `uint32`, a tolerance above `uint16` and a five-word answer each leave the asset Live with
    /// liquidation open and borrowing closed (SECOND_SOURCE reason).
    function test_TEST_276_secondSourceWordsDecodeStrictly() public {
        bytes memory call = abi.encodeWithSignature("secondSource(address)", usdc);
        vm.mockCall(address(store), call, _pack(_secondWords()));
        assertTrue(oracle.getPriceState().borrowAllowed, "control confirms");
        uint256[5] memory idx = [uint256(0), 0, 1, 3, 5];
        uint256[5] memory bad =
            [uint256(2), 0, uint256(uint160(address(second))) | (1 << 160), uint256(1) << 32, uint256(1) << 16];
        for (uint256 k = 0; k < idx.length; ++k) {
            uint256[] memory w = _secondWords();
            w[idx[k]] = bad[k];
            vm.mockCall(address(store), call, _pack(w));
            _assertUnconfirmed();
        }
        uint256[] memory five = new uint256[](5);
        uint256[] memory good = _secondWords();
        for (uint256 i = 0; i < 5; ++i) {
            five[i] = good[i];
        }
        vm.mockCall(address(store), call, _pack(five));
        _assertUnconfirmed();
    }

    // ─── Helpers ───

    function _pack(
        uint256[] memory w
    ) internal pure returns (bytes memory b) {
        for (uint256 i = 0; i < w.length; ++i) {
            b = bytes.concat(b, abi.encode(w[i]));
        }
    }

    function _assertLive(
        string memory what
    ) internal view {
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Live), what);
        assertEq(v.reasons & R_CONFIG, 0, what);
        assertEq(uint256(v.answer), 99_990_000, what);
    }

    function _assertFailed(
        string memory what
    ) internal view {
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Cached), what);
        assertEq(v.reasons & R_CONFIG, R_CONFIG, what);
        assertEq(uint256(v.answer), 99_990_000, what);
        assertEq(uint8(v.routeUsed), uint8(RouteSlot.None), what);
        assertTrue(v.liquidationPaused, what);
    }

    function _assertUnconfirmed() internal view {
        DebtPriceView memory v = oracle.getPriceState();
        assertEq(uint8(v.state), uint8(PriceState.Live));
        assertEq(v.reasons & R_SECOND_SOURCE, R_SECOND_SOURCE);
        assertFalse(v.borrowAllowed);
        assertFalse(v.liquidationPaused);
    }
}
