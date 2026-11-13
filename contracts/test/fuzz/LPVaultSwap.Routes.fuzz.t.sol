// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {ILPVaultSwapLiquidation} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";
import {LVSLyingRoute} from "../utils/mocks/LPVaultSwapMocks.sol";

/// @title LPVaultSwapRoutesFuzzTest
/// @notice Route selection, residues and re-entry fuzzed on the local Aave V4 (2.11 REQ-SWAP-002, REQ-SWAP-010,
/// REQ-SWAP-021 to REQ-SWAP-024, REQ-SWAP-058, SPEC-LIQ-013, SPEC-LIQ-018): for any primary and backup rates, route
/// usability and route mode, the leg settles on the first route of the mode that meets its minimum, with `R` the USDC
/// leg plus that route's output, or reverts `NoRouteAvailable`; a route that keeps part of its input leaves that part
/// to the caller as a residue; a route paying any amount at or above the minimum is accepted at its measured output;
/// a route re-entering `liquidate` or `settlePending` is refused `LockHeld(LPVaultSwap)` while the outer call settles.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 256
contract LPVaultSwapRoutesFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    /// @notice Primary and backup rates around the USDT leg's minimum (≈ 0.9895 at `s = 100`), either usable or not,
    /// either mode: the first route of the mode at or above the minimum is used, else `NoRouteAvailable`.
    // TEST-232 verifies: REQ-SWAP-010, REQ-SWAP-022, REQ-SWAP-058, SPEC-LIQ-013, SPEC-LIQ-018
    function testFuzz_TEST_232_firstRouteMeetingTheMinimum(
        uint256 primaryBps,
        uint256 backupBps,
        bool primaryUsable,
        bool backupUsable,
        bool backupOnly
    ) public {
        primaryBps = bound(primaryBps, 9800, 10_050);
        backupBps = bound(backupBps, 9800, 10_050);
        usdtUsdcPool.setRate(primaryBps, 10_000);
        usdtUsdcPool2.setRate(backupBps, 10_000);
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(usdtPrimary), primaryUsable);
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 1, address(usdtBackup), backupUsable);
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.routeMode = backupOnly ? RouteMode.BackupOnly : RouteMode.PrimaryThenBackup;
        (uint256 a0, uint256 a1) = _released(975e6);
        uint256 minOut = _usdtLegMinOut(a1, SLIPPAGE_BPS, 1);
        bool primaryOk = !backupOnly && primaryUsable && a1 * primaryBps / 10_000 >= minOut;
        bool backupOk = backupUsable && a1 * backupBps / 10_000 >= minOut;
        _fund(usdc, keeper, 1950e6);
        vm.prank(keeper);
        try lvs.liquidate(p) returns (LiquidationResult memory r) {
            assertTrue(primaryOk || backupOk, "settled only with a route meeting the minimum");
            uint256 rate = primaryOk ? primaryBps : backupBps;
            assertEq(r.recovered, a0 + a1 * rate / 10_000, "R from the first route meeting the minimum");
        } catch (bytes memory reason) {
            assertFalse(primaryOk || backupOk, "refused although a route met the minimum");
            bytes4 s = bytes4(reason);
            assertTrue(
                s == ILPVaultSwapErrors.NoRouteAvailable.selector
                    || s == ILPVaultSwapErrors.RecoveryBelowFloor.selector,
                "named refusal"
            );
        }
    }

    /// @notice A route that reports success at any output, even one below the leg minimum it ignored, is credited
    /// only its measured output; the aggregate floor on `R` still binds (`RecoveryBelowFloor` when it fails).
    // TEST-232 verifies: SPEC-LIQ-006, SPEC-LIQ-018, REQ-SWAP-019, REQ-SWAP-023
    function testFuzz_TEST_232_measuredOutputAccepted(
        uint256 out
    ) public {
        (uint256 a0, uint256 a1) = _released(975e6);
        uint256 minOut = _usdtLegMinOut(a1, SLIPPAGE_BPS, 1);
        out = bound(out, minOut - 1000, a1 * 103 / 100);
        LVSLyingRoute lying = new LVSLyingRoute(address(usdt), address(usdc));
        usdc.mint(address(lying), out);
        lying.setOut(out);
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(lying), true);
        _fund(usdc, keeper, 1950e6);
        vm.prank(keeper);
        try lvs.liquidate(_params(proxy, 1950e6)) returns (LiquidationResult memory r) {
            assertEq(r.recovered, a0 + out, "R is the measured output, whatever the route reported");
            assertGe(r.recovered + r.shortfall, r.minOut, "the aggregate floor still binds");
        } catch (bytes memory reason) {
            assertLt(out, minOut, "only an output below the leg minimum can fail the floor");
            assertEq(bytes4(reason), ILPVaultSwapErrors.RecoveryBelowFloor.selector, "held to the floor");
        }
    }

    /// @notice A route that keeps only part of its input (a hop capped by liquidity) leaves the rest of the USDT to the
    /// caller as a residue in the same call, with `ResidueReturned`; LPVaultSwap keeps none.
    // TEST-232 verifies: REQ-SWAP-024, REQ-SWAP-042, REQ-SWAP-121
    function testFuzz_TEST_232_partialInputReturnedAsResidue(
        uint256 left
    ) public {
        (, uint256 a1) = _released(975e6);
        left = bound(left, 1, a1 / 200);
        usdtUsdcPool.setMaxIn(a1 - left);
        usdtUsdcPool2.setMaxIn(a1 - left);
        uint256 callerUsdt = usdt.balanceOf(keeper);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(usdt.balanceOf(keeper), callerUsdt + left, "the residue goes to the caller");
        assertEq(usdt.balanceOf(address(lvs)), 0, "LPVaultSwap keeps no USDT");
        assertGt(r.recovered, 0, "settled");
    }

    /// @notice A route re-entering `liquidate` or `settlePending` with any parameters is refused `LockHeld(LPVaultSwap)`;
    /// the outer liquidation settles.
    // TEST-060 verifies: REQ-SWAP-002, REQ-LOCK-005, REQ-LOCK-023, PROP-037
    function testFuzz_TEST_060_reentryRefused(
        bool pending,
        uint256 debtToCover
    ) public {
        debtToCover = bound(debtToCover, 1, 10_000e6);
        bytes memory call = pending
            ? abi.encodeCall(ILPVaultSwapLiquidation.settlePending, (MARKET_ID, usdcReserveId))
            : abi.encodeCall(ILPVaultSwapLiquidation.liquidate, (_params(proxy, debtToCover)));
        LVSLyingRoute reentrant = new LVSLyingRoute(address(usdt), address(usdc));
        usdc.mint(address(reentrant), 1_009_594_950);
        reentrant.setOut(1_009_594_950);
        reentrant.setReenter(address(lvs), call);
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(reentrant), true);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertFalse(reentrant.lastReenterOk(), "re-entry refused");
        assertEq(
            keccak256(reentrant.lastReenterData()),
            keccak256(abi.encodeWithSelector(ILPVaultSwapErrors.LockHeld.selector, address(lvs))),
            "LockHeld(LPVaultSwap)"
        );
        assertGt(r.debtRepaid, 0, "outer call settles");
        assertFalse(lock.isLocked(), "Lock free after the call");
    }
}
