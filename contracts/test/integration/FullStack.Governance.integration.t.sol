// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {FullStackMarkets} from "../utils/fixtures/FullStackMarkets.sol";
import {HostileAdapter} from "../utils/mocks/HostileAdapter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title FullStackGovernanceIntegrationTest
/// @notice The exit window of a hostile AaveAdapter upgrade on the full real stack (`FullStackMarkets`): the upgrade is
/// an operation of the real AvanaTimelock at the normal delay, the pause is the real MarketRegistry's, and the exits
/// run through the real AaveAdapter, Collateralization, RiskModule and Aave V4 Spoke.
/// @dev The borrower holds 3,000 GHO and 2,000 USDC of debt and two pledged positions in market A and a third in
/// market B; `HostileAdapter` is the hostile implementation a test installs on purpose.
/// forge-config: default.isolate = false
contract FullStackGovernanceIntegrationTest is FullStackMarkets {
    uint256 internal mA;
    uint256 internal mB;
    bytes32[3] internal keys;
    address internal pA;
    address internal pB;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        mB = _addMarket(poolB);
        (keys[0], pA) = _pledgeAs(alice, mA, UNITS);
        (keys[1],) = _pledgeAs(alice, mA, UNITS);
        (keys[2], pB) = _pledgeAs(alice, mB, UNITS);
        _borrowAs(alice, mA, ghoReserveId, 3000e18);
        _borrowAs(alice, mA, usdcReserveId, 2000e6);
    }

    function _upgradeCall(
        address impl
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impl, ""));
    }

    /// @dev Repays both reserves (the Adapter approved for the exact amounts) and withdraws the three positions.
    function _exitEverything() internal {
        uint256[2] memory reserves = [ghoReserveId, usdcReserveId];
        for (uint256 i = 0; i < 2; ++i) {
            uint256 owed = _debtOf(pA, reserves[i]);
            _fund(alice, reserves[i], owed);
            vm.prank(alice);
            adapterC.repay(alice, mA, reserves[i], owed, true, _deadline());
            assertEq(_debtOf(pA, reserves[i]), 0, "reserve repaid");
        }
        uint256[3] memory ids = [mA, mA, mB];
        for (uint256 i = 0; i < 3; ++i) {
            uint128 units = coll.getRecord(coll.recordIdOf(V3, keys[i])).credited;
            vm.prank(alice);
            adapterC.withdraw(ids[i], _ref(keys[i]), units, _deadline(), 0);
            assertEq(lpVault.ownerOf(keys[i]), alice, "position back in the wallet");
        }
    }

    /// @notice The governance multisig schedules an AaveAdapter upgrade to a hostile implementation at the normal
    /// delay (5 days) and the Emergency Guardian pauses the Hub at once; while Paused and well inside the delay the
    /// borrower repays both debt reserves and withdraws all three positions (two repays, three withdrawals); a
    /// canceller then cancels the operation. In a second run the operation becomes ready and executes, and the
    /// borrower's accounts hold nothing for the hostile code to touch.
    // TEST-195 verifies: REQ-ADAPTER-060, REQ-ADAPTER-001, REQ-ADAPTER-003, REQ-ADAPTER-099, REQ-PROXY-086
    function test_TEST_195_exitInsideTheDelay() public {
        address hostile = address(new HostileAdapter());
        bytes memory call = _upgradeCall(hostile);
        assertEq(_requiredDelay(adapter, call), NORMAL_DELAY, "an Adapter upgrade takes the normal delay");
        uint256 scheduledAt = block.timestamp;
        vm.prank(governanceMultisig);
        timelock.schedule(adapter, 0, call, bytes32(0), bytes32("hostile"), NORMAL_DELAY);
        bytes32 id = timelock.hashOperation(adapter, 0, call, bytes32(0), bytes32("hostile"));
        _pause(PauseState.Paused, PauseReason.General);
        assertEq(uint8(registry.pauseState(aave.hub)), uint8(PauseState.Paused), "paused");
        uint256 snap = vm.snapshotState();
        vm.warp(block.timestamp + 1 hours);
        _refreshFeeds();
        _exitEverything();
        assertLt(block.timestamp, scheduledAt + NORMAL_DELAY, "every exit well inside the delay");
        vm.prank(emergencyGuardian);
        timelock.cancel(id);
        assertFalse(timelock.isOperation(id), "cancelled");
        vm.revertToState(snap);
        // Second run: the exits, then the operation becomes ready and executes.
        _exitEverything();
        vm.warp(scheduledAt + NORMAL_DELAY);
        vm.prank(attacker);
        timelock.execute(adapter, 0, call, bytes32(0), bytes32("hostile"));
        assertEq(
            address(
                uint160(uint256(vm.load(adapter, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)))
            ),
            hostile,
            "the hostile implementation is in force"
        );
        IAaveV4Spoke spoke = IAaveV4Spoke(aave.cdpSpoke);
        assertEq(spoke.getUserSuppliedShares(mkt[mA].reserveId, pA), 0, "nothing supplied in market A");
        assertEq(spoke.getUserSuppliedShares(mkt[mB].reserveId, pB), 0, "nothing supplied in market B");
        assertEq(_debtOf(pA, ghoReserveId) + _debtOf(pA, usdcReserveId), 0, "no debt");
        for (uint256 i = 0; i < 3; ++i) {
            assertEq(lpVault.ownerOf(keys[i]), alice, "every position with the wallet");
            assertEq(lpVault.depositorOf(keys[i]), address(0), "none in custody");
        }
    }
}
