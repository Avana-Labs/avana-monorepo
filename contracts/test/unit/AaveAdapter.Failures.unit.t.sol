// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AaveAdapter} from "../../src/policy/aave-adapter/AaveAdapter.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {BrokenAdapter} from "../utils/mocks/BrokenAdapter.sol";
import {HostileAdapter} from "../utils/mocks/HostileAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IFailSpokeConfigurator {
    function updatePaused(
        address spoke,
        uint256 reserveId,
        bool paused
    ) external;
}

/// @title AaveAdapterFailuresUnitTest
/// @notice The account steps' own failure conditions on the real Aave V4 Spoke (a reserve left disabled after the
/// enable step, a short or long withdrawal, a supply that leaves an allowance or adds no shares, a token call that
/// returns false), an Adapter implementation that reverts on every call and its repair by upgrade (REQ-ADAPTER-060),
/// and the attempts REQ-ADAPTER-043 names for a hostile implementation, each with its outcome.
/// forge-config: default.isolate = false
contract AaveAdapterFailuresUnitTest is AaveAdapterFixture {
    bytes32 internal k1;
    address internal p;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
    }

    // ─── Supply step ───

    // TEST-010 verifies: REQ-PROXY-074, REQ-PROXY-043, REQ-PROXY-095
    /// @notice When the Spoke still reports the reserve disabled after the enable step, the pledge reverts
    /// `CollateralNotEnabled(reserveId)` and nothing is minted or custodied.
    function test_TEST_010_collateralNotEnabled() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, bob, MARKET_ID, UNITS);
        address predicted = adapterC.predictProxy(bob, MARKET_ID);
        vm.mockCall(
            aave.cdpSpoke,
            abi.encodeCall(IAaveV4Spoke.getUserReserveStatus, (vtReserveId, predicted)),
            abi.encode(false, false)
        );
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.CollateralNotEnabled.selector, vtReserveId));
        vm.prank(bob);
        adapterC.pledge(MARKET_ID, _ref(key), d);
        assertEq(lpVault.ownerOf(key), bob, "no custody");
        assertEq(token.totalSupply(), UNITS, "nothing minted");
    }

    // TEST-010 verifies: REQ-PROXY-043
    /// @notice A top-up into an account whose reserve is already enabled makes no second enable call.
    function test_TEST_010_enabledReserveNotReEnabled() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        vm.expectCall(aave.cdpSpoke, abi.encodeWithSelector(IAaveV4Spoke.setUsingAsCollateral.selector), 0);
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), _deadline());
    }

    // TEST-010 verifies: REQ-PROXY-042, REQ-PROXY-094, REQ-ADAPTER-007
    /// @notice A supply that leaves an allowance to the Spoke (the reset not taking effect) reverts
    /// `BalanceDeltaMismatch`.
    function test_TEST_010_allowanceLeftReverts() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        vm.mockCall(vt, abi.encodeCall(IERC20.allowance, (p, aave.cdpSpoke)), abi.encode(uint256(1)));
        uint256 d = _deadline();
        vm.expectRevert(IAaveAdapterErrors.BalanceDeltaMismatch.selector);
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
    }

    // TEST-186 verifies: REQ-ADAPTER-068, REQ-PROXY-072, SPEC-PROXY-008, REQ-VAULT-111
    /// @notice A supply that does not raise the proxy's supplied shares by exactly the credited units reverts
    /// `SupplyIncomplete`.
    function test_TEST_186_sharesNotRaisedReverts() public {
        bytes32 key = _newKey();
        lpVault.mintPosition(key, alice, MARKET_ID, UNITS);
        vm.mockCall(
            aave.cdpSpoke,
            abi.encodeCall(IAaveV4Spoke.getUserSuppliedShares, (vtReserveId, p)),
            abi.encode(uint256(UNITS))
        );
        uint256 d = _deadline();
        vm.expectRevert(IAaveAdapterErrors.SupplyIncomplete.selector);
        vm.prank(alice);
        adapterC.pledge(MARKET_ID, _ref(key), d);
    }

    // ─── Withdrawal step ───

    // TEST-018 verifies: REQ-PROXY-089, REQ-PROXY-094, REQ-PROXY-072, SPEC-PROXY-005
    /// @notice A Spoke that reports withdrawing another amount than `units` makes the withdrawal revert
    /// `UnitsMismatch(units, reported)`; one that reports `units` but pays nothing reverts `UnitsMismatch(units, 0)`.
    function test_TEST_018_withdrawAmountChecks() public {
        bytes memory call = abi.encodeCall(IAaveV4Spoke.withdraw, (vtReserveId, UNITS, p));
        vm.mockCall(aave.cdpSpoke, call, abi.encode(uint256(UNITS), uint256(UNITS - 1)));
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnitsMismatch.selector, UNITS, UNITS - 1));
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, d, 0);
        vm.mockCall(aave.cdpSpoke, call, abi.encode(uint256(UNITS), uint256(UNITS)));
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnitsMismatch.selector, UNITS, 0));
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, d, 0);
        vm.clearMockedCalls();
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, d, 0);
    }

    // ─── Token calls through the proxy ───

    // TEST-027 verifies: REQ-PROXY-087, REQ-PROXY-023
    /// @notice A debt asset whose `transfer` returns false fails the forwarding with SafeERC20's error, undoing the
    /// borrow.
    function test_TEST_027_falseTransferReverts() public {
        vm.mockCall(address(debt), abi.encodeCall(IERC20.transfer, (alice, 1e18)), abi.encode(false));
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(debt)));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, d, 0, 0);
        assertEq(_debtOf(p, debtReserveId), 0, "borrow undone");
    }

    // TEST-029 verifies: REQ-PROXY-088, REQ-PROXY-094
    /// @notice A repay whose approval reset leaves an allowance reverts `BalanceDeltaMismatch`; an approval that
    /// returns false reverts SafeERC20's error.
    function test_TEST_029_repayStepChecks() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 100e18);
        _fund(alice, debtReserveId, 50e18);
        vm.mockCall(address(debt), abi.encodeCall(IERC20.allowance, (p, aave.cdpSpoke)), abi.encode(uint256(1)));
        uint256 d = _deadline();
        vm.expectRevert(IAaveAdapterErrors.BalanceDeltaMismatch.selector);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 50e18, false, d);
        vm.clearMockedCalls();
        vm.mockCall(address(debt), abi.encodeCall(IERC20.approve, (aave.cdpSpoke, 50e18)), abi.encode(false));
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(debt)));
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 50e18, false, d);
    }

    // ─── REQ-ADAPTER-060: a broken implementation and its repair ───

    // TEST-195 verifies: REQ-ADAPTER-060, REQ-ADAPTER-001, REQ-ADAPTER-003, REQ-ADAPTER-099, REQ-PROXY-086
    // Sources: 2.6 REQ-ADAPTER-060
    /// @notice An implementation that reverts on every call stops every entry point, the seized-unit burn of a
    /// liquidation included; positions stay in custody, records and supplied shares are unchanged, and an upgrade to a
    /// working implementation restores every exit for the same proxies.
    function test_TEST_195_brokenImplementationAndRepair() public {
        (bytes32 kB, address pB) = _pledgeAs(bob, MARKET_ID, UNITS);
        _borrowAs(bob, MARKET_ID, debtReserveId, 15_000e18);
        BrokenAdapter broken = new BrokenAdapter();
        vm.prank(timelock);
        AaveAdapter(adapter).upgradeToAndCall(address(broken), "");
        uint256 d = _deadline();
        bytes4 b = BrokenAdapter.Broken.selector;
        vm.startPrank(alice);
        vm.expectRevert(b);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, d, 0);
        vm.expectRevert(b);
        adapterC.borrow(MARKET_ID, debtReserveId, 1, alice, d, 0, 0);
        vm.expectRevert(b);
        adapterC.repay(bob, MARKET_ID, debtReserveId, 1, false, d);
        vm.expectRevert(b);
        adapterC.collectFees(MARKET_ID, _ref(k1), d);
        vm.expectRevert(b);
        adapterC.releaseZeroCredit(MARKET_ID, _ref(k1), d);
        vm.expectRevert(b);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), 1, _mins(), d, 0);
        vm.expectRevert(b);
        adapterC.refreshDebtMark(p);
        vm.stopPrank();
        vtPrice.set(1.5e8);
        vm.expectRevert(b);
        swap.liquidate(aave.cdpSpoke, MARKET_ID, vt, vtReserveId, debtReserveId, pB, 1000e18, 2);
        vtPrice.set(2e8);
        assertEq(lpVault.depositorOf(k1), alice, "k1 in custody");
        assertEq(lpVault.depositorOf(kB), bob, "kB in custody");
        assertEq(_sharesOf(p, vtReserveId), UNITS, "alice shares");
        assertEq(coll.getTotalCredited(vt), 2 * uint256(UNITS), "records unchanged");
        vm.expectRevert(b);
        adapterC.proxyOf(alice, MARKET_ID);
        // The fix: an upgrade to a working implementation, at the normal delay in production.
        vm.prank(timelock);
        AaveAdapter(adapter).upgradeToAndCall(address(implementation), "");
        assertEq(adapterC.proxyOf(alice, MARKET_ID), p, "binding kept");
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, _deadline(), 0);
        assertEq(lpVault.ownerOf(k1), alice, "exit restored");
        uint256 g = _debtOf(pB, debtReserveId);
        _fund(bob, debtReserveId, g);
        vm.prank(bob);
        adapterC.repay(bob, MARKET_ID, debtReserveId, g, true, _deadline());
        assertEq(_debtOf(pB, debtReserveId), 0, "repay restored");
    }

    // TEST-195 verifies: REQ-ADAPTER-060, REQ-ADAPTER-003
    /// @notice Even broken, the implementation upgrades only through `APPLICATION_ADMIN`.
    function test_TEST_195_brokenStillGatesUpgrade() public {
        BrokenAdapter broken = new BrokenAdapter();
        vm.prank(timelock);
        AaveAdapter(adapter).upgradeToAndCall(address(broken), "");
        vm.expectRevert();
        vm.prank(attacker);
        AaveAdapter(adapter).upgradeToAndCall(address(implementation), "");
    }

    // ─── REQ-ADAPTER-043: the hostile-implementation attempts ───

    function _installHostile() internal returns (HostileAdapter h) {
        HostileAdapter impl = new HostileAdapter();
        vm.prank(timelock);
        AaveAdapter(adapter).upgradeToAndCall(address(impl), "");
        h = HostileAdapter(adapter);
    }

    // TEST-130 verifies: REQ-ADAPTER-043, REQ-ADAPTER-040, REQ-ADAPTER-069, INV-080, ATTACK-011
    /// @notice Mint beyond credited: a hostile implementation can mint to a registered proxy, and the next honest
    /// call in that market (after the timelock restores a reviewed implementation) detects the unbacked supply with
    /// `BackingMismatch`.
    function test_TEST_130_mintBeyondCreditedDetected() public {
        HostileAdapter h = _installHostile();
        h.mintTo(vt, p, 777);
        assertEq(token.totalSupply(), UNITS + 777, "unbacked units exist");
        vm.prank(timelock);
        AaveAdapter(adapter).upgradeToAndCall(address(implementation), "");
        bytes32 key = _newKey();
        lpVault.mintPosition(key, bob, MARKET_ID, UNITS);
        uint256 d = _deadline();
        vm.expectRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.BackingMismatch.selector, 2 * UNITS + 777, 2 * UNITS, 0)
        );
        vm.prank(bob);
        adapterC.pledge(MARKET_ID, _ref(key), d);
    }

    // TEST-130 verifies: REQ-ADAPTER-043, REQ-VTOKEN-007, INV-010, ATTACK-124
    /// @notice Burn from the Hub: the vault token refuses a burn from any holder that is not a registered proxy or
    /// LPVaultSwap, so the Hub's units stay.
    function test_TEST_130_burnFromHubRefused() public {
        HostileAdapter h = _installHostile();
        uint256 hubUnits = token.balanceOf(aave.hub);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, aave.hub, address(0)));
        h.burnFrom(vt, aave.hub, 1);
        assertEq(token.balanceOf(aave.hub), hubUnits, "hub units kept");
    }

    // TEST-130 verifies: REQ-ADAPTER-043, REQ-ADAPTER-040, INV-012
    /// @notice Register a rogue proxy: any non-reserved address can be registered (the stated blast radius), a
    /// reserved one (the Hub, the vault token) cannot.
    function test_TEST_130_rogueRegistration() public {
        HostileAdapter h = _installHostile();
        h.register(vt, attacker);
        assertTrue(token.isValidProxy(attacker), "rogue registered");
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.ReservedAddress.selector, aave.hub));
        h.register(vt, aave.hub);
    }

    // TEST-130 verifies: REQ-ADAPTER-043, REQ-ADAPTER-040, REQ-ADAPTER-042, ATTACK-032
    /// @notice Borrow on another account: the hostile implementation can borrow against a victim's proxy, bounded by
    /// Aave's health factor and the Spoke's draw cap.
    function test_TEST_130_borrowOnAnotherAccountBounded() public {
        HostileAdapter h = _installHostile();
        h.borrowAgainst(p, aave.cdpSpoke, debtReserveId, 15_000e18, attacker);
        assertEq(debt.balanceOf(attacker), 15_000e18, "drawn");
        vm.expectRevert();
        h.borrowAgainst(p, aave.cdpSpoke, debtReserveId, 1001e18, attacker);
        assertGe(_hf(p), 1e18, "Aave health factor holds");
    }

    // TEST-130 verifies: REQ-ADAPTER-043, REQ-ADAPTER-041, INV-007, ATTACK-022
    /// @notice Send a position elsewhere: the LPVault refuses a direct call, and Collateralization's release returns
    /// the position to its depositor of record only.
    function test_TEST_130_positionOnlyToDepositor() public {
        HostileAdapter h = _installHostile();
        (bool direct,) = h.callAs(address(lpVault), abi.encodeWithSignature("returnPosition(bytes32)", k1));
        assertFalse(direct, "LPVault refuses");
        h.withdrawUnits(p, aave.cdpSpoke, vtReserveId, UNITS);
        h.burnFrom(vt, p, UNITS);
        h.releaseRecord(address(lock), address(coll), p, vt, k1, UNITS);
        assertEq(lpVault.ownerOf(k1), alice, "only to the depositor");
        assertEq(debt.balanceOf(attacker), 0, "nothing to the attacker");
    }

    // TEST-130 verifies: REQ-ADAPTER-043, REQ-ADAPTER-041, REQ-ADAPTER-006
    /// @notice Change a Spoke setting: impossible from the Adapter or through a proxy (the configurator answers only
    /// Aave's roles).
    function test_TEST_130_spokeSettingImpossible() public {
        HostileAdapter h = _installHostile();
        bytes memory pause = abi.encodeCall(IFailSpokeConfigurator.updatePaused, (aave.cdpSpoke, vtReserveId, true));
        (bool ok,) = h.callAs(aave.spokeConfigurator, pause);
        assertFalse(ok, "from the Adapter");
        vm.expectRevert();
        h.execAs(p, aave.spokeConfigurator, pause);
        assertFalse(IAaveV4Spoke(aave.cdpSpoke).getReserveConfig(vtReserveId).paused, "unchanged");
    }

    // TEST-208 verifies: REQ-ADAPTER-070, REQ-ADAPTER-047, REQ-ADAPTER-086
    /// @notice `burnSeized` reads no registry and no RiskModule: it burns with both reverting on every call.
    function test_TEST_208_burnSeizedIgnoresStops() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 15_000e18);
        vtPrice.set(1.5e8);
        uint256 seized = swap.seizeAndKeep(aave.cdpSpoke, vt, vtReserveId, debtReserveId, p, 1000e18);
        registry.setBroken(true);
        risk.setBroken(true);
        vm.expectCall(address(registry), "", 0);
        vm.expectCall(address(risk), "", 0);
        swap.burnUnderLock(MARKET_ID, vt, seized);
        assertEq(token.balanceOf(address(swap)), 0, "burned");
    }
}
