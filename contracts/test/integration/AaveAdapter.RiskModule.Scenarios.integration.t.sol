// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskStatus} from "../../src/amm/types/AmmTypes.sol";
import {ILPVault} from "../../src/custody/lp-vault/ILPVault.sol";
import {IAaveAdapterBase} from "../../src/policy/aave-adapter/IAaveAdapterBase.sol";
import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/AaveAdapterTypes.sol";
import {BreakerReasons} from "../../src/policy/market-registry/types/Breaker.sol";
import {DebtReserveDef, MarketStatus} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {IRiskModule} from "../../src/policy/risk-module/IRiskModule.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {DriftReason} from "../../src/types/MarketTypes.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";

/// @title AaveAdapterRiskModuleScenariosIntegrationTest
/// @notice Account scope, gate precedence and the repay with collateral against the reviewed RiskModule on the real
/// Aave V4 Spoke: the Adapter's own bounds (deadline, proxy, debt reserve, receiver, nonce) come before any RiskModule
/// gate; the RiskModule's scope is the account's one market and every reserve it borrows;
/// a repay with collateral and every exit never call the RiskModule, so no gate it applies can stop them.
/// forge-config: default.isolate = false
contract AaveAdapterRiskModuleScenariosIntegrationTest is AaveAdapterRiskFixture {
    bytes32 internal k1;
    bytes32 internal k2;
    address internal p;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (k2,) = _pledgeAs(alice, MARKET_ID, UNITS / 2);
        _borrowAs(alice, MARKET_ID, debtReserveId, 5000e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 1000e6);
    }

    function _borrowExpect(
        bytes memory err
    ) internal {
        uint256 n = adapterC.borrowNonce(p);
        uint256 d = _deadline();
        vm.expectRevert(err);
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, d, 0, n);
    }

    function _withdrawExpect(
        bytes memory err
    ) internal {
        uint256 d = _deadline();
        vm.expectRevert(err);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, d, 0);
    }

    function _stopEverythingTheRiskModuleReads() internal {
        lpOracleA.setState(PriceState.Expired, 0, false);
        usdcOracle.setReport(PriceState.Expired, uint64(block.timestamp), false);
        riskVault.setDepth(0, false);
        swap.setActiveKeeperCount(0);
    }

    // ─── Precedence: the Adapter's bounds before the RiskModule ───

    // ─── Scope: one market, every reserve the account borrows ───

    // TEST-030 verifies: REQ-ADAPTER-067, REQ-ADAPTER-057, REQ-PROXY-009, INV-073
    /// @notice A reserve the account still owes but the registry no longer approves stops every borrow and every
    /// withdrawal with debt (`ConfigDrift(0, BorrowedUnapprovedReserve)` in the RiskModule; `UnknownDebtReserve` in the
    /// Adapter for that reserve itself); repay of it and the exits never read the set and pass.
    function test_TEST_030_unapprovedHeldReserve() public {
        DebtReserveDef memory u = _debtDef(usdcReserveId, address(usdcDebt), 6, usdcAssetId);
        u.priceSource = address(usdcOracle);
        u.approved = false;
        registry.setDebtReserve(aave.cdpSpoke, usdcReserveId, u);
        bytes memory drift =
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 0, DriftReason.BorrowedUnapprovedReserve);
        _borrowExpect(drift);
        _withdrawExpect(drift);
        uint256 d = _deadline();
        vm.expectRevert(
            abi.encodeWithSelector(IAaveAdapterBase.UnknownDebtReserve.selector, aave.cdpSpoke, usdcReserveId)
        );
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, usdcReserveId, 1e6, alice, d, 0, 2);
        uint256 owed = _debtOf(p, usdcReserveId);
        _fund(alice, usdcReserveId, owed);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, usdcReserveId, owed, true, d);
        assertEq(_debtOf(p, usdcReserveId), 0, "repaid without the set");
    }

    // TEST-030 verifies: REQ-PROXY-009, INV-073
    /// @notice A registry record that disagrees with the Spoke's reserve (another asset) stops borrowing with
    /// `ConfigDrift(0, DebtReserveMismatch)`.
    function test_TEST_030_debtRecordMismatch() public {
        DebtReserveDef memory u = _debtDef(usdcReserveId, address(debt), 6, usdcAssetId);
        u.priceSource = address(usdcOracle);
        registry.setDebtReserve(aave.cdpSpoke, usdcReserveId, u);
        _borrowExpect(
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 0, DriftReason.DebtReserveMismatch)
        );
    }

    // ─── Repay with collateral and exits reach no RiskModule gate ───

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-086, REQ-ADAPTER-047, Q-356
    /// @notice With every gate the RiskModule applies failing (sequencer aside, which the Adapter itself reads for a
    /// repay with collateral), a repay with collateral completes and calls no RiskModule check.
    function test_TEST_239_repayWithCollateralCallsNoRiskModule() public {
        lpOracleA.setState(PriceState.Expired, 0, false);
        usdcOracle.setReport(PriceState.Expired, uint64(block.timestamp), false);
        riskVault.setDepth(0, false);
        swap.setActiveKeeperCount(0);
        swap.setDeleverage(1000e18, 2e12, 0);
        // An exit makes no RiskModule call; no check is called.
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.preBorrowCheck.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.preWithdrawCheck.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.postHealthCheck.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.checkPledge.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.pokeConfig.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.checkRemainingRecord.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.checkAaveConfig.selector), 0);
        RepayWithCollateralParams memory params = _rwc(MARKET_ID, k1, 500_000_000, debtReserveId);
        vm.prank(alice);
        (uint256 repaid,) = adapterC.repayWithCollateral(params);
        assertEq(repaid, 1000e18, "repaid");
        assertEq(_debtOf(p, debtReserveId), 4000e18, "debt lowered");
    }

    // TEST-099 verifies: REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-PROXY-035, INV-043, INV-045
    /// @notice Every exit completes with every RiskModule gate failing, the sequencer down included, and none calls a
    /// RiskModule check.
    function test_TEST_099_exitsCallNoRiskModule() public {
        _stopEverythingTheRiskModuleReads();
        // An exit makes no RiskModule call; no check is called.
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.preBorrowCheck.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.preWithdrawCheck.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.postHealthCheck.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.checkPledge.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.pokeConfig.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.checkRemainingRecord.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.checkAaveConfig.selector), 0);
        uint256 g = _debtOf(p, debtReserveId);
        uint256 u = _debtOf(p, usdcReserveId);
        _fund(alice, debtReserveId, g);
        _fund(alice, usdcReserveId, u);
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (debtReserveId, usdcReserveId);
        uint256[] memory caps = new uint256[](2);
        (caps[0], caps[1]) = (g, u);
        vm.startPrank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k2), UNITS / 2, ids, caps, _deadline());
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), 1_000_000_000, _mins(), _deadline(), 0);
        adapterC.collectFees(MARKET_ID, _ref(k1), _deadline());
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS - 1_000_000_000, _deadline(), 0);
        adapterC.refreshDebtMark(p);
        vm.stopPrank();
        assertEq(_sharesOf(p, vtReserveId), 0, "account closed");
    }

    // ─── Exact numbers through the reviewed health check ───

    // TEST-027 verifies: SPEC-PROXY-001, REQ-PROXY-022, REQ-PROXY-024
    /// @notice The `Borrowed` health factor is the reviewed RiskModule's value, the Spoke's own: $30,000 at CF 0.80
    /// against 5,000 GHO and 1,000 USDC at $1.00 after a further 4,000 GHO.
    function test_TEST_027_borrowedReportsSpokeHealth() public {
        uint256 d = _deadline();
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 4000e18, alice, d, 1.5e18, 2);
        assertEq(_hf(p), uint256(24_000e18) * 1e18 / 10_000e18, "2.4");
        vm.expectRevert(
            abi.encodeWithSelector(
                IRiskModuleErrors.HealthFactorTooLow.selector, uint256(24_000e18) * 1e18 / 11_000e18, 2.3e18
            )
        );
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1000e18, alice, d, 2.3e18, 3);
    }

    // TEST-028 verifies: REQ-ADAPTER-094, REQ-PROXY-018, REQ-ADAPTER-049
    /// @notice A market breaker is the market's own: market A's pool-depth breaker and Offboarding status stop market
    /// A's account, while the same wallet's account in market B keeps borrowing; market B's pool-depth breaker stops
    /// only B, and B borrows again in the same block once its depth is back.
    function test_TEST_028_breakerScopedToMarket() public {
        (, address pB) = _pledgeAs(alice, MARKET_B, UNITS);
        _noDepth(MARKET_ID);
        registry.setMarketStatus(MARKET_ID, MarketStatus.Offboarding);
        _borrowExpect(abi.encodeWithSelector(IRiskModuleErrors.MarketOffboarding.selector, MARKET_ID));
        _borrowAs(alice, MARKET_B, debtReserveId, 100e18);
        assertEq(_debtOf(pB, debtReserveId), 100e18, "market B borrows");
        _noDepth(MARKET_B);
        uint256 d = _deadline();
        vm.expectRevert(
            abi.encodeWithSelector(IRiskModuleErrors.BreakerTripped.selector, MARKET_B, BreakerReasons.POOL_DEPTH)
        );
        vm.prank(alice);
        adapterC.borrow(MARKET_B, debtReserveId, 1e18, alice, d, 0, 1);
        vm.clearMockedCalls();
        vm.prank(alice);
        adapterC.borrow(MARKET_B, debtReserveId, 1e18, alice, d, 0, 1);
        assertEq(_debtOf(pB, debtReserveId), 101e18, "market B borrows once its depth is back");
    }

    /// @dev The market's LPVault reports no pool depth, whatever the window: its `POOL_DEPTH` condition holds.
    function _noDepth(
        uint256 marketId
    ) internal {
        vm.mockCall(
            address(riskVault),
            abi.encodeWithSelector(ILPVault.riskStatus.selector, marketId),
            abi.encode(RiskStatus(0, false))
        );
    }
}
