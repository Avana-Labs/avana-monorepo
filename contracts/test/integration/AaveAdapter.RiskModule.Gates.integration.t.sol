// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../src/custody/collateralization/ICollateralizationViews.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IRiskModuleChecks} from "../../src/policy/risk-module/IRiskModuleChecks.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {DriftReason} from "../../src/types/DriftReason.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PledgeCounters} from "../../src/types/PledgeCounters.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";

interface IGatesSpokeConfigurator {
    function updateFrozen(
        address spoke,
        uint256 reserveId,
        bool frozen
    ) external;
    function updateReservePriceSource(
        address spoke,
        uint256 reserveId,
        address priceSource
    ) external;
}

/// @title AaveAdapterRiskModuleGatesIntegrationTest
/// @notice The Adapter with the reviewed RiskModule on the real Aave V4 Spoke: the application pause refuses a borrow
/// and a withdrawal that leaves debt before the RiskModule is reached; Spoke-implementation drift, an Aave-side price
/// source switch and a second market's bad price state stop new risk on the account they touch while repay and the
/// debt-free exits stay open.
/// @dev The account holds two records in market A (10,000 and 5,000 vault tokens) and owes 1,000 GHO and 500 USDC.
/// forge-config: default.isolate = false
contract AaveAdapterRiskModuleGatesIntegrationTest is AaveAdapterRiskFixture {
    bytes32 internal k1;
    bytes32 internal k2;
    address internal p;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (k2,) = _pledgeAs(alice, MARKET_ID, UNITS / 2);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 500e6);
    }

    function _configurator() internal view returns (IGatesSpokeConfigurator) {
        return IGatesSpokeConfigurator(aave.spokeConfigurator);
    }

    function _expectBorrow(
        bytes memory err
    ) internal {
        uint256 nonce = adapterC.borrowNonce(p);
        uint256 d = _deadline();
        vm.expectRevert(err);
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, 1e18, alice, d, 0, nonce);
        assertEq(adapterC.borrowNonce(p), nonce, "nonce kept");
    }

    function _expectWithdrawWithDebt(
        bytes memory err
    ) internal {
        uint256 d = _deadline();
        vm.expectRevert(err);
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, d, 0);
    }

    /// @dev A third-party repay, fee collection, then repay of everything and the debt-free withdrawal of both records.
    function _repayAndExit() internal {
        _fund(carol, debtReserveId, 10e18);
        vm.prank(carol);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 10e18, false, _deadline());
        lpVault.accrueFees(k1, 10);
        vm.prank(alice);
        adapterC.collectFees(MARKET_ID, _ref(k1), _deadline());
        uint256 g = _debtOf(p, debtReserveId);
        uint256 u = _debtOf(p, usdcReserveId);
        _fund(alice, debtReserveId, g);
        _fund(alice, usdcReserveId, u);
        vm.startPrank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, g, true, _deadline());
        adapterC.repay(alice, MARKET_ID, usdcReserveId, u, true, _deadline());
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, _deadline(), 0);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, _deadline(), 0);
        vm.stopPrank();
        assertEq(lpVault.ownerOf(k1), alice, "k1 back");
        assertEq(lpVault.ownerOf(k2), alice, "k2 back");
        assertEq(_debtOf(p, debtReserveId) + _debtOf(p, usdcReserveId), 0, "debt-free");
    }

    // ─── The application pause comes before the RiskModule ───

    // TEST-027 verifies: REQ-ADAPTER-052
    // Sources: 2.7 REQ-ADAPTER-052 (borrow while Frozen or Paused: the RiskModule is not reached)
    /// @notice Under Frozen and under each Paused reason a borrow reverts with the Adapter's own error and
    /// `preBorrowCheck` is never called; with the pause lifted the same borrow reaches it and succeeds.
    function test_TEST_027_pausedOrFrozenBorrowNeverReachesTheRiskModule() public {
        PauseState[3] memory states = [PauseState.Frozen, PauseState.Paused, PauseState.Paused];
        PauseReason[3] memory reasons = [PauseReason.None, PauseReason.General, PauseReason.MintPathSuspect];
        bytes4[3] memory errs = [
            IAaveAdapterErrors.ApplicationFrozen.selector,
            IAaveAdapterErrors.ApplicationPaused.selector,
            IAaveAdapterErrors.ApplicationPaused.selector
        ];
        // Over the whole test exactly one `preBorrowCheck` reaches the RiskModule: the final borrow's.
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModuleChecks.preBorrowCheck.selector), 1);
        for (uint256 i = 0; i < 3; ++i) {
            _pause(states[i], reasons[i]);
            _expectBorrow(abi.encodeWithSelector(errs[i]));
        }
        _pause(PauseState.None, PauseReason.None);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1e18);
    }

    // TEST-019 verifies: REQ-ADAPTER-053
    // Sources: 2.7 REQ-ADAPTER-053 (withdraw-with-debt while Paused: refused before preWithdrawCheck)
    /// @notice Under each Paused reason a withdrawal that leaves debt reverts `ApplicationPaused` without calling
    /// `preWithdrawCheck`; a debt-free withdrawal of another account passes in the same state.
    function test_TEST_019_pausedWithdrawWithDebtNeverReachesTheRiskModule() public {
        (bytes32 kb,) = _pledgeAs(bob, MARKET_B, UNITS);
        PauseReason[2] memory reasons = [PauseReason.General, PauseReason.MintPathSuspect];
        // No `preWithdrawCheck` reaches the RiskModule anywhere below.
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModuleChecks.preWithdrawCheck.selector), 0);
        for (uint256 i = 0; i < 2; ++i) {
            _pause(PauseState.Paused, reasons[i]);
            _expectWithdrawWithDebt(abi.encodeWithSelector(IAaveAdapterErrors.ApplicationPaused.selector));
        }
        vm.prank(bob);
        adapterC.withdraw(MARKET_B, _ref(kb), UNITS, _deadline(), 0);
        assertEq(lpVault.ownerOf(kb), bob, "debt-free withdrawal under Paused");
    }

    // ─── Drift and other markets ───

    // TEST-182 verifies: REQ-ADAPTER-063
    // Sources: 5.1 TEST-182 (the Adapter half: exits stay open under Spoke implementation drift)
    /// @notice While the CDP Spoke's implementation is not the recorded one, `preBorrowCheck` reverts
    /// `ConfigDrift(0, SpokeImplementation)` for a borrow and a withdrawal that leaves debt, while a top-up of the
    /// indebted account, a third-party repay, fee collection and the debt-free withdrawals succeed.
    function test_TEST_182_spokeImplementationDriftKeepsExitsOpen() public {
        registry.setImplementationStale(true);
        bytes memory err =
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, 0, DriftReason.SpokeImplementation);
        _expectBorrow(err);
        _expectWithdrawWithDebt(err);
        (bytes32 k3,) = _pledgeAs(alice, MARKET_ID, UNITS / 10);
        assertEq(lpVault.ownerOf(k3), address(lpVault), "top-up of the indebted account taken");
        _repayAndExit();
    }

    // TEST-284 verifies: INV-099, Q-327
    // Sources: 4.1 INV-099 (the RiskModule half: a switched Aave source is drift for new risk)
    /// @notice The Aave DAO points the vault-token reserve's AaveOracle source at another contract: the RiskModule's
    /// drift check refuses a new account's pledge, a borrow and a withdrawal that leaves debt with
    /// `ConfigDrift(market, PriceSource)`; the market's own LPOracle state is unchanged, and repay and the debt-free
    /// exits stay open.
    function test_TEST_284_aaveSourceSwitchIsDriftForNewRiskOnly() public {
        rstore.setTokenCap(aave.hub, address(usdc), 1e30);
        rstore.setTokenCap(aave.hub, address(usdt), 1e30);
        rstore.setDepositorCap(aave.hub, 1e30);
        PledgeCounters memory k = ICollateralizationViews(address(coll)).getCounters(vt, bob);
        address bobProxy_ = makeAddr("bob's proxy");
        rm.checkPledge(bob, bobProxy_, MARKET_ID, INTEGRATION, bytes32(uint256(77)), UNITS, k, false);
        vm.prank(aaveDao);
        _configurator().updateReservePriceSource(aave.cdpSpoke, vtReserveId, address(lpOracleB));
        bytes memory err =
            abi.encodeWithSelector(IRiskModuleErrors.ConfigDrift.selector, MARKET_ID, DriftReason.PriceSource);
        vm.expectRevert(err);
        rm.checkPledge(bob, bobProxy_, MARKET_ID, INTEGRATION, bytes32(uint256(77)), UNITS, k, false);
        _expectBorrow(err);
        _expectWithdrawWithDebt(err);
        assertEq(uint8(lpOracleA.getPriceState().state), uint8(PriceState.Live), "the LPOracle's state is unchanged");
        _repayAndExit();
    }

    // TEST-226 verifies: REQ-ADAPTER-086
    // Sources: 5.1 TEST-226 (contagion: repay and debt-free withdrawal in market B stay open)
    /// @notice The wallet's market-B account owes GHO. Market B goes Cached, then Expired, then Drifting with its routes
    /// disagreeing, then Aave-frozen, and separately the USDC DebtOracle goes stale: in each state the market-B account
    /// is repaid in part, and at the end it repays in full and withdraws debt-free.
    function test_TEST_226_otherMarketStatesLeaveRepayAndExitOpen() public {
        (bytes32 kb, address pb) = _pledgeAs(alice, MARKET_B, UNITS);
        _report(lpOracleB, uint64(block.timestamp));
        _borrowAs(alice, MARKET_B, debtReserveId, 500e18);
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp - 100_000), true);
        PriceState[3] memory states = [PriceState.Cached, PriceState.Expired, PriceState.Drifting];
        for (uint256 i = 0; i < 3; ++i) {
            lpOracleB.setState(states[i], i == 2 ? 1 : 0, false);
            _fund(carol, debtReserveId, 10e18);
            vm.prank(carol);
            adapterC.repay(alice, MARKET_B, debtReserveId, 10e18, false, _deadline());
        }
        vm.prank(aaveDao);
        _configurator().updateFrozen(aave.cdpSpoke, vtReserveIdB, true);
        uint256 owed = _debtOf(pb, debtReserveId);
        assertEq(owed, 470e18, "three partial repays landed");
        _fund(alice, debtReserveId, owed);
        vm.startPrank(alice);
        adapterC.repay(alice, MARKET_B, debtReserveId, owed, true, _deadline());
        adapterC.withdraw(MARKET_B, _ref(kb), UNITS, _deadline(), 0);
        vm.stopPrank();
        assertEq(_debtOf(pb, debtReserveId), 0, "market B debt-free");
        assertEq(lpVault.ownerOf(kb), alice, "market B position returned");
    }
}
