// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {ILensSpeed} from "../../src/lens/lens/ILensSpeed.sol";
import {BorrowSpeedView} from "../../src/lens/lens/types/BorrowSpeedView.sol";
import {MarketSpeedLimits} from "../../src/policy/parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../../src/policy/parameter-store/types/SpeedLimit.sol";
import {SpeedView} from "../../src/policy/risk-module/types/SpeedView.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @notice A Lock stand-in whose state the test sets.
contract SpeedLockStub {
    bool public isLocked;

    function set(
        bool on
    ) external {
        isLocked = on;
    }
}

/// @title LensSpeedUnitTest
/// @notice `LensSpeedModule` (2.17 REQ-LENS-061) on the real RiskModule: the two borrow windows unchanged,
/// `availableNow` as the smaller of the market room converted at the reserve's price (rounded down) and the debt
/// window's room, the earlier `moreAt`, the pledge window, and `Locked()` while the Lock is held.
contract LensSpeedUnitTest is RiskModuleFixture {
    uint256 internal constant TAU = 21_600;
    uint256 internal constant E8 = 1e8;

    ILensSpeed internal lens;
    SpeedLockStub internal lock;

    function setUp() public {
        _deployRiskWorld();
        _enableUsdcDebt();
        _debt(1.5e18, 1000);
        rHub.setSpokeListed(USDC_ASSET, address(spoke), true);
        hub.setOwed(GHO_ASSET, address(spoke), 1_000_000e18, 0);
        hub.setOwed(USDC_ASSET, address(spoke), 2_400_000e6, 0);
        aaveOracle.setPrice(USDC_RESERVE, 1e8);
        store.setMarketSpeed(
            mid, MarketSpeedLimits(uint32(TAU), 2500, 2500, 250_000e8, 2_500_000e8, 1_000_000e8, 10_000_000e8)
        );
        store.setDebtSpeed(address(hub), address(usdc), SpeedLimit(2500, uint32(TAU), 500_000e6, 5_000_000e6));
        lock = new SpeedLockStub();
        address[9] memory core = [
            address(coll),
            makeAddr("proxyManager"),
            address(adapter),
            address(lock),
            address(registry),
            address(store),
            address(riskModule),
            address(swap),
            makeAddr("payoutEscrow")
        ];
        // Deployed from its artifact: importing the module would pull this fixture into the via-IR Lens module
        // compilation unit.
        lens = ILensSpeed(deployCode("LensSpeedModule.sol:LensSpeedModule", abi.encode(core)));
    }

    // TEST-327 verifies: REQ-LENS-061, REQ-RISK-097, BOR-024
    function test_TEST_327_availableNowIsTheSmallerRoomInAssetUnits() public {
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 600_000e6);
        hub.setOwed(USDC_ASSET, address(spoke), 3_000_000e6, 0);
        aaveOracle.setPrice(USDC_RESERVE, 99_990_000);
        BorrowSpeedView memory v = lens.getBorrowSpeed(mid, USDC_RESERVE);
        (SpeedView memory m, SpeedView memory d) = riskModule.getBorrowSpeed(mid, USDC_RESERVE);
        assertEq(abi.encode(v.market), abi.encode(m), "market window unchanged");
        assertEq(abi.encode(v.debt), abi.encode(d), "debt window unchanged");
        // Market room $249,925 at $0.9999 = 249,949.99... USDC; the USDC window (L 600,000, used 600,000) has none.
        assertEq(d.available, 0);
        assertEq(v.availableNow, 0, "the debt window binds");
        // Loosen the USDC window: now the market room binds, converted down.
        store.setDebtSpeed(address(hub), address(usdc), SpeedLimit(2500, uint32(TAU), 5_000_000e6, 5_000_000e6));
        v = lens.getBorrowSpeed(mid, USDC_RESERVE);
        assertEq(v.market.available, 249_925 * E8);
        assertEq(v.availableNow, (249_925 * E8 * 1e6) / 99_990_000, "249,949.994999 USDC, rounded down");
        assertEq(v.moreAt, uint64(T0 + 2 * TAU));
    }

    // TEST-327 verifies: REQ-LENS-061, BOR-024
    function test_TEST_327_workedExampleOfThreePointTwo() public {
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 600_000e6);
        hub.setOwed(USDC_ASSET, address(spoke), 3_000_000e6, 0);
        store.setDebtSpeed(address(hub), address(usdc), SpeedLimit(2500, uint32(TAU), 5_000_000e6, 5_000_000e6));
        // At $1.00 the market room is $250,000; at $0.9999 the 3.2 example converts $250,000 to 250,025.0025 USDC.
        assertEq(lens.getBorrowSpeed(mid, USDC_RESERVE).availableNow, 250_000e6);
        uint256 converted = (250_000 * E8 * 1e6) / 99_990_000;
        assertEq(converted, 250_025_002_500);
    }

    // TEST-327 verifies: REQ-LENS-061
    function test_TEST_327_earlierMoreAtAndUnavailable() public {
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 100_000e6);
        // Every time is derived from the fixture's start T0.
        uint256 t0 = T0;
        vm.warp(t0 + TAU);
        _report(uint64(t0 + TAU), 1e8, 1e8);
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 100_000e18);
        // Market window: prev 100,000 (frees at t0 + 2 tau); USDC window: curr 100,000 since t0 (frees at t0 + 2 tau).
        BorrowSpeedView memory v = lens.getBorrowSpeed(mid, USDC_RESERVE);
        assertEq(v.market.moreAt, uint64(t0 + 2 * TAU));
        assertEq(v.moreAt, uint64(t0 + 2 * TAU));
        BorrowSpeedView memory u = lens.getBorrowSpeed(mid + 40, USDC_RESERVE);
        assertTrue(u.market.unavailable && u.debt.unavailable);
        assertEq(u.availableNow, 0);
        assertEq(u.moreAt, 0);
    }

    // TEST-327 verifies: REQ-LENS-061, REQ-LENS-006
    function test_TEST_327_pledgeViewAndLock() public {
        SpeedView memory p = lens.getPledgeSpeed(mid);
        assertEq(abi.encode(p), abi.encode(riskModule.getPledgeSpeed(mid)));
        assertEq(p.limit, 1_000_000e8, "empty market: P_min");
        lock.set(true);
        vm.expectRevert(ILensErrors.Locked.selector);
        lens.getPledgeSpeed(mid);
        vm.expectRevert(ILensErrors.Locked.selector);
        lens.getBorrowSpeed(mid, USDC_RESERVE);
    }

    // TEST-327 verifies: REQ-LENS-061, BOR-024
    function test_TEST_327_conversionRoundsDownAtEveryPrice() public {
        store.setDebtSpeed(address(hub), address(usdc), SpeedLimit(2500, uint32(TAU), 5_000_000e6, 5_000_000e6));
        uint256[4] memory prices = [uint256(1), 99_990_000, 1e8, 100_010_000];
        for (uint256 i = 0; i < prices.length; ++i) {
            aaveOracle.setPrice(USDC_RESERVE, prices[i]);
            BorrowSpeedView memory v = lens.getBorrowSpeed(mid, USDC_RESERVE);
            uint256 expected = (v.market.available * 1e6) / prices[i];
            if (expected > v.debt.available) expected = v.debt.available;
            assertEq(v.availableNow, expected);
            // Borrowing exactly availableNow fits the market window: its USD charge never exceeds the room.
            uint256 charge = (v.availableNow * prices[i] + 1e6 - 1) / 1e6;
            assertLe(charge, v.market.available, "availableNow is borrowable");
        }
    }

    // TEST-327 verifies: REQ-LENS-061
    function test_TEST_327_availableNowIsBorrowableThroughTheRiskModule() public {
        store.setDebtSpeed(address(hub), address(usdc), SpeedLimit(2500, uint32(TAU), 5_000_000e6, 5_000_000e6));
        aaveOracle.setPrice(USDC_RESERVE, 99_990_000);
        BorrowSpeedView memory v = lens.getBorrowSpeed(mid, USDC_RESERVE);
        // One base unit more than availableNow does not fit; availableNow does.
        vm.expectRevert();
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, v.availableNow + 2);
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, v.availableNow);
        (SpeedView memory m,) = riskModule.getBorrowSpeed(mid, USDC_RESERVE);
        assertEq(m.used, (v.availableNow * 99_990_000 + 1e6 - 1) / 1e6, "charged at the reserve price");
    }

    // TEST-327 verifies: REQ-LENS-061
    function test_TEST_327_debtWindowAloneUnavailable() public view {
        // An unknown reserve on a known market: both windows unavailable, no conversion attempted.
        BorrowSpeedView memory v = lens.getBorrowSpeed(mid, 77);
        assertTrue(v.market.unavailable && v.debt.unavailable);
        assertEq(v.availableNow, 0);
    }

    // TEST-327 verifies: REQ-LENS-061
    function test_TEST_327_zeroPriceGivesNothingNow() public {
        vm.mockCall(
            address(aaveOracle), abi.encodeWithSignature("getReservePrice(uint256)", USDC_RESERVE), abi.encode(0)
        );
        BorrowSpeedView memory v = lens.getBorrowSpeed(mid, USDC_RESERVE);
        assertFalse(v.market.unavailable);
        assertGt(v.market.available, 0);
        assertEq(v.availableNow, 0, "no conversion at a zero price");
    }

    // TEST-327 verifies: REQ-LENS-061, BOR-024
    function test_TEST_327_moreAtIsTheEarlierWindow() public {
        // GHO at T0 charges only the market window; USDC at T0 + tau starts the USDC window then.
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), GHO_RESERVE, 10_000e18);
        vm.warp(T0 + TAU);
        _report(uint64(T0 + TAU), 1e8, 1e8);
        BorrowSpeedView memory v = lens.getBorrowSpeed(mid, USDC_RESERVE);
        assertEq(v.debt.moreAt, 0, "USDC window empty");
        assertEq(v.moreAt, v.market.moreAt, "only the market window frees anything");
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 10_000e6);
        v = lens.getBorrowSpeed(mid, USDC_RESERVE);
        assertEq(v.market.moreAt, uint64(T0 + 2 * TAU), "the GHO charge frees first");
        assertEq(v.debt.moreAt, uint64(T0 + 3 * TAU));
        assertEq(v.moreAt, uint64(T0 + 2 * TAU), "the earlier of the two");
    }
}
