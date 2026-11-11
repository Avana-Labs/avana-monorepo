// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryLogic} from "../../src/policy/market-registry/IMarketRegistryLogic.sol";
import {IMarketRegistryWindDown} from "../../src/policy/market-registry/IMarketRegistryWindDown.sol";
import {MarketRegistry} from "../../src/policy/market-registry/MarketRegistry.sol";
import {MarketRegistryActivationLogic} from "../../src/policy/market-registry/MarketRegistryActivationLogic.sol";
import {MarketRegistryHubsLogic} from "../../src/policy/market-registry/MarketRegistryHubsLogic.sol";
import {MarketRegistryListingLogic} from "../../src/policy/market-registry/MarketRegistryListingLogic.sol";
import {MarketRegistryRoutesLogic} from "../../src/policy/market-registry/MarketRegistryRoutesLogic.sol";
import {MarketRegistrySafetyLogic} from "../../src/policy/market-registry/MarketRegistrySafetyLogic.sol";
import {MarketRegistryWindDownLogic} from "../../src/policy/market-registry/MarketRegistryWindDownLogic.sol";
import {MarketRegistryImmutables} from "../../src/policy/market-registry/types/MarketRegistryImmutables.sol";
import {MarketRegistryLogics} from "../../src/policy/market-registry/types/MarketRegistryLogics.sol";
import {RiskTier} from "../../src/policy/market-registry/types/RiskTier.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {RouteSlot} from "../../src/types/RouteSlot.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";

