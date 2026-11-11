// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";

/// @notice Stands in for the Spoke's `getUserAccountData`: it spends every unit of gas it is given.
contract GasBurningAccountRead {
    function getUserAccountData(
        address
    ) external view returns (uint256 burned) {
        while (gasleft() > 0) {
            ++burned;
        }
    }
}

/// @title CollateralizationDebtMarkUnitTest
/// @notice `markDebtFree` failure modes: a reverting read, a short return, a read that runs out of gas with a starved
/// caller and with a generous one; and the refresh path the AaveAdapter's `refreshDebtMark(proxy)` takes to clear a
/// mark a failing read left set, so `getMarketDebtFree` (what `closeMarket` reads) becomes true.
/// forge-config: default.isolate = false
contract CollateralizationDebtMarkUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));

    function setUp() public {
        _deployCollateralization();
        _pledge(alice, aliceProxy, KEY42, 5_000_000_000);
        vm.startPrank(adapter);
        lock.acquire();
        coll.markIndebted(aliceProxy);
        lock.release();
        vm.stopPrank();
    }

    // TEST-272 verifies: REQ-COLL-040
    // Sources: 2.3 REQ-COLL-040 (a failing read with at least 50,000 gas left changes nothing)
    /// @notice A reverting read and a read that returns fewer than seven words leave the mark and do not revert.
    function test_TEST_272_failingReadKeepsMark() public {
        bytes memory read = abi.encodeCall(IAaveV4Spoke.getUserAccountData, (aliceProxy));
        vm.mockCallRevert(aave.cdpSpoke, read, abi.encode("down"));
        _markDebtFree(adapter);
        assertFalse(coll.getMarketDebtFree(vt), "reverting read keeps the mark");
        vm.clearMockedCalls();
        vm.mockCall(aave.cdpSpoke, read, abi.encode(uint256(0), uint256(0), uint256(0)));
        _markDebtFree(lpVaultSwap);
        assertFalse(coll.getMarketDebtFree(vt), "short read keeps the mark");
        vm.clearMockedCalls();
    }

    // TEST-272 verifies: REQ-COLL-040
    // Sources: 2.3 REQ-COLL-040 (DEBT_MARK_GAS_FLOOR = 50,000; a starved read reverts InsufficientGas)
    /// @notice A read that runs out of gas with 1,000,000 gas given to the call leaves under 50,000 gas, so the call
    /// reverts `InsufficientGas` instead of keeping the mark; with 5,000,000 gas the read had more than 3,150,000 and the
    /// failure is the read's own, so the call returns and keeps the mark.
    function test_TEST_272_starvedReadReverts() public {
        GasBurningAccountRead burner = new GasBurningAccountRead();
        vm.mockFunction(aave.cdpSpoke, address(burner), abi.encodeCall(IAaveV4Spoke.getUserAccountData, (aliceProxy)));
        vm.prank(adapter);
        lock.acquire();
        vm.prank(adapter);
        vm.expectPartialRevert(ICollateralizationErrors.InsufficientGas.selector);
        coll.markDebtFree{gas: 1_000_000}(aliceProxy);
        vm.prank(adapter);
        coll.markDebtFree{gas: 5_000_000}(aliceProxy);
        vm.prank(adapter);
        lock.release();
        assertFalse(coll.getMarketDebtFree(vt), "the mark stays");
    }

    // TEST-272 verifies: REQ-COLL-040, Q-355
    // Sources: 2.3 REQ-COLL-040 example (an Offboarding market's last marked account)
    /// @notice The liquidation that repaid the account's last debt ran `markDebtFree` while the Spoke read reverted,
    /// so the market count stays 1; once the read works, the AaveAdapter's `refreshDebtMark` (Lock, `markDebtFree`,
    /// release) clears it and the market is debt-free. An account still in debt keeps its mark.
    function test_TEST_272_refreshClearsStaleMark() public {
        _borrow(aliceProxy, 1000e18);
        _markDebtFree(adapter);
        assertFalse(coll.getMarketDebtFree(vt), "indebted account keeps its mark");
        debt.mint(aliceProxy, 1000e18);
        vm.startPrank(aliceProxy);
        debt.approve(aave.cdpSpoke, type(uint256).max);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, type(uint256).max, aliceProxy);
        vm.stopPrank();
        vm.mockCallRevert(
            aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.getUserAccountData, (aliceProxy)), abi.encode("down")
        );
        _markDebtFree(lpVaultSwap);
        assertFalse(coll.getMarketDebtFree(vt), "stale mark after the failed read");
        vm.clearMockedCalls();
        // refreshDebtMark(aliceProxy): the Adapter takes the Lock for any caller and calls markDebtFree.
        _markDebtFree(adapter);
        assertTrue(coll.getMarketDebtFree(vt), "refresh clears the stale mark");
        _markDebtFree(adapter);
        assertTrue(coll.getMarketDebtFree(vt), "a second refresh changes nothing");
    }

    /// @dev One Lock session of `member` that calls `markDebtFree(aliceProxy)`.
    function _markDebtFree(
        address member
    ) internal {
        vm.startPrank(member);
        lock.acquire();
        coll.markDebtFree(aliceProxy);
        lock.release();
        vm.stopPrank();
    }
}
