// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {DexPathRoute} from "../../src/liquidation/settlement-routes/DexPathRoute.sol";
import {DexHop, HopKind} from "../../src/liquidation/settlement-routes/types/DexHop.sol";
import {SettlementReport} from "../../src/types/SettlementReport.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {MockCLPool} from "../utils/mocks/SwapRouteMocks.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LPVaultSwapResiduesUnitTest
/// @notice Route residues and dust legs (2.11 REQ-SWAP-024, REQ-SWAP-121): input or intermediate tokens a route
/// returns unswapped and released tokens worth at most one raw unit of the debt asset are paid to the caller in the
/// token they are in (escrowed for it when the transfer fails), count zero toward `R` and the recovery floor, are never
/// sent to a route, and leave LPVaultSwap's balance of every market and intermediate token unchanged.
/// forge-config: default.isolate = false
contract LPVaultSwapResiduesUnitTest is LPVaultSwapUnitBase {
    address internal proxy;
    uint256 internal a0;
    uint256 internal a1;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
        (a0, a1) = _released(975e6);
    }

    /// @notice A primary that fills only 95 % of its input returns the remaining USDT: the caller receives it as a
    /// residue (`ResidueReturned`), `R` counts only the USDC the route delivered, and the floor gap that leaves is the
    /// caller's top-up, never offset by the residue.
    // TEST-053 verifies: REQ-SWAP-024, REQ-SWAP-042, SPEC-LIQ-006, SPEC-LIQ-013
    function test_TEST_053_partialFillResidueToCallerCountsZero() public {
        uint256 filled = a1 * 95 / 100;
        usdtUsdcPool.setMaxIn(filled);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.maxShortfall = 1000e6;
        _fund(usdc, keeper, 1950e6 + 1000e6);
        Snap memory s0 = _snap(keeper);
        vm.expectEmit(true, true, false, true, address(lvs));
        emit ResidueReturned(keeper, address(usdt), a1 - filled, false);
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(p);
        assertEq(r.recovered, a0 + filled * 9995 / 10_000, "R = USDC leg + the filled part only");
        assertEq(usdt.balanceOf(keeper), s0.callerUsdt + (a1 - filled), "residue paid in USDT");
        assertEq(r.shortfall, r.minOut > r.recovered ? r.minOut - r.recovered : 0, "residue never offsets the floor");
        _assertNeutral(s0);
    }

    /// @notice A dust leg (`Vleg ≤ Uleg`: one raw USDT unit) is not swapped, has no route call, and goes whole to the
    /// caller; `routeUsed` is 0 for it.
    // TEST-053 verifies: REQ-SWAP-121, SPEC-LIQ-018, REQ-SWAP-024
    function test_TEST_053_dustLegToCallerUnswapped() public {
        uint256[] memory rates = new uint256[](2);
        rates[0] = 2_100_000;
        rates[1] = 1; // 975 raw USDT for 975e6 units: Vleg = 974, but U-scaled below see the price change
        lpVault.bind(MARKET_ID, pool, _pair(address(usdc), address(usdt)), rates);
        uint256[] memory prices = new uint256[](2);
        prices[0] = PRICE_UNIT;
        prices[1] = 100_000; // $0.001: 975 raw USDT are worth 0.975 raw USDC, at most one unit
        lpOracle.setPrices(prices);
        uint256 swaps = usdtUsdcPool.swaps() + usdtUsdcPool2.swaps();
        _fund(usdc, keeper, 1950e6);
        Snap memory s0 = _snap(keeper);
        vm.recordLogs();
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(_params(proxy, 1950e6));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(usdtUsdcPool.swaps() + usdtUsdcPool2.swaps(), swaps, "no route call for a dust leg");
        assertEq(r.amountsOut[1], 975, "975 raw USDT released");
        assertEq(usdt.balanceOf(keeper), s0.callerUsdt + 975, "dust leg to the caller");
        assertEq(r.recovered, r.amountsOut[0], "R = the USDC leg");
        (SettlementReport memory rep,) = _settledReport(logs);
        assertEq(rep.routeUsed[1], 0, "no route used for the dust leg");
        assertEq(_count(logs, ResidueReturned.selector), 1, "one residue event");
        _assertNeutral(s0);
    }

    /// @notice A two-hop route USDT → DAI → USDC whose second hop fills only half returns DAI, an intermediate token:
    /// the caller receives the DAI and LPVaultSwap's DAI balance is unchanged.
    // TEST-053 verifies: REQ-SWAP-024, REQ-SWAP-042
    function test_TEST_053_intermediateResidueToCaller() public {
        PayoutToken dai = new PayoutToken("DAI", 18);
        MockCLPool usdtDai = _clPool(usdt, dai, 1e12, 1);
        MockCLPool daiUsdc = _clPool(dai, usdc, 9995, 10_000 * 1e12);
        uint256 daiOut = a1 * 1e12;
        daiUsdc.setMaxIn(daiOut * 98 / 100);
        DexHop[] memory hops = new DexHop[](2);
        hops[0] =
            DexHop({kind: HopKind.ConcentratedLiquidity, pool: address(usdtDai), tokenOut: address(dai), i: 0, j: 0});
        hops[1] =
            DexHop({kind: HopKind.ConcentratedLiquidity, pool: address(daiUsdc), tokenOut: address(usdc), i: 0, j: 0});
        DexPathRoute twoHop = new DexPathRoute(_routeConfig(address(usdt), address(usdc)), hops);
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(twoHop), true);
        dai.mint(address(lvs), 3e18); // a prior donation stays and is not paid out
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.maxShortfall = 1000e6;
        _fund(usdc, keeper, 1950e6 + 1000e6);
        vm.expectEmit(true, true, false, true, address(lvs));
        emit ResidueReturned(keeper, address(dai), daiOut - daiOut * 98 / 100, false);
        vm.prank(keeper);
        lvs.liquidate(p);
        assertEq(dai.balanceOf(keeper), daiOut - daiOut * 98 / 100, "DAI residue paid");
        assertEq(dai.balanceOf(address(lvs)), 3e18, "LPVaultSwap's DAI unchanged");
    }

    /// @notice A residue the caller cannot receive (the token blocks it) is escrowed for the caller, and the
    /// liquidation completes; the caller later claims it to another address.
    // TEST-179 verifies: REQ-SWAP-024, REQ-SWAP-076, REQ-SWAP-082, INV-061, Q-389
    function test_TEST_179_residueEscrowedForBlockedCaller() public {
        uint256 filled = a1 * 95 / 100;
        usdtUsdcPool.setMaxIn(filled);
        usdt.setBlocked(keeper, true);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.maxShortfall = 1000e6;
        _fund(usdc, keeper, 1950e6 + 1000e6);
        vm.expectEmit(true, true, false, true, address(lvs));
        emit ResidueReturned(keeper, address(usdt), a1 - filled, true);
        vm.prank(keeper);
        lvs.liquidate(p);
        assertEq(escrow.claimable(address(usdt), keeper), a1 - filled, "credited to the caller");
        address other = makeAddr("keeperColdWallet");
        vm.prank(keeper);
        escrow.claim(address(usdt), other);
        assertEq(usdt.balanceOf(other), a1 - filled, "claimed elsewhere");
    }

    /// @notice No residue, no residue event: a full fill pays nothing in USDT and LPVaultSwap keeps no USDT.
    // TEST-053 verifies: REQ-SWAP-077, REQ-SWAP-042
    function test_TEST_053_noResidueNoTransfer() public {
        _fund(usdc, keeper, 1950e6);
        uint256 before = usdt.balanceOf(keeper);
        vm.recordLogs();
        vm.prank(keeper);
        lvs.liquidate(_params(proxy, 1950e6));
        assertEq(_count(vm.getRecordedLogs(), ResidueReturned.selector), 0, "no residue event");
        assertEq(usdt.balanceOf(keeper), before, "no USDT paid");
        assertEq(usdt.balanceOf(address(lvs)), 0, "no USDT kept");
    }
}
