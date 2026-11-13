// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {AaveAdapterFixture} from "../utils/fixtures/AaveAdapterFixture.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Re-arms a token's one-shot transfer hook, so the hook fires on the transfer after the next one: a token
/// that calls back on a later leg of the same step.
contract HookRearmer {
    function rearm(
        address token,
        address target,
        bytes calldata data
    ) external {
        CollPoolToken(token).armHook(target, data);
    }
}

/// @title AaveAdapterDefensesUnitTest
/// @notice The Adapter's own checks around each account step against a token or Spoke that does not behave as the
/// pinned Aave V4 and a plain ERC-20 do: a token that credits the proxy during a step, a Spoke that reports a debt it
/// did not clear, a borrow count with no borrowed reserve, a paused reserve at cleanup, supplied shares that do not
/// fall. Each must revert with the Adapter's error or skip the step, never move value.
/// forge-config: default.isolate = false
contract AaveAdapterDefensesUnitTest is AaveAdapterFixture {
    bytes32 internal k1;
    address internal p;
    HookRearmer internal rearmer;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        rearmer = new HookRearmer();
    }

    /// @dev Arms `token` so that its second transfer from now first mints `amount` to the proxy.
    function _creditProxyOnSecondTransfer(
        CollPoolToken token,
        uint256 amount
    ) internal {
        bytes memory mintToProxy = abi.encodeCall(CollPoolToken.mint, (p, amount));
        token.armHook(
            address(rearmer), abi.encodeCall(HookRearmer.rearm, (address(token), address(token), mintToProxy))
        );
    }

    // TEST-027 verifies: REQ-PROXY-023, REQ-PROXY-087, REQ-PROXY-072, SPEC-PROXY-004
    /// @notice A debt asset that credits the proxy while it forwards the borrow leaves the proxy above its start
    /// balance: `BalanceDeltaMismatch`, nothing borrowed.
    function test_TEST_027_forwardLegCreditRefused() public {
        _creditProxyOnSecondTransfer(debt, 1);
        uint256 d = _deadline();
        vm.expectRevert(IAaveAdapterErrors.BalanceDeltaMismatch.selector);
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1000e18, alice, d, 0, 0);
        assertEq(_debtOf(p, debtReserveId), 0, "no debt");
    }

    // TEST-027 verifies: REQ-PROXY-021, REQ-PROXY-072, SPEC-PROXY-004
    /// @notice A draw that leaves the proxy's balance where it was (nothing arrived) reverts `UnitsMismatch(amount, 0)`.
    function test_TEST_027_nothingDrawnRefused() public {
        vm.mockCall(address(debt), abi.encodeCall(debt.balanceOf, (p)), abi.encode(uint256(0)));
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnitsMismatch.selector, 1000e18, 0));
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1000e18, alice, d, 0, 0);
    }

    // TEST-029 verifies: REQ-PROXY-088, REQ-PROXY-030, REQ-PROXY-013
    /// @notice A debt asset that credits the proxy during the Spoke's repay leaves the proxy above its start: the repay
    /// step refuses with `BalanceDeltaMismatch` and nothing is repaid.
    function test_TEST_029_repayLegCreditRefused() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        _fund(bob, debtReserveId, 500e18);
        _creditProxyOnSecondTransfer(debt, 600e18);
        uint256 d = _deadline();
        vm.expectRevert(IAaveAdapterErrors.BalanceDeltaMismatch.selector);
        vm.prank(bob);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 500e18, false, d);
        assertEq(_debtOf(p, debtReserveId), 1000e18, "nothing repaid");
    }

    // TEST-248 verifies: REQ-PROXY-031, REQ-PROXY-071, REQ-ADAPTER-085
    /// @notice A repay-all after which the Spoke still reports debt reverts `DebtRemaining(r, d)`: the Adapter checks
    /// the reserve at zero rather than trusting the amount it paid.
    function test_TEST_248_debtStillReportedRefused() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        vm.mockCall(
            aave.cdpSpoke,
            abi.encodeCall(IAaveV4Spoke.getUserTotalDebt, (debtReserveId, p)),
            abi.encode(uint256(1000e18))
        );
        _fund(alice, debtReserveId, 1000e18);
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DebtRemaining.selector, debtReserveId, 1000e18));
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 1000e18, true, d);
    }

    // TEST-203 verifies: REQ-ADAPTER-071, REQ-PROXY-071, REQ-PROXY-034
    /// @notice A borrow count above 0 with no reserve reported borrowed still refuses the withdrawal of
    /// `repayAllAndWithdraw`: `DebtRemaining(reserveCount, 0)`, so the debt-free test stays Aave's borrow count.
    function test_TEST_203_borrowCountWithoutReserveRefused() public {
        IAaveV4Spoke.UserAccountData memory data = IAaveV4Spoke(aave.cdpSpoke).getUserAccountData(p);
        data.borrowCount = 1;
        vm.mockCall(aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.getUserAccountData, (p)), abi.encode(data));
        uint256 count = IAaveV4Spoke(aave.cdpSpoke).getReserveCount();
        uint256 d = _deadline();
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.DebtRemaining.selector, count, 0));
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k1), UNITS, new uint256[](0), new uint256[](0), d);
        assertEq(lpVault.depositorOf(k1), alice, "still in custody");
    }

    // TEST-018 verifies: REQ-PROXY-046
    /// @notice The collateral cleanup skips a paused reserve: the last withdrawal succeeds and the reserve stays
    /// enabled, with no `CollateralDisabled`.
    function test_TEST_018_cleanupSkipsPausedReserve() public {
        IAaveV4Spoke.ReserveConfig memory cfg = IAaveV4Spoke(aave.cdpSpoke).getReserveConfig(vtReserveId);
        cfg.paused = true;
        vm.mockCall(aave.cdpSpoke, abi.encodeCall(IAaveV4Spoke.getReserveConfig, (vtReserveId)), abi.encode(cfg));
        vm.recordLogs();
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, _deadline(), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != IAaveAdapterEvents.CollateralDisabled.selector, "no cleanup");
        }
        (bool enabled,) = IAaveV4Spoke(aave.cdpSpoke).getUserReserveStatus(vtReserveId, p);
        assertTrue(enabled, "still enabled");
        assertEq(lpVault.ownerOf(k1), alice, "position returned");
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-PROXY-072
    /// @notice A repay with collateral whose supplied shares do not fall by the session's units reverts
    /// `UnitsMismatch(units, fell)`.
    function test_TEST_239_sharesMustFallByUnits() public {
        _borrowAs(alice, MARKET_ID, debtReserveId, 5000e18);
        swap.setDeleverage(1000e18, 2e12, 0);
        vm.mockCall(
            aave.cdpSpoke,
            abi.encodeCall(IAaveV4Spoke.getUserSuppliedShares, (vtReserveId, p)),
            abi.encode(uint256(UNITS))
        );
        vm.expectRevert(abi.encodeWithSelector(IAaveAdapterErrors.UnitsMismatch.selector, 500_000_000, 0));
        vm.prank(alice);
        adapterC.repayWithCollateral(_rwc(MARKET_ID, k1, 500_000_000, debtReserveId));
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-068, REQ-PROXY-037, SPEC-PROXY-009
    /// @notice A repay with collateral in market B (whose vault-token reserve is not the first one listed) withdraws
    /// from that market's own reserve, derived from its vault token: the shares of market B fall by `units` and
    /// market A's account is untouched.
    function test_TEST_239_marketBReserveDerived() public {
        (bytes32 kb, address pb) = _pledgeAs(alice, MARKET_B, UNITS);
        _borrowAs(alice, MARKET_B, debtReserveId, 5000e18);
        swap.setDeleverage(1000e18, 2e12, 0);
        uint256 sharesA = _sharesOf(p, vtReserveId);
        vm.prank(alice);
        adapterC.repayWithCollateral(_rwc(MARKET_B, kb, 500_000_000, debtReserveId));
        assertEq(_sharesOf(pb, vtReserveIdB), UNITS - 500_000_000, "market B shares fell by units");
        assertEq(_sharesOf(p, vtReserveId), sharesA, "market A untouched");
        assertEq(_debtOf(pb, debtReserveId), 4000e18, "1,000 repaid");
    }

    // TEST-241 verifies: REQ-ADAPTER-069, REQ-ADAPTER-080, SPEC-PROXY-008, INV-080
    /// @notice With a gap `G > 0` left by an orphan seizure burn, a repay with collateral still succeeds and keeps `G`:
    /// the check compares with the gap read before the session, not with zero.
    function test_TEST_241_repayWithCollateralKeepsGap() public {
        (, address pb) = _pledgeAs(bob, MARKET_ID, UNITS);
        _borrowAs(bob, MARKET_ID, debtReserveId, 15_000e18);
        vtPrice.set(1.5e8);
        uint256 seized = swap.seizeAndKeep(aave.cdpSpoke, vt, vtReserveId, debtReserveId, pb, 2000e18);
        swap.burnUnderLock(MARKET_ID, vt, seized);
        vtPrice.set(2e8);
        int256 g = _gap();
        assertGt(g, 0, "gap opened");
        _borrowAs(alice, MARKET_ID, debtReserveId, 5000e18);
        swap.setDeleverage(1000e18, 2e12, 0);
        vm.prank(alice);
        adapterC.repayWithCollateral(_rwc(MARKET_ID, k1, 500_000_000, debtReserveId));
        assertEq(_gap(), g, "gap kept");
    }
}
