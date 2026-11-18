// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILensDynamicCap} from "../../src/lens/lens/ILensDynamicCap.sol";
import {ILensErrors} from "../../src/lens/lens/ILensErrors.sol";
import {MarketDynamicCap} from "../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {RiskModuleFixture} from "../utils/fixtures/RiskModuleFixture.sol";

/// @notice A Lock stand-in whose state the test sets.
contract DynamicCapLockStub {
    bool public isLocked;

    function set(
        bool on
    ) external {
        isLocked = on;
    }
}

/// @title LensDynamicCapUnitTest
/// @notice `LensDynamicCapModule` (2.17 REQ-LENS-061) on the real RiskModule: the market's `(cap, debt,
/// intervalStart)` unchanged from the RiskModule's view, before and after a borrow and after the interval ends, and
/// `Locked()` while the Lock is held.
contract LensDynamicCapUnitTest is RiskModuleFixture {
    uint256 internal constant TAU = 21_600;
    uint256 internal constant E8 = 1e8;

    ILensDynamicCap internal lens;
    DynamicCapLockStub internal lock;

    function setUp() public {
        _deployRiskWorld();
        _enableUsdcDebt();
        _debt(1.5e18, 1000);
        hub.setOwed(GHO_ASSET, address(spoke), 1_000_000e18, 0);
        hub.setOwed(USDC_ASSET, address(spoke), 2_400_000e6, 0);
        aaveOracle.setPrice(USDC_RESERVE, 1e8);
        store.setMarketDynamicCap(mid, MarketDynamicCap(uint32(TAU), 2500, 250_000e8, 2_500_000e8));
        lock = new DynamicCapLockStub();
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
        lens = ILensDynamicCap(deployCode("LensDynamicCapModule.sol:LensDynamicCapModule", abi.encode(core)));
    }

    function test_viewIsTheRiskModulesViewBeforeAnyBorrow() public view {
        (uint256 cap, uint256 debt, uint64 start) = lens.getDynamicBorrowCap(mid);
        (uint256 c, uint256 d, uint64 s) = riskModule.getDynamicBorrowCap(mid);
        assertEq(cap, c);
        assertEq(debt, d);
        assertEq(start, s);
        assertEq(debt, 3_400_000 * E8);
        assertEq(cap, 4_250_000 * E8, "D + 25 % of D");
        assertEq(start, uint64(T0), "the next borrow opens an interval now");
    }

    function test_viewReportsTheRunningIntervalAndThenTheNextOne() public {
        vm.prank(address(adapter));
        riskModule.preBorrowCheck(address(proxy), USDC_RESERVE, 850_000e6);
        hub.setOwed(USDC_ASSET, address(spoke), 3_250_000e6, 0);
        (uint256 cap, uint256 debt, uint64 start) = lens.getDynamicBorrowCap(mid);
        assertEq(cap, 4_250_000 * E8, "the running interval's cap");
        assertEq(debt, 4_250_000 * E8);
        assertEq(start, uint64(T0));
        vm.warp(T0 + TAU);
        (cap, debt, start) = lens.getDynamicBorrowCap(mid);
        assertEq(cap, 5_312_500 * E8, "the cap the next borrow would fix on the debt now");
        assertEq(start, uint64(T0 + TAU));
    }

    function test_lockedAndUnknownMarket() public {
        lock.set(true);
        vm.expectRevert(ILensErrors.Locked.selector);
        lens.getDynamicBorrowCap(mid);
        lock.set(false);
        vm.expectRevert();
        lens.getDynamicBorrowCap(mid + 40);
    }
}
