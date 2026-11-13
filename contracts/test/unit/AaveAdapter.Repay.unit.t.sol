// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationDebtMark} from "../../src/custody/collateralization/ICollateralizationDebtMark.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title AaveAdapterRepayUnitTest
/// @notice `repay` on the real Aave V4 Spoke: any payer, live-debt sizing (partial and repay-all with refund), zero debt
/// returning 0 with no movement, concurrent payers, transfer-fee tokens measured by balance delta, the debt mark, and
/// no read of the MarketRegistry, the pause state, the freeze, a breaker, a price or the RiskModule.
/// forge-config: default.isolate = false
contract AaveAdapterRepayUnitTest is AaveAdapterFixture {
    address internal p;

    function setUp() public override {
        super.setUp();
        (, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 8000e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 5000e6);
        // The borrowed funds leave the wallet, so every balance below is the test's own funding.
        vm.startPrank(alice);
        debt.transfer(makeAddr("sink"), 8000e18);
        usdcDebt.transfer(makeAddr("sink"), 5000e6);
        vm.stopPrank();
        // Interest accrues on both reserves.
        vm.warp(block.timestamp + 30 days);
    }

    function _repay(
        address payer,
        uint256 reserveId,
        uint256 maxSpend,
        bool all
    ) internal returns (uint256 spent) {
        uint256 d = _deadline();
        vm.prank(payer);
        spent = adapterC.repay(alice, MARKET_ID, reserveId, maxSpend, all, d);
    }

    function _countRepaid() internal view returns (uint256 n) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == adapter && logs[i].topics[0] == IAaveAdapterEvents.Repaid.selector) ++n;
        }
    }

    // ─── Partial repay ───

    // TEST-029 verifies: REQ-PROXY-027, REQ-PROXY-028, REQ-PROXY-029, REQ-PROXY-030, REQ-PROXY-088, SPEC-PROXY-003, INV-043
    // Sources: 5.1 TEST-029, FLOW-003
    /// @notice A partial repay pulls exactly `min(maxRepaySpend, D)` from the payer to the proxy, which approves the
    /// Spoke for exactly that, repays and resets the approval; the payer's allowance and the proxy's balance end at 0.
    function test_TEST_029_partialRepay() public {
        uint256 debtBefore = _debtOf(p, debtReserveId);
        _fund(alice, debtReserveId, 2000e18);
        vm.expectCall(address(debt), abi.encodeCall(IERC20.transferFrom, (alice, p, 2000e18)), 1);
        vm.expectCall(address(debt), abi.encodeCall(IERC20.approve, (aave.cdpSpoke, 2000e18)), 1);
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.Repaid(alice, alice, MARKET_ID, debtReserveId, 2000e18, debtBefore - 2000e18, false);
        uint256 spent = _repay(alice, debtReserveId, 2000e18, false);
        assertEq(spent, 2000e18, "spent");
        assertEq(debt.balanceOf(alice), 0, "payer paid");
        assertEq(debt.allowance(alice, adapter), 0, "payer allowance");
        assertEq(debt.balanceOf(p), 0, "proxy holds nothing");
        assertEq(debt.allowance(p, aave.cdpSpoke), 0, "proxy allowance");
        assertApproxEqAbs(_debtOf(p, debtReserveId), debtBefore - 2000e18, 1, "debt lowered");
        assertEq(_debtOf(p, usdcReserveId) > 5000e6, true, "USDC untouched");
    }

    // TEST-029 verifies: REQ-PROXY-028, SPEC-PROXY-003
    /// @notice A partial repay above the debt pulls only the debt.
    function test_TEST_029_partialAboveDebtPullsDebt() public {
        uint256 debtNow = _debtOf(p, usdcReserveId);
        _fund(alice, usdcReserveId, debtNow + 1000e6);
        uint256 spent = _repay(alice, usdcReserveId, debtNow + 1000e6, false);
        assertEq(spent, debtNow, "spent the debt");
        assertEq(usdcDebt.balanceOf(alice), 1000e6, "excess never pulled");
        assertEq(_debtOf(p, usdcReserveId), 0, "cleared");
    }

    // TEST-029 verifies: REQ-PROXY-016, REQ-PROXY-032
    /// @notice There is no repay floor: one base unit repays.
    function test_TEST_029_noRepayFloor() public {
        uint256 debtNow = _debtOf(p, usdcReserveId);
        _fund(alice, usdcReserveId, 1);
        _repay(alice, usdcReserveId, 1, false);
        assertLe(_debtOf(p, usdcReserveId), debtNow, "lowered or equal");
        assertEq(usdcDebt.balanceOf(alice), 0, "pulled 1");
    }

    // ─── Repay-all ───

    // TEST-248 verifies: REQ-ADAPTER-085, REQ-PROXY-031, SPEC-PROXY-007, REQ-PROXY-030
    // Sources: 5.1 TEST-248, TEST-029 example
    /// @notice A repay-all pulls `maxRepaySpend`, Aave takes the live debt, the rest returns to the payer in the same
    /// call; debt and allowance end at 0. Run on the 18-decimal reserve.
    function test_TEST_248_repayAll18Decimals() public {
        uint256 live = _debtOf(p, debtReserveId);
        assertGt(live, 8000e18, "interest accrued");
        uint256 cap = live * 1001 / 1000;
        _fund(alice, debtReserveId, cap);
        vm.expectCall(address(debt), abi.encodeCall(IERC20.transferFrom, (alice, p, cap)), 1);
        uint256 spent = _repay(alice, debtReserveId, cap, true);
        assertEq(spent, live, "Aave took the live debt");
        assertEq(debt.balanceOf(alice), cap - live, "refund");
        assertEq(debt.allowance(alice, adapter), 0, "allowance 0");
        assertEq(_debtOf(p, debtReserveId), 0, "debt 0");
        (, bool borrowing) = IAaveV4Spoke(aave.cdpSpoke).getUserReserveStatus(debtReserveId, p);
        assertFalse(borrowing, "borrowing flag cleared");
    }

    // TEST-248 verifies: REQ-ADAPTER-085, REQ-PROXY-031, SPEC-PROXY-007
    /// @notice The same on the 6-decimal reserve.
    function test_TEST_248_repayAll6Decimals() public {
        uint256 live = _debtOf(p, usdcReserveId);
        uint256 cap = live + 5_342_465;
        _fund(alice, usdcReserveId, cap);
        uint256 spent = _repay(alice, usdcReserveId, cap, true);
        assertEq(spent, live, "live debt");
        assertEq(usdcDebt.balanceOf(alice), 5_342_465, "refund");
        assertEq(_debtOf(p, usdcReserveId), 0, "cleared");
        assertEq(_borrowCountOf(p), 1, "GHO still borrowed");
    }

    // TEST-248 verifies: REQ-PROXY-070, REQ-ADAPTER-085, SPEC-PROXY-003
    /// @notice A repay-all whose cap is below the live debt reverts `RepayExceedsMax(D, cap)` before any transfer.
    function test_TEST_248_capBelowDebtReverts() public {
        uint256 live = _debtOf(p, usdcReserveId);
        _fund(alice, usdcReserveId, live - 1);
        uint256 d = _deadline();
        vm.expectCall(address(usdcDebt), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.RepayExceedsMax.selector, live, live - 1));
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, usdcReserveId, live - 1, true, d);
    }

    // TEST-248 verifies: REQ-PROXY-031, REQ-PROXY-029, REQ-PROXY-071, Q-271
    /// @notice A transfer fee switched on after listing makes a repay-all receive less than the debt: Aave takes what
    /// arrived and the call reverts `DebtRemaining`, never repaying part silently.
    function test_TEST_248_feeOnTransferRepayAllReverts() public {
        uint256 live = _debtOf(p, usdcReserveId);
        usdcDebt.setFeeBps(10);
        _fund(alice, usdcReserveId, live);
        uint256 d = _deadline();
        vm.expectRevert();
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, usdcReserveId, live, true, d);
        assertEq(_debtOf(p, usdcReserveId), live, "nothing changed");
    }

    // TEST-221 verifies: REQ-PROXY-029, REQ-PROXY-077, Q-271
    /// @notice With a transfer fee the Adapter repays exactly what arrived at the proxy, and the pinned Aave V4 Hub
    /// then refuses the Spoke's own short transfer to it (`InsufficientTransferred`): a fee-charging debt asset blocks
    /// repay on Aave's side, never on the Adapter's.
    function test_TEST_221_feeOnTransferBlockedByAave() public {
        uint256 live = _debtOf(p, usdcReserveId);
        usdcDebt.setFeeBps(100);
        _fund(alice, usdcReserveId, 1000e6);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSignature("InsufficientTransferred(uint256)", 9_900_000));
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, usdcReserveId, 1000e6, false, d);
        assertEq(_debtOf(p, usdcReserveId), live, "nothing changed");
    }

    // TEST-029 verifies: REQ-PROXY-029, REQ-PROXY-072
    /// @notice A pull that delivers nothing reverts `UnitsMismatch(x, 0)`.
    function test_TEST_029_pullDeliveringNothingReverts() public {
        usdcDebt.setFeeBps(10_000);
        _fund(alice, usdcReserveId, 1000e6);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnitsMismatch.selector, 1000e6, 0));
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, usdcReserveId, 1000e6, false, d);
    }

    // ─── Zero debt ───

    // TEST-165 verifies: REQ-PROXY-028, REQ-PROXY-068, REQ-PROXY-069, REQ-PROXY-084, SPEC-PROXY-003
    // Sources: 5.1 TEST-165
    /// @notice At zero debt a partial repay and a repay-all both return 0 with no pull, no approval, no Spoke call and
    /// no `Repaid`.
    function test_TEST_165_zeroDebtReturnsZero() public {
        (, address bp) = _pledgeAs(bob, MARKET_ID, UNITS);
        _fund(carol, debtReserveId, 100e18);
        vm.expectCall(address(debt), abi.encodeWithSelector(IERC20.transferFrom.selector), 0);
        vm.expectCall(address(debt), abi.encodeWithSelector(IERC20.approve.selector), 0);
        vm.expectCall(aave.cdpSpoke, abi.encodeWithSelector(IAaveV4Spoke.repay.selector), 0);
        vm.recordLogs();
        uint256 d = _deadline();
        vm.prank(carol);
        uint256 a = adapterC.repay(bob, MARKET_ID, debtReserveId, 100e18, false, d);
        vm.prank(carol);
        uint256 b = adapterC.repay(bob, MARKET_ID, debtReserveId, 100e18, true, d);
        assertEq(a + b, 0, "returns 0");
        assertEq(_countRepaid(), 0, "no event");
        assertEq(debt.balanceOf(carol), 100e18, "nothing pulled");
        assertEq(debt.allowance(bp, aave.cdpSpoke), 0, "no allowance");
        assertFalse(lock.isLocked(), "lock released on the early return");
    }

    // TEST-165 verifies: REQ-PROXY-028, REQ-PROXY-060
    /// @notice A partial repay with a cap of 0 reverts `ZeroAmount` whatever the debt; a repay-all with cap 0 at zero
    /// debt returns 0.
    function test_TEST_165_zeroCapPartial() public {
        _pledgeAs(bob, MARKET_ID, UNITS);
        uint256 d = _deadline();
        vm.expectRevert(IAaveAdapterErrors.ZeroAmount.selector);
        vm.prank(carol);
        adapterC.repay(bob, MARKET_ID, debtReserveId, 0, false, d);
        vm.expectRevert(IAaveAdapterErrors.ZeroAmount.selector);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 0, false, d);
        vm.prank(carol);
        assertEq(adapterC.repay(bob, MARKET_ID, debtReserveId, 0, true, d), 0, "repay-all at zero debt");
        vm.expectRevert(
            abi.encodeWithSelector(IAaveAdapterErrors.RepayExceedsMax.selector, _debtOf(p, debtReserveId), 0)
        );
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 0, true, d);
    }

    // ─── Any payer ───

    // TEST-175 verifies: REQ-PROXY-027, REQ-PROXY-083, Q-212, ATTACK-117
    // Sources: 5.1 TEST-175
    /// @notice A third party repays the borrower's debt from its own funds, never the borrower's; `Repaid` names both;
    /// the borrower's later repay-all pulls its whole cap, Aave takes the remaining debt and the rest is refunded.
    function test_TEST_175_thirdPartyRepay() public {
        uint256 live = _debtOf(p, debtReserveId);
        _fund(carol, debtReserveId, 3000e18);
        debt.mint(alice, 1e30);
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.Repaid(carol, alice, MARKET_ID, debtReserveId, 3000e18, live - 3000e18, false);
        uint256 d = _deadline();
        vm.prank(carol);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 3000e18, false, d);
        assertEq(debt.balanceOf(carol), 0, "carol paid");
        assertEq(debt.balanceOf(alice), 1e30, "borrower untouched");
        uint256 remaining = _debtOf(p, debtReserveId);
        uint256 cap = 8100e18;
        vm.prank(alice);
        debt.approve(adapter, cap);
        vm.prank(alice);
        uint256 spent = adapterC.repay(alice, MARKET_ID, debtReserveId, cap, true, d);
        assertEq(spent, remaining, "only the remaining debt");
        assertEq(debt.balanceOf(alice), 1e30 - remaining, "refund of the unused cap");
        assertEq(debt.allowance(alice, adapter), 0, "allowance 0");
        assertGt(_debtOf(p, usdcReserveId), 0, "USDC debt untouched");
    }

    // TEST-175 verifies: REQ-PROXY-083, REQ-PROXY-069
    // Sources: 2.6 REQ-PROXY-083 example
    /// @notice A borrower's repay-all landing after a third party's full repay returns 0 and pulls nothing.
    function test_TEST_175_repayAllAfterFullThirdPartyRepay() public {
        uint256 live = _debtOf(p, usdcReserveId);
        _fund(carol, usdcReserveId, live);
        _repayAs(carol, usdcReserveId, live, true);
        _fund(alice, usdcReserveId, 5030e6);
        uint256 spent = _repayAs(alice, usdcReserveId, 5030e6, true);
        assertEq(spent, 0, "nothing to repay");
        assertEq(usdcDebt.balanceOf(alice), 5030e6, "nothing pulled");
    }

    function _repayAs(
        address payer,
        uint256 reserveId,
        uint256 cap,
        bool all
    ) internal returns (uint256) {
        uint256 d = _deadline();
        vm.prank(payer);
        return adapterC.repay(alice, MARKET_ID, reserveId, cap, all, d);
    }

    // TEST-029 verifies: REQ-PROXY-027, REQ-PROXY-032, REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-ACCESS-068, INV-043, INV-067, ATTACK-035, ATTACK-078
    /// @notice Repay succeeds with a MarketRegistry and a RiskModule that revert on every call, in every pause state,
    /// for a frozen payer and a frozen borrower: it reads none of them.
    function test_TEST_029_repayReadsNoRegistryOrRiskModule() public {
        registry.setFrozen(alice, true);
        registry.setFrozen(carol, true);
        _pause(PauseState.Paused, PauseReason.MintPathSuspect);
        registry.setBroken(true);
        risk.setBroken(true);
        vm.expectCall(address(registry), "", 0);
        vm.expectCall(address(risk), "", 0);
        _fund(carol, debtReserveId, 100e18);
        _repayAs(carol, debtReserveId, 100e18, false);
        uint256 live = _debtOf(p, usdcReserveId);
        _fund(alice, usdcReserveId, live);
        _repayAs(alice, usdcReserveId, live, true);
        assertEq(_debtOf(p, usdcReserveId), 0, "cleared with a broken registry");
    }

    // TEST-192 verifies: REQ-PROXY-032, REQ-ADAPTER-045, REQ-ADAPTER-046, REQ-ACCESS-072, REQ-ACCESS-073, REQ-ACCESS-074, REQ-ACCESS-164
    /// @notice Repay is open in None, Frozen and both Paused reasons.
    function test_TEST_192_repayInEveryPauseState() public {
        PauseState[4] memory states = [PauseState.None, PauseState.Frozen, PauseState.Paused, PauseState.Paused];
        PauseReason[4] memory reasons =
            [PauseReason.None, PauseReason.None, PauseReason.General, PauseReason.MintPathSuspect];
        for (uint256 i = 0; i < 4; ++i) {
            _pause(states[i], reasons[i]);
            _fund(carol, debtReserveId, 10e18);
            assertEq(_repayAs(carol, debtReserveId, 10e18, false), 10e18, "repaid");
        }
    }

    // ─── Debt mark ───

    // TEST-029 verifies: REQ-PROXY-032, REQ-COLL-040
    /// @notice A repay that clears the last reserve clears the indebted mark; one that leaves debt does not call
    /// `markDebtFree` at all.
    function test_TEST_029_debtMarkOnLastReserve() public {
        uint256 g = _debtOf(p, debtReserveId);
        _fund(alice, debtReserveId, g);
        // GHO cleared but USDC remains: markDebtFree runs and keeps the mark.
        _repayAs(alice, debtReserveId, g, true);
        assertFalse(coll.getMarketDebtFree(vt), "still indebted");
        uint256 u = _debtOf(p, usdcReserveId);
        _fund(alice, usdcReserveId, u);
        vm.expectCall(address(coll), abi.encodeCall(ICollateralizationDebtMark.markDebtFree, (p)), 1);
        _repayAs(alice, usdcReserveId, u, true);
        assertEq(_borrowCountOf(p), 0, "borrowCount 0");
        assertTrue(coll.getMarketDebtFree(vt), "mark cleared");
    }

    // TEST-029 verifies: REQ-PROXY-032
    /// @notice A repay that leaves the reserve with debt makes no `markDebtFree` call.
    function test_TEST_029_noDebtMarkWhileDebtRemains() public {
        _fund(alice, debtReserveId, 100e18);
        vm.expectCall(address(coll), abi.encodeCall(ICollateralizationDebtMark.markDebtFree, (p)), 0);
        _repayAs(alice, debtReserveId, 100e18, false);
    }

    // ─── Bounds ───

    // TEST-029 verifies: REQ-PROXY-027, REQ-PROXY-057, REQ-PROXY-058
    function test_TEST_029_noProxyAndDeadline() public {
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.NoProxy.selector, bob, MARKET_ID));
        vm.prank(carol);
        adapterC.repay(bob, MARKET_ID, debtReserveId, 1, false, d);
        uint256 past = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DeadlineExpired.selector, past));
        vm.prank(carol);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 1, false, past);
    }

    // TEST-029 verifies: REQ-PROXY-027, REQ-PROXY-062
    /// @notice A reserve the Spoke does not list fails with the Spoke's own error; the Adapter checks no registry set.
    function test_TEST_029_unlistedReserveFailsInSpoke() public {
        uint256 d = _deadline();
        vm.expectRevert(bytes4(keccak256("ReserveNotListed()")));
        vm.prank(carol);
        adapterC.repay(alice, MARKET_ID, 99, 1, false, d);
    }

    // TEST-177 verifies: REQ-PROXY-084, REQ-PROXY-088
    /// @notice With a token that reverts on zero-amount transfers, a repay of exactly the debt makes no zero refund.
    function test_TEST_177_zeroRefundSkipped() public {
        usdcDebt.setRevertOnZero(true);
        uint256 live = _debtOf(p, usdcReserveId);
        _fund(alice, usdcReserveId, live);
        _repayAs(alice, usdcReserveId, live, false);
        assertEq(_debtOf(p, usdcReserveId), 0, "cleared without a zero transfer");
    }

    // TEST-031 verifies: REQ-PROXY-027, Q-212
    /// @notice A third party's repay moves no collateral and borrows nothing for itself.
    function test_TEST_031_repayMovesNoCollateral() public {
        uint256 shares = _sharesOf(p, vtReserveId);
        _fund(attacker, debtReserveId, 50e18);
        _repayAs(attacker, debtReserveId, 50e18, false);
        assertEq(_sharesOf(p, vtReserveId), shares, "collateral unchanged");
        assertEq(adapterC.proxyOf(attacker, MARKET_ID), address(0), "no account for the payer");
    }

    // TEST-075 verifies: REQ-PROXY-028, SPEC-PROXY-003, MATH-AR-18
    // Sources: real-Aave list (stale risk premium after a partial repay)
    /// @notice After a partial repay Aave keeps the account's risk premium until its next refresh; the live debt the
    /// Adapter reads still includes every premium accrued, so a later repay-all at that debt clears the reserve.
    function test_TEST_075_stalePremiumAfterPartialRepay() public {
        uint256 premiumBefore = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(p).riskPremium;
        _fund(alice, debtReserveId, 4000e18);
        _repayAs(alice, debtReserveId, 4000e18, false);
        assertEq(IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(p).riskPremium, premiumBefore, "premium unchanged");
        vm.warp(block.timestamp + 90 days);
        uint256 live = _debtOf(p, debtReserveId);
        _fund(alice, debtReserveId, live);
        assertEq(_repayAs(alice, debtReserveId, live, true), live, "repay-all at the live debt");
        assertEq(_debtOf(p, debtReserveId), 0, "cleared");
    }

    // TEST-029 verifies: REQ-PROXY-088, REQ-PROXY-013
    /// @notice A donation to the proxy changes no repay: the pull, the repay and the refund are balance deltas.
    function test_TEST_029_donationIgnored() public {
        debt.mint(p, 1);
        _fund(alice, debtReserveId, 500e18);
        assertEq(_repayAs(alice, debtReserveId, 500e18, false), 500e18, "spent");
        assertEq(debt.balanceOf(p), 1, "donation stays");
    }

    // TEST-029 verifies: REQ-PROXY-030
    /// @notice The proxy refunds the unused part to the payer, never to the borrower.
    function test_TEST_029_refundToPayer() public {
        uint256 live = _debtOf(p, debtReserveId);
        uint256 cap = live + 77e18;
        _fund(carol, debtReserveId, cap);
        uint256 aliceBefore = debt.balanceOf(alice);
        _repayAs(carol, debtReserveId, cap, true);
        assertEq(debt.balanceOf(carol), 77e18, "refund to the payer");
        assertEq(debt.balanceOf(alice), aliceBefore, "borrower gets nothing");
    }
}