/// @notice The six logic contracts behind the MarketRegistry: every body refuses a direct call (it runs only by
/// delegatecall from the registry), each reports its kind and the hash of the implementation immutables, every
/// zero immutable is refused at construction, and the registry's constructor accepts only the right logic in each slot.
contract MarketRegistryLogicGuardsUnitTest is MarketRegistryFixture {
    struct Body {
        address logic;
        bytes data;
    }

    function setUp() public {
        _setUpWorld();
    }

    /// @dev Every write body of every logic contract, with arguments that would pass the checks on the registry.
    function _bodies() internal view returns (Body[] memory b) {
        address[] memory one = new address[](1);
        one[0] = address(gho);
        b = new Body[](38);
        uint256 k = 0;
        // Hubs logic.
        b[k++] = Body(logics.hubs, abi.encodeCall(MarketRegistryHubsLogic.recordHub, (alice, RiskTier.Stable)));
        b[k++] = Body(logics.hubs, abi.encodeCall(MarketRegistryHubsLogic.registerIntegration, (2, alice, bob)));
        b[k++] = Body(logics.hubs, abi.encodeCall(MarketRegistryHubsLogic.setCoverageSpoke, (address(hub), alice, bob)));
        b[k++] =
            Body(logics.hubs, abi.encodeCall(MarketRegistryHubsLogic.setCrossHubLine, (address(hub), alice, bob, 0)));
        b[k++] = Body(logics.hubs, abi.encodeCall(MarketRegistryHubsLogic.setCrossHubLinesEnabled, (true)));
        b[k++] = Body(logics.hubs, abi.encodeCall(MarketRegistryHubsLogic.setFlashSource, (address(flash))));
        b[k++] = Body(logics.hubs, abi.encodeCall(MarketRegistryHubsLogic.approveSpokeCodeHash, (keccak256("h"))));
        b[k++] = Body(logics.hubs, abi.encodeCall(MarketRegistryHubsLogic.recordIntegrationContracts, (V3, one)));
        b[k++] = Body(logics.hubs, abi.encodeCall(MarketRegistryHubsLogic.deployCdpSpoke, (_spokeDef())));
        b[k++] =
            Body(logics.hubs, abi.encodeCall(MarketRegistryHubsLogic.enableDebtReserve, (address(spoke), _ghoDef())));
        b[k++] = Body(logics.hubs, abi.encodeCall(MarketRegistryHubsLogic.removeDebtReserve, (address(spoke), 0)));
        // Listing logic.
        b[k++] = Body(
            logics.listing, abi.encodeCall(MarketRegistryListingLogic.listToken, (alice, _tokenDef(one, one, one)))
        );
        b[k++] = Body(
            logics.listing, abi.encodeCall(MarketRegistryListingLogic.setPriceSource, (address(usdc), one, one, one))
        );
        b[k++] = Body(
            logics.listing, abi.encodeCall(MarketRegistryListingLogic.listCollateralMarket, (_marketDef(alice, bob)))
        );
        // Activation logic.
        b[k++] = Body(logics.activation, abi.encodeCall(MarketRegistryActivationLogic.activateMarket, (1)));
        b[k++] = Body(logics.activation, abi.encodeCall(MarketRegistryActivationLogic.cancelRegistration, (1)));
        b[k++] = Body(logics.activation, abi.encodeCall(MarketRegistryActivationLogic.setMarketOffboarding, (1)));
        // Routes logic.
        b[k++] = Body(
            logics.routes, abi.encodeCall(MarketRegistryRoutesLogic.setRoute, (1, address(usdc), address(gho), 0, bob))
        );
        b[k++] = Body(
            logics.routes, abi.encodeCall(MarketRegistryRoutesLogic.disableRoute, (1, address(usdc), address(gho), 0))
        );
        b[k++] = Body(
            logics.routes,
            abi.encodeCall(MarketRegistryRoutesLogic.restoreRoute, (1, address(usdc), address(gho), 0, bob))
        );
        b[k++] = Body(
            logics.routes, abi.encodeCall(MarketRegistryRoutesLogic.useStandbyRoute, (address(usdc), RouteSlot.Primary))
        );
        b[k++] = Body(logics.routes, abi.encodeCall(MarketRegistryRoutesLogic.cancelStandbySwitch, (address(usdc))));
        b[k++] = Body(logics.routes, abi.encodeCall(MarketRegistryRoutesLogic.restorePriceRoute, (address(usdc))));
        // Safety logic.
        b[k++] = Body(logics.safety, abi.encodeCall(MarketRegistrySafetyLogic.freeze, (address(hub))));
        b[k++] = Body(logics.safety, abi.encodeCall(MarketRegistrySafetyLogic.freezeAll, ()));
        b[k++] =
            Body(logics.safety, abi.encodeCall(MarketRegistrySafetyLogic.pause, (address(hub), PauseReason.General)));
        b[k++] = Body(logics.safety, abi.encodeCall(MarketRegistrySafetyLogic.pauseAll, (PauseReason.General)));
        b[k++] = Body(logics.safety, abi.encodeCall(MarketRegistrySafetyLogic.unfreeze, (address(hub))));
        b[k++] = Body(logics.safety, abi.encodeCall(MarketRegistrySafetyLogic.unpause, (address(hub))));
        b[k++] = Body(logics.safety, abi.encodeCall(MarketRegistrySafetyLogic.freezeAddress, (bob)));
        b[k++] = Body(logics.safety, abi.encodeCall(MarketRegistrySafetyLogic.unfreezeAddress, (bob)));
        b[k++] = Body(logics.safety, abi.encodeCall(MarketRegistrySafetyLogic.recordBreach, (bytes32(uint256(1)), 8)));
        b[k++] = Body(logics.safety, abi.encodeCall(MarketRegistrySafetyLogic.tripMarketBreaker, (1)));
        b[k++] = Body(logics.safety, abi.encodeCall(MarketRegistrySafetyLogic.tripDebtBreaker, (address(spoke), 0)));
        // Wind-down logic.
        b[k++] = Body(logics.windDown, abi.encodeCall(MarketRegistryWindDownLogic.stepWindDown, (1)));
        b[k++] = Body(logics.windDown, abi.encodeCall(MarketRegistryWindDownLogic.closeMarket, (1)));
        b[k++] = Body(
            logics.windDown,
            abi.encodeCall(MarketRegistryWindDownLogic.recordCreditLine, (address(hub), address(gho), 20_000_000))
        );
        b[k++] = Body(logics.windDown, abi.encodeCall(MarketRegistryWindDownLogic.syncDrawCap, (address(spoke), 0)));
        assert(k == b.length);
    }

    // TEST-168 verifies: REQ-CONFIG-001, REQ-CONFIG-005, REQ-MREG-004
    // Sources: 5.1 TEST-168
    // A direct call to any logic body reverts Unauthorized(caller), for the timelock, a guardian, the RiskModule and a
    // stranger alike: the bodies run only inside the registry, after its caller check.
    function test_TEST_168_everyLogicBodyRefusesADirectCall() public {
        Body[] memory b = _bodies();
        address[4] memory callers = [address(timelock), emergencyGuardian, address(rm), attacker];
        for (uint256 i = 0; i < b.length; ++i) {
            for (uint256 c = 0; c < callers.length; ++c) {
                vm.prank(callers[c]);
                (bool ok, bytes memory ret) = b[i].logic.call(b[i].data);
                assertFalse(ok, "direct call admitted");
                assertEq(ret, abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, callers[c]));
            }
        }
    }

    // TEST-168 verifies: REQ-CONFIG-001, REQ-CONFIG-005
    // The remaining bodies (resets and the settlement reserve) refuse a direct call the same way.
    function test_TEST_168_resetAndSettlementBodiesRefuseDirectCalls() public {
        bytes memory unauthorized = abi.encodeWithSelector(IMarketRegistryErrors.Unauthorized.selector, address(this));
        vm.expectRevert(unauthorized);
        MarketRegistrySafetyLogic(logics.safety).resetMarketBreaker(1);
        vm.expectRevert(unauthorized);
        MarketRegistrySafetyLogic(logics.safety).resetDebtBreaker(address(spoke), 0);
        vm.expectRevert(unauthorized);
        MarketRegistryWindDownLogic(logics.windDown).setSettlementReserve(1, 0);
    }

    // TEST-168 verifies: REQ-CONFIG-005, REQ-CONFIG-002
    // Each logic contract reports its own kind and the hash of the immutables it was built with, the registry's.
    function test_TEST_168_logicConfigOfEachContract() public view {
        bytes32 h = keccak256(abi.encode(im));
        address[6] memory l =
            [logics.hubs, logics.listing, logics.activation, logics.routes, logics.safety, logics.windDown];
        string[6] memory kinds = [
            "MarketRegistryHubsLogic",
            "MarketRegistryListingLogic",
            "MarketRegistryActivationLogic",
            "MarketRegistryRoutesLogic",
            "MarketRegistrySafetyLogic",
            "MarketRegistryWindDownLogic"
        ];
        for (uint256 i = 0; i < 6; ++i) {
            (bytes32 kind, bytes32 hash) = IMarketRegistryLogic(l[i]).logicConfig();
            assertEq(kind, keccak256(bytes(kinds[i])));
            assertEq(hash, h);
        }
    }

    // TEST-168 verifies: REQ-CONFIG-005, REQ-CONFIG-002
    // Every one of the six slots refuses a logic of another kind: the registry cannot be built with a body in the wrong
    // place.
    function test_TEST_168_eachSlotRefusesAnotherKind() public {
        for (uint256 slot = 0; slot < 6; ++slot) {
            MarketRegistryLogics memory l = logics;
            // Put the next slot's logic into this slot.
            address wrong = _slot(logics, (slot + 1) % 6);
            if (slot == 0) l.hubs = wrong;
            if (slot == 1) l.listing = wrong;
            if (slot == 2) l.activation = wrong;
            if (slot == 3) l.routes = wrong;
            if (slot == 4) l.safety = wrong;
            if (slot == 5) l.windDown = wrong;
            vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("logic")));
            new MarketRegistry(im, l);
        }
    }

    function _slot(
        MarketRegistryLogics memory l,
        uint256 i
    ) internal pure returns (address) {
        if (i == 0) return l.hubs;
        if (i == 1) return l.listing;
        if (i == 2) return l.activation;
        if (i == 3) return l.routes;
        if (i == 4) return l.safety;
        return l.windDown;
    }

    // TEST-168 verifies: REQ-CONFIG-005, REQ-CONFIG-002
    // A logic contract built with any one immutable different from the registry's is refused in its slot.
    function test_TEST_168_eachSlotRefusesForeignImmutables() public {
        MarketRegistryImmutables memory other = im;
        other.payoutEscrow = makeAddr("otherEscrow");
        MarketRegistryLogics memory foreign = _deployLogics(other);
        for (uint256 slot = 0; slot < 6; ++slot) {
            MarketRegistryLogics memory l = logics;
            if (slot == 0) l.hubs = foreign.hubs;
            if (slot == 1) l.listing = foreign.listing;
            if (slot == 2) l.activation = foreign.activation;
            if (slot == 3) l.routes = foreign.routes;
            if (slot == 4) l.safety = foreign.safety;
            if (slot == 5) l.windDown = foreign.windDown;
            vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("logic")));
            new MarketRegistry(im, l);
        }
    }

    /// @dev `im` with field `i` (0..12) set to zero.
    function _zeroField(
        uint256 i
    ) internal view returns (MarketRegistryImmutables memory x) {
        x = im;
        if (i == 0) x.timelock = address(0);
        if (i == 1) x.aaveGovernanceExecutor = address(0);
        if (i == 2) x.vaultTokenFactory = address(0);
        if (i == 3) x.aaveAdapter = address(0);
        if (i == 4) x.collateralization = address(0);
        if (i == 5) x.lock = address(0);
        if (i == 6) x.proxyManager = address(0);
        if (i == 7) x.parameterStore = address(0);
        if (i == 8) x.riskModule = address(0);
        if (i == 9) x.lpVaultSwap = address(0);
        if (i == 10) x.payoutEscrow = address(0);
        if (i == 11) x.flashLiquidator = address(0);
        if (i == 12) x.standardSpokeImplementation = address(0);
    }

    // TEST-168 verifies: REQ-CONFIG-005
    // Fail closed at construction: each of the 13 per-chain addresses at zero is refused by every logic contract and
    // by the registry implementation.
    function test_TEST_168_everyZeroImmutableRefused() public {
        bytes memory err =
            abi.encodeWithSelector(IMarketRegistryErrors.ListingCheckFailed.selector, bytes32("immutables"));
        for (uint256 i = 0; i < 13; ++i) {
            MarketRegistryImmutables memory x = _zeroField(i);
            vm.expectRevert(err);
            new MarketRegistryHubsLogic(x);
            vm.expectRevert(err);
            new MarketRegistryListingLogic(x);
            vm.expectRevert(err);
            new MarketRegistryActivationLogic(x);
            vm.expectRevert(err);
            new MarketRegistryRoutesLogic(x);
            vm.expectRevert(err);
            new MarketRegistrySafetyLogic(x);
            vm.expectRevert(err);
            new MarketRegistryWindDownLogic(x);
            vm.expectRevert(err);
            new MarketRegistry(x, logics);
        }
    }

    // TEST-204 verifies: REQ-CONFIG-076, INV-093
    // The per-market drift read is a view that reads no registry storage, so the activation logic serves it directly:
    // a healthy reserve reads None, a reserve on another Hub HomeHubMismatch, an unknown reserve ReserveIdentity.
    function test_TEST_204_marketDriftIsADirectView() public {
        (uint256 id, address vt,) = _activeMarket();
        MarketRegistryActivationLogic a = MarketRegistryActivationLogic(logics.activation);
        assertEq(uint8(a.marketDrift(address(spoke), address(hub), vt, VT_RESERVE, VT_ASSET)), uint8(DriftReason.None));
        assertEq(
            uint8(a.marketDrift(address(spoke), alice, vt, VT_RESERVE, VT_ASSET)), uint8(DriftReason.HomeHubMismatch)
        );
        assertEq(
            uint8(a.marketDrift(address(spoke), address(hub), vt, 77, VT_ASSET)), uint8(DriftReason.ReserveIdentity)
        );
        assertEq(
            uint8(a.marketDrift(address(spoke), address(hub), alice, VT_RESERVE, VT_ASSET)),
            uint8(DriftReason.ReserveIdentity)
        );
        assertEq(
            uint8(a.marketDrift(address(spoke), address(hub), vt, VT_RESERVE, VT_ASSET + 1)),
            uint8(DriftReason.ReserveIdentity)
        );
        assertEq(registry.getMarket(id).reserveId, VT_RESERVE);
    }

    // TEST-168 verifies: REQ-CONFIG-001, REQ-CONFIG-002
    // Calling the registry implementation itself (not the proxy) cannot change anything: it holds no roles, its
    // initializer is disabled, and its permissionless writes find no market in its own storage.
    function test_TEST_168_implementationContractIsInert() public {
        MarketRegistry impl = new MarketRegistry(im, logics);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(timelock));
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryWindDown.MarketNotOffboarding.selector, 1));
        impl.stepWindDown(1);
        vm.expectRevert(abi.encodeWithSelector(IMarketRegistryErrors.UnknownDebtReserve.selector, address(spoke), 0));
        impl.syncDrawCap(address(spoke), 0);
        vm.prank(address(rm));
        impl.recordBreach(bytes32(uint256(1)), 8);
        (uint32 latched,) = impl.marketBreaker(1);
        assertEq(latched, 8, "only the implementation's own storage is written");
        (latched,) = registry.marketBreaker(1);
        assertEq(latched, 0, "the proxy's storage is untouched");
    }
}
