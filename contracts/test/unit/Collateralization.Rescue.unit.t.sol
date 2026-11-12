// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {CollateralizationFixture} from "../utils/fixtures/CollateralizationFixture.sol";

/// @title CollateralizationRescueUnitTest
/// @notice Rescue units and the slice bucket through a record's life (SPEC-BACK-004, SPEC-BACK-014, REQ-COLL-016): a
/// slice-funded pledge books rescue units in proportion to its slice share and a rescue pledge books all its units;
/// a seizure caps each debited record's rescue units at its remaining credit and lowers the account sum by exactly the
/// cap; a partial removal caps again; a rescue re-credit adds the units it credits; and the `requireRescue` flag and
/// the charge checks of a re-credit.
/// forge-config: default.isolate = false
contract CollateralizationRescueUnitTest is CollateralizationFixture {
    bytes32 internal constant K1 = bytes32(uint256(1));
    bytes32 internal constant K2 = bytes32(uint256(2));

    function setUp() public {
        _deployCollateralization();
    }

    function _rescue(
        uint256 id
    ) internal view returns (uint128) {
        return coll.getRecord(id).rescueUnits;
    }

    // TEST-236 verifies: REQ-COLL-016, SPEC-BACK-014, SPEC-BACK-004, SPEC-BACK-006, INV-082
    // Sources: 2.3 SPEC-BACK-014 (rescueUnits never above credited; capped by every debit), SPEC-BACK-004
    /// @notice K1 (1e9 units, $500 of its $2,000 charge in the slice) books `ceil(1e9 x 5e10 / 2e11) = 2.5e8` rescue
    /// units; K2 (2e9, a rescue pledge) books all 2e9. A seizure that empties K2 and takes part of K1 drops K2's rescue
    /// units to 0 and leaves K1's 2.5e8 while its credit stays above them; a partial removal down to 1e8 caps K1 at
    /// 1e8; the account sum follows each step exactly.
    function test_TEST_236_rescueUnitsThroughSeizureAndPartialRemoval() public {
        riskModule.setSlice(50_000_000_000);
        uint256 id1 = _pledge(alice, aliceProxy, K1, 1_000_000_000);
        riskModule.setSlice(0);
        riskModule.setRescue(true);
        uint256 id2 = _pledge(alice, aliceProxy, K2, 2_000_000_000);
        riskModule.setRescue(false);
        assertEq(_rescue(id1), 250_000_000, "slice share of the units");
        assertEq(_rescue(id2), 2_000_000_000, "a rescue pledge books every unit");
        assertEq(coll.getAccountRescueUnits(aliceProxy, vt), 2_250_000_000);
        PledgeCounters memory k = coll.getCounters(vt, alice);
        assertEq(k.sliceUsed, 50_000_000_000, "only K1 used the slice");
        assertEq(k.regularUsed, 150_000_000_000 + 400_000_000_000);

        _borrow(aliceProxy, 4500e18);
        vtPrice.set(1.5e8);
        (uint256 seized,) = _liquidate(aliceProxy, 3000e18);
        assertGt(seized, 2_000_000_000, "the seizure empties K2");
        assertLt(seized, 2_750_000_000, "and leaves K1 above its rescue units");
        assertEq(_rescue(id2), 0, "capped at K2's credit of 0");
        assertEq(_rescue(id1), 250_000_000, "K1's credit still covers its rescue units");
        assertEq(coll.getAccountRescueUnits(aliceProxy, vt), 250_000_000);

        vtPrice.set(2e8);
        debt.mint(aliceProxy, 1_000_000e18);
        vm.startPrank(aliceProxy);
        debt.approve(aave.cdpSpoke, type(uint256).max);
        IAaveV4Spoke(aave.cdpSpoke).repay(debtReserveId, type(uint256).max, aliceProxy);
        vm.stopPrank();
        uint128 credited = coll.getRecord(id1).credited;
        uint128 remove = credited - 100_000_000;
        vm.prank(adapter);
        lock.acquire();
        _withdrawAndBurn(aliceProxy, remove);
        vm.prank(adapter);
        coll.releasePartial(aliceProxy, vt, K1, remove, new uint256[](2));
        vm.prank(adapter);
        lock.release();
        assertEq(_rescue(id1), 100_000_000, "capped at the 1e8 left");
        assertEq(coll.getAccountRescueUnits(aliceProxy, vt), 100_000_000);
        assertEq(coll.getCounters(vt, alice).sliceUsed, 0, "exits release the slice first");
    }

    // TEST-238 verifies: REQ-COLL-015, REQ-COLL-016, SPEC-BACK-013, SPEC-BACK-014, REQ-VAULT-015
    // Sources: 2.3 REQ-COLL-015 (a re-credit books its charge's rescue units), REQ-VAULT-015 (rescueUnits == units when
    // rescue)
    /// @notice A rescue re-credit of 500,000,000 added units books exactly those as rescue units on the record and the
    /// account; a re-credit whose rescue charge names fewer units than it credits, or more, reverts `InvalidCharge` and
    /// changes nothing; `requireRescue` reaches `checkPledge` unchanged.
    function test_TEST_238_rescueRecreditAndItsChargeChecks() public {
        uint256 id = _pledge(alice, aliceProxy, K1, 1_000_000_000);
        lpVault.addUnits(K1, 500_000_000);
        vm.startPrank(adapter);
        lock.acquire();
        riskModule.setOverride(
            PledgeCharge({usdCharge: 100_000_000_000, sliceUsd: 0, rescue: true, rescueUnits: 499_999_999})
        );
        vm.expectRevert(ICollateralizationErrors.InvalidCharge.selector);
        coll.recredit(alice, aliceProxy, vt, K1, "", true);
        riskModule.setOverride(
            PledgeCharge({usdCharge: 100_000_000_000, sliceUsd: 0, rescue: false, rescueUnits: 500_000_001})
        );
        vm.expectRevert(ICollateralizationErrors.InvalidCharge.selector);
        coll.recredit(alice, aliceProxy, vt, K1, "", false);
        riskModule.clearOverride();
        riskModule.setRescue(true);
        vm.expectCall(
            address(riskModule),
            // The head of checkPledge's calldata up to `requireRescue`: the counters struct is dynamic, so its slot holds
            // the offset 8 x 32 = 256 and `requireRescue` follows it.
            abi.encodeWithSelector(
                IRiskModuleChecks.checkPledge.selector,
                alice,
                aliceProxy,
                MARKET_ID,
                INTEGRATION,
                K1,
                uint128(500_000_000),
                uint256(256),
                true
            )
        );
        (uint128 added, uint128 rescueUnits) = coll.recredit(alice, aliceProxy, vt, K1, "", true);
        token.mint(aliceProxy, added);
        vm.stopPrank();
        _supply(aliceProxy, added);
        vm.prank(adapter);
        lock.release();
        assertEq(added, 500_000_000);
        assertEq(rescueUnits, 500_000_000);
        assertEq(_rescue(id), 500_000_000, "booked on the record");
        assertEq(coll.getAccountRescueUnits(aliceProxy, vt), 500_000_000);
        assertEq(coll.getRecord(id).credited, 1_500_000_000);
        assertEq(_gap(), 0);
    }
}
