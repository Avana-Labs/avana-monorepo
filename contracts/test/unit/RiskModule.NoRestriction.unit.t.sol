// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @title RiskModuleNoRestrictionUnitTest
/// @notice The RiskModule holds no restriction of its own (the only pause state is the MarketRegistry's), and the
/// minimum pledge value is exact at its boundary, on the real MarketRegistry.
contract RiskModuleNoRestrictionUnitTest is RiskModuleFixture {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() public {
        _deployRiskWorld();
    }

    // TEST-168 verifies: REQ-RISK-035, REQ-RISK-037, Q-226, Q-227
    // Sources: 5.1 TEST-168 (pause location: the RiskModule holds no restriction storage or selector)
    /// @notice Neither the RiskModule proxy nor its implementation answers any pause, per-function pause, market
    /// freeze, pool-broken flag, keeper suspension, quarantine, incident clock or tolerance override selector; a
    /// freeze and a pause of the Hub, which live in the MarketRegistry, leave the RiskModule's borrow check unchanged.
    function test_TEST_168_noRestrictionSelectorOrState() public {
        string[14] memory absent = [
            "pause()",
            "unpause()",
            "paused()",
            "pauseFunction(bytes4)",
            "pauseMarket(uint256)",
            "freezeMarket(uint256)",
            "setPoolBroken(uint256,bool)",
            "isPoolBroken(uint256)",
            "suspendKeeper(address)",
            "quarantineRoute(uint256)",
            "startIncident(uint256)",
            "incidentStartedAt(uint256)",
            "setToleranceOverride(uint256,uint256)",
            "pauseState(address)"
        ];
        address impl = address(uint160(uint256(vm.load(address(riskModule), IMPLEMENTATION_SLOT))));
        assertTrue(impl.code.length > 0, "implementation read from the proxy");
        address[2] memory targets = [address(riskModule), impl];
        for (uint256 t = 0; t < 2; ++t) {
            for (uint256 i = 0; i < absent.length; ++i) {
                (bool ok,) = targets[t].call(abi.encodeWithSignature(absent[i], mid, true));
                assertFalse(ok, absent[i]);
            }
        }
        _debt(1.5e18, 1000);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.prank(emergencyGuardian);
        registry.freeze(address(hub));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
        vm.prank(emergencyGuardian);
        registry.pause(address(hub), PauseReason.General);
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 1);
    }

    // TEST-072 verifies: REQ-RISK-057, SPEC-CAP-001, REQ-RISK-013
    // Sources: 5.1 TEST-072 (a pledge exactly at minPledgeUsd and one base unit of liquidity below it)
    /// @notice At $2.00 per whole 18-decimal token and `minPledgeUsd = $10`, a pledge of exactly 5e18 units is worth
    /// $10.00000000 and passes; one base unit less floors to $9.99999999 and reverts `BelowMinPledge(999999999,
    /// 1000000000)`, for a new account and for a top-up alike; zero units revert `ZeroLiquidity`.
    function test_TEST_072_pledgeAtMinimumAndOneUnitBelow() public {
        PledgeCounters memory k = _counters();
        PledgeCharge memory c =
            riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), 5e18, k, false);
        assertEq(c.usdCharge, 10e8, "exactly the minimum");
        bytes memory below =
            abi.encodeWithSelector(IRiskModuleErrors.BelowMinPledge.selector, 999_999_999, 1_000_000_000);
        vm.expectRevert(below);
        riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), 5e18 - 1, k, false);
        _debt(1.5e18, 1000);
        k.accountRecords = 1;
        riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), 5e18, k, false);
        vm.expectRevert(below);
        riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), 5e18 - 1, k, false);
        vm.expectRevert(IRiskModuleErrors.ZeroLiquidity.selector);
        riskModule.checkPledge(wallet, address(proxy), mid, V3, bytes32(uint256(1)), 0, k, false);
    }
}
