// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../src/interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {MarketSpeedLimits} from "../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../src/policy/parameter-store/types/SpeedLimit.sol";
import {IRiskModuleErrors} from "../../src/policy/risk-module/IRiskModuleErrors.sol";
import {SpeedView} from "../../src/policy/risk-module/types/SpeedView.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {AaveAdapterRiskFixture} from "../utils/fixtures/AaveAdapterRiskFixture.sol";

/// @title AaveAdapterSpeedIntegrationTest
/// @notice The borrow-speed limit through the real AaveAdapter on the real local Aave V4 Hub, CDP Spoke and AaveOracle
/// (TEST-326): the windows' bases are the Hub's real owed amounts, a borrow charges both windows, a borrow over the
/// room reverts with the reported figures and passes once the room frees, and repay, withdrawal with and without debt
/// and `repayAllAndWithdraw` pass while every window is closed.
/// @dev The account holds two records ($30,000 at CF 80 %) and owes 1,000 GHO; the windows are cleared by waiting two
/// windows before each test sets its limits.
/// forge-config: default.isolate = false
contract AaveAdapterSpeedIntegrationTest is AaveAdapterRiskFixture {
    uint32 internal constant TAU = 3600;

    bytes32 internal k1;
    bytes32 internal k2;
    address internal p;

    function setUp() public override {
        super.setUp();
        (k1, p) = _pledgeAs(alice, MARKET_ID, UNITS);
        (k2,) = _pledgeAs(alice, MARKET_ID, UNITS / 2);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1000e18);
        // Past every window the setup charged under the store's open defaults.
        vm.warp(block.timestamp + 30 days);
        _report(lpOracleA, uint64(block.timestamp));
        _report(lpOracleB, uint64(block.timestamp));
    }

    function _limits(
        uint96 marketMax,
        uint96 debtMax
    ) internal {
        rstore.setMarketSpeed(MARKET_ID, MarketSpeedLimits(TAU, 0, 0, marketMax, marketMax, 0, 0));
        rstore.setDebtSpeed(aave.hub, address(debt), SpeedLimit(0, TAU, debtMax, debtMax));
    }

    function _borrowExpect(
        bytes memory err,
        uint256 amount
    ) internal {
        uint256 nonce = adapterC.borrowNonce(p);
        uint256 d = _deadline();
        vm.expectRevert(err);
        vm.prank(alice);
        adapterC.borrow(MARKET_ID, debtReserveId, amount, alice, d, 0, nonce);
    }

    // TEST-326 verifies: REQ-RISK-092, REQ-RISK-097, BOR-023
    function test_TEST_326_basesAreTheHubsOwedAmounts() public {
        rstore.setMarketSpeed(MARKET_ID, MarketSpeedLimits(TAU, 10_000, 0, 0, type(uint96).max, 0, 0));
        rstore.setDebtSpeed(aave.hub, address(debt), SpeedLimit(10_000, TAU, 0, type(uint96).max));
        (SpeedView memory m, SpeedView memory d) = rm.getBorrowSpeed(MARKET_ID, debtReserveId);
        uint256 owed = IAaveV4Hub(aave.hub).getSpokeTotalOwed(ghoAssetId, aave.cdpSpoke);
        assertGt(owed, 1000e18, "1,000 GHO plus a month of interest");
        assertEq(d.limit, owed, "100 % of the Hub's owed amount");
        assertGt(m.limit, 0);
        assertEq(m.used + d.used, 0, "windows cleared");
    }

    // TEST-326 verifies: REQ-RISK-092, REQ-RISK-098, SPEC-CAP-011, BOR-023, ATTACK-204
    function test_TEST_326_borrowChargesAndRefusesWithFigures() public {
        _limits(2000e8, 5000e18);
        uint256 t0 = block.timestamp;
        _borrowAs(alice, MARKET_ID, debtReserveId, 1500e18);
        (SpeedView memory m, SpeedView memory d) = rm.getBorrowSpeed(MARKET_ID, debtReserveId);
        assertEq(d.used, 1500e18, "debt window in GHO units");
        assertGe(m.used, 1500e8 - 1e8, "market window in USD at the AaveOracle price");
        uint256 room = m.available;
        _borrowExpect(
            abi.encodeWithSelector(
                IRiskModuleErrors.BorrowSpeedExceeded.selector, MARKET_ID, room, uint64(t0 + 2 * TAU)
            ),
            600e18
        );
        vm.warp(t0 + 2 * TAU);
        _report(lpOracleA, uint64(block.timestamp));
        _borrowAs(alice, MARKET_ID, debtReserveId, 600e18);
    }

    // TEST-326 verifies: REQ-RISK-092, REQ-RISK-098
    function test_TEST_326_debtWindowRefusesAcrossTheHub() public {
        _limits(1_000_000e8, 700e18);
        _borrowAs(alice, MARKET_ID, debtReserveId, 500e18);
        _borrowExpect(
            abi.encodeWithSelector(
                IRiskModuleErrors.DebtSpeedExceeded.selector,
                aave.hub,
                address(debt),
                200e18,
                uint64(block.timestamp + 2 * TAU)
            ),
            201e18
        );
        _borrowAs(alice, MARKET_ID, debtReserveId, 200e18);
    }

    // TEST-326 verifies: REQ-RISK-094, REQ-RISK-096, REQ-RISK-005
    function test_TEST_326_exitsPassWithClosedWindows() public {
        rstore.setMarketSpeed(MARKET_ID, MarketSpeedLimits(0, 0, 0, 0, 0, 0, 0));
        rstore.setDebtSpeed(aave.hub, address(debt), SpeedLimit(0, 0, 0, 0));
        _borrowExpect(abi.encodeWithSelector(IRiskModuleErrors.BorrowSpeedExceeded.selector, MARKET_ID, 0, 0), 1e18);
        // Withdrawal of the second record with debt left (HF stays above 1).
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k2), UNITS / 2, _deadline(), 1.1e18);
        assertEq(lpVault.ownerOf(k2), alice, "withdrawn with debt");
        // Repay all, then the debt-free withdrawal of the last record.
        uint256 owed = _debtOf(p, debtReserveId);
        _fund(alice, debtReserveId, owed);
        vm.prank(alice);
        adapterC.repay(alice, MARKET_ID, debtReserveId, owed, false, _deadline());
        assertEq(_borrowCountOf(p), 0, "debt-free");
        vm.prank(alice);
        adapterC.withdraw(MARKET_ID, _ref(k1), UNITS, _deadline(), 0);
        assertEq(lpVault.ownerOf(k1), alice, "k1 back");
    }

    // TEST-326 verifies: REQ-RISK-092, SPEC-CAP-013, BOR-023
    function test_TEST_326_usdcBorrowChargesUsdAndSixDecimalUnits() public {
        usdcOracle.setReport(PriceState.Live, uint64(block.timestamp), true);
        rstore.setMarketSpeed(MARKET_ID, MarketSpeedLimits(TAU, 0, 0, 5000e8, 5000e8, 0, 0));
        rstore.setDebtSpeed(aave.hub, address(usdcDebt), SpeedLimit(0, TAU, 3000e6, 3000e6));
        _borrowAs(alice, MARKET_ID, usdcReserveId, 2000e6);
        (SpeedView memory m, SpeedView memory d) = rm.getBorrowSpeed(MARKET_ID, usdcReserveId);
        assertEq(d.used, 2000e6, "USDC window in 6-decimal base units");
        uint256 price = IAaveV4Oracle(IAaveV4Spoke(aave.cdpSpoke).ORACLE()).getReservePrice(usdcReserveId);
        assertEq(m.used, (2000e6 * price + 1e6 - 1) / 1e6, "market window at the AaveOracle price, rounded up");
        // The GHO window is a different (Hub, asset): untouched.
        (, SpeedView memory g) = rm.getBorrowSpeed(MARKET_ID, debtReserveId);
        assertEq(g.used, 0);
    }

    // TEST-326 verifies: REQ-RISK-092, SPEC-CAP-012
    function test_TEST_326_interestRaisesTheBase() public {
        rstore.setDebtSpeed(aave.hub, address(debt), SpeedLimit(10_000, TAU, 0, type(uint96).max));
        (, SpeedView memory before) = rm.getBorrowSpeed(MARKET_ID, debtReserveId);
        vm.warp(block.timestamp + 365 days);
        (, SpeedView memory later) = rm.getBorrowSpeed(MARKET_ID, debtReserveId);
        assertGt(later.limit, before.limit, "accrued interest is debt the base counts");
        assertEq(later.limit, IAaveV4Hub(aave.hub).getSpokeTotalOwed(ghoAssetId, aave.cdpSpoke));
    }

    // TEST-326 verifies: REQ-RISK-092, ATTACK-205
    function test_TEST_326_twoWalletsShareTheMarketWindow() public {
        _limits(2000e8, 1_000_000e18);
        _pledgeAs(bob, MARKET_ID, UNITS);
        _borrowAs(alice, MARKET_ID, debtReserveId, 1200e18);
        address pb = adapterC.proxyOf(bob, MARKET_ID);
        uint256 nonce = adapterC.borrowNonce(pb);
        uint256 dl = _deadline();
        vm.expectRevert();
        vm.prank(bob);
        adapterC.borrow(MARKET_ID, debtReserveId, 900e18, bob, dl, 0, nonce);
        _borrowAs(bob, MARKET_ID, debtReserveId, 700e18);
        (SpeedView memory m,) = rm.getBorrowSpeed(MARKET_ID, debtReserveId);
        assertGe(m.used, 1899e8, "both wallets in one window");
    }
}
