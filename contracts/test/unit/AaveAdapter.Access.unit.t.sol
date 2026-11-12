// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../src/governance/roles/AvanaRoles.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AaveAdapter} from "../../src/policy/aave-adapter/AaveAdapter.sol";
import {AaveAdapterCollateralLogic} from "../../src/policy/aave-adapter/AaveAdapterCollateralLogic.sol";
import {AaveAdapterExitLogic} from "../../src/policy/aave-adapter/AaveAdapterExitLogic.sol";
import {AaveAdapterSettlementLogic} from "../../src/policy/aave-adapter/AaveAdapterSettlementLogic.sol";
import {AaveAdapterUserLogic} from "../../src/policy/aave-adapter/AaveAdapterUserLogic.sol";
import {IAaveAdapterAdmin} from "../../src/policy/aave-adapter/IAaveAdapterAdmin.sol";
import {IAaveAdapterCollateral} from "../../src/policy/aave-adapter/IAaveAdapterCollateral.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterLogic} from "../../src/policy/aave-adapter/IAaveAdapterLogic.sol";
import {IAaveAdapterSettlement} from "../../src/policy/aave-adapter/IAaveAdapterSettlement.sol";
import {IAaveAdapterUser} from "../../src/policy/aave-adapter/IAaveAdapterUser.sol";
import {IAaveAdapterViews} from "../../src/policy/aave-adapter/IAaveAdapterViews.sol";
import {AaveAdapterImmutables} from "../../src/policy/aave-adapter/types/AaveAdapterImmutables.sol";
import {AaveAdapterLogics} from "../../src/policy/aave-adapter/types/AaveAdapterLogics.sol";
import {BytecodeInspector} from "../utils/BytecodeInspector.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @title AaveAdapterAccessUnitTest
/// @notice The Adapter's form and powers: UUPS behind ERC-1967 with the upgrade gated by `APPLICATION_ADMIN`, admin
/// roles only for the timelock, the constructor checks of the router and its logic contracts, the views, the selector
/// inventory, and the fixed target and selector set of every call a proxy makes (the PositionManagerApproved proof).
/// forge-config: default.isolate = false
contract AaveAdapterAccessUnitTest is AaveAdapterFixture {
    using BytecodeInspector for bytes;

    bytes32 internal constant ADMIN = keccak256("APPLICATION_ADMIN");

    // ─── Initialization and roles ───

    // TEST-242 verifies: REQ-ADAPTER-074, REQ-ADAPTER-084, REQ-ADAPTER-093, REQ-ACCESS-153, Q-259
    // Sources: 5.1 TEST-242
    /// @notice `grantRole(APPLICATION_ADMIN, a)` and `grantRole(DEFAULT_ADMIN_ROLE, a)` for any `a ≠ TIMELOCK` revert
    /// `AdminRoleOnlyTimelock(role, a)`, even from the timelock itself; the timelock holds both roles after init.
    function test_TEST_242_adminRolesOnlyTimelock() public {
        AaveAdapter a = AaveAdapter(adapter);
        assertTrue(a.hasRole(bytes32(0), timelock), "default admin");
        assertTrue(a.hasRole(ADMIN, timelock), "application admin");
        assertFalse(a.hasRole(bytes32(0), address(this)), "deployer has no role");
        address[3] memory others = [alice, address(this), governanceMultisig];
        for (uint256 i = 0; i < others.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.AdminRoleOnlyTimelock.selector, ADMIN, others[i]));
            vm.prank(timelock);
            a.grantRole(ADMIN, others[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IAaveAdapterErrors.AdminRoleOnlyTimelock.selector, bytes32(0), others[i])
            );
            vm.prank(timelock);
            a.grantRole(bytes32(0), others[i]);
        }
        assertEq(a.getRoleAdmin(ADMIN), bytes32(0), "admin of APPLICATION_ADMIN");
    }

    // TEST-062 verifies: REQ-ADAPTER-003, REQ-ADAPTER-084, REQ-ACCESS-153
    /// @notice A non-admin cannot grant any role, and other roles can be granted only by the timelock.
    function test_TEST_062_roleChangesOnlyByTimelock() public {
        AaveAdapter a = AaveAdapter(adapter);
        bytes32 other = keccak256("SOME_ROLE");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, bytes32(0))
        );
        vm.prank(attacker);
        a.grantRole(other, attacker);
        vm.prank(timelock);
        a.grantRole(other, alice);
        assertTrue(a.hasRole(other, alice), "timelock grants other roles");
    }

    // TEST-062 verifies: REQ-ADAPTER-003, REQ-ADAPTER-042, REQ-ACCESS-153
    /// @notice `upgradeToAndCall` needs `APPLICATION_ADMIN`: any other caller reverts, the timelock upgrades.
    function test_TEST_062_upgradeOnlyApplicationAdmin() public {
        AaveAdapter next = new AaveAdapter(im, logics);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, ADMIN)
        );
        vm.prank(attacker);
        AaveAdapter(adapter).upgradeToAndCall(address(next), "");
        vm.prank(timelock);
        AaveAdapter(adapter).upgradeToAndCall(address(next), "");
        bytes32 impl = vm.load(adapter, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertEq(address(uint160(uint256(impl))), address(next), "implementation slot");
        assertEq(adapterC.proxyOf(alice, MARKET_ID), address(0), "storage survives");
    }

    // TEST-062 verifies: REQ-ADAPTER-001, REQ-ADAPTER-099, REQ-PROXY-086
    /// @notice An upgrade keeps every proxy binding, nonce and account: the proxies are untouched and the new
    /// implementation serves them at once.
    function test_TEST_062_upgradeKeepsAccounts() public {
        (bytes32 k, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 100e18);
        AaveAdapter next = new AaveAdapter(im, logics);
        vm.prank(timelock);
        AaveAdapter(adapter).upgradeToAndCall(address(next), "");
        assertEq(adapterC.proxyOf(alice, MARKET_ID), p, "binding");
        assertEq(adapterC.borrowNonce(p), 1, "nonce");
        uint256 g = _debtOf(p, debtReserveId);
        _fund(alice, debtReserveId, g);
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k), UNITS, _one(debtReserveId), _one(g), _deadline());
        assertEq(lpVault.ownerOf(k), alice, "exit after upgrade");
    }

    function _one(
        uint256 x
    ) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = x;
    }

    // TEST-242 verifies: REQ-ADAPTER-074, REQ-ADAPTER-004
    /// @notice `initialize` runs once (a second call reverts), refuses a zero timelock and any timelock other than the
    /// immutable one, and the implementation itself cannot be initialized.
    function test_TEST_242_initializeRules() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        IAaveAdapterAdmin(adapter).initialize(timelock);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(timelock);
        AaveAdapter impl2 = new AaveAdapter(im, logics);
        vm.expectRevert(IAaveAdapterErrors.ZeroAddress.selector);
        new ERC1967Proxy(address(impl2), abi.encodeCall(AaveAdapter.initialize, (address(0))));
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.AdminRoleOnlyTimelock.selector, bytes32(0), attacker));
        new ERC1967Proxy(address(impl2), abi.encodeCall(AaveAdapter.initialize, (attacker)));
        ERC1967Proxy fresh = new ERC1967Proxy(address(impl2), abi.encodeCall(AaveAdapter.initialize, (timelock)));
        assertTrue(AaveAdapter(address(fresh)).hasRole(ADMIN, timelock), "fresh proxy initialized");
    }

    // TEST-062 verifies: REQ-ADAPTER-074, REQ-ADAPTER-004
    /// @notice Every dependency must be non-zero, and each logic contract must be of its kind and built with the same
    /// immutables (`InvalidLogic`).
    function test_TEST_062_constructorChecks() public {
        AaveAdapterImmutables memory bad;
        for (uint256 i = 0; i < 9; ++i) {
            bad = im;
            if (i == 0) bad.proxyManager = address(0);
            if (i == 1) bad.collateralization = address(0);
            if (i == 2) bad.riskModule = address(0);
            if (i == 3) bad.marketRegistry = address(0);
            if (i == 4) bad.parameterStore = address(0);
            if (i == 5) bad.lpVaultSwap = address(0);
            if (i == 6) bad.lock = address(0);
            if (i == 7) bad.vaultTokenFactory = address(0);
            if (i == 8) bad.timelock = address(0);
            vm.expectRevert(IAaveAdapterErrors.ZeroAddress.selector);
            new AaveAdapterUserLogic(bad);
        }
        AaveAdapterLogics memory swapped = logics;
        swapped.user = logics.exit;
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.InvalidLogic.selector, logics.exit));
        new AaveAdapter(im, swapped);
        AaveAdapterImmutables memory other = im;
        other.parameterStore = makeAddr("otherStore");
        AaveAdapterLogics memory foreign = logics;
        foreign.settlement = address(new AaveAdapterSettlementLogic(other));
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.InvalidLogic.selector, foreign.settlement));
        new AaveAdapter(im, foreign);
        foreign = logics;
        foreign.collateral = address(new AaveAdapterCollateralLogic(other));
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.InvalidLogic.selector, foreign.collateral));
        new AaveAdapter(im, foreign);
        foreign = logics;
        foreign.exit = address(new AaveAdapterExitLogic(other));
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.InvalidLogic.selector, foreign.exit));
        new AaveAdapter(im, foreign);
        foreign = logics;
        foreign.user = address(new AaveAdapterUserLogic(other));
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.InvalidLogic.selector, foreign.user));
        new AaveAdapter(im, foreign);
    }

    // TEST-062 verifies: REQ-ADAPTER-004, REQ-LOCK-030
    /// @notice Called directly, every logic body reverts `NotDelegated()`, and each logic contract reports its kind
    /// and the router's immutables hash.
    function test_TEST_062_logicContractsRefuseDirectCalls() public {
        bytes32 h = keccak256(abi.encode(im));
        (bytes32 kind, bytes32 hash) = IAaveAdapterLogic(logics.user).logicConfig();
        assertEq(kind, keccak256("AaveAdapterUserLogic"), "user kind");
        assertEq(hash, h, "user hash");
        (kind, hash) = IAaveAdapterLogic(logics.exit).logicConfig();
        assertEq(kind, keccak256("AaveAdapterExitLogic"), "exit kind");
        assertEq(hash, h, "exit hash");
        (kind, hash) = IAaveAdapterLogic(logics.collateral).logicConfig();
        assertEq(kind, keccak256("AaveAdapterCollateralLogic"), "collateral kind");
        assertEq(hash, h, "collateral hash");
        (kind, hash) = IAaveAdapterLogic(logics.settlement).logicConfig();
        assertEq(kind, keccak256("AaveAdapterSettlementLogic"), "settlement kind");
        assertEq(hash, h, "settlement hash");
        bytes4 nd = IAaveAdapterErrors.NotDelegated.selector;
        vm.expectRevert(nd);
        IAaveAdapterUser(logics.user).pledge(MARKET_ID, _ref(bytes32(0)), 0);
        vm.expectRevert(nd);
        IAaveAdapterUser(logics.user).borrow(MARKET_ID, 0, 1, alice, 0, 0, 0);
        vm.expectRevert(nd);
        IAaveAdapterUser(logics.user).repay(alice, MARKET_ID, 0, 1, false, 0);
        vm.expectRevert(nd);
        IAaveAdapterUser(logics.exit).withdraw(MARKET_ID, _ref(bytes32(0)), 1, 0, 0);
        vm.expectRevert(nd);
        IAaveAdapterUser(logics.exit)
            .repayAllAndWithdraw(MARKET_ID, _ref(bytes32(0)), 1, new uint256[](0), new uint256[](0), 0);
        vm.expectRevert(nd);
        IAaveAdapterUser(logics.exit).collectFees(MARKET_ID, _ref(bytes32(0)), 0);
        vm.expectRevert(nd);
        IAaveAdapterUser(logics.exit).releaseZeroCredit(MARKET_ID, _ref(bytes32(0)), 0);
        vm.expectRevert(nd);
        IAaveAdapterUser(logics.exit).refreshDebtMark(alice);
        vm.expectRevert(nd);
        IAaveAdapterCollateral(logics.collateral).removeLiquidity(MARKET_ID, _ref(bytes32(0)), 1, _mins(), 0, 0);
        vm.expectRevert(nd);
        IAaveAdapterCollateral(logics.collateral).recredit(MARKET_ID, _ref(bytes32(0)), "", 0);
        vm.expectRevert(nd);
        IAaveAdapterCollateral(logics.collateral).repayWithCollateral(_rwc(MARKET_ID, bytes32(0), 1, debtReserveId));
        vm.expectRevert(nd);
        IAaveAdapterSettlement(logics.settlement).burnSeized(MARKET_ID, vt, 1);
        vm.expectRevert(nd);
        IAaveAdapterSettlement(logics.settlement).deleverageRepay(alice, 0, 1);
        vm.expectRevert(nd);
        IAaveAdapterSettlement(logics.settlement).deleverageRelease(alice, _ref(bytes32(0)), 1, _mins());
    }

    // ─── Views ───

    // TEST-247 verifies: REQ-PROXY-049, REQ-ADAPTER-074, REQ-ADAPTER-084
    /// @notice The implementation immutables and the role identifier read back as built.
    function test_TEST_247_views() public view {
        IAaveAdapterViews v = IAaveAdapterViews(adapter);
        assertEq(v.APPLICATION_ADMIN(), AvanaRoles.APPLICATION_ADMIN, "role");
        assertEq(v.PROXY_MANAGER(), address(proxyManager), "pm");
        assertEq(v.COLLATERALIZATION(), address(coll), "coll");
        assertEq(v.RISK_MODULE(), address(risk), "risk");
        assertEq(v.MARKET_REGISTRY(), address(registry), "registry");
        assertEq(v.PARAMETER_STORE(), address(pstore), "store");
        assertEq(v.LP_VAULT_SWAP(), address(swap), "swap");
        assertEq(v.LOCK(), address(lock), "lock");
        assertEq(v.VAULT_TOKEN_FACTORY(), address(factory), "factory");
        assertEq(v.TIMELOCK(), timelock, "timelock");
        assertEq(v.borrowNonce(alice), 0, "nonce of a non-proxy");
        (address s,,,) = v.accountOf(alice);
        assertEq(s, address(0), "no account");
        assertEq(v.walletOf(alice), address(0), "no wallet");
    }

    // TEST-247 verifies: REQ-PROXY-049, REQ-PROXY-052
    /// @notice `predictProxy` equals the ProxyManager's CREATE2 prediction before the first pledge and `proxyOf`
    /// after; for a market the registry does not know it reverts like the ProxyManager.
    function test_TEST_247_predictProxy() public {
        address predicted = adapterC.predictProxy(bob, MARKET_B);
        assertEq(predicted, proxyManager.predictProxy(bob, aave.cdpSpoke, MARKET_B), "prediction");
        (, address p) = _pledgeAs(bob, MARKET_B, UNITS);
        assertEq(p, predicted, "deployed at prediction");
        registry.setBroken(true);
        assertEq(adapterC.predictProxy(bob, MARKET_B), p, "after creation: no registry read");
        registry.setBroken(false);
        vm.expectRevert();
        adapterC.predictProxy(bob, 99);
    }

    // TEST-062 verifies: REQ-ADAPTER-004
    /// @notice The ERC-7201 slot constant is the namespace's formula.
    function test_TEST_062_storageSlot() public pure {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("avana.storage.AaveAdapter")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(expected, 0x2072e6d03f11061b0cb3832feb372a04fa53d710ed44fa8554d505a1e2dbd700, "slot");
    }

    // ─── Selector inventory ───

    // TEST-031 verifies: REQ-PROXY-025, REQ-ADAPTER-007, REQ-ADAPTER-095, REQ-ADAPTER-100, REQ-ADAPTER-048, INV-018, ATTACK-027
    // Sources: 5.1 TEST-031, TEST-206, TEST-035
    /// @notice The router's dispatcher holds exactly the interface's functions plus AccessControl and UUPS: no
    /// multicall, no combined pledge-and-borrow, no sweep or rescue, no fee, pause or freeze setter, no `releaseIdle`.
    function test_TEST_031_selectorInventory() public view {
        bytes memory code = address(implementation).code;
        bytes4[] memory found = code.dispatcherSelectors(0, code.length);
        bytes4[] memory expected = _expectedSelectors();
        for (uint256 i = 0; i < expected.length; ++i) {
            assertTrue(_has(found, expected[i]), "expected selector missing");
        }
        for (uint256 i = 0; i < found.length; ++i) {
            assertTrue(_has(expected, found[i]), "unexpected selector");
        }
        assertEq(found.length, expected.length, "count");
    }

    // TEST-206 verifies: REQ-ADAPTER-100, REQ-ADAPTER-095, Q-231, Q-396
    /// @notice A call to a removed or never-existing selector (`releaseIdle`, a fee setter, a sweep) reverts at
    /// dispatch.
    function test_TEST_206_absentSelectorsRevert() public {
        bytes[5] memory calls = [
            abi.encodeWithSignature("releaseIdle(address)", alice),
            abi.encodeWithSignature("setInterestFeeBps(uint16)", uint16(10)),
            abi.encodeWithSignature("sweep(address,address)", address(debt), alice),
            abi.encodeWithSignature("multicall(bytes[])", new bytes[](0)),
            abi.encodeWithSignature("pause()")
        ];
        for (uint256 i = 0; i < calls.length; ++i) {
            (bool ok,) = adapter.call(calls[i]);
            assertFalse(ok, "absent selector reverts");
        }
    }

    // TEST-031 verifies: REQ-PROXY-008, REQ-ADAPTER-006, REQ-ADAPTER-099, REQ-RISK-088, INV-063, ATTACK-022, ATTACK-156
    // Sources: Wave 2 review decision (PositionManagerApproved: selector allowlist)
    /// @notice No code of the Adapter (router and every logic contract) holds a selector that approves, activates or
    /// renounces an Aave position manager, refreshes an account on Aave's behalf, liquidates, batches or permits.
    function test_TEST_031_noPositionManagerSelectorInAnyCode() public view {
        bytes4[10] memory forbidden = [
            bytes4(keccak256("setUserPositionManager(address,bool)")),
            bytes4(keccak256("setUserPositionManagersWithSig((address,(address,bool)[],uint256,uint256),bytes)")),
            bytes4(keccak256("renouncePositionManagerRole(address)")),
            bytes4(keccak256("multicall(bytes[])")),
            bytes4(keccak256("updateUserRiskPremium(address)")),
            bytes4(keccak256("updateUserDynamicConfig(address)")),
            bytes4(keccak256("updatePositionManager(address,bool)")),
            bytes4(keccak256("permitReserve(uint256,address,uint256,uint256,uint8,bytes32,bytes32)")),
            IAaveV4Spoke.liquidationCall.selector,
            bytes4(keccak256("setApprovalForAll(address,bool)"))
        ];
        address[5] memory codes =
            [address(implementation), logics.user, logics.exit, logics.collateral, logics.settlement];
        for (uint256 c = 0; c < codes.length; ++c) {
            bytes memory code = codes[c].code;
            for (uint256 i = 0; i < forbidden.length; ++i) {
                assertFalse(code.pushesSelector(0, code.length, forbidden[i]), "forbidden selector in Adapter code");
            }
        }
    }

    // TEST-031 verifies: REQ-PROXY-008, REQ-PROXY-010, REQ-ADAPTER-006, REQ-ADAPTER-099, INV-016, INV-063, ATTACK-022
    // Sources: Wave 2 review decision (PositionManagerApproved: selector allowlist, dynamic)
    /// @notice Across every entry point (pledge, borrow, repay, repay-all, withdraw, partial removal, re-credit, repay
    /// with collateral, repayAllAndWithdraw, fee collection, a liquidation's burn, the debt mark), every call a proxy
    /// makes goes to its own Spoke with `supply`, `setUsingAsCollateral`, `borrow`, `repay` or `withdraw` naming
    /// itself, or to its market's vault token or a debt asset with `approve(spoke, x)` or `transfer`; the Adapter
    /// itself makes no state-changing call to a Spoke or Hub.
    function test_TEST_031_proxyCallAllowlist() public {
        vm.startStateDiffRecording();
        _everyEntryPoint();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        uint256 proxyCalls = 0;
        for (uint256 i = 0; i < accesses.length; ++i) {
            VmSafe.AccountAccess memory a = accesses[i];
            if (a.kind != VmSafe.AccountAccessKind.Call) continue;
            if (adapterC.walletOf(a.accessor) != address(0)) {
                ++proxyCalls;
                _checkProxyCall(a.accessor, a.account, a.data);
            }
            if (a.accessor == adapter) {
                assertTrue(a.account != aave.cdpSpoke && a.account != aave.hub, "Adapter writes to Aave");
            }
            if (a.account == aave.cdpSpoke && a.data.length >= 4) {
                bytes4 s = bytes4(a.data);
                assertTrue(
                    s != bytes4(keccak256("setUserPositionManager(address,bool)"))
                        && s != bytes4(keccak256("renouncePositionManagerRole(address)"))
                        && s != bytes4(keccak256("multicall(bytes[])")),
                    "position-manager call"
                );
            }
        }
        assertGt(proxyCalls, 30, "proxy calls observed");
    }

    function _checkProxyCall(
        address proxy,
        address target,
        bytes memory data
    ) internal view {
        bytes4 s = bytes4(data);
        (address spoke,, address vaultToken,) = adapterC.accountOf(proxy);
        if (target == spoke) {
            assertTrue(
                s == IAaveV4Spoke.supply.selector || s == IAaveV4Spoke.setUsingAsCollateral.selector
                    || s == IAaveV4Spoke.borrow.selector || s == IAaveV4Spoke.repay.selector
                    || s == IAaveV4Spoke.withdraw.selector,
                "Spoke selector outside the set"
            );
            address onBehalfOf = _lastAddress(data);
            assertEq(onBehalfOf, proxy, "onBehalfOf is the proxy");
            return;
        }
        assertTrue(
            target == vaultToken || target == address(debt) || target == address(usdcDebt), "target outside the set"
        );
        assertTrue(s == IERC20.approve.selector || s == IERC20.transfer.selector, "token selector outside the set");
        if (s == IERC20.approve.selector) assertEq(_firstAddress(data), spoke, "approval only to the Spoke");
    }

    function _firstAddress(
        bytes memory data
    ) internal pure returns (address a) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            a := mload(add(data, 36))
        }
    }

    function _lastAddress(
        bytes memory data
    ) internal pure returns (address a) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            a := mload(add(data, mload(data)))
        }
    }

    /// @dev Runs every Adapter entry point once on two accounts.
    function _everyEntryPoint() internal {
        (bytes32 k1, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (bytes32 k2,) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 5000e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 1000e6);
        _fund(bob, debtReserveId, 100e18);
        vm.prank(bob);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 100e18, false, _deadline());
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k2), 1_000_000_000, _mins(), _deadline(), 0);
        lpVault.addUnits(k2, 500_000_000);
        vm.prank(alice);
        adapterC.recredit(MARKET_ID, _ref(k2), "", _deadline());
        swap.setDeleverage(1000e18, 2e12, 0);
        vm.prank(alice);
        adapterC.repayWithCollateral(_rwc(MARKET_ID, k2, 500_000_000, debtReserveId));
        uint256 g = _debtOf(p, debtReserveId);
        uint256 u = _debtOf(p, usdcReserveId);
        _fund(alice, debtReserveId, g);
        _fund(alice, usdcReserveId, u);
        uint256[] memory ids = new uint256[](2);
        ids[0] = debtReserveId;
        ids[1] = usdcReserveId;
        uint256[] memory caps = new uint256[](2);
        caps[0] = g;
        caps[1] = u;
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k1), UNITS, ids, caps, _deadline());
        lpVault.accrueFees(k2, 1000);
        vm.prank(alice);
        adapterC.collectFees(MARKET_ID, _ref(k2), _deadline());
        uint256 left = coll.previewRelease(INTEGRATION, k2);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), left, _deadline(), 0);
        (, address bp) = _pledgeAs(bob, MARKET_ID, UNITS);
        _borrowAs(bob, MARKET_ID, debtReserveId, 15_000e18);
        vtPrice.set(1.5e8);
        swap.liquidate(aave.cdpSpoke, MARKET_ID, vt, vtReserveId, debtReserveId, bp, 2000e18, 2);
        vm.prank(carol);
        adapterC.refreshDebtMark(bp);
    }

    function _expectedSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](40);
        s[0] = IAaveAdapterUser.pledge.selector;
        s[1] = IAaveAdapterUser.borrow.selector;
        s[2] = IAaveAdapterUser.repay.selector;
        s[3] = IAaveAdapterUser.withdraw.selector;
        s[4] = IAaveAdapterUser.repayAllAndWithdraw.selector;
        s[5] = IAaveAdapterUser.releaseZeroCredit.selector;
        s[6] = IAaveAdapterUser.collectFees.selector;
        s[7] = IAaveAdapterUser.refreshDebtMark.selector;
        s[8] = IAaveAdapterCollateral.removeLiquidity.selector;
        s[9] = IAaveAdapterCollateral.recredit.selector;
        s[10] = IAaveAdapterCollateral.repayWithCollateral.selector;
        s[11] = IAaveAdapterSettlement.burnSeized.selector;
        s[12] = IAaveAdapterSettlement.deleverageRepay.selector;
        s[13] = IAaveAdapterSettlement.deleverageRelease.selector;
        s[14] = IAaveAdapterAdmin.initialize.selector;
        s[15] = IAaveAdapterViews.proxyOf.selector;
        s[16] = IAaveAdapterViews.walletOf.selector;
        s[17] = IAaveAdapterViews.accountOf.selector;
        s[18] = IAaveAdapterViews.predictProxy.selector;
        s[19] = IAaveAdapterViews.borrowNonce.selector;
        s[20] = IAaveAdapterViews.APPLICATION_ADMIN.selector;
        s[21] = IAaveAdapterViews.PROXY_MANAGER.selector;
        s[22] = IAaveAdapterViews.COLLATERALIZATION.selector;
        s[23] = IAaveAdapterViews.RISK_MODULE.selector;
        s[24] = IAaveAdapterViews.MARKET_REGISTRY.selector;
        s[25] = IAaveAdapterViews.PARAMETER_STORE.selector;
        s[26] = IAaveAdapterViews.LP_VAULT_SWAP.selector;
        s[27] = IAaveAdapterViews.LOCK.selector;
        s[28] = IAaveAdapterViews.VAULT_TOKEN_FACTORY.selector;
        s[29] = IAaveAdapterViews.TIMELOCK.selector;
        s[30] = IAccessControl.hasRole.selector;
        s[31] = IAccessControl.getRoleAdmin.selector;
        s[32] = IAccessControl.grantRole.selector;
        s[33] = IAccessControl.revokeRole.selector;
        s[34] = IAccessControl.renounceRole.selector;
        s[35] = UUPSUpgradeable.upgradeToAndCall.selector;
        s[36] = UUPSUpgradeable.proxiableUUID.selector;
        s[37] = bytes4(keccak256("supportsInterface(bytes4)"));
        s[38] = bytes4(keccak256("UPGRADE_INTERFACE_VERSION()"));
        s[39] = bytes4(keccak256("DEFAULT_ADMIN_ROLE()"));
    }

    function _has(
        bytes4[] memory set,
        bytes4 s
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < set.length; ++i) {
            if (set[i] == s) return true;
        }
        return false;
    }

    // TEST-026 verifies: REQ-ADAPTER-066, REQ-PROXY-033, REQ-PROXY-057, INV-063
    /// @notice Every proxy-acting entry point resolves the account from `msg.sender` (or the named borrower for
    /// repay): a wallet without an account gets `NoProxy` from each, and a proxy itself cannot act through the Adapter.
    function test_TEST_026_entryPointsResolveFromCaller() public {
        (bytes32 k, address p) = _pledgeAs(alice, MARKET_ID, UNITS);
        uint256 d = _deadline();
        bytes memory noProxy = abi.encodeWithSelector(IAaveAdapterErrors.NoProxy.selector, attacker, MARKET_ID);
        vm.startPrank(attacker);
        vm.expectRevert(noProxy);
        adapterC.withdraw(MARKET_ID, _ref(k), UNITS, d, 0);
        vm.expectRevert(noProxy);
        adapterC.removeLiquidity(MARKET_ID, _ref(k), 1, _mins(), d, 0);
        vm.expectRevert(noProxy);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k), UNITS, new uint256[](0), new uint256[](0), d);
        vm.expectRevert(noProxy);
        adapterC.recredit(MARKET_ID, _ref(k), "", d);
        vm.expectRevert(noProxy);
        adapterC.repayWithCollateral(_rwc(MARKET_ID, k, 1, debtReserveId));
        vm.expectRevert(noProxy);
        adapterC.collectFees(MARKET_ID, _ref(k), d);
        vm.expectRevert(noProxy);
        adapterC.releaseZeroCredit(MARKET_ID, _ref(k), d);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.NoProxy.selector, p, MARKET_ID));
        vm.prank(p);
        adapterC.withdraw(MARKET_ID, _ref(k), UNITS, d, 0);
        assertEq(_sharesOf(p, vtReserveId), UNITS, "alice untouched");
    }
}
