// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationUser} from "../../src/custody/collateralization/ICollateralizationUser.sol";
import {AvanaTimelock} from "../../src/governance/timelock/AvanaTimelock.sol";
import {SelectorPair} from "../../src/governance/timelock/types/SelectorPair.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {IPositionProxy} from "../../src/proxy/position-proxy/IPositionProxy.sol";
import {IProxyManager} from "../../src/proxy/proxy-manager/IProxyManager.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {AdapterRiskModuleMock} from "../utils/mocks/AaveAdapterMocks.sol";
import {HostileAdapter} from "../utils/mocks/HostileAdapter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @dev Aave V4 position-manager entry points of the pinned Spoke, used to show what a hostile Adapter can and cannot
/// do through a proxy.
interface ISpokeManagers {
    function setUserPositionManager(
        address positionManager,
        bool approve
    ) external;

    function isPositionManager(
        address user,
        address positionManager
    ) external view returns (bool);
}

interface ISpokeConfiguratorManagers {
    function updatePositionManager(
        address spoke,
        address positionManager,
        bool active
    ) external;
}

/// @title AaveAdapterHostileUnitTest
/// @notice A hostile Adapter upgrade through the real AvanaTimelock and the borrower's exit inside its delay (TEST-195,
/// TEST-210); what the hostile implementation can and cannot do once executed (TEST-130); a RiskModule that approves or
/// refuses everything (TEST-132, TEST-156); a MarketRegistry that answers nothing useful or reverts (TEST-243).
/// @dev The Adapter's `TIMELOCK` is a real AvanaTimelock built before the fixture (normal delay 5 days, the governance
/// multisig and the Aave governance executor as proposers, the Emergency Guardian and the Aave Protocol Guardian as
/// cancellers, public execution).
/// forge-config: default.isolate = false
contract AaveAdapterHostileUnitTest is AaveAdapterFixture {
    AvanaTimelock internal tl;
    HostileAdapter internal hostile;
    bytes32 internal kA1;
    bytes32 internal kA2;
    bytes32 internal kB;
    address internal pA;
    address internal pAB;

    function setUp() public override {
        address[] memory proposers = new address[](2);
        (proposers[0], proposers[1]) = (governanceMultisig, aaveGovernanceExecutor);
        address[] memory executors = new address[](1);
        executors[0] = governanceMultisig;
        address[] memory cancellers = new address[](2);
        (cancellers[0], cancellers[1]) = (emergencyGuardian, aaveGuardian);
        address[] memory daoCancellers = new address[](1);
        daoCancellers[0] = aaveGovernanceExecutor;
        tl = new AvanaTimelock(
            proposers,
            executors,
            cancellers,
            daoCancellers,
            NORMAL_DELAY,
            true,
            new SelectorPair[](0),
            new SelectorPair[](0)
        );
        timelock = address(tl);
        super.setUp();
        hostile = new HostileAdapter();
        // Alice: three positions in two markets, 3,000 GHO and 2,000 USDC of debt on market A.
        (kA1, pA) = _pledgeAs(alice, MARKET_ID, UNITS);
        (kA2,) = _pledgeAs(alice, MARKET_ID, UNITS / 2);
        (kB, pAB) = _pledgeAs(alice, MARKET_B, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 3000e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 2000e6);
        vm.warp(block.timestamp + 1 days);
    }

    function _upgradeCall() internal view returns (bytes memory) {
        return abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(hostile), ""));
    }

    function _schedule(
        bytes32 salt
    ) internal returns (bytes32 id) {
        bytes memory data = _upgradeCall();
        assertEq(tl.requiredDelay(_targets(), _payloads(data)), NORMAL_DELAY, "normal delay");
        vm.prank(governanceMultisig);
        tl.schedule(adapter, 0, data, bytes32(0), salt, NORMAL_DELAY);
        id = tl.hashOperation(adapter, 0, data, bytes32(0), salt);
    }

    function _targets() internal view returns (address[] memory t) {
        t = new address[](1);
        t[0] = adapter;
    }

    function _payloads(
        bytes memory data
    ) internal pure returns (bytes[] memory p) {
        p = new bytes[](1);
        p[0] = data;
    }

    function _installHostile() internal {
        _schedule(bytes32("install"));
        vm.warp(block.timestamp + NORMAL_DELAY);
        vm.prank(attacker);
        tl.execute(adapter, 0, _upgradeCall(), bytes32(0), bytes32("install"));
        bytes32 slot = vm.load(adapter, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc);
        assertEq(address(uint160(uint256(slot))), address(hostile), "hostile installed");
    }

    /// @dev The borrower's exit: one repay per debt reserve (exact approvals) and one withdrawal per position.
    function _exitEverything() internal returns (uint256 calls) {
        uint256[2] memory reserves = [debtReserveId, usdcReserveId];
        for (uint256 i = 0; i < 2; ++i) {
            uint256 d = _debtOf(pA, reserves[i]);
            _fund(alice, reserves[i], d);
            vm.prank(alice);
            adapterC.repay(alice, MARKET_ID, reserves[i], d, true, _deadline());
            ++calls;
        }
        vm.startPrank(alice);
        adapterC.withdraw(MARKET_ID, _ref(kA1), UNITS, _deadline(), 0);
        adapterC.withdraw(MARKET_ID, _ref(kA2), UNITS / 2, _deadline(), 0);
        adapterC.withdraw(MARKET_B, _ref(kB), UNITS, _deadline(), 0);
        vm.stopPrank();
        calls += 3;
    }

    // ─── Exit inside the delay ───

    // TEST-195 verifies: REQ-ADAPTER-042, REQ-ADAPTER-003, REQ-ADAPTER-047, REQ-ACCESS-148, REQ-PROXY-035, INV-045, ATTACK-122
    // Sources: 5.1 TEST-195, Q-228
    /// @notice The governance multisig schedules an upgrade to a hostile implementation at the normal delay; the
    /// Emergency Guardian pauses the Hub at once; the borrower repays both reserves and withdraws all three positions
    /// while Paused and well inside the delay, in five calls; then a canceller cancels the operation.
    function test_TEST_195_exitInsideDelayThenCancel() public {
        bytes32 id = _schedule(bytes32("hostile"));
        registry.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        uint256 readyAt = tl.getTimestamp(id);
        vm.warp(block.timestamp + 2 hours);
        uint256 calls = _exitEverything();
        assertEq(calls, 5, "two repays and three withdrawals");
        assertLt(block.timestamp, readyAt, "inside the delay");
        assertEq(lpVault.ownerOf(kA1), alice, "position 1");
        assertEq(lpVault.ownerOf(kA2), alice, "position 2");
        assertEq(lpVault.ownerOf(kB), alice, "position 3");
        assertEq(_borrowCountOf(pA), 0, "no debt");
        assertTrue(tl.isOperationPending(id), "still pending");
        vm.prank(emergencyGuardian);
        tl.cancel(id);
        assertFalse(tl.isOperation(id), "cancelled");
    }

    // TEST-195 verifies: REQ-ADAPTER-042, REQ-ADAPTER-040, INV-018, ATTACK-122
    // Sources: 5.1 TEST-195 (second run)
    /// @notice Second run: the borrower leaves inside the delay, the operation becomes ready and executes, and the
    /// hostile implementation finds no position and no collateral to act on.
    function test_TEST_195_readyOperationFindsNothing() public {
        _schedule(bytes32("install"));
        _exitEverything();
        vm.warp(block.timestamp + NORMAL_DELAY);
        vm.prank(attacker);
        tl.execute(adapter, 0, _upgradeCall(), bytes32(0), bytes32("install"));
        HostileAdapter h = HostileAdapter(adapter);
        vm.expectRevert();
        h.borrowAgainst(pA, aave.cdpSpoke, debtReserveId, 1e18, attacker);
        vm.expectRevert();
        h.releaseRecord(address(lock), address(coll), pA, vt, kA1, UNITS);
        assertEq(token.totalSupply() + tokenB.totalSupply(), 0, "no unit left to take");
        assertEq(lpVault.ownerOf(kA1), alice, "position stays with alice");
    }

    // TEST-210 verifies: REQ-ADAPTER-003, REQ-ADAPTER-042, REQ-ACCESS-148
    // Sources: 5.1 TEST-210
    /// @notice Every canceller of the Adapter upgrade (the two proposers and the two guardians) can cancel it inside
    /// the delay, and nobody can execute it early.
    function test_TEST_210_everyCancellerCancels() public {
        address[4] memory cancellers = [governanceMultisig, aaveGovernanceExecutor, emergencyGuardian, aaveGuardian];
        for (uint256 i = 0; i < cancellers.length; ++i) {
            bytes32 salt = bytes32(i + 1);
            bytes32 id = _schedule(salt);
            vm.expectRevert();
            tl.execute(adapter, 0, _upgradeCall(), bytes32(0), salt);
            vm.prank(cancellers[i]);
            tl.cancel(id);
            assertFalse(tl.isOperation(id), "cancelled");
        }
        vm.expectRevert();
        vm.prank(attacker);
        tl.cancel(bytes32(uint256(1)));
    }

    // ─── What a hostile implementation can and cannot do ───

    // TEST-130 verifies: REQ-ADAPTER-040, REQ-ADAPTER-041, REQ-PROXY-086, INV-018, ATTACK-122, ATTACK-032
    // Sources: 5.1 TEST-130, TEST-210
    /// @notice Once executed, the hostile Adapter can make a proxy borrow to the attacker, but only within Aave's own
    /// health factor and the Spoke's draw cap.
    function test_TEST_130_borrowBoundedByAave() public {
        _installHostile();
        HostileAdapter h = HostileAdapter(adapter);
        // Alice's market-A account: $30,000 at CF 80% = $24,000 against 3,000 GHO and 2,000 USDC.
        h.borrowAgainst(pA, aave.cdpSpoke, debtReserveId, 10_000e18, attacker);
        assertEq(debt.balanceOf(attacker), 10_000e18, "taken");
        assertGe(_hf(pA), 1e18, "Aave keeps HF >= 1");
        vm.expectRevert();
        h.borrowAgainst(pA, aave.cdpSpoke, debtReserveId, 10_000e18, attacker);
        uint256 cap = uint256(IAaveV4Hub(aave.hub).getSpokeConfig(ghoAssetId, aave.cdpSpoke).drawCap) * 1e18;
        assertLe(IAaveV4Hub(aave.hub).getSpokeTotalOwed(ghoAssetId, aave.cdpSpoke), cap, "within drawCap");
    }

    // TEST-130 verifies: REQ-ADAPTER-040, REQ-ADAPTER-005, REQ-VTOKEN-007, INV-009, INV-012, ATTACK-124
    /// @notice It can mint to a registered proxy, register any non-reserved address, burn any holder's units and
    /// withdraw supplied units into a proxy; it cannot register a Hub, mint to an unregistered address, or supply
    /// beyond the Hub's add cap.
    function test_TEST_130_mintBurnRegisterBounds() public {
        _installHostile();
        HostileAdapter h = HostileAdapter(adapter);
        vm.expectRevert();
        h.mintTo(vt, attacker, 1e6);
        h.register(vt, attacker);
        h.mintTo(vt, attacker, 1e6);
        assertEq(token.balanceOf(attacker), 1e6, "minted to a registered address");
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.ReservedAddress.selector, aave.hub));
        h.register(vt, aave.hub);
        h.withdrawUnits(pAB, aave.cdpSpoke, vtReserveIdB, UNITS);
        assertEq(tokenB.balanceOf(pAB), UNITS, "units land in the proxy, not with the attacker");
        h.burnFrom(vtB, pAB, UNITS);
        assertEq(tokenB.totalSupply(), 0, "burned");
        uint256 overCap = 5_500_001e6;
        h.mintTo(vt, pA, overCap);
        vm.expectRevert();
        h.supplyUnits(pA, aave.cdpSpoke, vt, vtReserveId, overCap);
    }

    // TEST-130 verifies: REQ-ADAPTER-041, INV-007, ATTACK-122, ATTACK-022
    /// @notice It cannot send a position to anyone but its depositor: Collateralization releases only to the
    /// depositor of record, the LPVault refuses a direct call, and fee collection pays only the depositor.
    function test_TEST_130_positionsOnlyToDepositor() public {
        _installHostile();
        HostileAdapter h = HostileAdapter(adapter);
        (bool ok,) = address(h)
            .call(abi.encodeCall(HostileAdapter.releaseRecord, (address(lock), address(coll), pA, vt, kA1, UNITS)));
        address owner = lpVault.ownerOf(kA1);
        assertTrue(owner == alice || owner == address(lpVault), "position only in custody or with alice");
        assertTrue(ok || owner == address(lpVault), "a failed release leaves it in custody");
        (bool direct,) = h.callAs(address(lpVault), abi.encodeWithSignature("returnPosition(bytes32)", kA2));
        assertFalse(direct, "LPVault refuses the Adapter directly");
        lpVault.accrueFees(kA2, 100);
        vm.prank(adapter);
        lock.acquire();
        vm.expectRevert();
        vm.prank(adapter);
        ICollateralizationUser(address(coll)).collectFees(attacker, vt, kA2);
        vm.prank(adapter);
        lock.release();
        assertEq(usdc.balanceOf(attacker), 0, "no fees to the attacker");
    }

    // TEST-130 verifies: REQ-ADAPTER-041, REQ-PROXY-086, REQ-PROXY-091, INV-016, INV-065, ATTACK-172
    /// @notice It cannot change a Spoke setting, a proxy's binding or code, or deploy a second proxy for a bound
    /// triple; an approval it makes a proxy grant is inert until the Aave DAO activates that manager.
    function test_TEST_130_noSpokeSettingNoRebinding() public {
        _installHostile();
        HostileAdapter h = HostileAdapter(adapter);
        bytes memory activate =
            abi.encodeCall(ISpokeConfiguratorManagers.updatePositionManager, (aave.cdpSpoke, attacker, true));
        (bool ok,) = h.callAs(aave.spokeConfigurator, activate);
        assertFalse(ok, "no Spoke setting from the Adapter");
        vm.expectRevert();
        h.execAs(pA, aave.spokeConfigurator, activate);
        bytes32 codeHash = pA.codehash;
        vm.expectRevert(abi.encodeWithSelector(IPositionProxy.InvalidTarget.selector, address(proxyManager)));
        h.execAs(pA, address(proxyManager), abi.encodeCall(IProxyManager.deployProxy, (attacker, aave.cdpSpoke, 1)));
        (bool deployed, bytes memory err) = h.callAs(
            address(proxyManager), abi.encodeCall(IProxyManager.deployProxy, (alice, aave.cdpSpoke, MARKET_ID))
        );
        assertFalse(deployed, "no second proxy");
        assertEq(err, abi.encodeWithSelector(IProxyManager.ProxyExists.selector, alice, aave.cdpSpoke, MARKET_ID));
        assertEq(IPositionProxy(pA).WALLET(), alice, "wallet");
        assertEq(IPositionProxy(pA).SPOKE(), aave.cdpSpoke, "spoke");
        assertEq(IPositionProxy(pA).MARKET_ID(), MARKET_ID, "market");
        assertEq(pA.codehash, codeHash, "code");
        h.execAs(pA, aave.cdpSpoke, abi.encodeCall(ISpokeManagers.setUserPositionManager, (attacker, true)));
        assertFalse(ISpokeManagers(aave.cdpSpoke).isPositionManager(pA, attacker), "inactive manager");
        vm.expectRevert(bytes4(keccak256("Unauthorized()")));
        vm.prank(attacker);
        IAaveV4Spoke(aave.cdpSpoke).borrow(debtReserveId, 1e18, pA);
    }

    // ─── Hostile RiskModule ───

    // TEST-132 verifies: REQ-PROXY-026, REQ-ADAPTER-008, REQ-ADAPTER-040, ATTACK-034, INV-025
    // Sources: 5.1 TEST-132, TEST-156
    /// @notice A RiskModule that approves everything lets a borrow ignore the caller's minimum, but Aave still refuses
    /// a health factor below 1, the draw cap holds, and the Adapter still enforces the nonce, the deadline, the receiver
    /// rule and the proxy resolution.
    function test_TEST_132_approveAllRiskModule() public {
        risk.setApproveAll(true);
        uint256 d = _deadline();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1000e18, alice, d, 100e18, 2);
        assertEq(adapterC.borrowNonce(pA), 3, "borrowed past the caller minimum");
        vm.expectRevert();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 30_000e18, alice, d, 0, 3);
        assertGe(_hf(pA), 1e18, "Aave HF >= 1");
        uint256 cap = uint256(IAaveV4Hub(aave.hub).getSpokeConfig(ghoAssetId, aave.cdpSpoke).drawCap) * 1e18;
        assertLe(IAaveV4Hub(aave.hub).getSpokeTotalOwed(ghoAssetId, aave.cdpSpoke), cap, "drawCap");
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.BadNonce.selector, 3, 0));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, d, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DeadlineExpired.selector, block.timestamp - 1));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, block.timestamp - 1, 0, 3);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.InvalidReceiver.selector, pAB));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, pAB, d, 0, 3);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.NoProxy.selector, attacker, MARKET_ID));
        vm.prank(attacker);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, attacker, d, 0, 0);
    }

    // TEST-156 verifies: REQ-PROXY-026, REQ-ADAPTER-008
    // Sources: 5.1 TEST-156 (approve-all scope; the frozen-reserve and Drifting refusals are the reviewed RiskModule's,
    // TEST-155 and TEST-028)
    /// @notice With an approve-all RiskModule the Adapter adds no gate of its own beyond its call bounds: a borrow up
    /// to Aave's limit passes and ends at HF >= 1, and the next one beyond it is refused by Aave.
    function test_TEST_156_approveAllStillAaveBounded() public {
        risk.setApproveAll(true);
        _borrowAs(alice, MARKET_ID, debtReserveId, 15_000e18);
        assertGe(_hf(pA), 1e18, "HF >= 1");
        uint256 d = _deadline();
        uint256 n = adapterC.borrowNonce(pA);
        vm.expectRevert();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 5000e18, alice, d, 0, n);
    }

    // TEST-132 verifies: REQ-PROXY-026, REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-ACCESS-068, REQ-RISK-040, REQ-RISK-053, ATTACK-035, INV-043, INV-044, INV-045
    // Sources: 5.1 TEST-132
    /// @notice A RiskModule that reverts everything blocks borrowing, withdraw-with-debt and removal with debt only;
    /// repay, fee collection, debt-free withdrawal (after the repay), zero-credit release and liquidation never call
    /// it and succeed.
    function test_TEST_132_revertingRiskModule() public {
        risk.setBroken(true);
        uint256 d = _deadline();
        vm.expectRevert(AdapterRiskModuleMock.RiskModuleBroken.selector);
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, d, 0, 2);
        vm.expectRevert(AdapterRiskModuleMock.RiskModuleBroken.selector);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(kA2), UNITS / 2, d, 0);
        vm.expectRevert(AdapterRiskModuleMock.RiskModuleBroken.selector);
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(kA2), 1_000_000_000, _mins(), d, 0);
        lpVault.accrueFees(kA1, 10);
        vm.prank(alice);
        adapterC.collectFees(MARKET_ID, _ref(kA1), d);
        vm.prank(alice);
        adapterC.withdraw(MARKET_B, _ref(kB), UNITS, d, 0);
        _exitMarketA();
        assertEq(lpVault.ownerOf(kA2), alice, "debt-free exit");
        (bytes32 kc, address pc) = _pledgeAs(carol, MARKET_B, UNITS);
        risk.setBroken(false);
        _borrowAs(carol, MARKET_B, debtReserveId, 15_000e18);
        risk.setBroken(true);
        vtPrice.set(1.5e8);
        uint256 seized = swap.liquidate(aave.cdpSpoke, MARKET_B, vtB, vtReserveIdB, debtReserveId, pc, 2000e18, 2);
        assertGt(seized, 0, "liquidation never calls the RiskModule");
        assertEq(lpVault.depositorOf(kc), carol, "carol's position stays in custody");
    }

    function _exitMarketA() internal {
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (debtReserveId, usdcReserveId);
        uint256[] memory caps = new uint256[](2);
        caps[0] = _debtOf(pA, debtReserveId);
        caps[1] = _debtOf(pA, usdcReserveId);
        _fund(alice, debtReserveId, caps[0]);
        _fund(alice, usdcReserveId, caps[1]);
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(kA2), UNITS / 2, ids, caps, _deadline());
    }

    // ─── Hostile MarketRegistry ───

    // TEST-243 verifies: REQ-PROXY-027, REQ-PROXY-034, REQ-PROXY-035, REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-ADAPTER-067, ATTACK-035, ATTACK-043
    // Sources: 5.1 TEST-243
    /// @notice A registry that disables every debt reserve, so the set looks empty: new debt fails closed
    /// (`UnknownDebtReserve`), while repay, `repayAllAndWithdraw` and debt-free withdrawal complete, the debt-free test
    /// coming from Aave's borrow count, not the registry.
    function test_TEST_243_emptyDebtSet() public {
        DebtReserveDef memory def = _debtDef(debtReserveId, address(debt), 18, ghoAssetId);
        def.approved = false;
        registry.setDebtReserve(aave.cdpSpoke, debtReserveId, def);
        DebtReserveDef memory def2 = _debtDef(usdcReserveId, address(usdcDebt), 6, usdcAssetId);
        def2.approved = false;
        registry.setDebtReserve(aave.cdpSpoke, usdcReserveId, def2);
        uint256 d = _deadline();
        vm.expectRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.UnknownDebtReserve.selector, aave.cdpSpoke, debtReserveId)
        );
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, d, 0, 2);
        // An indebted account does not look debt-free: a withdrawal still goes through the with-debt gates.
        vm.expectCall(address(risk), abi.encodeWithSignature("preWithdrawCheck(address)", pA), 1);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(kA2), UNITS / 2, d, 0);
        uint256 g = _debtOf(pA, debtReserveId);
        _fund(carol, debtReserveId, g);
        vm.prank(carol);
        adapterC.repay(alice, MARKET_ID, debtReserveId, g, true, d);
        uint256[] memory ids = new uint256[](1);
        ids[0] = usdcReserveId;
        uint256[] memory caps = new uint256[](1);
        caps[0] = _debtOf(pA, usdcReserveId);
        _fund(alice, usdcReserveId, caps[0]);
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(kA1), UNITS, ids, caps, d);
        assertEq(lpVault.ownerOf(kA1), alice, "exit completed");
    }

    // TEST-243 verifies: REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-ACCESS-068, INV-067, ATTACK-035
    /// @notice A registry that reverts on every call: pledges, borrows and with-debt exits fail closed; repay, fee
    /// collection, `repayAllAndWithdraw`, debt-free withdrawal and the debt mark complete.
    function test_TEST_243_revertingRegistry() public {
        registry.setBroken(true);
        uint256 d = _deadline();
        bytes32 key = _newKey();
        lpVault.mintPosition(key, bob, MARKET_ID, UNITS);
        vm.expectRevert();
        vm.prank(bob);
        adapterC.pledge(MARKET_ID, _ref(key), d);
        vm.expectRevert();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, d, 0, 2);
        vm.expectRevert();
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(kA2), UNITS / 2, d, 0);
        lpVault.accrueFees(kA1, 10);
        vm.prank(alice);
        adapterC.collectFees(MARKET_ID, _ref(kA1), d);
        vm.prank(alice);
        adapterC.withdraw(MARKET_B, _ref(kB), UNITS, d, 0);
        _exitMarketA();
        vm.prank(attacker);
        adapterC.refreshDebtMark(pA);
        assertEq(lpVault.ownerOf(kA2), alice, "exit");
        assertEq(lpVault.ownerOf(kB), alice, "exit B");
    }

    // TEST-107 verifies: REQ-ADAPTER-069, REQ-ADAPTER-047, INV-018, INV-080, INV-008, ATTACK-035
    // Sources: 5.1 TEST-107 (Adapter side)
    /// @notice With a reverting registry, an approve-all RiskModule and an LPVaultSwap that seizes and keeps, the
    /// reviewed Adapter keeps every unit in circulation backed (`totalSupply <= credited + pending`) after each call,
    /// and the borrower still exits: the next withdrawal reconciles the unsettled seizure.
    function test_TEST_107_hostileNeighboursBackingAndExit() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 18_000e18);
        registry.setBroken(true);
        risk.setApproveAll(true);
        vtPrice.set(1.2e8);
        swap.seizeAndKeep(aave.cdpSpoke, vt, vtReserveId, debtReserveId, pA, 5000e18);
        vtPrice.set(2e8);
        assertLe(token.totalSupply(), coll.getTotalCredited(vt) + coll.getPending(vt).units, "backed");
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (debtReserveId, usdcReserveId);
        uint256[] memory caps = new uint256[](2);
        caps[0] = _debtOf(pA, debtReserveId);
        caps[1] = _debtOf(pA, usdcReserveId);
        _fund(alice, debtReserveId, caps[0]);
        _fund(alice, usdcReserveId, caps[1]);
        uint256 units = coll.previewRelease(INTEGRATION, kA1);
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(kA1), units, ids, caps, _deadline());
        assertEq(lpVault.ownerOf(kA1), alice, "exit after the hostile seizure");
        assertLe(token.totalSupply(), coll.getTotalCredited(vt) + coll.getPending(vt).units, "still backed");
    }
}
