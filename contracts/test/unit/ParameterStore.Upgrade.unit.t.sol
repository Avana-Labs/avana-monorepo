// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IParameterStoreErrors} from "../../src/policy/parameter-store/IParameterStoreErrors.sol";
import {ParameterStore} from "../../src/policy/parameter-store/ParameterStore.sol";
import {ParameterStoreAdminOracleLogic} from "../../src/policy/parameter-store/ParameterStoreAdminOracleLogic.sol";
import {ParameterStoreAdminRiskLogic} from "../../src/policy/parameter-store/ParameterStoreAdminRiskLogic.sol";
import {ParameterStoreListingLogic} from "../../src/policy/parameter-store/ParameterStoreListingLogic.sol";
import {ParameterStoreLoosenLogic} from "../../src/policy/parameter-store/ParameterStoreLoosenLogic.sol";
import {ParameterStoreTightenLogic} from "../../src/policy/parameter-store/ParameterStoreTightenLogic.sol";
import {ParameterStoreLogics} from "../../src/policy/parameter-store/types/ParameterStoreLogics.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @notice Upgrades of the ParameterStore (REQ-PSTORE-001, REQ-PSTORE-003): only `APPLICATION_ADMIN` through a
/// normal-delay operation, every namespaced value and every role kept, the new implementation's logic contracts
/// serving the setters from then on, and the incident-response round trip of REQ-CONFIG-071 run through the real
/// timelock at its delays.
contract ParameterStoreUpgradeUnitTest is ParameterStoreFixture {
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function setUp() public {
        _deployStore(false);
        _listMarket();
    }

    function _freshLogics() internal returns (ParameterStoreLogics memory l) {
        address tl = address(timelock);
        address reg = address(registry);
        l = ParameterStoreLogics({
            tighten: address(new ParameterStoreTightenLogic(tl, reg, BLOCK_TIME, false)),
            loosen: address(new ParameterStoreLoosenLogic(tl, reg, BLOCK_TIME, false)),
            listing: address(new ParameterStoreListingLogic(tl, reg, BLOCK_TIME, false)),
            adminOracle: address(new ParameterStoreAdminOracleLogic(tl, reg, BLOCK_TIME, false)),
            adminRisk: address(new ParameterStoreAdminRiskLogic(tl, reg, BLOCK_TIME, false))
        });
    }

    function _upgrade(
        address next
    ) internal {
        _run(
            _one(address(store), abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (next, bytes("")))),
            keccak256(abi.encode(next))
        );
    }

    // TEST-062 verifies: REQ-PSTORE-001, INV-065
    function test_TEST_062_upgradeKeepsEveryValueAndRole() public {
        vm.startPrank(address(timelock));
        store.tightenHardHealthFloor(M, 1.1e18);
        store.tightenRouteDepthThreshold(M, usdc, gho, 1, 7e8);
        store.setCoverageRatioBps(1500);
        store.grantRole(AvanaRoles.APPLICATION_RISK_STEWARD, alice);
        store.loosenMarketUsdCap(M, 6_000_000e8);
        vm.stopPrank();
        bytes32 key = keccak256(abi.encode(bytes32("marketUsdCap"), bytes32(M)));
        uint64 stamped = store.lastLoosenedAt(key);
        ParameterStore next =
            new ParameterStore(address(timelock), address(registry), BLOCK_TIME, false, _freshLogics());
        _upgrade(address(next));
        assertEq(address(uint160(uint256(vm.load(address(store), IMPL_SLOT)))), address(next));
        assertEq(store.hardHealthFloor(M), 1.1e18);
        assertEq(store.routeDepthThreshold(M, usdc, gho, 1), 7e8);
        assertEq(store.coverageRatioBps(), 1500);
        assertEq(store.marketUsdCap(M), 6_000_000e8);
        assertEq(store.lastLoosenedAt(key), stamped);
        assertEq(store.feedAgreementToleranceBps(usdc), 150);
        assertEq(store.getFeed(address(fUsdc)).feedMaxAge, 88_200);
        assertTrue(store.hasRole(AvanaRoles.APPLICATION_RISK_STEWARD, alice));
        assertTrue(store.hasRole(AvanaRoles.APPLICATION_ADMIN, address(timelock)));
        // The upgrade waited a normal delay, so the next loosening runs; the one after it is spaced from it.
        assertGe(block.timestamp, uint256(stamped) + NORMAL_DELAY);
        _tl();
        store.loosenMarketUsdCap(M, 7_000_000e8);
        assertEq(store.lastLoosenedAt(key), block.timestamp);
        _tl();
        vm.expectRevert(
            abi.encodeWithSelector(IParameterStoreErrors.LoosenTooSoon.selector, key, block.timestamp + NORMAL_DELAY)
        );
        store.loosenMarketUsdCap(M, 8_000_000e8);
    }

    // TEST-062 verifies: REQ-PSTORE-001
    function test_TEST_062_newLogicsServeTheSettersAfterUpgrade() public {
        ParameterStoreLogics memory fresh = _freshLogics();
        ParameterStore next = new ParameterStore(address(timelock), address(registry), BLOCK_TIME, false, fresh);
        _upgrade(address(next));
        // The setter now runs in the new tighten logic: the state is the proxy's, the call the new logic's.
        vm.startStateDiffRecording();
        _tl();
        store.tightenMinPledgeUsd(M, 20e8);
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        bool viaFresh = false;
        for (uint256 i = 0; i < acc.length; ++i) {
            if (acc[i].kind != VmSafe.AccountAccessKind.DelegateCall) continue;
            assertTrue(acc[i].account != logics.tighten, "old logic still serves");
            if (acc[i].account == fresh.tighten) viaFresh = true;
        }
        assertTrue(viaFresh, "new tighten logic not used");
        assertEq(store.minPledgeUsd(M), 20e8);
        // The old logic contracts are still refused direct calls and hold nothing.
        (bool ok, bytes memory ret) = logics.tighten.call(abi.encodeCall(store.tightenMinPledgeUsd, (M, 30e8)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(IParameterStoreErrors.NotDelegated.selector));
    }

    // TEST-062 verifies: REQ-PSTORE-001, REQ-PSTORE-002, INV-065, REQ-ACCESS-015, REQ-ACCESS-031
    function test_TEST_062_onlyTheAdminUpgrades() public {
        ParameterStore next = new ParameterStore(address(timelock), address(registry), BLOCK_TIME, false, logics);
        address safe = makeAddr("jointConfigurationSafe");
        vm.startPrank(address(timelock));
        store.grantRole(AvanaRoles.APPLICATION_RISK_STEWARD, safe);
        store.grantRole(AvanaRoles.APPLICATION_PAUSE_GUARDIAN, emergencyGuardian);
        vm.stopPrank();
        address[3] memory callers = [safe, emergencyGuardian, governanceMultisig];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IAccessControl.AccessControlUnauthorizedAccount.selector, callers[i], AvanaRoles.APPLICATION_ADMIN
                )
            );
            UUPSUpgradeable(address(store)).upgradeToAndCall(address(next), "");
        }
        // Through the timelock, an upgrade is never short.
        assertEq(
            _required(_one(address(store), abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(next), "")))),
            NORMAL_DELAY
        );
    }

    // TEST-062 verifies: REQ-PSTORE-001
    function test_TEST_062_upgradeTargetMustBeUups() public {
        // A logic contract is no UUPS implementation: the proxy refuses it and keeps its implementation.
        _tl();
        vm.expectRevert(abi.encodeWithSelector(ERC1967Utils.ERC1967InvalidImplementation.selector, logics.tighten));
        UUPSUpgradeable(address(store)).upgradeToAndCall(logics.tighten, "");
        assertEq(address(uint160(uint256(vm.load(address(store), IMPL_SLOT)))), address(implementation));
        // The implementation answers the UUPS identity only outside a delegatecall.
        assertEq(implementation.proxiableUUID(), IMPL_SLOT);
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        UUPSUpgradeable(address(store)).proxiableUUID();
    }

    // TEST-225 verifies: REQ-CONFIG-071, REQ-PSTORE-017, REQ-PSTORE-002, Q-246
    function test_TEST_225_incidentTighteningReturnsOneStepPerDelay() public {
        // Market slippage tightened from 100 to 40 bps by a short-delay operation.
        uint256 t0 = block.timestamp;
        _run(_one(address(store), abi.encodeCall(store.tightenSlippageAllowanceBps, (M, 40))), bytes32("t"));
        assertEq(block.timestamp, t0 + SHORT_DELAY);
        assertEq(store.getMarketParams(M).slippageAllowanceBps, 40);
        // Back to 100: 65, then 90, then 100, each at the normal delay and one normal delay after the previous one.
        uint16[3] memory steps = [uint16(65), 90, 100];
        uint256 first = 0;
        for (uint256 i = 0; i < steps.length; ++i) {
            Call[] memory c = _one(address(store), abi.encodeCall(store.loosenSlippageAllowanceBps, (M, steps[i])));
            assertEq(_required(c), NORMAL_DELAY);
            _run(c, bytes32(uint256(i + 1)));
            if (i == 0) first = block.timestamp;
            assertEq(store.getMarketParams(M).slippageAllowanceBps, steps[i]);
        }
        // The return took at least three normal delays (15 days at launch) after the tightening.
        assertGe(block.timestamp - t0, 3 * NORMAL_DELAY);
        assertEq(block.timestamp - first, 2 * NORMAL_DELAY);
        // A larger step in one operation would have failed at execution.
        _tl();
        store.tightenSlippageAllowanceBps(M, 40);
        vm.warp(block.timestamp + NORMAL_DELAY);
        Call[] memory big = _one(address(store), abi.encodeCall(store.loosenSlippageAllowanceBps, (M, 66)));
        _schedule(governanceMultisig, big, NORMAL_DELAY, bytes32("big"));
        vm.warp(block.timestamp + NORMAL_DELAY);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(big);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                IParameterStoreErrors.LoosenStepTooLarge.selector,
                keccak256(abi.encode(bytes32("slippageAllowanceBps"), bytes32(M)))
            )
        );
        timelock.executeBatch(t, v, p, bytes32(0), bytes32("big"));
    }

    // TEST-063 verifies: REQ-PSTORE-016, REQ-PSTORE-002, REQ-CONFIG-053
    function test_TEST_063_deficitTighteningAtTheShortDelay() public {
        _tl();
        store.loosenBreakerDeficitMax(address(hub), gho, 10_000e18);
        Call[] memory c =
            _one(address(store), abi.encodeCall(store.tightenBreakerDeficitMax, (address(hub), gho, 5000e18)));
        assertEq(_required(c), SHORT_DELAY);
        _run(c, bytes32("deficit"));
        assertEq(store.breakerDeficitMax(address(hub), gho), 5000e18);
        Call[] memory back =
            _one(address(store), abi.encodeCall(store.loosenBreakerDeficitMax, (address(hub), gho, 10_000e18)));
        assertEq(_required(back), NORMAL_DELAY);
    }
}
