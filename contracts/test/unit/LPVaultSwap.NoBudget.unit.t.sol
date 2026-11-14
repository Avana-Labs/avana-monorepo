// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {Market} from "../../src/types/Market.sol";
import {SettlementReport} from "../../src/types/SettlementReport.sol";
import {LVSRevertingRoute} from "../utils/mocks/LPVaultSwapMocks.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LPVaultSwapNoBudgetUnitTest
/// @notice No settlement budget, no in-kind mode, no cross-call state (2.11 REQ-SWAP-029, REQ-SWAP-030, REQ-SWAP-031,
/// REQ-SWAP-103, REQ-SWAP-104, REQ-SWAP-003; Q-397, Q-399, Q-401): a liquidation writes no storage of LPVaultSwap, so
/// many dust liquidations in one market change nothing about how another market settles; the caller alone bears a
/// recovery below the debt it funded; repeated route failures switch no mode; LPVaultSwap reads no pause state, pause
/// reason or breaker and runs in every market status.
/// forge-config: default.isolate = false
contract LPVaultSwapNoBudgetUnitTest is LPVaultSwapUnitBase {
    address internal proxy;

    function setUp() public override {
        super.setUp();
        _deploySecondMarket();
        (proxy,) = _bobAccount();
    }

    /// @notice A liquidation writes no storage slot of LPVaultSwap: no per-call, per-market or per-window allowance,
    /// shortfall clock or failure counter exists (REQ-SWAP-103); `settlePending` writes only its carry.
    // TEST-200 verifies: REQ-SWAP-029, REQ-SWAP-103, INV-037, INV-097, PROP-063, PROP-084, Q-397
    // TEST-277 verifies: REQ-SWAP-029, REQ-SWAP-103, INV-097, PROP-084
    function test_TEST_200_noStorageWrittenByLiquidation() public {
        _fund(usdc, keeper, 1950e6);
        vm.record();
        vm.prank(keeper);
        lvs.liquidate(_params(proxy, 1950e6));
        (, bytes32[] memory writes) = vm.accesses(address(lvs));
        assertEq(writes.length, 0, "no storage write");
    }

    /// @notice Twenty dust liquidations in market 4, then a liquidation in market 5 settles exactly as it does with no
    /// earlier liquidation: no allowance is shared or consumed across markets.
    // TEST-277 verifies: REQ-SWAP-029, REQ-SWAP-103, INV-097, PROP-063, PROP-084, Q-397
    // TEST-200 verifies: REQ-SWAP-029, INV-037, Q-397
    function test_TEST_277_dustInMarketANoEffectOnMarketB() public {
        (address proxyB,) = _openAccountB(carol, 10_000e6, 18_000e6, 250_000_000);
        uint256 snapshot = vm.snapshotState();
        LiquidationParams memory pB = _params(proxyB, 1950e6);
        pB.marketId = MARKET_B;
        LiquidationResult memory fresh = _liquidateAs(keeper, pB);
        vm.revertToState(snapshot);
        usdtUsdcPool.setRate(5, 10); // dust legs at half value: each dust liquidation costs its caller
        for (uint256 i = 0; i < 20; ++i) {
            _liquidateAs(keeper, _params(proxy, 3e6));
        }
        usdtUsdcPool.setRate(9995, 10_000);
        LiquidationResult memory afterDust = _liquidateAs(keeper, pB);
        assertEq(afterDust.debtRepaid, fresh.debtRepaid, "D");
        assertEq(afterDust.unitsSeized, fresh.unitsSeized, "c");
        assertEq(afterDust.recovered, fresh.recovered, "R");
        assertEq(afterDust.avanaFee, fresh.avanaFee, "A");
        assertEq(afterDust.keeperOut, fresh.keeperOut, "keeperOut");
    }

    /// @notice TEST-246: a dust repayment sized up front; the gap below `D` is borne in `keeperOut`; no Avana contract
    /// (escrow, First-Loss Reserves, fee recipient) pays any part; without a top-up a recovery below the floor reverts with
    /// no state change.
    // TEST-246 verifies: SPEC-LIQ-005, SPEC-LIQ-010, SPEC-SET-001, REQ-SWAP-029, REQ-SWAP-073, INV-038, Q-267, Q-397
    // TEST-059 verifies: REQ-SWAP-029, REQ-SWAP-073, INV-037, Q-397
    function test_TEST_246_gapBorneInKeeperOut() public {
        usdtUsdcPool.setRate(5, 10);
        uint256 coverage = usdcCoverage.fundedBalance();
        uint256 escrowUsdc = usdc.balanceOf(address(escrow));
        uint256 fee = usdc.balanceOf(feeRecipient);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 3e6));
        assertLt(r.recovered, r.debtRepaid, "R < D");
        assertEq(r.keeperOut, r.callerFunds - (r.debtRepaid - r.recovered), "the caller bears D - R");
        assertEq(usdcCoverage.fundedBalance(), coverage, "no First-Loss Reserve draw");
        assertEq(usdc.balanceOf(address(escrow)), escrowUsdc, "no escrow");
        assertEq(usdc.balanceOf(feeRecipient), fee, "no fee");
        // Bound of INV-038: the loss is within one vault unit's value plus U + eps.
        uint256 vaultUnit = _ceilDiv(P_VAULT, PRICE_UNIT);
        assertLe(r.debtRepaid - r.recovered, _valueOf(r.unitsSeized, P_VAULT, PRICE_UNIT, 6) - r.minOut + vaultUnit);
    }

    /// @notice Without a top-up, a recovery below the floor reverts `RecoveryBelowFloor` and changes nothing.
    // TEST-246 verifies: SPEC-LIQ-019, REQ-SWAP-025
    function test_TEST_246_noTopUpRevertsWithoutStateChange() public {
        uint256[] memory rates = new uint256[](2);
        rates[0] = 500_000;
        rates[1] = USDT_RATE;
        lpVault.bind(MARKET_ID, pool, _pair(address(usdc), address(usdt)), rates);
        uint256 debt = _debtOf(proxy, usdcReserveId);
        uint256 units = _suppliedUnits(proxy);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.RecoveryBelowFloor.selector));
        assertEq(_debtOf(proxy, usdcReserveId), debt, "debt");
        assertEq(_suppliedUnits(proxy), units, "collateral");
    }

    /// @notice TEST-234: five liquidations with a reverting primary each emit `RouteFailed` and settle over the backup;
    /// once the primary is restored the next liquidation uses it: no failure count, probe or timer changes how a
    /// liquidation settles, and every payout stays in the debt asset.
    // TEST-234 verifies: REQ-SWAP-030, REQ-SWAP-031, REQ-SWAP-102, REQ-SWAP-103, REQ-SWAP-104, REQ-SWAP-115, Q-399, Q-401
    // TEST-053 verifies: REQ-SWAP-030, REQ-SWAP-094, Q-401
    function test_TEST_234_routeFailuresChangeNoSettlementMode() public {
        LVSRevertingRoute down = new LVSRevertingRoute();
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(down), true);
        for (uint256 i = 0; i < 5; ++i) {
            _fund(usdc, keeper, 500e6);
            vm.recordLogs();
            vm.prank(keeper);
            lvs.liquidate(_params(proxy, 500e6));
            Vm.Log[] memory logs = vm.getRecordedLogs();
            assertEq(_count(logs, RouteFailed.selector), 1, "RouteFailed");
            (SettlementReport memory rep,) = _settledReport(logs);
            assertEq(rep.routeUsed[1], 2, "backup");
            assertEq(usdt.balanceOf(keeper), 0, "no pool token paid out");
        }
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(usdtPrimary), true);
        _fund(usdc, keeper, 500e6);
        vm.recordLogs();
        vm.prank(keeper);
        lvs.liquidate(_params(proxy, 500e6));
        (SettlementReport memory rep2,) = _settledReport(vm.getRecordedLogs());
        assertEq(rep2.routeUsed[1], 1, "primary again");
    }

    /// @notice REQ-SWAP-003: LPVaultSwap never reads the pause state, pause reason or a breaker of the MarketRegistry;
    /// it settles in every market status (Registered, Active, Offboarding, Closed records alike).
    // TEST-053 verifies: REQ-SWAP-003, REQ-SWAP-049, REQ-SWAP-104, INV-067, Q-241, Q-252
    function test_TEST_053_noPauseOrBreakerReads() public {
        vm.expectCall(address(registry), abi.encodeWithSignature("pauseState(address)"), 0);
        vm.expectCall(address(registry), abi.encodeWithSignature("pauseReason(address)"), 0);
        vm.expectCall(address(registry), abi.encodeWithSignature("marketBreaker(uint256)"), 0);
        vm.expectCall(address(registry), abi.encodeWithSignature("debtBreaker(address,uint256)"), 0);
        MarketStatus[3] memory statuses = [MarketStatus.Registered, MarketStatus.Offboarding, MarketStatus.Closed];
        for (uint256 i = 0; i < statuses.length; ++i) {
            Market memory m = registry.getMarket(MARKET_ID);
            m.status = statuses[i];
            registry.setMarket(MARKET_ID, m);
            _liquidateAs(keeper, _params(proxy, 500e6));
        }
    }

    /// @notice TEST-059: the caller's funding is the only debt asset entering LPVaultSwap besides the recovery and the
    /// top-up: no Avana contract transfers the debt asset into LPVaultSwap during a liquidation.
    // TEST-059 verifies: REQ-SWAP-029, REQ-SWAP-088, INV-037, PROP-020, Q-397
    // TEST-093 verifies: REQ-SWAP-029, INV-037
    function test_TEST_059_noAvanaFundsEnter() public {
        _fund(usdc, keeper, 1950e6);
        vm.recordLogs();
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(_params(proxy, 1950e6));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        uint256 inflow = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(usdc) || logs[i].topics[0] != transferSig) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != address(lvs)) continue;
            address from = address(uint160(uint256(logs[i].topics[1])));
            assertTrue(
                from == keeper || from == address(lpVault) || from == address(usdtPrimary)
                    || from == address(usdtBackup),
                "USDC into LPVaultSwap only from the caller, the unwind and the routes"
            );
            inflow += abi.decode(logs[i].data, (uint256));
        }
        assertEq(inflow, r.callerFunds + r.recovered + r.shortfall, "inflow = Kf + R + shortfall");
    }
}
