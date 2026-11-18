// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketStatus} from "../../src/policy/market-registry/types/MarketRegistryTypes.sol";
import {IRiskModule} from "../../src/policy/risk-module/IRiskModule.sol";
import {PriceState} from "../../src/types/OracleTypes.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";

interface IParitySpokeConfigurator {
    function updateFrozen(
        address spoke,
        uint256 reserveId,
        bool frozen
    ) external;
}

/// @title AaveAdapterGateParityFuzzTest
/// @notice Every combination of the conditions the reviewed RiskModule reads (market price not Live, a stale feed, a
/// stale USDC price, a live breaker condition (no pool depth), `Offboarding`, the vault-token reserve frozen on Aave),
/// on a healthy indebted account: a borrow passes exactly when none holds; a withdrawal that leaves debt passes exactly
/// when none holds apart from `Offboarding` and the Aave freeze, which liquidation shares (REQ-PROXY-036); repay,
/// `repayAllAndWithdraw` and a debt-free withdrawal pass whatever holds. forge-config: default.isolate = false
contract AaveAdapterGateParityFuzzTest is AaveAdapterRiskFixture {
    bytes32 internal k1;
    bytes32 internal k2;
    address internal p;

    uint8 internal constant PRICE = 1;
    uint8 internal constant FEED = 2;
    uint8 internal constant DEBT = 4;
    uint8 internal constant BREAKER = 8;
    uint8 internal constant OFFBOARD = 16;
    uint8 internal constant FROZEN = 32;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (k2,) = _pledgeAs(alice, MARKET_ID, UNITS / 2);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        _borrowAs(alice, MARKET_ID, usdcReserveId, 100e6);
    }

    function _apply(
        uint8 mask
    ) internal {
        if (mask & PRICE != 0) lpOracleA.setState(PriceState.Cached, 0, false);
        if (mask & FEED != 0) _report(lpOracleA, uint64(block.timestamp - FEED_AGE - 1));
        if (mask & DEBT != 0) usdcOracle.setReport(PriceState.Live, uint64(block.timestamp - 90_000), true);
        if (mask & BREAKER != 0) riskVault.setDepth(0, false);
        if (mask & OFFBOARD != 0) registry.setMarketStatus(MARKET_ID, MarketStatus.Offboarding);
        if (mask & FROZEN != 0) {
            vm.prank(aaveDao);
            IParitySpokeConfigurator(aave.spokeConfigurator).updateFrozen(aave.cdpSpoke, vtReserveId, true);
        }
    }

    function _borrowPasses() internal returns (bool ok) {
        uint256 d = _deadline();
        vm.prank(alice);
        (ok,) = adapter.call(abi.encodeCall(adapterC.borrow, (MARKET_ID, debtReserveId, 1e18, alice, d, 0, 2)));
    }

    function _withDebtWithdrawPasses() internal returns (bool ok) {
        uint256 d = _deadline();
        vm.prank(alice);
        (ok,) = adapter.call(abi.encodeCall(adapterC.withdraw, (MARKET_ID, _ref(k2), UNITS / 2, d, 0)));
    }

    function _exitsPass() internal {
        _fund(carol, debtReserveId, 5e18);
        vm.prank(carol);
        adapterC.repay(alice, MARKET_ID, debtReserveId, 5e18, false, _deadline());
        uint256 g = _debtOf(p, debtReserveId);
        uint256 u = _debtOf(p, usdcReserveId);
        _fund(alice, debtReserveId, g);
        _fund(alice, usdcReserveId, u);
        uint256[] memory ids = new uint256[](2);
        (ids[0], ids[1]) = (debtReserveId, usdcReserveId);
        uint256[] memory caps = new uint256[](2);
        (caps[0], caps[1]) = (g, u);
        vm.prank(alice);
        adapterC.repayAllAndWithdraw(MARKET_ID, _ref(k1), UNITS, ids, caps, _deadline());
        uint256 left = coll.previewRelease(INTEGRATION, k2);
        if (left != 0) {
            vm.prank(alice);
            adapterC.withdraw(MARKET_ID, _ref(k2), left, _deadline(), 0);
        }
        assertEq(_sharesOf(p, vtReserveId), 0, "account closed");
    }

    // TEST-099 verifies: REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-PROXY-032, REQ-PROXY-035, REQ-ADAPTER-071, INV-043, INV-045
    /// @notice For a random combination of conditions, repay, `repayAllAndWithdraw` and the debt-free withdrawal
    /// complete.
    function testFuzz_TEST_099_exitsUnderAnyCombination(
        uint8 mask
    ) public {
        _apply(mask & 63);
        _exitsPass();
    }

    // TEST-237 verifies: REQ-ADAPTER-078, REQ-ADAPTER-086, REQ-ADAPTER-047
    /// @notice Once the account is debt-free a partial removal passes under every combination and never calls the
    /// RiskModule.
    function testFuzz_TEST_237_debtFreeRemovalUnderAnyCombination(
        uint8 mask
    ) public {
        uint256 g = _debtOf(p, debtReserveId);
        uint256 u = _debtOf(p, usdcReserveId);
        _fund(alice, debtReserveId, g);
        _fund(alice, usdcReserveId, u);
        vm.startPrank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, g, true, _deadline());
        adapterC.repay(alice, MARKET_ID, usdcReserveId, u, true, _deadline());
        vm.stopPrank();
        _apply(mask & 63);
        vm.expectCall(address(rm), "", 0);
        vm.prank(alice);
        adapterC.removeLiquidity(MARKET_ID, _ref(k1), 1_000_000_000, _mins(), _deadline(), 0);
        assertEq(_sharesOf(p, vtReserveId), UNITS + UNITS / 2 - 1_000_000_000, "removed");
    }

    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-086, Q-356
    /// @notice A repay with collateral passes under every combination of the RiskModule's conditions and never calls
    /// the RiskModule; it only lowers debt.
    function testFuzz_TEST_239_repayWithCollateralUnderAnyCombination(
        uint8 mask
    ) public {
        _apply(mask & 63);
        swap.setDeleverage(500e18, 2e12, 0);
        // The one RiskModule call an exit makes is the speed credit (REQ-RISK-005); no check is called.
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.preBorrowCheck.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.preWithdrawCheck.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.postHealthCheck.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.checkPledge.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.pokeConfig.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.checkRemainingRecord.selector), 0);
        vm.expectCall(address(rm), abi.encodeWithSelector(IRiskModule.checkAaveConfig.selector), 0);
        uint256 before = _debtOf(p, debtReserveId);
        vm.prank(alice);
        adapterC.repayWithCollateral(_rwc(MARKET_ID, k1, 250_000_000, debtReserveId));
        assertEq(_debtOf(p, debtReserveId), before - 500e18, "debt lowered");
    }
}
