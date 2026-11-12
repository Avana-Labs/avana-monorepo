// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";

/// @notice Stands in for the Spoke's `getUserAccountData`: it spends every unit of gas it is given.
contract DebtMarkGasBurner {
    function getUserAccountData(
        address
    ) external view returns (uint256 burned) {
        while (gasleft() > 0) {
            ++burned;
        }
    }
}

/// @title CollateralizationDebtMarkReadsUnitTest
/// @notice The indebted mark of REQ-COLL-039 and REQ-COLL-040 on the real local Aave V4: the Spoke read is made only
/// for a marked account, on the proxy's own market Spoke; the return-length boundary (224 bytes, seven words); the
/// borrow count read from the seventh word; the per-market count over several accounts and two markets; idempotent
/// marking and clearing; and the exact arguments of `InsufficientGas`.
/// forge-config: default.isolate = false
contract CollateralizationDebtMarkReadsUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));
    bytes32 internal constant KEY7 = bytes32(uint256(7));

    function setUp() public {
        _deployCollateralization();
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        _pledge(bob, bobProxy, KEY7, 4_000_000_000);
    }

    // TEST-272 verifies: REQ-COLL-040, REQ-VAULT-087
    // Sources: 2.3 REQ-COLL-040 (a marked account is read; an unmarked one is not)
    /// @notice An unmarked account, bound or never bound, makes no Spoke read and changes nothing.
    function test_TEST_272_noReadForAnUnmarkedAccount() public {
        vm.expectCall(aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.getUserAccountData, (aliceProxy)), 0);
        _markDebtFree(adapter, aliceProxy);
        _markDebtFree(lpVaultSwap, makeAddr("neverBound"));
        assertTrue(coll.getMarketDebtFree(vt), "nothing marked");
    }

    // TEST-272 verifies: REQ-COLL-040, REQ-VAULT-087
    /// @notice A marked account is read exactly once, with its own address, on the Spoke of its bound market.
    function test_TEST_272_readOnlyForAMarkedAccount() public {
        bytes memory read = abi.encodeCall(IAaveV4Spoke.getUserAccountData, (aliceProxy));
        _mark(aliceProxy);
        assertFalse(coll.getMarketDebtFree(vt));
        vm.expectCall(aave.cdpSpoke, read, 1);
        _markDebtFree(lpVaultSwap, aliceProxy);
        assertTrue(coll.getMarketDebtFree(vt), "no borrow: cleared");
    }

    // TEST-272 verifies: REQ-COLL-040
    // Sources: 2.3 REQ-COLL-040 (a short return changes nothing; seven words are read)
    /// @notice A return of 223 bytes keeps the mark; exactly 224 bytes with a zero borrow count clears it; a return
    /// longer than seven words is read from its first seven.
    function test_TEST_272_returnLengthBoundary() public {
        bytes memory read = abi.encodeCall(IAaveV4Spoke.getUserAccountData, (aliceProxy));
        _mark(aliceProxy);
        vm.mockCall(aave.cdpSpoke, read, _bytes(223));
        _markDebtFree(adapter, aliceProxy);
        assertFalse(coll.getMarketDebtFree(vt), "223 bytes: mark kept");
        vm.mockCall(aave.cdpSpoke, read, _bytes(224));
        _markDebtFree(adapter, aliceProxy);
        assertTrue(coll.getMarketDebtFree(vt), "224 bytes, borrow count 0: cleared");

        _mark(aliceProxy);
        bytes memory long = abi.encode(uint256(1), uint256(2), uint256(3), uint256(4), uint256(5), uint256(6), 0, 9);
        vm.mockCall(aave.cdpSpoke, read, long);
        _markDebtFree(adapter, aliceProxy);
        assertTrue(coll.getMarketDebtFree(vt), "eight words: the seventh is the borrow count");
        vm.clearMockedCalls();
    }

    // TEST-272 verifies: REQ-COLL-040
    // Sources: 2.3 REQ-COLL-040 (cleared only when borrowCount is 0)
    /// @notice A borrow count of 1 or `type(uint256).max` in the seventh word keeps the mark, whatever the other words;
    /// non-zero words before it with a zero count clear it.
    function test_TEST_272_borrowCountDecidesTheMark() public {
        bytes memory read = abi.encodeCall(IAaveV4Spoke.getUserAccountData, (aliceProxy));
        _mark(aliceProxy);
        uint256 max = type(uint256).max;
        vm.mockCall(aave.cdpSpoke, read, abi.encode(0, 0, 0, 0, 0, 0, uint256(1)));
        _markDebtFree(adapter, aliceProxy);
        assertFalse(coll.getMarketDebtFree(vt), "one borrow");
        vm.mockCall(aave.cdpSpoke, read, abi.encode(0, 0, 0, 0, 0, 0, max));
        _markDebtFree(adapter, aliceProxy);
        assertFalse(coll.getMarketDebtFree(vt), "a maximal count");
        vm.mockCall(aave.cdpSpoke, read, abi.encode(max, max, max, max, max, max, uint256(0)));
        _markDebtFree(adapter, aliceProxy);
        assertTrue(coll.getMarketDebtFree(vt), "other words do not matter");
        vm.clearMockedCalls();
    }

    // TEST-272 verifies: REQ-COLL-038, REQ-COLL-039, REQ-COLL-040, REQ-CONFIG-080, Q-355
    // Sources: 2.3 REQ-COLL-039 (indebtedCount per market), REQ-COLL-040
    /// @notice Marking is once per account (a second mark is a no-op), the market stays indebted while any account is
    /// marked, clearing an account twice decrements once, and marking an account again after a clear counts it again.
    function test_TEST_272_countOverSeveralAccounts() public {
        _mark(aliceProxy);
        _mark(aliceProxy);
        _mark(bobProxy);
        _borrow(bobProxy, 100e18);
        _markDebtFree(adapter, aliceProxy);
        assertFalse(coll.getMarketDebtFree(vt), "bob still marked");
        _markDebtFree(adapter, aliceProxy);
        _markDebtFree(adapter, bobProxy);
        assertFalse(coll.getMarketDebtFree(vt), "bob has a borrow");
        _repay(bobProxy);
        _markDebtFree(lpVaultSwap, bobProxy);
        assertTrue(coll.getMarketDebtFree(vt), "both cleared, alice's double mark counted once");
        _markDebtFree(lpVaultSwap, bobProxy);
        assertTrue(coll.getMarketDebtFree(vt), "a second clear does not underflow the count");
        _mark(aliceProxy);
        assertFalse(coll.getMarketDebtFree(vt), "a new mark counts again");
        _markDebtFree(adapter, aliceProxy);
        assertTrue(coll.getMarketDebtFree(vt));
    }

    // TEST-272 verifies: REQ-COLL-039, REQ-COLL-031, REQ-CONFIG-080
    // Sources: 2.3 REQ-COLL-039 (the mark counts in the proxy's bound market)
    /// @notice Two markets keep separate counts: bob's mark in a second market leaves the first debt-free; a proxy whose
    /// every record has closed stays bound to its market and can still be marked there.
    function test_TEST_272_countsArePerMarket() public {
        address second = _secondMarketToken();
        address carolProxy = makeAddr("carolProxy");
        address carol = makeAddr("carol");
        lpVault.mintPosition(bytes32(uint256(9)), carol, MARKET_ID + 1, 1_000_000);
        vm.startPrank(adapter);
        lock.acquire();
        _addValidProxy(second, carolProxy);
        coll.pledge(carol, carolProxy, second, bytes32(uint256(9)), false);
        coll.markIndebted(carolProxy);
        lock.release();
        vm.stopPrank();
        assertTrue(coll.getMarketDebtFree(vt), "first market unaffected");
        assertFalse(coll.getMarketDebtFree(second), "second market indebted");

        _withdraw(aliceProxy, KEY42, 5_000_000_000);
        assertEq(coll.getOpenRecordCount(aliceProxy, vt), 0, "every record closed");
        _mark(aliceProxy);
        assertFalse(coll.getMarketDebtFree(vt), "a proxy keeps its market binding after its records close");
        _markDebtFree(adapter, aliceProxy);
        assertTrue(coll.getMarketDebtFree(vt));
        assertFalse(coll.getMarketDebtFree(second), "the other market keeps its count");
    }

    // TEST-272 verifies: REQ-COLL-040
    // Sources: 2.3 REQ-COLL-040 (DEBT_MARK_GAS_FLOOR = 50,000)
    /// @notice A read starved of gas reverts `InsufficientGas(gasLeft, 50,000)` with `gasLeft` below the floor and the
    /// mark and count unchanged.
    function test_TEST_272_insufficientGasArguments() public {
        _mark(aliceProxy);
        DebtMarkGasBurner burner = new DebtMarkGasBurner();
        vm.mockFunction(aave.cdpSpoke, address(burner), abi.encodeCall(IAaveV4Spoke.getUserAccountData, (aliceProxy)));
        vm.prank(adapter);
        lock.acquire();
        vm.prank(adapter);
        (bool ok, bytes memory ret) = address(coll).call{gas: 800_000}(abi.encodeCall(coll.markDebtFree, (aliceProxy)));
        assertFalse(ok, "starved read");
        assertEq(bytes4(ret), ICollateralizationErrors.InsufficientGas.selector);
        (uint256 left, uint256 required) = abi.decode(_tail(ret), (uint256, uint256));
        assertEq(required, 50_000, "DEBT_MARK_GAS_FLOOR");
        assertLt(left, 50_000, "the gas left is below the floor");
        vm.prank(adapter);
        lock.release();
        assertFalse(coll.getMarketDebtFree(vt), "mark unchanged");
    }

    // ─── Helpers ───

    function _mark(
        address proxy
    ) internal {
        vm.startPrank(adapter);
        lock.acquire();
        coll.markIndebted(proxy);
        lock.release();
        vm.stopPrank();
    }

    function _markDebtFree(
        address member,
        address proxy
    ) internal {
        vm.startPrank(member);
        lock.acquire();
        coll.markDebtFree(proxy);
        lock.release();
        vm.stopPrank();
    }

    function _repay(
        address proxy
    ) internal {
        debt.mint(proxy, 1_000_000e18);
        vm.startPrank(proxy);
        debt.approve(aave.cdpSpoke, type(uint256).max);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, type(uint256).max, proxy);
        vm.stopPrank();
    }

    /// @dev `n` bytes, all zero: seven zero words when `n >= 224`.
    function _bytes(
        uint256 n
    ) internal pure returns (bytes memory b) {
        b = new bytes(n);
    }

    function _tail(
        bytes memory ret
    ) internal pure returns (bytes memory t) {
        t = new bytes(ret.length - 4);
        for (uint256 i = 0; i < t.length; ++i) {
            t[i] = ret[i + 4];
        }
    }

    function _addValidProxy(
        address vaultToken,
        address proxy
    ) internal {
        IValidProxyAdmin(vaultToken).addValidProxy(proxy);
    }

    /// @notice A second market of the same pool (another range) on the same Spoke and Hub.
    function _secondMarketToken() internal returns (address second) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(usdt);
        uint256[] memory rates = new uint256[](2);
        rates[0] = 800_000;
        rates[1] = 1_250_000;
        lpVault.bind(MARKET_ID + 1, pool, tokens, rates);
        vm.prank(timelock);
        second = factory.deployVaultToken(
            INTEGRATION,
            pool,
            bytes32(0),
            PositionShape(ShapeKind.TickRange, -100, 100),
            aave.hub,
            aave.cdpSpoke,
            MARKET_ID + 1,
            address(oracle),
            VT_DECIMALS,
            "Avana USDC/USDT wide",
            "avUSDC-USDT-w"
        );
    }
}

interface IValidProxyAdmin {
    function addValidProxy(
        address proxy
    ) external;
}
