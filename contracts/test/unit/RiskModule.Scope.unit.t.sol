// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../src/oracle/lp-oracle/ILPOracle.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {RiskModule} from "../../src/policy/risk-module/RiskModule.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @title RiskModuleScopeUnitTest
/// @notice What the RiskModule does not do: it keeps the `checkPledge` interface the immutable Collateralization calls
/// across upgrades (REQ-RISK-001), it stores no exposure counter (REQ-RISK-004), it leaves the `drawCap`, a debt
/// reserve's freeze and any daily limit to Aave (REQ-ADAPTER-023), and it evaluates no price-drop breaker
/// (SPEC-BRK-001).
/// forge-config: default.isolate = false
contract RiskModuleScopeUnitTest is RiskModuleFixture {
    /// @dev $20,000 at $2.00 per whole vault token.
    uint128 internal constant UNITS = 10_000e18;

    function setUp() public {
        _deployRiskWorld();
        _debt(1.5e18, 1000);
    }

    function _checkPledgeCall(
        PledgeCounters memory k
    ) internal view returns (bytes memory) {
        return abi.encodeCall(
            IRiskModuleChecks.checkPledge, (wallet, address(proxy), mid, V3, bytes32(uint256(1)), UNITS, k, false)
        );
    }

    // TEST-062 verifies: REQ-RISK-001, Q-224, Q-226
    // Sources: 2.7 REQ-RISK-001 (selector, arguments, PledgeCounters and PledgeCharge layouts, return = yes, revert = no)
    /// @notice The `checkPledge` selector is the one of its canonical signature, the answer is the four-word
    /// `PledgeCharge`, and after an upgrade through the timelock the same proxy address gives the same answer to the
    /// same call, and the same revert to a refused one.
    /// @dev Kills: any change to the `checkPledge` argument list, the `PledgeCounters` fields or the `PledgeCharge`
    /// fields (the pinned signature and the 128-byte answer), and an upgrade path that moves the RiskModule's address.
    function test_TEST_062_checkPledgeInterfaceStableAcrossUpgrades() public {
        assertEq(
            IRiskModuleChecks.checkPledge.selector,
            bytes4(
                keccak256(
                    "checkPledge(address,address,uint256,uint32,bytes32,uint128,"
                    "(address,uint128,uint128,uint256,bytes32,uint256,uint256,uint256[]),bool)"
                )
            ),
            "checkPledge selector"
        );
        PledgeCounters memory k = _counters();
        bytes memory call = _checkPledgeCall(k);
        k.regularUsed = 990_000e8;
        bytes memory refused = _checkPledgeCall(k);
        address at = address(riskModule);
        (bool ok, bytes memory answer) = at.staticcall(call);
        assertTrue(ok, "an eligible pledge returns");
        assertEq(answer.length, 128, "PledgeCharge is four words");
        PledgeCharge memory c = abi.decode(answer, (PledgeCharge));
        assertEq(c.usdCharge, 20_000e8, "charge");
        (bool refusedOk, bytes memory refusal) = at.staticcall(refused);
        assertFalse(refusedOk, "a refusal reverts");
        assertEq(refusal, abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("MARKET")));

        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 implBefore = vm.load(at, implSlot);
        RiskModule next = new RiskModule(rmIm, rmLogics);
        vm.prank(address(timelock));
        riskModule.upgradeToAndCall(address(next), "");
        assertEq(vm.load(at, implSlot), bytes32(uint256(uint160(address(next)))), "new implementation");
        assertTrue(vm.load(at, implSlot) != implBefore);
        (bool ok2, bytes memory answer2) = at.staticcall(call);
        assertTrue(ok2);
        assertEq(answer2, answer, "same answer at the same address");
        (bool refusedOk2, bytes memory refusal2) = at.staticcall(refused);
        assertFalse(refusedOk2);
        assertEq(refusal2, refusal, "same refusal at the same address");
    }

    // TEST-012 verifies: REQ-RISK-004, REQ-RISK-007, Q-158, Q-224
    // Sources: 2.7 REQ-RISK-004 (Collateralization keeps the counters and passes them as PledgeCounters)
    /// @notice `checkPledge` writes no storage anywhere, so it keeps no counter: the same pledge passes or fails only by
    /// the counters its caller passes, and a passing call leaves every counter it was given for the caller to update.
    /// @dev Kills: a storage write added to the pledge path (an exposure counter kept in the RiskModule), and a pledge
    /// check that reads its own record of usage instead of the `PledgeCounters` argument.
    function test_TEST_012_checkPledgeWritesNoCounter() public {
        PledgeCounters memory k = _counters();
        k.regularUsed = 900_000e8;
        bytes memory call = _checkPledgeCall(k);
        vm.startStateDiffRecording();
        (bool ok,) = address(riskModule).call(call);
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertTrue(ok, "room for $20,000 above $900,000");
        for (uint256 i = 0; i < accesses.length; ++i) {
            for (uint256 j = 0; j < accesses[i].storageAccesses.length; ++j) {
                assertFalse(accesses[i].storageAccesses[j].isWrite, "checkPledge writes storage");
            }
        }
        // The same pledge twice: still room, because nothing was booked.
        PledgeCharge memory again = _pledge(UNITS, k, false);
        assertEq(again.usdCharge, 20_000e8);
        // Only the counters passed decide the market cap.
        k.regularUsed = 980_000e8;
        assertEq(_pledge(UNITS, k, false).usdCharge, 20_000e8, "exactly at the cap");
        k.regularUsed = 980_000e8 + 1;
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.CapExceeded.selector, bytes32("MARKET")));
        _pledge(UNITS, k, false);
    }

    // TEST-028 verifies: REQ-ADAPTER-023, REQ-RISK-077, Q-118, Q-197, Q-314
    // Sources: 2.7 REQ-ADAPTER-023 (Aave enforces the drawCap and the freeze inside Spoke.borrow; no daily limit)
    /// @notice `preBorrowCheck` of a same-Hub reserve passes whatever the reserve's `drawCap` and drawn amount, with the
    /// debt reserve frozen on the Spoke, and for any number of borrows of any size in one block: those limits are
    /// Aave's, checked inside `Spoke.borrow`.
    /// @dev Kills: a `drawCap`, drawn-amount, debt-reserve freeze or cumulative-amount check added to the borrow gate.
    function test_TEST_028_drawCapFreezeAndDailyLimitAreAaves() public {
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        // The GHO draw cap at 1 whole token, with far more drawn.
        hub.setSpokeConfig(GHO_ASSET, address(spoke), 0, 1);
        rHub.setDrawn(GHO_ASSET, 1e40);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1e30);
        // The GHO reserve frozen on the Spoke (still borrowable).
        rSpoke.setConfig(GHO_RESERVE, IAaveV4Spoke.ReserveConfig(0, false, true, true, false));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1e30);
        // No daily limit: repeated large borrows in one block.
        for (uint256 i = 0; i < 5; ++i) {
            riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1e36);
        }
        riskModule.preWithdrawCheck(address(proxy));
    }

    // TEST-228 verifies: SPEC-BRK-001, Q-241, Q-399
    // Sources: 2.7 SPEC-BRK-001 (monitoring alert only; PRICE_DROP never set)
    /// @notice A drop of 4 % from the stored checkpoint within the hour trips nothing: the borrow and withdraw gates
    /// pass, `pokeBreakers` reports the same reasons as before the drop and latches nothing, and no RiskModule path
    /// reads the LPOracle's price checkpoint at all.
    /// @dev Kills: a price-drop breaker evaluated by the RiskModule (a `priceCheckpoint` read or a trip on the drop).
    function test_TEST_228_priceDropTripsNoBreaker() public {
        vm.expectCall(address(oracle), abi.encodeWithSelector(ILPOracle.priceCheckpoint.selector), 0);
        uint32 before = riskModule.pokeBreakers(mid);
        (uint32 latchedBefore,) = registry.marketBreaker(mid);
        vm.warp(block.timestamp + 40 minutes);
        // Accepted at the checkpoint $2.00, served now $1.92.
        oracle.setPrices(2e8, 1.92e8);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        riskModule.preWithdrawCheck(address(proxy));
        assertEq(riskModule.pokeBreakers(mid), before, "same reasons after the drop");
        (uint32 latched,) = registry.marketBreaker(mid);
        assertEq(latched, latchedBefore, "nothing latched");
        (uint32 status,) = riskModule.getBreakerStatus(mid);
        assertEq(status, before, "the status view agrees");
    }
}
