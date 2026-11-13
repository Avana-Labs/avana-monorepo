// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {PledgeCharge} from "../../src/policy/risk-module/types/PledgeCharge.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

interface IHostileSpokeConfigurator {
    function updateFrozen(
        address spoke,
        uint256 reserveId,
        bool frozen
    ) external;
}

/// @notice A RiskModule implementation that reverts on every call, as a broken upgrade would.
contract RevertingRiskModule {
    error RiskModuleBroken();

    function proxiableUUID() external pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }

    fallback() external {
        revert RiskModuleBroken();
    }
}

/// @notice A RiskModule implementation that approves every pledge, borrow and withdraw-with-debt.
contract ApproveAllRiskModule {
    function proxiableUUID() external pure returns (bytes32) {
        return 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    }

    function checkPledge(
        address,
        address,
        uint256,
        uint32,
        bytes32,
        uint128 units,
        bytes calldata,
        bool
    ) external pure returns (PledgeCharge memory charge) {
        charge.usdCharge = units;
    }

    function preBorrowCheck(
        address,
        uint256,
        uint256
    ) external {}

    function preWithdrawCheck(
        address
    ) external {}

    function postHealthCheck(
        address,
        uint256
    ) external pure returns (uint256) {
        return type(uint256).max;
    }

    function checkRemainingRecord(
        uint256,
        uint128
    ) external view {}

    fallback() external {}
}

