// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";
import {AaveAdapterRiskHandler, RiskWorld} from "./handlers/AaveAdapterRiskHandler.sol";

/// @title AaveAdapterRiskGatesInvariantTest
/// @notice The Adapter with the reviewed RiskModule on the real Aave V4 Spoke under random changes of every input the
/// RiskModule reads. After every call: no borrow and no withdrawal that leaves debt completed while a condition that
/// refuses it held; every account that borrowed ends at Aave health factor ≥ 1; repay never reverted.
/// forge-config: default.isolate = false
contract AaveAdapterRiskGatesInvariantTest is AaveAdapterRiskFixture {
    AaveAdapterRiskHandler internal handler;

    function setUp() public override {
        super.setUp();
        RiskWorld memory world = RiskWorld({
            adapter: adapterC,
            coll: coll,
            registry: registry,
            lpOracle: lpOracleA,
            usdcOracle: usdcOracle,
            lpVault: lpVault,
            spoke: IAaveV4Spoke(aave.cdpSpoke),
            configurator: aave.spokeConfigurator,
            aaveDao: aaveDao,
            market: MARKET_ID,
            vtReserve: vtReserveId,
            gho: debt,
            ghoReserve: debtReserveId,
            integrationId: INTEGRATION,
            usdc: address(usdc),
            usdt: address(usdt),
            feedUsdc: feedUsdc,
            feedUsdt: feedUsdt,
            feedAge: FEED_AGE
        });
        handler = new AaveAdapterRiskHandler(world, [alice, bob, carol]);
        address[3] memory ws = [alice, bob, carol];
        for (uint256 i = 0; i < 3; ++i) {
            (bytes32 a,) = _pledgeAs(ws[i], MARKET_ID, UNITS);
            (bytes32 b,) = _pledgeAs(ws[i], MARKET_ID, UNITS / 2);
            handler.track(ws[i], a);
            handler.track(ws[i], b);
            _borrowAs(ws[i], MARKET_ID, debtReserveId, 100e18);
            _borrowAs(ws[i], MARKET_ID, usdcReserveId, 50e6);
        }
        targetContract(address(handler));
        bytes4[] memory actions = new bytes4[](13);
        actions[0] = AaveAdapterRiskHandler.setPrice.selector;
        actions[1] = AaveAdapterRiskHandler.report.selector;
        actions[2] = AaveAdapterRiskHandler.debtReport.selector;
        actions[3] = AaveAdapterRiskHandler.setBreaker.selector;
        actions[4] = AaveAdapterRiskHandler.setOffboarding.selector;
        actions[5] = AaveAdapterRiskHandler.setReserveFrozen.selector;
        actions[6] = AaveAdapterRiskHandler.setDrift.selector;
        actions[7] = AaveAdapterRiskHandler.warp.selector;
        actions[8] = AaveAdapterRiskHandler.borrow.selector;
        actions[9] = AaveAdapterRiskHandler.borrow.selector;
        actions[10] = AaveAdapterRiskHandler.withdrawWithDebt.selector;
        actions[11] = AaveAdapterRiskHandler.repay.selector;
        actions[12] = AaveAdapterRiskHandler.pledge.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: actions}));
    }

    // TEST-095 verifies: REQ-PROXY-019, REQ-PROXY-020, REQ-PROXY-036, REQ-PROXY-079, REQ-ADAPTER-049, REQ-ADAPTER-094, SPEC-PROXY-002, INV-004, INV-023, INV-060, INV-072
    // Sources: 5.1 TEST-095
    /// @notice No borrow and no withdrawal with debt completed while the market's price was not Live and borrowable,
    /// a feed or the USDC DebtOracle was stale, a breaker was latched or a drift held; no borrow while the market was
    /// Offboarding or its reserve frozen on Aave.
    function invariant_TEST_095_noRiskIncreaseThroughAClosedGate() public view {
        assertEq(handler.uncheckedSuccesses(), 0, "risk-increasing action through a closed gate");
    }

    // TEST-095 verifies: REQ-PROXY-022, SPEC-PROXY-001, INV-025
    /// @notice Every account ends at Aave health factor ≥ 1 after the campaign's borrows and withdrawals.
    function invariant_TEST_095_healthAtLeastOne() public view {
        address[3] memory ws = [alice, bob, carol];
        for (uint256 i = 0; i < 3; ++i) {
            address p = adapterC.proxyOf(ws[i], MARKET_ID);
            assertGe(_hf(p), 1e18, "health factor");
        }
    }

    // TEST-099 verifies: REQ-PROXY-032, REQ-ADAPTER-086, INV-043
    /// @notice Repay never reverted, whatever the RiskModule's inputs.
    function invariant_TEST_099_repayAlwaysOpen() public view {
        assertEq(handler.exitFailures(), 0, string(handler.lastError()));
    }

    // TEST-095 verifies: REQ-PROXY-020
    /// @notice A directed sequence closes each gate in turn and shows the borrow refused, then reopens them all and
    /// shows it passing, so the campaign's gates are live.
    function test_TEST_095_gatesOpenAndClose() public {
        handler.setBreaker(true);
        handler.borrow(0, 10e18);
        assertEq(handler.borrowsDone(), 0, "breaker refuses");
        handler.setBreaker(false);
        handler.setOffboarding(true);
        handler.borrow(0, 10e18);
        assertEq(handler.borrowsDone(), 0, "offboarding refuses");
        handler.setOffboarding(false);
        handler.setReserveFrozen(true);
        handler.borrow(0, 10e18);
        assertEq(handler.borrowsDone(), 0, "frozen reserve refuses");
        handler.setReserveFrozen(false);
        handler.setDrift(true);
        handler.borrow(0, 10e18);
        assertEq(handler.borrowsDone(), 0, "drift refuses");
        handler.setDrift(false);
        handler.setPrice(2);
        handler.borrow(0, 10e18);
        assertEq(handler.borrowsDone(), 0, "a cached price refuses");
        handler.setPrice(4);
        handler.debtReport(100_000, true);
        handler.borrow(0, 10e18);
        assertEq(handler.borrowsDone(), 0, "a stale debt price refuses");
        handler.debtReport(0, true);
        handler.borrow(0, 10e18);
        assertEq(handler.borrowsDone(), 1, "all gates open");
        assertEq(handler.uncheckedSuccesses(), 0, "consistent");
    }
}
