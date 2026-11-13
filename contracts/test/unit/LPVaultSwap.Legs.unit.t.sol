// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {ILPVaultSwapEvents} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapEvents.sol";
import {LPVaultSwapImmutables} from "../../src/liquidation/lp-vault-swap/types/LPVaultSwapImmutables.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {
    LPVaultSwapSettlementHarness,
    LVSHarnessRegistry,
    LVSHarnessRoute,
    LVSHarnessToken
} from "../utils/harness/LPVaultSwapSettlementHarness.sol";
import {Test} from "forge-std/Test.sol";

/// @title LPVaultSwapLegsUnitTest
/// @notice The shared swap-leg step of `liquidate`, `settlePending` and `deleverage` on the real
/// `LPVaultSwapSettlement` code (2.11 SPEC-LIQ-018, REQ-SWAP-021 to REQ-SWAP-024, REQ-SWAP-058, REQ-SWAP-089,
/// REQ-SWAP-100), over three- and four-token markets with 6-, 8- and 18-decimal tokens: the debt-asset leg is never
/// routed; a dust leg (`Vleg ≤ Uleg`) is not swapped; every other leg gets exactly its SPEC-LIQ-018 minimum with `ε`
/// split over the swapped legs; `PrimaryThenBackup` tries the primary and falls back on a revert, an `intermediates()`
/// failure or an unusable primary, emitting `RouteFailed` with the reason's selector for a primary only; `BackupOnly`
/// never calls the primary; no usable route reverts `NoRouteAvailable`; a route that takes less than its input, or
/// sends back an intermediate token, leaves a residue measured per token; each route's approval is exact during the
/// call and zero after it.
contract LPVaultSwapLegsUnitTest is Test, ILPVaultSwapEvents {
    uint256 internal constant BPS = 10_000;

    LPVaultSwapSettlementHarness internal harness;
    LVSHarnessRegistry internal registry;
    LVSHarnessToken internal usdc; // the debt asset, 6 decimals
    LVSHarnessToken internal usdt; // 6 decimals
    LVSHarnessToken internal wbtc; // 8 decimals
    LVSHarnessToken internal dai; // 18 decimals
    LVSHarnessToken internal weth; // an intermediate, 18 decimals
    LVSHarnessRoute internal usdtPrimary;
    LVSHarnessRoute internal usdtBackup;
    LVSHarnessRoute internal wbtcPrimary;
    LVSHarnessRoute internal daiPrimary;
    LVSHarnessRoute internal usdcRoute;

    function setUp() public {
        registry = new LVSHarnessRegistry();
        usdc = new LVSHarnessToken("USDC", 6);
        usdt = new LVSHarnessToken("USDT", 6);
        wbtc = new LVSHarnessToken("WBTC", 8);
        dai = new LVSHarnessToken("DAI", 18);
        weth = new LVSHarnessToken("WETH", 18);
        harness = new LPVaultSwapSettlementHarness(
            LPVaultSwapImmutables({
                lock: address(0x1001),
                aaveAdapter: address(0x1002),
                collateralization: address(0x1003),
                marketRegistry: address(registry),
                parameterStore: address(0x1005),
                payoutEscrow: address(0x1006),
                keeperFloor: 1
            })
        );
        usdtPrimary = new LVSHarnessRoute(usdt, usdc, 1, 1);
        usdtBackup = new LVSHarnessRoute(usdt, usdc, 1, 1);
        // 1 WBTC (1e8) = 60,000 USDC (6e10): out = in × 600.
        wbtcPrimary = new LVSHarnessRoute(wbtc, usdc, 600, 1);
        // 1 DAI (1e18) = 1 USDC (1e6): out = in / 1e12.
        daiPrimary = new LVSHarnessRoute(dai, usdc, 1, 1e12);
        usdcRoute = new LVSHarnessRoute(usdc, usdt, 1, 1);
        registry.setRoute(address(usdt), address(usdc), address(usdtPrimary));
        registry.setBackup(address(usdt), address(usdc), address(usdtBackup));
        registry.setRoute(address(wbtc), address(usdc), address(wbtcPrimary));
        registry.setRoute(address(dai), address(usdc), address(daiPrimary));
        registry.setRoute(address(usdc), address(usdt), address(usdcRoute));
    }

    struct Legs {
        address[] tokens;
        uint8[] decimals;
        uint256[] prices;
        uint256[] amounts;
    }

    /// @dev USDC (debt), USDT at $0.9995, WBTC at $60,000 and DAI at $1, with `amounts`, minted to the harness.
    function _four(
        uint256 aUsdc,
        uint256 aUsdt,
        uint256 aWbtc,
        uint256 aDai
    ) internal returns (Legs memory l) {
        l.tokens = new address[](4);
        (l.tokens[0], l.tokens[1], l.tokens[2], l.tokens[3]) =
        (address(usdc), address(usdt), address(wbtc), address(dai));
        l.decimals = new uint8[](4);
        (l.decimals[0], l.decimals[1], l.decimals[2], l.decimals[3]) = (6, 6, 8, 18);
        l.prices = new uint256[](4);
        (l.prices[0], l.prices[1], l.prices[2], l.prices[3]) = (1e8, 99_950_000, 60_000e8, 1e8);
        l.amounts = new uint256[](4);
        (l.amounts[0], l.amounts[1], l.amounts[2], l.amounts[3]) = (aUsdc, aUsdt, aWbtc, aDai);
        usdc.mint(address(harness), aUsdc);
        usdt.mint(address(harness), aUsdt);
        wbtc.mint(address(harness), aWbtc);
        dai.mint(address(harness), aDai);
    }

    function _run(
        Legs memory l,
        uint256 sLeg,
        uint256 eps
    ) internal returns (uint8[] memory used, uint256 recovered, uint256[] memory residues) {
        return harness.swapLegs(address(usdc), 6, l.tokens, l.decimals, l.prices, l.amounts, sLeg, eps);
    }

    function _h(
        Legs memory l,
        uint256 sLeg
    ) internal view returns (LPVaultSwapSettlementHarness.HarnessLegs memory) {
        return LPVaultSwapSettlementHarness.HarnessLegs(
            address(usdc), 6, l.tokens, l.decimals, l.prices, l.amounts, sLeg, 1e6
        );
    }

    function _ceil(
        uint256 a,
        uint256 b
    ) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @dev SPEC-LIQ-018 minimum for a leg of value `v` and unit `u`, with `ε` split over `n` swapped legs.
    function _min(
        uint256 v,
        uint256 sLeg,
        uint256 u,
        uint256 eps,
        uint256 n
    ) internal pure returns (uint256) {
        uint256 term = _ceil(v * (BPS - sLeg), BPS);
        uint256 cut = u + eps / n;
        return term > cut ? term - cut : 1;
    }

    /// @notice Four tokens: USDC is the debt asset and never routed; USDT, WBTC and DAI each get their exact minimum
    /// with `ε` split three ways and their unit values (`⌈p 10^dd / (10^dᵢ Pdebt)⌉`: 1, 600 and 1 USDC base units);
    /// `R` is the USDC released plus every route's output.
    // TEST-232 verifies: SPEC-LIQ-018, REQ-SWAP-021, REQ-SWAP-100, INV-083
    function test_TEST_232_fourTokenMinimumsAndRecovery() public {
        Legs memory l = _four(1000e6, 1000e6, 0.05e8, 2000e18);
        uint256 eps = 1e6;
        (uint8[] memory used, uint256 recovered,) = _run(l, 100, eps);
        assertEq(used[0], 0, "debt asset not routed");
        (used[1], used[2], used[3]);
        assertEq(usdtPrimary.lastMinOut(), _min(999_500_000, 100, 1, eps, 3), "USDT minimum");
        assertEq(wbtcPrimary.lastMinOut(), _min(3000e6, 100, 600, eps, 3), "WBTC minimum, unit 600");
        assertEq(daiPrimary.lastMinOut(), _min(2000e6, 100, 1, eps, 3), "DAI minimum, 18 decimals");
        assertEq(recovered, 1000e6 + 1000e6 + 0.05e8 * 600 + 2000e6, "R");
        assertEq(usdcRoute.calls(), 0, "no buy leg of USDC");
    }

    /// @notice A dust leg (`Vleg ≤ Uleg`: 1 raw unit of WBTC is worth 600 base units ≤ its unit 600) is not swapped and
    /// does not count in `n'`: the two other legs split `ε` two ways.
    // TEST-232 verifies: SPEC-LIQ-018, REQ-SWAP-121
    function test_TEST_232_dustLegSkippedAndNotCounted() public {
        Legs memory l = _four(0, 1000e6, 1, 2000e18);
        uint256 eps = 1e6;
        (uint8[] memory used,, uint256[] memory residues) = _run(l, 100, eps);
        assertEq(used[2], 0, "dust leg skipped");
        assertEq(wbtcPrimary.calls(), 0, "dust leg never routed");
        assertEq(usdtPrimary.lastMinOut(), _min(999_500_000, 100, 1, eps, 2), "eps split over the two swapped legs");
        assertEq(residues[2], 1, "the dust stays as a residue for the caller");
    }

    /// @notice A primary that reverts sends the leg to the backup, with `RouteFailed(market, token, route, selector)`;
    /// the backup's failure emits nothing and leaves `NoRouteAvailable`.
    // TEST-232 verifies: REQ-SWAP-022, REQ-SWAP-058, SPEC-LIQ-013
    function test_TEST_232_primaryRevertFallsBackWithEvent() public {
        usdtPrimary.setBehaviour(BPS, true, false);
        Legs memory l = _four(0, 1000e6, 0, 0);
        vm.expectEmit(address(harness));
        emit RouteFailed(1, address(usdt), address(usdtPrimary), bytes4(keccak256("Error(string)")));
        (uint8[] memory used, uint256 recovered,) = _run(l, 100, 1e6);
        assertEq(used[1], 2, "backup used");
        assertEq(recovered, 1000e6, "backup output");
        usdtBackup.setBehaviour(BPS, true, false);
        Legs memory again = _four(0, 1000e6, 0, 0);
        vm.expectRevert(ILPVaultSwapErrors.NoRouteAvailable.selector);
        _run(again, 100, 1e6);
    }

    /// @notice A primary whose `intermediates()` read fails counts as a reverted route: `RouteFailed` and the backup.
    // TEST-232 verifies: REQ-SWAP-022, REQ-SWAP-024
    function test_TEST_232_intermediatesFailureIsARevertedRoute() public {
        usdtPrimary.setBehaviour(BPS, false, true);
        Legs memory l = _four(0, 500e6, 0, 0);
        vm.expectEmit(address(harness));
        emit RouteFailed(1, address(usdt), address(usdtPrimary), bytes4(keccak256("Error(string)")));
        (uint8[] memory used,,) = _run(l, 100, 1e6);
        assertEq(used[1], 2, "backup used");
        assertEq(usdtPrimary.calls(), 0, "the primary's swap never ran");
    }

    /// @notice An unusable primary is skipped without an event; `BackupOnly` never calls the primary; an unusable
    /// backup in `BackupOnly` reverts even when the primary works.
    // TEST-174 verifies: REQ-SWAP-010, REQ-SWAP-022, REQ-SWAP-058
    function test_TEST_174_routeModesAndUsability() public {
        registry.setUsable(address(usdt), address(usdc), 0, false);
        Legs memory l = _four(0, 300e6, 0, 0);
        (uint8[] memory used,,) = _run(l, 100, 1e6);
        assertEq(used[1], 2, "unusable primary skipped");
        assertEq(usdtPrimary.calls(), 0, "not called");
        registry.setUsable(address(usdt), address(usdc), 0, true);
        Legs memory b = _four(0, 300e6, 0, 0);
        (uint8[] memory usedB,,) = harness.swapLegsIn(RouteMode.BackupOnly, _h(b, 100));
        assertEq(usedB[1], 2, "BackupOnly uses the backup");
        assertEq(usdtPrimary.calls(), 0, "BackupOnly never calls the primary");
        registry.setUsable(address(usdt), address(usdc), 1, false);
        Legs memory c = _four(0, 300e6, 0, 0);
        vm.expectRevert(ILPVaultSwapErrors.NoRouteAvailable.selector);
        harness.swapLegsIn(RouteMode.BackupOnly, _h(c, 100));
    }

    /// @notice A primary that pays below its minimum fails it (`MinOutNotMet`) and the backup settles; both below it,
    /// `NoRouteAvailable`.
    // TEST-232 verifies: SPEC-LIQ-018, REQ-SWAP-023, REQ-SWAP-058
    function test_TEST_232_belowMinimumFailsTheRoute() public {
        usdtPrimary.setRate(98, 100);
        Legs memory l = _four(0, 1000e6, 0, 0);
        (uint8[] memory used, uint256 recovered,) = _run(l, 100, 1e6);
        assertEq(used[1], 2, "backup after a primary below its minimum");
        assertEq(recovered, 1000e6, "backup at par");
        usdtBackup.setRate(98, 100);
        Legs memory again = _four(0, 1000e6, 0, 0);
        vm.expectRevert(ILPVaultSwapErrors.NoRouteAvailable.selector);
        _run(again, 100, 1e6);
    }

    /// @notice A route that takes only part of its input leaves the rest as a residue of that token; a route that
    /// sends back an intermediate token leaves it as a residue of the intermediate, tracked from before the call.
    // TEST-232 verifies: REQ-SWAP-024, REQ-SWAP-042, REQ-SWAP-121
    function test_TEST_232_residuesMeasuredPerToken() public {
        usdtPrimary.setBehaviour(9000, false, false);
        usdtPrimary.setIntermediate(weth, 3e15);
        weth.mint(address(harness), 7e15); // a donation before the call is not a residue
        Legs memory l = _four(0, 1000e6, 0, 0);
        (,, uint256[] memory residues) = _run(l, 100, 1e6);
        assertEq(residues.length, 5, "the four market tokens plus the tracked intermediate");
        assertEq(residues[0], 0, "the debt asset is never a residue");
        assertEq(residues[1], 100e6, "10 % of the USDT input left");
        assertEq(residues[4], 3e15, "the intermediate sent back, not the donation");
    }

    /// @notice During the call each route holds an approval of exactly its input; after it, zero.
    // TEST-232 verifies: REQ-SWAP-023, REQ-SWAP-042, INV-021
    function test_TEST_232_exactApprovalThenZero() public {
        Legs memory l = _four(0, 1234e6, 0.01e8, 0);
        _run(l, 100, 1e6);
        assertEq(usdtPrimary.lastAmountIn(), 1234e6, "input is the released amount");
        assertEq(wbtcPrimary.lastAmountIn(), 0.01e8, "input is the released amount");
        assertEq(usdt.allowance(address(harness), address(usdtPrimary)), 0, "no USDT approval left");
        assertEq(wbtc.allowance(address(harness), address(wbtcPrimary)), 0, "no WBTC approval left");
    }

    /// @notice A relaxed leg slippage (`sLeg` above `s` by the caller's budget) lowers every minimum by the formula
    /// and lets a route paying below the unrelaxed minimum settle.
    // TEST-233 verifies: SPEC-LIQ-019, REQ-SWAP-111
    function test_TEST_233_relaxedLegSlippage() public {
        usdtPrimary.setRate(97, 100);
        usdtBackup.setRate(97, 100);
        Legs memory l = _four(0, 1000e6, 0, 0);
        vm.expectRevert(ILPVaultSwapErrors.NoRouteAvailable.selector);
        _run(l, 100, 1e6);
        Legs memory relaxed = _four(0, 1000e6, 0, 0);
        (, uint256 recovered,) = _run(relaxed, 400, 1e6);
        assertEq(recovered, 970e6, "settled at 0.97 with sLeg 400");
        assertEq(usdtPrimary.lastMinOut(), _min(999_500_000, 400, 1, 1e6, 1), "minimum at sLeg");
    }

    /// @notice Any amounts of the three non-debt tokens at par routes: every non-dust leg is routed once at its exact
    /// minimum, `R` is the USDC released plus the outputs, no residue remains and no approval is left.
    // TEST-161 verifies: SPEC-LIQ-018, REQ-SWAP-021, REQ-SWAP-100, INV-083
    function testFuzz_TEST_161_legsMatchModel(
        uint64 aUsdc,
        uint64 aUsdt,
        uint32 aWbtc,
        uint96 aDai
    ) public {
        Legs memory l = _four(aUsdc, aUsdt, aWbtc, aDai);
        (uint8[] memory used, uint256 recovered, uint256[] memory residues) = _run(l, 100, 1e6);
        _checkFuzzLegs(l.amounts, used, recovered, residues);
        assertEq(usdcRoute.calls(), 0, "never a buy leg");
    }

    function _checkFuzzLegs(
        uint256[] memory a,
        uint8[] memory used,
        uint256 recovered,
        uint256[] memory residues
    ) internal view {
        bool[3] memory swapped = [a[1] * 99_950_000 / 1e8 > 1, a[2] * 600 > 600, a[3] / 1e12 > 1];
        uint256 n = (swapped[0] ? 1 : 0) + (swapped[1] ? 1 : 0) + (swapped[2] ? 1 : 0);
        uint256 expected = a[0];
        if (swapped[0]) {
            assertEq(used[1], 1, "USDT routed");
            assertEq(usdtPrimary.lastMinOut(), _min(a[1] * 99_950_000 / 1e8, 100, 1, 1e6, n), "USDT minimum");
            expected += a[1];
        } else {
            assertEq(residues[1], a[1], "USDT dust stays");
        }
        if (swapped[1]) {
            assertEq(used[2], 1, "WBTC routed");
            expected += a[2] * 600;
        }
        if (swapped[2]) {
            assertEq(used[3], 1, "DAI routed");
            expected += a[3] / 1e12;
        }
        assertEq(recovered, expected, "R");
    }
}
