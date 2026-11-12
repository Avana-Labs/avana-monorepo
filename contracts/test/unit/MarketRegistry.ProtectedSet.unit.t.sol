// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {IMarketRegistryHubs} from "../../src/policy/market-registry/IMarketRegistryHubs.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryFlashSourceMock, RegistryLPOracleMock, RegistryTokenMock} from "../utils/mocks/MarketRegistryMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The protected set of the address freeze follows each market through its life: its vault token and
/// LPOracle are protected while it is Registered, Active, Offboarding or Closed, free while it is Cancelled, and
/// protected again once relisted; every wallet with a proxy and every recorded swap route is protected.
contract MarketRegistryProtectedSetUnitTest is MarketRegistryFixture {
    uint256 internal id;
    address internal vt;
    RegistryLPOracleMock internal lpo;

    function setUp() public {
        _setUpWorld();
        (id, vt, lpo) = _listMarket();
        vm.warp(1000 * 3600);
    }

    function _protected(
        address a
    ) internal returns (bool) {
        uint256 snap = vm.snapshotState();
        vm.prank(emergencyGuardian);
        (bool ok, bytes memory ret) = address(registry).call(abi.encodeCall(registry.freezeAddress, (a)));
        vm.revertToState(snap);
        if (ok) return false;
        assertEq(ret, abi.encodeWithSelector(IMarketRegistryErrors.ProtectedAddress.selector, a), "other refusal");
        return true;
    }

    // TEST-229 verifies: REQ-MREG-020, INV-085, REQ-CONFIG-048, REQ-MREG-030
    // Sources: 5.1 TEST-229
    function test_TEST_229_marketAddressesThroughTheLifecycle() public {
        assertTrue(_protected(vt) && _protected(address(lpo)), "Registered");
        vm.prank(address(timelock));
        registry.cancelRegistration(id);
        assertFalse(_protected(vt) || _protected(address(lpo)), "Cancelled");
        vm.prank(address(timelock));
        registry.listCollateralMarket(_marketDef(vt, address(lpo)));
        assertTrue(_protected(vt) && _protected(address(lpo)), "relisted");
        _prepareActivation(id, vt);
        vm.prank(address(timelock));
        registry.activateMarket(id);
        assertTrue(_protected(vt) && _protected(address(lpo)), "Active");
        vm.prank(address(timelock));
        registry.setMarketOffboarding(id);
        assertTrue(_protected(vt) && _protected(address(lpo)), "Offboarding");
        vm.warp(block.timestamp + 5 days);
        registry.closeMarket(id);
        assertTrue(_protected(vt) && _protected(address(lpo)), "Closed");
    }

    // TEST-229 verifies: REQ-MREG-020, INV-085, ATTACK-139
    // Every recorded swap route stays protected, including one replaced or disabled, and from a cancelled market.
    function test_TEST_229_recordedRoutesStayProtected() public {
        address r1 = _setRoute(id, address(usdc), address(gho), 0, "dexA");
        address r2 = _setRoute(id, address(usdc), address(gho), 0, "dexB");
        vm.prank(address(timelock));
        registry.disableRoute(id, address(usdc), address(gho), 0);
        vm.prank(address(timelock));
        registry.cancelRegistration(id);
        assertTrue(_protected(r1), "replaced route");
        assertTrue(_protected(r2), "disabled route of a cancelled market");
        // A route contract never recorded is not protected.
        address stray = address(_newRoute(address(usdc), address(gho), "dexC"));
        assertFalse(_protected(stray));
    }

    // TEST-229 verifies: REQ-MREG-020, INV-085, ATTACK-139
    // A wallet is protected exactly while the AaveAdapter reports a proxy for it.
    function testFuzz_TEST_229_proxiesOfWalletsAreProtected(
        address proxy,
        address wallet
    ) public {
        vm.assume(proxy != address(0) && wallet != address(0));
        vm.assume(!_protected(proxy));
        adapterMock.setWallet(proxy, wallet);
        assertTrue(_protected(proxy));
        adapterMock.setWallet(proxy, address(0));
        assertFalse(_protected(proxy));
    }

    // TEST-229 verifies: REQ-MREG-020, INV-085
    // Every per-chain address of the implementation is protected, whatever else happens to the registry.
    function test_TEST_229_everyImmutableIsProtected() public {
        address[13] memory imm = [
            im.timelock,
            im.aaveGovernanceExecutor,
            im.vaultTokenFactory,
            im.aaveAdapter,
            im.collateralization,
            im.lock,
            im.proxyManager,
            im.parameterStore,
            im.riskModule,
            im.lpVaultSwap,
            im.payoutEscrow,
            im.flashLiquidator,
            address(registry)
        ];
        for (uint256 i = 0; i < imm.length; ++i) {
            assertTrue(_protected(imm[i]));
        }
        assertTrue(_protected(address(0)), "the zero address");
    }

    // TEST-285 verifies: REQ-CONFIG-005, REQ-FLASH-006, REQ-MREG-020, Q-386
    // Sources: decisions of 2026-11-11 (dedicated FlashSourceSet test)
    // `FlashSourceSet(previous, current)` on the first setting (previous 0) and on a replacement; a refused source
    // emits nothing and leaves the source in force.
    function test_TEST_285_flashSourceSetOnFirstSettingAndReplacement() public {
        _deployRegistry();
        RegistryFlashSourceMock f1 = new RegistryFlashSourceMock(makeAddr("pool1"), address(lpVaultSwap));
        RegistryFlashSourceMock f2 = new RegistryFlashSourceMock(makeAddr("pool2"), address(lpVaultSwap));
        vm.expectEmit(address(registry));
        emit IMarketRegistryHubs.FlashSourceSet(address(0), address(f1));
        vm.prank(address(timelock));
        registry.setFlashSource(address(f1));
        vm.expectEmit(address(registry));
        emit IMarketRegistryHubs.FlashSourceSet(address(f1), address(f2));
        vm.prank(address(timelock));
        registry.setFlashSource(address(f2));
        RegistryFlashSourceMock wrong = new RegistryFlashSourceMock(makeAddr("pool3"), alice);
        vm.recordLogs();
        vm.prank(address(timelock));
        vm.expectRevert(IMarketRegistryErrors.InvalidRoute.selector);
        registry.setFlashSource(address(wrong));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "a refused source emitted");
        assertEq(registry.flashSource(), address(f2));
    }

    // TEST-229 verifies: REQ-MREG-020, INV-085, Q-386
    // Sources: decisions of 2026-11-11 (each protected-set member: the flash source's LENDER())
    // The member is `LENDER()` of the source in force, read at the freeze: it moves with the source.
    function test_TEST_229_flashSourceLenderIsAMember() public {
        address lender = flash.LENDER();
        assertTrue(_protected(lender), "lender of the source in force");
        assertTrue(_protected(address(flash)), "the source itself");
        address pool2 = makeAddr("aaveV3Pool2");
        RegistryFlashSourceMock f2 = new RegistryFlashSourceMock(pool2, address(lpVaultSwap));
        assertFalse(_protected(pool2), "lender of a source not set");
        vm.prank(address(timelock));
        registry.setFlashSource(address(f2));
        assertTrue(_protected(pool2), "lender of the new source");
        assertFalse(_protected(lender), "lender of the replaced source");
        // The source changes its lender: the protection follows the live read.
        address pool3 = makeAddr("aaveV3Pool3");
        f2.setLender(pool3);
        assertTrue(_protected(pool3));
        assertFalse(_protected(pool2));
    }

    // TEST-229 verifies: REQ-MREG-020, REQ-MREG-035, INV-085
    // Sources: decisions of 2026-11-11 (each protected-set member: the integration contracts)
    // Every contract recorded for an integration is a member from the call that records it, finalized or not.
    function test_TEST_229_everyRecordedIntegrationContractIsAMember() public {
        address[] memory recorded = registry.integrationContracts(V3);
        assertEq(recorded.length, 2);
        assertEq(recorded[0], ammPositionManager);
        assertEq(recorded[1], ammFactory);
        for (uint256 i = 0; i < recorded.length; ++i) {
            assertTrue(_protected(recorded[i]));
        }
        address extra = address(new RegistryTokenMock(0));
        assertFalse(_protected(extra), "before it is recorded");
        address[] memory one = new address[](1);
        one[0] = extra;
        vm.prank(address(timelock));
        registry.recordIntegrationContracts(V3, one);
        assertTrue(_protected(extra), "from the recording call");
    }
}
