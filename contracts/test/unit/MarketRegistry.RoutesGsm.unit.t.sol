// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IGsm} from "../../src/interfaces/external/gho/IGsm.sol";
import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "../../src/policy/market-registry/IMarketRegistryEvents.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryRouteMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {RegistryErc1820Mock, RegistryGsmMock} from "../utils/mocks/MarketRegistryRouteMocks.sol";

/// @notice The route-type, GSM and ERC-777 checks of `setRoute` and `restoreRoute` (2.12 REQ-ROUTE-002, REQ-ROUTE-005,
/// REQ-ROUTE-019, REQ-ROUTE-030; Q-341, Q-342). The market is the fixture's USDC/USDT market with GHO debt.
contract MarketRegistryRoutesGsmUnitTest is MarketRegistryFixture {
    address internal constant ERC1820 = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;
    bytes32 internal constant ERC777_TOKEN = keccak256("ERC777Token");
    uint8 internal constant PRIMARY = 0;
    uint8 internal constant BACKUP = 1;
    uint8 internal constant GSM_KIND = 0;
    uint8 internal constant LITE_PSM_KIND = 1;
    uint8 internal constant REVERTS = 1;
    uint8 internal constant SHORT = 2;
    uint8 internal constant LONG = 3;

    uint256 internal id;
    address internal usdcIn;
    RegistryGsmMock internal gsm;

    function setUp() public {
        _setUpWorld();
        (id,,) = _listMarket();
        usdcIn = address(usdc);
        gsm = new RegistryGsmMock();
    }

    /// @dev A `PegModule` route of USDC into GHO through a static aToken and `module` of peg-module kind `pegKind`.
    function _pegRoute(
        uint256 pegKind,
        address module,
        string memory wrapper
    ) internal returns (RegistryRouteMock r) {
        address[] memory deps = new address[](2);
        (deps[0], deps[1]) = (makeAddr(wrapper), module);
        r = new RegistryRouteMock(usdcIn, address(gho), address(lpVaultSwap), deps);
        r.setRouteType(0);
        r.setPegModule(pegKind, uint256(uint160(module)));
    }

    function _gsmRoute() internal returns (RegistryRouteMock) {
        return _pegRoute(GSM_KIND, address(gsm), "staticAUsdc");
    }

    function _set(
        uint8 kind,
        address route
    ) internal {
        vm.prank(address(timelock));
        registry.setRoute(id, usdcIn, address(gho), kind, route);
    }

    function _refused(
        uint8 kind,
        address route
    ) internal {
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.setRoute(id, usdcIn, address(gho), kind, route);
    }

    function _usable(
        uint8 kind,
        address route
    ) internal view {
        (address r, bool usable) = registry.getRoute(id, usdcIn, address(gho), kind);
        assertEq(r, route);
        assertTrue(usable);
    }

    function _etchErc1820() internal returns (RegistryErc1820Mock reg) {
        vm.etch(ERC1820, address(new RegistryErc1820Mock()).code);
        reg = RegistryErc1820Mock(ERC1820);
    }

    // TEST-054 verifies: REQ-ROUTE-002, REQ-ROUTE-005, REQ-ROUTE-030, Q-341
    // Sources: 5.1 TEST-054 (a GSM only in the backup slot); 4.4 Q-341
    /// @notice A live GSM route is refused in the primary slot and accepted in the backup slot.
    function test_TEST_054_gsmRouteOnlyInBackupSlot() public {
        RegistryRouteMock r = _gsmRoute();
        _refused(PRIMARY, address(r));
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.RouteSet(id, usdcIn, address(gho), BACKUP, address(r));
        _set(BACKUP, address(r));
        _usable(BACKUP, address(r));
    }

    // TEST-054 verifies: REQ-ROUTE-002, REQ-ROUTE-005
    /// @notice A LitePSM `PegModule` route fills a primary slot (the GSM rule binds only GSM routes), and the other route
    /// types (1 `DexPath`, 2 `WrapperThenDex`) are admitted in either slot.
    function test_TEST_054_litePsmAndDexTypesAdmittedInPrimary() public {
        RegistryRouteMock psm = _pegRoute(LITE_PSM_KIND, makeAddr("litePsm"), "daiUsds");
        _set(PRIMARY, address(psm));
        _usable(PRIMARY, address(psm));
        RegistryRouteMock wrapped = _newRoute(usdcIn, address(gho), "wrapperDex");
        wrapped.setRouteType(2);
        _set(BACKUP, address(wrapped));
        _usable(BACKUP, address(wrapped));
        RegistryRouteMock dex = _newRoute(usdcIn, address(gho), "dexP");
        _set(PRIMARY, address(dex));
        _usable(PRIMARY, address(dex));
    }

    // TEST-054 verifies: REQ-ROUTE-002, REQ-ROUTE-005, REQ-ROUTE-030
    /// @notice A route type outside 0..2, or a `routeType()` read that reverts or has the wrong length, is refused.
    function test_TEST_054_unknownOrUnreadableRouteTypeRefused() public {
        RegistryRouteMock r = _newRoute(usdcIn, address(gho), "dexT");
        r.setRouteType(3);
        _refused(PRIMARY, address(r));
        _refused(BACKUP, address(r));
        r.setRouteType(1);
        bytes4 sel = r.routeType.selector;
        uint8[3] memory modes = [REVERTS, SHORT, LONG];
        for (uint256 i = 0; i < modes.length; ++i) {
            r.setAnswerMode(sel, modes[i]);
            _refused(PRIMARY, address(r));
        }
        r.setAnswerMode(sel, 0);
        _set(PRIMARY, address(r));
    }

    // TEST-054 verifies: REQ-ROUTE-002, REQ-ROUTE-005, REQ-ROUTE-030
    /// @notice A `PegModule` route whose `pegModule()` names an unknown kind, a word that is not an address, a module
    /// missing from `dependencies()` or the zero module, or whose read reverts or has the wrong length, is refused in
    /// either slot; the same route with a well-formed answer is accepted.
    function test_TEST_054_malformedPegModuleAnswerRefused() public {
        RegistryRouteMock r = _gsmRoute();
        uint256 gsmWord = uint256(uint160(address(gsm)));
        r.setPegModule(2, gsmWord);
        _refused(BACKUP, address(r));
        r.setPegModule(GSM_KIND, gsmWord | (1 << 160));
        _refused(BACKUP, address(r));
        r.setPegModule(GSM_KIND, uint256(uint160(makeAddr("otherGsm"))));
        _refused(BACKUP, address(r));
        r.setPegModule(LITE_PSM_KIND, uint256(uint160(makeAddr("otherPsm"))));
        _refused(PRIMARY, address(r));
        r.setPegModule(LITE_PSM_KIND, 0);
        _refused(PRIMARY, address(r));
        r.setPegModule(GSM_KIND, gsmWord);
        bytes4 sel = r.pegModule.selector;
        uint8[3] memory modes = [REVERTS, SHORT, LONG];
        for (uint256 i = 0; i < modes.length; ++i) {
            r.setAnswerMode(sel, modes[i]);
            _refused(BACKUP, address(r));
        }
        r.setAnswerMode(sel, 0);
        _set(BACKUP, address(r));
        _usable(BACKUP, address(r));
    }

    // TEST-054 verifies: REQ-ROUTE-005, REQ-ROUTE-030, Q-341
    // Sources: 4.4 Q-341 (the GSMs named earlier are seized with a cap of 0)
    /// @notice A GSM that is seized, frozen or capped at 0 refuses its route in the backup slot; so does an answer
    /// outside its type's range (a bool word of 2, a cap above `type(uint128).max`).
    function test_TEST_054_unhealthyGsmRefused() public {
        RegistryRouteMock r = _gsmRoute();
        gsm.setSeized(1);
        _refused(BACKUP, address(r));
        gsm.setSeized(2);
        _refused(BACKUP, address(r));
        gsm.setSeized(0);
        gsm.setFrozen(1);
        _refused(BACKUP, address(r));
        gsm.setFrozen(2);
        _refused(BACKUP, address(r));
        gsm.setFrozen(0);
        gsm.setCap(0);
        _refused(BACKUP, address(r));
        gsm.setCap(uint256(type(uint128).max) + 1);
        _refused(BACKUP, address(r));
        gsm.setCap(type(uint128).max);
        _set(BACKUP, address(r));
        _usable(BACKUP, address(r));
    }

    // TEST-054 verifies: REQ-ROUTE-005, REQ-ROUTE-030, Q-341
    /// @notice Each GSM health read that reverts, answers one byte short or one word long refuses the route, even when
    /// the first word of a long answer is the healthy value.
    function test_TEST_054_unreadableGsmRefused() public {
        RegistryRouteMock r = _gsmRoute();
        bytes4[3] memory sels = [IGsm.getIsSeized.selector, IGsm.getIsFrozen.selector, IGsm.getExposureCap.selector];
        uint8[3] memory modes = [REVERTS, SHORT, LONG];
        for (uint256 s = 0; s < sels.length; ++s) {
            for (uint256 m = 0; m < modes.length; ++m) {
                gsm.setMode(sels[s], modes[m]);
                _refused(BACKUP, address(r));
            }
            gsm.setMode(sels[s], 0);
        }
        _set(BACKUP, address(r));
    }

    // TEST-054 verifies: REQ-ROUTE-019, REQ-ROUTE-005, REQ-ROUTE-030, REQ-CONFIG-062, Q-341
    // Sources: 2.12 REQ-ROUTE-019 ("including the GSM health check")
    /// @notice `restoreRoute` re-runs the GSM health check at the restoring block: a GSM route disabled and then frozen
    /// (or seized, or capped at 0) cannot be restored, and is restored once the GSM is live again.
    function test_TEST_054_restoreRerunsGsmHealthCheck() public {
        RegistryRouteMock r = _gsmRoute();
        _set(BACKUP, address(r));
        vm.prank(address(timelock));
        registry.disableRoute(id, usdcIn, address(gho), BACKUP);
        gsm.setFrozen(1);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.restoreRoute(id, usdcIn, address(gho), BACKUP, address(r));
        gsm.setFrozen(0);
        gsm.setSeized(1);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.restoreRoute(id, usdcIn, address(gho), BACKUP, address(r));
        gsm.setSeized(0);
        gsm.setCap(0);
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.restoreRoute(id, usdcIn, address(gho), BACKUP, address(r));
        (, bool usable) = registry.getRoute(id, usdcIn, address(gho), BACKUP);
        assertFalse(usable);
        gsm.setCap(1e24);
        vm.prank(address(timelock));
        vm.expectEmit(address(registry));
        emit IMarketRegistryEvents.RouteRestored(id, usdcIn, address(gho), BACKUP, address(r));
        registry.restoreRoute(id, usdcIn, address(gho), BACKUP, address(r));
        _usable(BACKUP, address(r));
    }

    // TEST-054 verifies: REQ-ROUTE-005, REQ-ROUTE-030, Q-342
    // Sources: 4.4 Q-342 (tokens with an ERC-1820 ERC777Token implementer are not listed)
    /// @notice With the ERC-1820 registry present, a route is refused when its input token, its debt asset or any of
    /// its intermediates has an `ERC777Token` implementer, in either slot; an implementer for another interface hash
    /// does not count, and a route whose tokens have none is accepted.
    function test_TEST_054_erc777TokenRefused() public {
        RegistryErc1820Mock reg = _etchErc1820();
        address mid = makeAddr("intermediate");
        address[] memory mids = new address[](2);
        (mids[0], mids[1]) = (makeAddr("intermediate0"), mid);
        RegistryRouteMock r = _newRoute(usdcIn, address(gho), "dexE");
        r.setIntermediates(mids);
        address hook = makeAddr("hookImplementer");
        reg.setImplementer(usdcIn, ERC777_TOKEN, uint256(uint160(hook)));
        _refused(PRIMARY, address(r));
        _refused(BACKUP, address(r));
        reg.setImplementer(usdcIn, ERC777_TOKEN, 0);
        reg.setImplementer(address(gho), ERC777_TOKEN, uint256(uint160(hook)));
        _refused(PRIMARY, address(r));
        reg.setImplementer(address(gho), ERC777_TOKEN, 0);
        reg.setImplementer(mid, ERC777_TOKEN, uint256(uint160(hook)));
        _refused(PRIMARY, address(r));
        _refused(BACKUP, address(r));
        reg.setImplementer(mid, ERC777_TOKEN, 0);
        reg.setImplementer(usdcIn, keccak256("ERC20Token"), uint256(uint160(hook)));
        _set(PRIMARY, address(r));
        _usable(PRIMARY, address(r));
    }

    // TEST-054 verifies: REQ-ROUTE-005, REQ-ROUTE-030, Q-342
    /// @notice An ERC-1820 read that reverts, answers one byte short, or answers one word long with a zero first word
    /// counts as an implementer and refuses the route (fail closed); a chain without the registry has no ERC-777 token,
    /// so the route is accepted there.
    function test_TEST_054_unreadableErc1820Refused() public {
        RegistryRouteMock r = _newRoute(usdcIn, address(gho), "dexF");
        RegistryErc1820Mock reg = _etchErc1820();
        uint8[3] memory modes = [REVERTS, SHORT, LONG];
        for (uint256 i = 0; i < modes.length; ++i) {
            reg.setMode(modes[i]);
            _refused(PRIMARY, address(r));
        }
        vm.etch(ERC1820, "");
        _set(PRIMARY, address(r));
        _usable(PRIMARY, address(r));
    }

    // TEST-054 verifies: REQ-ROUTE-019, REQ-ROUTE-030, REQ-CONFIG-062, Q-342
    /// @notice `restoreRoute` re-runs the ERC-777 check: an intermediate that registered an `ERC777Token` implementer
    /// after the route was set keeps the route disabled.
    function test_TEST_054_restoreRerunsErc777Check() public {
        RegistryRouteMock r = _newRoute(usdcIn, address(gho), "dexG");
        address[] memory mids = new address[](1);
        mids[0] = makeAddr("intermediate");
        r.setIntermediates(mids);
        _set(PRIMARY, address(r));
        vm.prank(address(timelock));
        registry.disableRoute(id, usdcIn, address(gho), PRIMARY);
        RegistryErc1820Mock reg = _etchErc1820();
        reg.setImplementer(mids[0], ERC777_TOKEN, uint256(uint160(makeAddr("hook"))));
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.restoreRoute(id, usdcIn, address(gho), PRIMARY, address(r));
        reg.setImplementer(mids[0], ERC777_TOKEN, 0);
        vm.prank(address(timelock));
        registry.restoreRoute(id, usdcIn, address(gho), PRIMARY, address(r));
        _usable(PRIMARY, address(r));
    }
}