/// @title RiskModuleHostileIntegrationTest
/// @notice The reviewed RiskModule's proxy upgraded through the timelock to a broken (always-reverting) or an
/// approve-all implementation, with the real AaveAdapter, Collateralization, LPVaultSwap and Aave V4 Hub and Spoke: a
/// broken RiskModule stops only the actions that call it, and an approving one is still bounded by Aave's health factor
/// and the Spoke's draw cap.
/// forge-config: default.isolate = false
contract RiskModuleHostileIntegrationTest is IntegrationFlows {
    function setUp() public {
        _deployIntegration();
    }

    function _install(
        address implementation
    ) internal {
        vm.prank(timelock);
        UUPSUpgradeable(address(rm)).upgradeToAndCall(implementation, "");
    }

    // TEST-132 verifies: REQ-RISK-053, REQ-ADAPTER-009, REQ-RISK-040
    // Sources: 2.7 REQ-RISK-053 (RiskModule implementation broken or reverting), REQ-ADAPTER-009, REQ-RISK-040
    /// @notice With the RiskModule proxy upgraded to an implementation that reverts on every call, a new pledge, a
    /// rescue-free top-up, a borrow and a withdrawal that leaves debt fail closed, while repay by a third party, fee
    /// collection, a debt-free withdrawal, `repayAllAndWithdraw` and a liquidation never call it and succeed.
    function test_TEST_132_brokenRiskModuleStopsOnlyWhatCallsIt() public {
        (address pA, bytes32 kA) = _openAccount(alice, MARKET_ID, 10_000e6, 4000e6, P_VAULT);
        (bytes32 kA2,) = _pledgeVia(alice, MARKET_ID, 2000e6);
        (bytes32 kC,) = _pledgeVia(carol, MARKET_ID, 1000e6);
        (address pB,) = _bobAccount();
        _install(address(new RevertingRiskModule()));

        // Fail closed: borrow, withdraw-with-debt, a new pledge.
        uint256 nonce = adapterC.borrowNonce(pA);
        uint256 d = _deadline();
        vm.expectRevert(RevertingRiskModule.RiskModuleBroken.selector);
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, usdcReserveId, 1e6, alice, d, 0, nonce);
        vm.expectRevert(RevertingRiskModule.RiskModuleBroken.selector);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(kA2), 2000e6, d, 0);
        bytes32 kNew = _newKey();
        address dave = makeAddr("dave");
        vault.mintPosition(kNew, dave, MARKET_ID, 1000e6);
        vm.expectRevert(RevertingRiskModule.RiskModuleBroken.selector);
        vm.prank(dave);
        adapterC.pledge(MARKET_ID, _ref(kNew), d);
        assertEq(vault.ownerOf(kNew), dave, "the refused pledge moved nothing");

        // Exits and liquidation continue.
        vault.accrueFees(kA, 5e6);
        vm.prank(alice);
        adapterC.collectFees(MARKET_ID, _ref(kA), _deadline());
        assertEq(usdc.balanceOf(alice), 4000e6 + 5e6, "fees collected");
        _repayVia(carol, alice, MARKET_ID, usdcReserveId, 1000e6, false);
        _withdrawVia(carol, MARKET_ID, kC, 1000e6);
        assertEq(vault.ownerOf(kC), carol, "debt-free withdrawal");
        LiquidationResult memory r = _liquidateAs(keeper, _liqParams(pB, MARKET_ID, usdcReserveId, 1950e6));
        assertEq(r.debtRepaid, 1950e6, "liquidation settles");
        uint256 owed = _debtOf(pA, usdcReserveId);
        usdc.mint(alice, owed);
        uint256[] memory ids = new uint256[](1);
        ids[0] = usdcReserveId;
        uint256[] memory caps = new uint256[](1);
        caps[0] = owed;
        vm.startPrank(alice);
        usdc.approve(adapter, owed);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(kA), 10_000e6, ids, caps, _deadline());
        vm.stopPrank();
        assertEq(_debtOf(pA, usdcReserveId), 0, "repaid in full");
        assertEq(vault.ownerOf(kA), alice, "position returned");
        _withdrawVia(alice, MARKET_ID, kA2, 2000e6);
        assertEq(vault.ownerOf(kA2), alice, "debt-free withdrawal after repay-all");
        assertFalse(lock.isLocked(), "Lock free");
    }

    // TEST-132 verifies: Q-226, Q-229
    // Sources: 5.1 TEST-132 (approve-all RiskModule: Aave HF >= 1 and the drawCap still bound the borrow)
    /// @notice An approve-all RiskModule lets a borrow through every Avana gate, but Aave refuses one that would end
    /// below HF 1, the reserve's draw cap holds, and the Adapter still enforces the nonce and the deadline.
    function test_TEST_132_approveAllRiskModuleStillAaveBounded() public {
        (address pA,) = _openAccount(alice, MARKET_ID, 10_000e6, 4000e6, P_VAULT);
        _install(address(new ApproveAllRiskModule()));
        _borrowVia(alice, MARKET_ID, usdcReserveId, 10_000e6);
        assertGe(_hf(pA), 1e18, "Aave HF >= 1");
        uint256 nonce = adapterC.borrowNonce(pA);
        uint256 d = _deadline();
        vm.expectRevert();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, usdcReserveId, 10_000e6, alice, d, 0, nonce);
        assertGe(_hf(pA), 1e18, "still >= 1 after the refused borrow");
        uint256 cap = uint256(IAaveV4Hub(aave.hub).getSpokeConfig(usdcAssetId, aave.cdpSpoke).drawCap) * 1e6;
        assertLe(IAaveV4Hub(aave.hub).getSpokeTotalOwed(usdcAssetId, aave.cdpSpoke), cap, "within drawCap");
        vm.expectRevert();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, usdcReserveId, 1e6, alice, d, 0, nonce + 1);
    }

    // TEST-156 verifies: Q-203, Q-229
    // Sources: 5.1 TEST-156 (Quint C-QNT-3, reviewed-implementation scope)
    /// @notice With the reviewed RiskModule, a borrow against an account whose vault-token reserve Aave froze reverts
    /// `ReserveFrozen`, and one against a Drifting market reverts `PriceNotLive`; after the approve-all implementation
    /// is installed through the timelock both borrows pass, and each still ends at Aave HF >= 1.
    function test_TEST_156_reviewedRefusesApproveAllStaysAaveBounded() public {
        (address pA,) = _openAccount(alice, MARKET_ID, 10_000e6, 4000e6, P_VAULT);
        uint256 vtReserve = _vtReserve(MARKET_ID);
        vm.prank(aaveDao);
        IHostileSpokeConfigurator(aave.spokeConfigurator).updateFrozen(aave.cdpSpoke, vtReserve, true);
        uint256 nonce = adapterC.borrowNonce(pA);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.ReserveFrozen.selector, vtReserve));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, usdcReserveId, 1000e6, alice, d, 0, nonce);
        vm.prank(aaveDao);
        IHostileSpokeConfigurator(aave.spokeConfigurator).updateFrozen(aave.cdpSpoke, vtReserve, false);
        _lpoOf(MARKET_ID).setState(PriceState.Drifting, 1, false);
        vm.expectRevert(abi.encodeWithSelector(IRiskModuleErrors.PriceNotLive.selector, MARKET_ID, PriceState.Drifting));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, usdcReserveId, 1000e6, alice, d, 0, nonce);

        _install(address(new ApproveAllRiskModule()));
        _borrowVia(alice, MARKET_ID, usdcReserveId, 1000e6);
        assertGe(_hf(pA), 1e18, "Drifting market: HF >= 1");
        vm.prank(aaveDao);
        IHostileSpokeConfigurator(aave.spokeConfigurator).updateFrozen(aave.cdpSpoke, vtReserve, true);
        _borrowVia(alice, MARKET_ID, usdcReserveId, 1000e6);
        assertGe(_hf(pA), 1e18, "frozen collateral reserve: HF >= 1");
        assertEq(_debtOf(pA, usdcReserveId), 6000e6, "both borrows taken");
    }
}
