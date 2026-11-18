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
import {ParameterStoreFixture} from "../utils/fixtures/ParameterStoreFixture.sol";
import {
    MockAvanaComponent,
    MockPositionProxy,
    MockProxyBindings,
    MockProxyManager
} from "../utils/mocks/ParameterStoreMocks.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @notice Access, initialization, upgrade authorization and the logic-contract wiring of the ParameterStore.
contract ParameterStoreAccessUnitTest is ParameterStoreFixture {
    address internal jointSafe = makeAddr("jointConfigurationSafe");

    function setUp() public {
        _deployStore();
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-ACCESS-153, Q-259, REQ-ACCESS-002, REQ-ACCESS-014, REQ-ACCESS-032
    function test_TEST_242_authorityIsTheAccessManager() public view {
        assertEq(store.authority(), address(accessManager));
        assertEq(
            accessManager.getTargetFunctionRole(
                address(store), IParameterStoreTighten.tightenSlippageAllowanceBps.selector
            ),
            AvanaRoles.TIGHTEN_ROLE
        );
        assertEq(
            accessManager.getTargetFunctionRole(address(store), IParameterStoreLoosen.loosenMarketUsdCap.selector),
            AvanaRoles.GOVERNANCE_ROLE
        );
    }

    // TEST-242 verifies: REQ-PSTORE-001, Q-259, REQ-ACCESS-150
    function test_TEST_242_initializeRunsOnce() public {
        ParameterStore impl = new ParameterStore(address(registry), 12, logics);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        store.initialize(address(accessManager), _defaultGlobals());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(accessManager), _defaultGlobals());
    }

    // TEST-242 verifies: REQ-PSTORE-001, REQ-CONFIG-050, REQ-PSTORE-030, REQ-PSTORE-018
    function test_TEST_242_initializeChecksBounds() public {
        ParameterStore impl = new ParameterStore(address(registry), 12, logics);
        GlobalParams memory g = _defaultGlobals();
        g.maxShortfallBps = 5001;
        _expectInitRevert(impl, g, IParameterStoreBase.OutOfBounds.selector);
        g = _defaultGlobals();
        g.feeRecipient = address(0);
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.InvalidFeeRecipient.selector, address(0)));
        new ERC1967Proxy(address(impl), abi.encodeCall(IParameterStore.initialize, (address(accessManager), g)));
        // Initial values read back.
        assertEq(store.maxShortfallBps(), 1000);
        assertEq(store.maxFlashFeeBps(), 10);
    }

    function _expectInitRevert(
        ParameterStore impl,
        GlobalParams memory g,
        bytes4 err
    ) internal {
        vm.expectRevert(err);
        new ERC1967Proxy(address(impl), abi.encodeCall(IParameterStore.initialize, (address(accessManager), g)));
    }

    // TEST-062 verifies: REQ-PSTORE-001, REQ-PSTORE-002, REQ-CONFIG-058, REQ-PSTORE-029, REQ-ACCESS-037, REQ-ACCESS-038, REQ-ACCESS-039, REQ-ACCESS-040, REQ-ACCESS-041, REQ-ACCESS-043, REQ-ACCESS-186, REQ-ACCESS-044, REQ-ACCESS-131, REQ-ACCESS-132, REQ-ACCESS-138, REQ-ACCESS-049, REQ-ACCESS-050, REQ-ACCESS-135, REQ-ACCESS-146, REQ-ACCESS-165, REQ-ACCESS-179, REQ-ACCESS-025, REQ-ACCESS-111
    function test_TEST_062_everySetterNeedsItsRole() public {
        bytes[] memory calls = _setterCalls();
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(attacker);
            (bool ok, bytes memory ret) = address(store).call(calls[i]);
            assertFalse(ok, "setter ran without its role");
            assertEq(
                ret, abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker), "wrong revert"
            );
        }
    }

    // TEST-062 verifies: REQ-PSTORE-001, INV-065
    function test_TEST_062_upgradeNeedsTheGovernanceRole() public {
        ParameterStore next = new ParameterStore(address(registry), 12, logics);
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, attacker));
        ParameterStore(address(store)).upgradeToAndCall(address(next), "");
        bytes memory data = abi.encodeCall(ParameterStore(address(store)).upgradeToAndCall, (address(next), ""));
        assertEq(_delayOf(address(store), data), NORMAL_DELAY);
        _runScheduled(address(store), data);
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
        new ParameterStore(address(registry), 12, l);
        l = logics;
        l.tighten = address(new ParameterStoreTightenLogic(address(registry), 2));
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        new ParameterStore(address(registry), 12, l);
        // Logic contracts built for another MarketRegistry.
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        new ParameterStore(makeAddr("otherRegistry"), 12, logics);
        vm.expectRevert(IParameterStoreBase.OutOfBounds.selector);
        new ParameterStoreTightenLogic(address(0), 12);
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
            address(accessManager),
            registry.AAVE_ADAPTER(),
            address(new MockPositionProxy(registry.AAVE_ADAPTER()))
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(governor);
            vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.InvalidFeeRecipient.selector, bad[i]));
            store.setFeeRecipient(bad[i]);
        }
        address h = address(hub);
        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.InvalidFeeRecipient.selector, h));
        store.setFeeRecipient(h);
        vm.prank(governor);
        store.setFeeRecipient(bob);
        assertEq(store.feeRecipient(), bob);
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-PSTORE-010, REQ-ROLE-006, REQ-ROLE-027, REQ-ROLE-117, REQ-ACCESS-185, REQ-ACCESS-044, REQ-ACCESS-049, REQ-ACCESS-165
    function test_TEST_062_riskStewardHoldsTightenSettersAndFeeShareOnly() public {
        assertEq(accessManager.getRoleAdmin(AvanaRoles.TIGHTEN_ROLE), AvanaRoles.ADMIN_ROLE);
        vm.prank(aaveGovernanceExecutor);
        accessManager.grantRole(AvanaRoles.TIGHTEN_ROLE, jointSafe, 0);
        bytes[] memory calls = _setterCalls();
        uint256 allowed = 0;
        for (uint256 i = 0; i < calls.length; ++i) {
            bytes4 sel = bytes4(calls[i]);
            bytes memory unauthorized =
                abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, jointSafe);
            vm.prank(jointSafe);
            (bool ok, bytes memory ret) = address(store).call(calls[i]);
            if (_stewardSelector(sel)) {
                assertTrue(ok || keccak256(ret) != keccak256(unauthorized), "steward refused a tightening");
                ++allowed;
            } else {
                assertFalse(ok, "steward ran a governance-only function");
                assertEq(ret, unauthorized, "wrong revert");
            }
        }
        // The 13 tighten setters and setAvanaFeeShareBps.
        assertEq(allowed, 14);
        // The steward cannot grant its own role or any other.
        vm.prank(jointSafe);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector, jointSafe, AvanaRoles.ADMIN_ROLE
            )
        );
        accessManager.grantRole(AvanaRoles.TIGHTEN_ROLE, alice, 0);
    }

    // TEST-062 verifies: REQ-PSTORE-002, REQ-PSTORE-010, REQ-CONFIG-051, REQ-ROLE-117, SPEC-LIQ-009, REQ-ACCESS-185, REQ-ACCESS-043
    function test_TEST_062_riskStewardActsAtOnceWithinBounds() public {
        _listMarket();
        vm.prank(aaveGovernanceExecutor);
        accessManager.grantRole(AvanaRoles.TIGHTEN_ROLE, jointSafe, 0);
        vm.prank(jointSafe);
        vm.expectEmit(address(store));
        emit IParameterStoreBase.CapTightened("marketUsdCap", bytes32(M), 5_000_000e8, 4_000_000e8, jointSafe);
        store.tightenMarketUsdCap(M, 4_000_000e8);
        assertEq(store.marketUsdCap(M), 4_000_000e8);
        // Strictly safer only, as for the governance path.
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
        vm.prank(aaveGovernanceExecutor);
        accessManager.revokeRole(AvanaRoles.TIGHTEN_ROLE, jointSafe);
        vm.prank(jointSafe);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, jointSafe));
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
        for (uint256 i = 0; i < calls.length; ++i) {
            for (uint256 j = 0; j < l.length; ++j) {
                (bool ok, bytes memory ret) = l[j].call(calls[i]);
                assertFalse(ok, "logic ran a direct call");
                if (ret.length == 0) continue;
                assertEq(ret, notDelegated, "wrong revert");
                ++refused;
            }
        }
        assertEq(refused, calls.length);
        GlobalParams memory g = _defaultGlobals();
        (bool done, bytes memory r) =
            logics.adminRisk.call(abi.encodeCall(IParameterStore.initialize, (address(accessManager), g)));
        assertFalse(done);
        assertEq(r, notDelegated);
        (done, r) =
            logics.adminOracle.call(abi.encodeCall(IParameterStore.liquidationLivenessHolds, (address(spoke), M, 1)));
        assertFalse(done);
        assertEq(r, notDelegated);
        // The identity view stays callable: the implementation constructor reads it.
        (bytes32 kind,,) = ParameterStoreTightenLogic(logics.tighten).logicConfig();
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
            address(new MockAvanaComponent(address(accessManager), address(0))),
            address(new MockAvanaComponent(address(0), address(registry))),
            logics.tighten,
            address(implementation),
            address(fakeAdapterProxy)
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.prank(governor);
            vm.expectRevert(abi.encodeWithSelector(IParameterStoreBase.InvalidFeeRecipient.selector, bad[i]));
            store.setFeeRecipient(bad[i]);
        }
        // Bindings the ProxyManager does not map to the address are not a proxy.
        MockProxyBindings other = new MockProxyBindings(bob, address(spoke), M);
        vm.prank(governor);
        store.setFeeRecipient(address(other));
        assertEq(store.feeRecipient(), address(other));
        // A contract with no bindings at all (a Safe, say) is accepted.
        address safe = address(new MockProxyManager());
        vm.prank(governor);
        store.setFeeRecipient(safe);
        assertEq(store.feeRecipient(), safe);
    }

    function _stewardSelector(
        bytes4 sel
    ) internal pure returns (bool) {
        return sel == IParameterStore.setAvanaFeeShareBps.selector
            || sel == IParameterStore.tightenMaxFlashFeeBps.selector
            || sel == IParameterStoreTighten.tightenSlippageAllowanceBps.selector
            || sel == IParameterStoreTighten.tightenFloorRoundingAllowance.selector
            || sel == IParameterStoreTighten.tightenBorrowPriceMaxAge.selector
            || sel == IParameterStoreTighten.tightenPoolRiskFactor.selector
            || sel == IParameterStoreTighten.tightenRouteDepthThreshold.selector
            || sel == IParameterStoreTighten.tightenMarketUsdCap.selector
            || sel == IParameterStoreTighten.tightenTopUpSliceUsd.selector
            || sel == IParameterStoreTighten.tightenTokenUsdCap.selector
            || sel == IParameterStoreTighten.tightenMinPledgeUsd.selector
            || sel == IParameterStore.tightenDeficitMax.selector
            || sel == IParameterStore.tightenMaxShortfallBps.selector
            || sel == IParameterStore.tightenDebtStressRiseBps.selector;
    }

    function _setterCalls() internal view returns (bytes[] memory c) {
        MarketParams memory mp;
        FeedDef memory fd;
        DebtReserveParams memory dp;
        c = new bytes[](39);
        uint256 k;
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenSlippageAllowanceBps, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenFloorRoundingAllowance, (gho, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenBorrowPriceMaxAge, (usdc, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenPoolRiskFactor, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenRouteDepthThreshold, (M, usdc, gho, 0, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenMarketUsdCap, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenTopUpSliceUsd, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenTokenUsdCap, (address(hub), usdc, 1));
        c[k++] = abi.encodeCall(IParameterStoreTighten.tightenMinPledgeUsd, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenSlippageAllowanceBps, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenFloorRoundingAllowance, (gho, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenRouteDepthThreshold, (M, usdc, gho, 0, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenMarketUsdCap, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenTopUpSliceUsd, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenTokenUsdCap, (address(hub), usdc, 1));
        c[k++] = abi.encodeCall(IParameterStoreLoosen.loosenMinPledgeUsd, (M, 1));
        c[k++] = abi.encodeCall(IParameterStore.setBorrowPriceMaxAge, (usdc, 1));
        c[k++] = abi.encodeCall(IParameterStore.setPoolRiskFactor, (M, 1));
        c[k++] = abi.encodeCall(IParameterStore.setAvanaFeeShareBps, (1));
        c[k++] = abi.encodeCall(IParameterStore.setFeeRecipient, (alice));
        c[k++] = abi.encodeCall(IParameterStore.setMaxFlashFeeBps, (1));
        c[k++] = abi.encodeCall(IParameterStore.tightenMaxFlashFeeBps, (1));
        c[k++] = abi.encodeCall(IParameterStore.setLiquidationPriceMaxAge, (usdc, 1));
        c[k++] = abi.encodeCall(IParameterStore.setFeedMaxAge, (usdc, 1));
        c[k++] = abi.encodeCall(IParameterStore.setSlippageAllowanceMinBps, (M, 1));
        c[k++] = abi.encodeCall(IParameterStore.setTokenCollateralFactorBps, (usdc, 1));
        c[k++] = abi.encodeCall(IParameterStore.setStressFloorUsd, (M, 1));
        c[k++] = abi.encodeCall(IParameterStoreListing.setInitialMarketParams, (M, mp));
        c[k++] = abi.encodeCall(IParameterStoreListing.setInitialMarketCaps, (M, 1, 1, 1));
        c[k++] = abi.encodeCall(IParameterStoreListing.setInitialTokenCap, (address(hub), usdc, 1));
        c[k++] = abi.encodeCall(IParameterStoreListing.setFeed, (usdc, fd));
        c[k++] = abi.encodeCall(IParameterStoreListing.setDebtAssetParams, (gho, dp));
        c[k++] = abi.encodeCall(IParameterStore.tightenDeficitMax, (address(hub), gho, 1));
        c[k++] = abi.encodeCall(IParameterStore.loosenDeficitMax, (address(hub), gho, 1));
        c[k++] = abi.encodeCall(IParameterStore.tightenMaxShortfallBps, (1));
        c[k++] = abi.encodeCall(IParameterStore.loosenMaxShortfallBps, (1));
        c[k++] = abi.encodeCall(IParameterStore.tightenDebtStressRiseBps, (gho, 1));
        c[k++] = abi.encodeCall(IParameterStore.loosenDebtStressRiseBps, (gho, 1));
        c[k++] = abi.encodeCall(IParameterStore.setCoverageRatioBps, (1));
        assert(k == c.length);
    }
}
