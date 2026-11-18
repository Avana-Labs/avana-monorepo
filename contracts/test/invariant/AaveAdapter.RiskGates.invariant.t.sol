// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";
import {AaveAdapterRiskHandler, RiskWorld} from "./handlers/AaveAdapterRiskHandler.sol";
import {HandlerReach} from "./handlers/HandlerReach.sol";

/// @title AaveAdapterRiskGatesInvariantTest
/// @notice The Adapter with the reviewed RiskModule on the real Aave V4 Spoke under random changes of every input the
/// RiskModule reads. After every call: no borrow and no withdrawal that leaves debt completed while a condition that
/// refuses it held; every account that borrowed ends at Aave health factor ≥ 1; repay never reverted.
/// forge-config: default.isolate = false
contract AaveAdapterRiskGatesInvariantTest is AaveAdapterRiskFixture, HandlerReach {
    AaveAdapterRiskHandler internal handler;

    function setUp() public override {
        super.setUp();
        lpOracleA.setLegMaxAge(FEED_AGE);
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

    // TEST-082 verifies: TEST-007
    /// @notice What the handler does: over 32 fixed-seed runs of 50 calls from set-up, counts per action the calls that
    /// changed the state of a contract other than the handler and this test, the skipped and failed calls and the
    /// calls that returned without changing anything; each action must change the state in at least its floor of
    /// calls (`forge test -vv` prints the table).
    function test_TEST_082_handlerReach() public {
        (bytes4[] memory actions, string[] memory names,) = _reachActions();
        address[] memory own = new address[](2);
        (own[0], own[1]) = (address(handler), address(this));
        Reach memory r = _replayLanded(address(handler), actions, bytes4(0), 32, 50, 0, own, true);
        // Floors: 80 % of the landed share measured with these seeds, rounded down to 5 %; a check's normal return lands.
        uint256[] memory floors = new uint256[](12);
        bool[] memory check = new bool[](12);
        floors[0] = 60; // setPrice
        floors[1] = 80; // report
        floors[2] = 80; // debtReport
        floors[3] = 40; // setBreaker
        floors[4] = 45; // setOffboarding
        floors[5] = 35; // setReserveFrozen
        floors[6] = 40; // setDrift
        floors[7] = 80; // warp
        check[7] = true; // warp
        floors[10] = 80; // repay
        floors[11] = 80; // pledge
        _check(r, names, new string[](0), floors, new uint256[](0), check);
    }

    function _reached() internal pure override returns (bool[] memory hit) {
        hit = new bool[](0);
    }

    /// @dev The targeted actions, their names and the type of each of their parameters (see `_typed`).
    function _reachActions()
        internal
        pure
        returns (bytes4[] memory actions, string[] memory names, int16[][] memory kinds)
    {
        (actions, names, kinds) = (new bytes4[](12), new string[](12), new int16[][](12));
        (actions[0], names[0]) = (AaveAdapterRiskHandler.setPrice.selector, "setPrice");
        kinds[0] = new int16[](1);
        kinds[0][0] = 8;
        (actions[1], names[1]) = (AaveAdapterRiskHandler.report.selector, "report");
        kinds[1] = new int16[](1);
        kinds[1][0] = 32;
        (actions[2], names[2]) = (AaveAdapterRiskHandler.debtReport.selector, "debtReport");
        kinds[2] = new int16[](2);
        kinds[2][0] = 32;
        kinds[2][1] = 1;
        (actions[3], names[3]) = (AaveAdapterRiskHandler.setBreaker.selector, "setBreaker");
        kinds[3] = new int16[](1);
        kinds[3][0] = 1;
        (actions[4], names[4]) = (AaveAdapterRiskHandler.setOffboarding.selector, "setOffboarding");
        kinds[4] = new int16[](1);
        kinds[4][0] = 1;
        (actions[5], names[5]) = (AaveAdapterRiskHandler.setReserveFrozen.selector, "setReserveFrozen");
        kinds[5] = new int16[](1);
        kinds[5][0] = 1;
        (actions[6], names[6]) = (AaveAdapterRiskHandler.setDrift.selector, "setDrift");
        kinds[6] = new int16[](1);
        kinds[6][0] = 1;
        (actions[7], names[7]) = (AaveAdapterRiskHandler.warp.selector, "warp");
        kinds[7] = new int16[](1);
        kinds[7][0] = 32;
        (actions[8], names[8]) = (AaveAdapterRiskHandler.borrow.selector, "borrow");
        kinds[8] = new int16[](2);
        kinds[8][0] = 8;
        kinds[8][1] = 256;
        (actions[9], names[9]) = (AaveAdapterRiskHandler.withdrawWithDebt.selector, "withdrawWithDebt");
        kinds[9] = new int16[](1);
        kinds[9][0] = 8;
        (actions[10], names[10]) = (AaveAdapterRiskHandler.repay.selector, "repay");
        kinds[10] = new int16[](2);
        kinds[10][0] = 8;
        kinds[10][1] = 256;
        (actions[11], names[11]) = (AaveAdapterRiskHandler.pledge.selector, "pledge");
        kinds[11] = new int16[](1);
        kinds[11][0] = 8;
    }

    function _calldata(
        bytes4 selector,
        uint256 seed
    ) internal pure override returns (bytes memory) {
        (bytes4[] memory actions,, int16[][] memory kinds) = _reachActions();
        for (uint256 k = 0; k < actions.length; ++k) {
            if (actions[k] == selector) return _typed(selector, kinds[k], seed);
        }
        return abi.encodePacked(selector);
    }

    // TEST-095 verifies: REQ-PROXY-019, REQ-PROXY-020, REQ-PROXY-036, REQ-PROXY-079, REQ-ADAPTER-049, REQ-ADAPTER-094, SPEC-PROXY-002, INV-004, INV-023, INV-060, INV-072
    // Sources: 5.1 TEST-095
    // TEST-106 verifies: REQ-PROXY-020; shared: the same campaign turns Aave drift (receiveSharesEnabled on the vault-token reserve) on and off and counts any borrow that completed while it held
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
