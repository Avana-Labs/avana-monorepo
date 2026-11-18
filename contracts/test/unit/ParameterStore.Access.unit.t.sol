// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IParameterStore} from "../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreBase} from "../../src/policy/parameter-store/IParameterStoreBase.sol";
import {IParameterStoreListing} from "../../src/policy/parameter-store/IParameterStoreListing.sol";
import {IParameterStoreLoosen} from "../../src/policy/parameter-store/IParameterStoreLoosen.sol";
import {IParameterStoreTighten} from "../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {ParameterStore} from "../../src/policy/parameter-store/ParameterStore.sol";
import {ParameterStoreTightenLogic} from "../../src/policy/parameter-store/ParameterStoreTightenLogic.sol";
import {
    DebtReserveParams,
    FeedDef,
    GlobalParams,
    MarketParams,
    ParameterStoreLogics
} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {SecondSource} from "../../src/types/SecondSource.sol";
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {
    MockAvanaComponent,
    MockPositionProxy,
    MockProxyBindings,
    MockProxyManager
} from "../utils/mocks/ParameterStoreMocks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @notice Roles, initialization, upgrade authorization and the logic-contract wiring of the ParameterStore.
contract ParameterStoreAccessUnitTest is ParameterStoreFixture {
    bytes32 internal constant ADMIN = AvanaRoles.APPLICATION_ADMIN;
    bytes32 internal constant GUARDIAN = AvanaRoles.APPLICATION_PAUSE_GUARDIAN;
    bytes32 internal constant STEWARD = AvanaRoles.APPLICATION_RISK_STEWARD;
    address internal jointSafe = makeAddr("jointConfigurationSafe");

    function setUp() public {
        _deployStore(false);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-ACCESS-153, Q-259, REQ-ACCESS-002, REQ-ACCESS-014, REQ-ACCESS-032
    function test_TEST_242_adminRolesOnlyTimelock() public {
        address tl = address(timelock);
        assertTrue(store.hasRole(bytes32(0), tl));
        assertTrue(store.hasRole(ADMIN, tl));
        assertEq(store.getRoleAdmin(ADMIN), bytes32(0));
        assertEq(store.getRoleAdmin(GUARDIAN), ADMIN);
        address safe = governanceMultisig;
        vm.prank(tl);
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.AdminRoleOnlyTimelock.selector, ADMIN, safe));
        store.grantRole(ADMIN, safe);
        vm.prank(tl);
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.AdminRoleOnlyTimelock.selector, bytes32(0), safe));
        store.grantRole(bytes32(0), safe);
        // Granting to the timelock again is allowed and changes nothing.
        vm.prank(tl);
        store.grantRole(ADMIN, tl);
        assertTrue(store.hasRole(ADMIN, tl));
    }

    // TEST-242 verifies: REQ-PSTORE-001, Q-259
    function test_TEST_242_adminGrantRevertsThroughTimelockOperation() public {
        Call[] memory calls = _one(address(store), abi.encodeCall(IAccessControl.grantRole, (ADMIN, alice)));
        uint256 delay = _required(calls);
        assertEq(delay, NORMAL_DELAY);
        _schedule(governanceMultisig, calls, delay, bytes32("grant"));
        vm.warp(block.timestamp + delay);
        (address[] memory t, uint256[] memory v, bytes[] memory p) = _arrays(calls);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.AdminRoleOnlyTimelock.selector, ADMIN, alice));
        timelock.executeBatch(t, v, p, bytes32(0), bytes32("grant"));
    }

    // TEST-242 verifies: REQ-PSTORE-001, Q-259, REQ-ACCESS-150
    function test_TEST_242_initializeRefusesOtherTimelockAndRunsOnce() public {
        ParameterStore impl = new ParameterStore(address(timelock), address(registry), 12, false, logics);
        bytes memory bad = abi.encodeCall(IParameterStore.initialize, (alice, _defaultGlobals(), 10_000));
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.AdminRoleOnlyTimelock.selector, bytes32(0), alice));
        new ERC1967Proxy(address(impl), bad);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        store.initialize(address(timelock), _defaultGlobals(), 10_000);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(timelock), _defaultGlobals(), 10_000);
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-CONFIG-050, REQ-PSTORE-030, REQ-PSTORE-018
    function test_TEST_242_initializeChecksBounds() public {
        ParameterStore impl = new ParameterStore(address(timelock), address(registry), 12, false, logics);
        GlobalParams memory g = _defaultGlobals();
        g.gateRecoverySeconds = 599;
        _expectInitRevert(impl, g, 10_000, IParameterStoreBase.OutOfBounds.selector);
        g = _defaultGlobals();
        g.graceHealthFactor = 0.89e18;
        _expectInitRevert(impl, g, 10_000, IParameterStoreBase.LivenessBound.selector);
        g = _defaultGlobals();
        g.graceDuration = 7201;
        _expectInitRevert(impl, g, 10_000, IParameterStoreBase.LivenessBound.selector);
        g = _defaultGlobals();
        g.maxShortfallBps = 5001;
        _expectInitRevert(impl, g, 10_000, IParameterStoreBase.OutOfBounds.selector);
        _expectInitRevert(impl, _defaultGlobals(), 0, IParameterStoreBase.OutOfBounds.selector);
        g = _defaultGlobals();
        g.feeRecipient = address(0);
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.InvalidFeeRecipient.selector, address(0)));
        new ERC1967Proxy(address(impl), abi.encodeCall(IParameterStore.initialize, (address(timelock), g, 1)));
        // Initial values read back.
        assertEq(store.gateRecoverySeconds(), 1800);
        assertEq(store.maxShortfallBps(), 1000);
        assertEq(store.maxFlashFeeBps(), 10);
        assertEq(store.poolShareMaxBps(), 10_000);
        (address feed, uint32 grace) = store.sequencer();
        assertEq(feed, address(0));
        assertEq(grace, 0);
    }

    function _expectInitRevert(
        ParameterStore impl,
        GlobalParams memory g,
        uint16 share,
        bytes4 err
    ) internal {
        vm.expectRevert(err);
        new ERC1967Proxy(address(impl), abi.encodeCall(IParameterStore.initialize, (address(timelock), g, share)));
    }

    // TEST-062 verifies: REQ-PSTORE-001, REQ-PSTORE-002, REQ-CONFIG-058, REQ-PSTORE-029, REQ-ACCESS-037, REQ-ACCESS-038, REQ-ACCESS-039, REQ-ACCESS-040, REQ-ACCESS-041, REQ-ACCESS-043, REQ-ACCESS-186, REQ-ACCESS-044, REQ-ACCESS-131, REQ-ACCESS-132, REQ-ACCESS-138, REQ-ACCESS-049, REQ-ACCESS-050, REQ-ACCESS-135, REQ-ACCESS-146, REQ-ACCESS-165, REQ-ACCESS-179, REQ-ACCESS-025, REQ-ACCESS-111
    function test_TEST_062_everySetterNeedsItsRole() public {
        bytes[] memory calls = _setterCalls();
        for (uint256 i = 0; i < calls.length; ++i) {
            bytes4 sel = bytes4(calls[i]);
            bytes32 role = sel == IParameterStore.useStandbySecondSource.selector ? GUARDIAN : ADMIN;
            vm.prank(attacker);
            (bool ok, bytes memory ret) = address(store).call(calls[i]);
            assertFalse(ok, "setter ran without its role");
            assertEq(
                ret,
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, role),
                "wrong revert"
            );
        }
        // A guardian holds only useStandbySecondSource: the timelock grants the role, every other setter still fails.
        vm.prank(address(timelock));
        store.grantRole(GUARDIAN, emergencyGuardian);
        for (uint256 i = 0; i < calls.length; ++i) {
            if (bytes4(calls[i]) == IParameterStore.useStandbySecondSource.selector) continue;
            vm.prank(emergencyGuardian);
            (bool ok,) = address(store).call(calls[i]);
            assertFalse(ok, "guardian ran an admin setter");
        }
    }

    // TEST-062 verifies: REQ-PSTORE-001, INV-065
    function test_TEST_062_upgradeNeedsApplicationAdmin() public {
        ParameterStore next = new ParameterStore(address(timelock), address(registry), 12, false, logics);
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, ADMIN)
        );
        ParameterStore(address(store)).upgradeToAndCall(address(next), "");
        Call[] memory calls =
            _one(address(store), abi.encodeCall(ParameterStore(address(store)).upgradeToAndCall, (address(next), "")));
        assertEq(_required(calls), NORMAL_DELAY);
        _run(calls, bytes32("upgrade"));
        bytes32 slot = vm.load(address(store), 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertEq(address(uint160(uint256(slot))), address(next));
        // State survives the upgrade.
        assertEq(store.maxShortfallBps(), 1000);
    }

    // TEST-062 verifies: REQ-PSTORE-001
    function test_TEST_062_constructorChecksLogicContracts() public {
        ParameterStoreLogics memory l = logics;
        (l.tighten, l.loosen) = (l.loosen, l.tighten);
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        new ParameterStore(address(timelock), address(registry), 12, false, l);
        l = logics;
        l.tighten = address(new ParameterStoreTightenLogic(address(timelock), address(registry), 2, false));
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        new ParameterStore(address(timelock), address(registry), 12, false, l);
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        new ParameterStore(address(timelock), address(registry), 12, true, logics);
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        new ParameterStoreTightenLogic(address(0), address(registry), 12, false);
    }

    // TEST-206 verifies: REQ-PSTORE-010, Q-231, REQ-ACCESS-043; shared: the same probe shows the store has no interest-fee selector and only the liquidation fee share
    // TEST-278 verifies: REQ-PSTORE-025, Q-381, REQ-ACCESS-146
    function test_TEST_278_noMinimumDebtOrInterestFeeSelector() public view {
        bytes4[4] memory absent = [
            bytes4(keccak256("minDebtUsd()")),
            bytes4(keccak256("setMinDebtUsd(uint256)")),
            bytes4(keccak256("interestFeeBps()")),
            bytes4(keccak256("setInterestFeeBps(uint16)"))
        ];
        for (uint256 i = 0; i < absent.length; ++i) {
            (bool ok,) = address(store).staticcall(abi.encodeWithSelector(absent[i]));
            assertFalse(ok);
        }
        assertEq(store.avanaFeeShareBps(), 2000);
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_feeRecipientRefusesAvanaAddresses() public {
        address[5] memory bad = [
            address(0),
            address(store),
            address(timelock),
            registry.AAVE_ADAPTER(),
            address(new MockPositionProxy(registry.AAVE_ADAPTER()))
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(address(timelock));
            vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.InvalidFeeRecipient.selector, bad[i]));
            store.setFeeRecipient(bad[i]);
        }
        address h = address(hub);
        vm.prank(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.InvalidFeeRecipient.selector, h));
        store.setFeeRecipient(h);
        vm.prank(address(timelock));
        store.setFeeRecipient(bob);
        assertEq(store.feeRecipient(), bob);
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-PSTORE-010, REQ-ROLE-006, REQ-ROLE-027, REQ-ROLE-117, REQ-ACCESS-185, REQ-ACCESS-044, REQ-ACCESS-049, REQ-ACCESS-165
    function test_TEST_062_riskStewardHoldsTightenSettersAndFeeShareOnly() public {
        assertEq(store.getRoleAdmin(STEWARD), ADMIN);
        vm.prank(address(timelock));
        store.grantRole(STEWARD, jointSafe);
        bytes[] memory calls = _setterCalls();
        uint256 allowed = 0;
        for (uint256 i = 0; i < calls.length; ++i) {
            bytes4 sel = bytes4(calls[i]);
            bytes memory unauthorized = abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                jointSafe,
                sel == IParameterStore.useStandbySecondSource.selector ? GUARDIAN : ADMIN
            );
            vm.prank(jointSafe);
            (bool ok, bytes memory ret) = address(store).call(calls[i]);
            if (_stewardSelector(sel)) {
                assertTrue(ok || keccak256(ret) != keccak256(unauthorized), "steward refused a tightening");
                ++allowed;
            } else {
                assertFalse(ok, "steward ran a timelock-only function");
                assertEq(ret, unauthorized, "wrong revert");
            }
        }
        // The 19 tighten setters and setAvanaFeeShareBps.
        assertEq(allowed, 20);
        // The steward cannot grant its own role or any other.
        vm.prank(jointSafe);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, jointSafe, ADMIN)
        );
        store.grantRole(STEWARD, alice);
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-PSTORE-010, REQ-CONFIG-051, REQ-ROLE-117, SPEC-LIQ-009, REQ-ACCESS-185, REQ-ACCESS-043
    function test_TEST_062_riskStewardActsAtOnceWithinBounds() public {
        _listMarket();
        vm.prank(address(timelock));
        store.grantRole(STEWARD, jointSafe);
        vm.prank(jointSafe);
        vm.expectEmit(address(store));
        emit IParameterStoreBase.CapTightened("marketUsdCap", bytes32(M), 5_000_000e8, 4_000_000e8, jointSafe);
        store.tightenMarketUsdCap(M, 4_000_000e8);
        assertEq(store.marketUsdCap(M), 4_000_000e8);
        // Strictly safer only, as for the timelock.
        vm.prank(jointSafe);
        vm.expectRevert(IParameterStoreBase.NotStricter.selector);
        store.tightenMarketUsdCap(M, 4_000_000e8);
        // Avana's fee share either way within [0, 5,000] bps.
        vm.prank(jointSafe);
        store.setAvanaFeeShareBps(5000);
        assertEq(store.avanaFeeShareBps(), 5000);
        vm.prank(jointSafe);
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        store.setAvanaFeeShareBps(5001);
        vm.prank(jointSafe);
        store.setAvanaFeeShareBps(0);
        assertEq(store.avanaFeeShareBps(), 0);
        // A revoked steward holds nothing.
        vm.prank(address(timelock));
        store.revokeRole(STEWARD, jointSafe);
        vm.prank(jointSafe);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, jointSafe, ADMIN)
        );
        store.tightenMarketUsdCap(M, 3_000_000e8);
    }

    // TEST-062 verifies: REQ-PSTORE-001, REQ-PSTORE-002
    function test_TEST_062_logicContractsRefuseDirectCalls() public {
        bytes[] memory calls = _setterCalls();
        address[5] memory l = [logics.tighten, logics.loosen, logics.listing, logics.adminOracle, logics.adminRisk];
        bytes memory notDelegated = abi.encodeWithSelector(IParameterStoreBase.NotDelegated.selector);
        uint256 refused = 0;
        // Every setter body lives in exactly one logic contract, which refuses a direct call; the others have no such
        // selector and revert with no data.
        for (uint256 i = 0; i + 1 < calls.length; ++i) {
            for (uint256 j = 0; j < l.length; ++j) {
                (bool ok, bytes memory ret) = l[j].call(calls[i]);
                assertFalse(ok, "logic ran a direct call");
                if (ret.length == 0) continue;
                assertEq(ret, notDelegated, "wrong revert");
                ++refused;
            }
        }
        assertEq(refused, calls.length - 1);
        GlobalParams memory g = _defaultGlobals();
        (bool done, bytes memory r) =
            logics.adminRisk.call(abi.encodeCall(IParameterStore.initialize, (address(timelock), g, 10_000)));
        assertFalse(done);
        assertEq(r, notDelegated);
        (done, r) = logics.adminOracle.call(abi.encodeWithSignature("getOracleConfig(address)", address(lpOracle)));
        assertFalse(done);
        assertEq(r, notDelegated);
        // The identity view stays callable: the implementation constructor reads it.
        (bytes32 kind,,,,) = ParameterStoreTightenLogic(logics.tighten).logicConfig();
        assertEq(kind, keccak256("ParameterStoreTightenLogic"));
    }

    // TEST-062 verifies: REQ-CONFIG-056
    function test_TEST_062_feeRecipientRefusesEveryAvanaContract() public {
        MockProxyManager pm = new MockProxyManager();
        registry.setProxyManager(address(pm));
        MockProxyBindings fakeAdapterProxy = new MockProxyBindings(alice, address(spoke), M);
        pm.setPrediction(alice, address(spoke), M, address(fakeAdapterProxy));
        address[13] memory bad = [
            registry.PARAMETER_STORE(),
            registry.FLASH_LIQUIDATOR(),
            registry.STANDARD_SPOKE_IMPLEMENTATION(),
            registry.flashSource(),
            address(coverage),
            address(ghoPrice),
            address(lpOracle),
            address(vaultToken),
            address(new MockAvanaComponent(address(timelock), address(0))),
            address(new MockAvanaComponent(address(0), address(registry))),
            logics.tighten,
            address(implementation),
            address(fakeAdapterProxy)
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(address(timelock));
            vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.InvalidFeeRecipient.selector, bad[i]));
            store.setFeeRecipient(bad[i]);
        }
        // Bindings the ProxyManager does not map to the address are not a proxy.
        MockProxyBindings other = new MockProxyBindings(bob, address(spoke), M);
        vm.prank(address(timelock));
        store.setFeeRecipient(address(other));
        assertEq(store.feeRecipient(), address(other));
        // A contract with no bindings at all (a Safe, say) is accepted.
        address safe = address(new MockProxyManager());
        vm.prank(address(timelock));
        store.setFeeRecipient(safe);
        assertEq(store.feeRecipient(), safe);
    }

    function _stewardSelector(
        bytes4 sel
    ) internal pure returns (bool) {
        return sel == IParameterStore.setAvanaFeeShareBps.selector
            || sel == IParameterStore.tightenMaxFlashFeeBps.selector
            || sel == IParameterStoreTighten.tightenHardHealthFloor.selector
            || sel == IParameterStoreTighten.tightenSlippageAllowanceBps.selector
            || sel == IParameterStoreTighten.tightenFloorRoundingAllowance.selector
            || sel == IParameterStoreTighten.tightenBorrowPriceMaxAge.selector
            || sel == IParameterStoreTighten.tightenConsistencyToleranceBps.selector
            || sel == IParameterStoreTighten.tightenFeedAgreementToleranceBps.selector
            || sel == IParameterStoreTighten.tightenPoolRiskFactor.selector
            || sel == IParameterStoreTighten.tightenRouteDepthThreshold.selector
            || sel == IParameterStoreTighten.tightenMarketUsdCap.selector
            || sel == IParameterStoreTighten.tightenTopUpSliceUsd.selector
            || sel == IParameterStoreTighten.tightenTokenUsdCap.selector
            || sel == IParameterStoreTighten.tightenPoolShareMaxBps.selector
            || sel == IParameterStoreTighten.tightenMinPledgeUsd.selector
            || sel == IParameterStoreTighten.tightenPoolShareMaxBpsOf.selector
            || sel == IParameterStore.tightenGateRecoverySeconds.selector
            || sel == IParameterStore.tightenBreakerDeficitMax.selector
            || sel == IParameterStore.tightenMaxShortfallBps.selector
            || sel == IParameterStore.tightenDebtStressRiseBps.selector;
    }

    function _setterCalls() internal view returns (bytes[] memory c) {
        MarketParams memory mp;
        FeedDef memory fd;
        SecondSource memory ss;
        DebtReserveParams memory dp;
        c = new bytes[](64);
        uint256 k;
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenHardHealthFloor, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenSlippageAllowanceBps, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenFloorRoundingAllowance, (gho, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenBorrowPriceMaxAge, (usdc, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenConsistencyToleranceBps, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenFeedAgreementToleranceBps, (usdc, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenPoolRiskFactor, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenRouteDepthThreshold, (M, usdc, gho, 0, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenMarketUsdCap, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenTopUpSliceUsd, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenTokenUsdCap, (address(hub), usdc, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenPoolShareMaxBps, (1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenMinPledgeUsd, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenPoolShareMaxBpsOf, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenHardHealthFloor, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenSlippageAllowanceBps, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenFloorRoundingAllowance, (gho, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenRouteDepthThreshold, (M, usdc, gho, 0, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenMarketUsdCap, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenTopUpSliceUsd, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenTokenUsdCap, (address(hub), usdc, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenPoolShareMaxBps, (1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenMinPledgeUsd, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenPoolShareMaxBpsOf, (M, 1));
        c[k++] = abi.encodeCall(IParameterStore.setBorrowPriceMaxAge, (usdc, 1));
        c[k++] = abi.encodeCall(IParameterStore.setConsistencyToleranceBps, (M, 1));
        c[k++] = abi.encodeCall(IParameterStore.setFeedAgreementToleranceBps, (usdc, 1));
        c[k++] = abi.encodeCall(IParameterStore.setPoolRiskFactor, (M, 1));
        c[k++] = abi.encodeCall(IParameterStore.setAvanaFeeShareBps, (1));
        c[k++] = abi.encodeCall(IParameterStore.setFeeRecipient, (alice));
        c[k++] = abi.encodeCall(IParameterStore.setMaxFlashFeeBps, (1));
        c[k++] = abi.encodeCall(IParameterStore.tightenMaxFlashFeeBps, (1));
        c[k++] = abi.encodeCall(IParameterStore.setSecondSource, (usdc, ss, ss));
        c[k++] = abi.encodeCall(IParameterStore.useStandbySecondSource, (usdc));
        c[k++] = abi.encodeCall(IParameterStore.restoreSecondSource, (usdc));
        c[k++] = abi.encodeCall(IParameterStore.setCachedWindow, (1));
        c[k++] = abi.encodeCall(IParameterStore.setDisagreementPauseMax, (1));
        c[k++] = abi.encodeCall(IParameterStore.setTwapWindow, (M, 1));
        c[k++] = abi.encodeCall(IParameterStore.setUsdBand, (1, 2));
        c[k++] = abi.encodeCall(IParameterStore.setLiquidationPriceMaxAge, (usdc, 1));
        c[k++] = abi.encodeCall(IParameterStore.setFeedMaxAge, (usdc, 1));
        c[k++] = abi.encodeCall(IParameterStore.setGraceDuration, (1));
        c[k++] = abi.encodeCall(IParameterStore.setGraceHealthFactor, (1));
        c[k++] = abi.encodeCall(IParameterStore.setFeedAgreementMarginBps, (1));
        c[k++] = abi.encodeCall(IParameterStore.setSlippageAllowanceMinBps, (M, 1));
        c[k++] = abi.encodeCall(IParameterStore.setTokenCollateralFactorBps, (usdc, 1));
        c[k++] = abi.encodeCall(IParameterStore.setStressFloorUsd, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreListing.setInitialMarketParams, (M, mp));
        c[k++] = abi.encodeCall(IParameterStoreListing.setInitialMarketCaps, (M, 1, 1, 1));
        c[k++] = abi.encodeCall(IParameterStoreListing.setInitialTokenCap, (address(hub), usdc, 1));
        c[k++] = abi.encodeCall(IParameterStoreListing.setFeed, (usdc, fd));
        c[k++] = abi.encodeCall(IParameterStoreListing.setDebtAssetParams, (gho, dp));
        c[k++] = abi.encodeCall(IParameterStore.tightenGateRecoverySeconds, (1));
        c[k++] = abi.encodeCall(IParameterStore.loosenGateRecoverySeconds, (1));
        c[k++] = abi.encodeCall(IParameterStore.tightenBreakerDeficitMax, (address(hub), gho, 1));
        c[k++] = abi.encodeCall(IParameterStore.loosenBreakerDeficitMax, (address(hub), gho, 1));
        c[k++] = abi.encodeCall(IParameterStore.tightenMaxShortfallBps, (1));
        c[k++] = abi.encodeCall(IParameterStore.loosenMaxShortfallBps, (1));
        c[k++] = abi.encodeCall(IParameterStore.tightenDebtStressRiseBps, (gho, 1));
        c[k++] = abi.encodeCall(IParameterStore.loosenDebtStressRiseBps, (gho, 1));
        c[k++] = abi.encodeCall(IParameterStore.setLiquidationExpectations, (address(spoke), 1, 1));
        c[k++] = abi.encodeCall(IParameterStore.setSequencer, (address(0), 0));
        c[k++] = abi.encodeCall(IParameterStore.setCoverageRatioBps, (1));
        c[k++] = abi.encodeCall(IAccessControl.grantRole, (GUARDIAN, alice));
        assert(k == c.length);
    }
}
