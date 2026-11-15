// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationAdapter} from "../../src/custody/collateralization/ICollateralizationAdapter.sol";
import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";

/// @title CollateralizationSpeedCreditUnitTest
/// @notice The pledge-speed credit of an exit (REQ-RISK-093): a withdrawal, a partial removal and a deleverage release
/// give the booked value they released back to the market's pledge window through the RiskModule's `creditWithdraw`;
/// a failing or gas-hungry credit never stops the exit (REQ-RISK-005), and no gas limit lets an exit succeed without it.
/// @dev The RiskModule is `CollRiskModuleMock`, which records the credits. NFT 42 holds 5,000,000,000 units charged
/// $10,000 (1,000,000,000,000 in 8-decimal USD).
/// forge-config: default.isolate = false
contract CollateralizationSpeedCreditUnitTest is CollateralizationFixture {
    bytes32 internal constant KEY42 = bytes32(uint256(42));
    bytes32 internal constant KEY43 = bytes32(uint256(43));
    uint128 internal constant UNITS = 5_000_000_000;

    function setUp() public {
        _deployCollateralization();
        _pledge(alice, aliceProxy, KEY42, UNITS);
    }

    function _withdrawUnits(
        uint256 units
    ) internal {
        vm.prank(adapter);
        lock.acquire();
        _withdrawAndBurn(aliceProxy, units);
    }

    // TEST-018 verifies: REQ-RISK-093, REQ-VAULT-068
    function test_TEST_018_withdrawalCreditsThePledgeWindow() public {
        _withdrawUnits(UNITS);
        vm.prank(adapter);
        coll.release(aliceProxy, vt, KEY42, UNITS);
        assertEq(riskModule.withdrawCredits(), 1);
        assertEq(riskModule.creditedUsd(), 1_000_000_000_000, "the whole booked charge");
        assertEq(riskModule.lastCreditMarket(), MARKET_ID);
    }

    // TEST-237 verifies: REQ-RISK-093, REQ-COLL-014
    function test_TEST_237_partialRemovalCreditsWhatItReleased() public {
        _withdrawUnits(1_000_000_000);
        vm.prank(adapter);
        coll.releasePartial(aliceProxy, vt, KEY42, 1_000_000_000, new uint256[](2));
        assertEq(riskModule.creditedUsd(), 200_000_000_000, "$2,000 of the $10,000");
    }

    // TEST-239 verifies: REQ-RISK-093, REQ-COLL-017
    function test_TEST_239_deleverageReleaseCreditsWhatItReleased() public {
        _withdrawUnits(UNITS);
        vm.prank(adapter);
        coll.releaseForDeleverage(aliceProxy, vt, KEY42, UNITS, new uint256[](2));
        assertEq(riskModule.creditedUsd(), 1_000_000_000_000);
    }

    /// @notice Audit finding L-02 (fresh audit 2026-11-15): a rescue top-up is never charged to the pledge window
    /// (REQ-RISK-093), so withdrawing it must credit nothing back; otherwise uncharged rescues wash other users' charges
    /// out of the window.
    // TEST-018 verifies: REQ-RISK-093, REQ-RISK-095
    function test_TEST_018_rescueChargeIsNotCreditedBack() public {
        riskModule.setRescue(true);
        _pledge(alice, aliceProxy, KEY43, UNITS);
        riskModule.setRescue(false);
        _withdrawUnits(UNITS);
        vm.prank(adapter);
        coll.release(aliceProxy, vt, KEY43, UNITS);
        assertEq(riskModule.creditedUsd(), 0, "nothing was charged, nothing is credited");
        assertEq(riskModule.withdrawCredits(), 0);
    }

    /// @notice A record with $10,000 charged to the window and a $10,000 rescue re-credit gives back only the charged
    /// share of what it releases.
    // TEST-237 verifies: REQ-RISK-093, REQ-RISK-095, REQ-COLL-014
    function test_TEST_237_mixedRecordCreditsOnlyItsChargedShare() public {
        lpVault.addUnits(KEY42, UNITS);
        riskModule.setRescue(true);
        vm.startPrank(adapter);
        lock.acquire();
        (uint128 added,) = coll.recredit(alice, aliceProxy, vt, KEY42, "", false);
        token.mint(aliceProxy, added);
        vm.stopPrank();
        _supply(aliceProxy, added);
        vm.prank(adapter);
        lock.release();
        riskModule.setRescue(false);
        _withdrawUnits(UNITS);
        vm.prank(adapter);
        coll.releasePartial(aliceProxy, vt, KEY42, UNITS, new uint256[](2));
        assertEq(riskModule.creditedUsd(), 500_000_000_000, "half of the $10,000 released was charged");
        vm.prank(adapter);
        lock.release();
        _withdrawUnits(UNITS);
        vm.prank(adapter);
        coll.release(aliceProxy, vt, KEY42, UNITS);
        assertEq(riskModule.creditedUsd(), 1_000_000_000_000, "in total exactly the $10,000 charged");
    }

    // TEST-018 verifies: REQ-RISK-005, REQ-RISK-093
    function test_TEST_018_aFailingCreditNeverStopsTheExit() public {
        riskModule.setCredit(true, false);
        _withdrawUnits(UNITS);
        vm.prank(adapter);
        coll.release(aliceProxy, vt, KEY42, UNITS);
        assertEq(lpVault.ownerOf(KEY42), alice, "withdrawn although the credit reverted");
        assertEq(riskModule.withdrawCredits(), 0);
    }

    // TEST-018 verifies: REQ-RISK-005, REQ-RISK-093
    function test_TEST_018_aGasHungryCreditIsBoundedByItsStipend() public {
        riskModule.setCredit(false, true);
        _withdrawUnits(UNITS);
        vm.prank(adapter);
        coll.release(aliceProxy, vt, KEY42, UNITS);
        assertEq(lpVault.ownerOf(KEY42), alice, "withdrawn after the stipend ran out");
    }

    // TEST-018 verifies: REQ-RISK-005, REQ-RISK-093
    /// @dev Over a range of gas limits a `release` either reverts or has made the credit: a caller cannot pick a limit
    /// that skips it. The low end reverts `InsufficientGas` at the floor.
    function test_TEST_018_noGasLimitSkipsTheCredit() public {
        _withdrawUnits(UNITS);
        bool sawFloor = false;
        bool sawSuccess = false;
        for (uint256 g = 100_000; g <= 700_000; g += 4000) {
            uint256 snap = vm.snapshotState();
            vm.prank(adapter);
            (bool ok, bytes memory data) = address(coll).call{gas: g}(
                abi.encodeCall(ICollateralizationAdapter.release, (aliceProxy, vt, KEY42, uint256(UNITS)))
            );
            if (ok) {
                sawSuccess = true;
                assertEq(riskModule.withdrawCredits(), 1, "a successful exit made the credit");
            } else if (data.length >= 4 && bytes4(data) == ICollateralizationErrors.InsufficientGas.selector) {
                sawFloor = true;
            }
            vm.revertToState(snap);
        }
        assertTrue(sawFloor, "some limit stopped at the floor");
        assertTrue(sawSuccess, "some limit succeeded");
    }
}
