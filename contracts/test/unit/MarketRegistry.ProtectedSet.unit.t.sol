// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IMarketRegistryErrors} from "../../src/policy/market-registry/IMarketRegistryErrors.sol";
import {MarketRegistryFixture} from "../utils/fixtures/MarketRegistryFixture.sol";
import {RegistryLPOracleMock} from "../utils/mocks/MarketRegistryMocks.sol";

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
}
