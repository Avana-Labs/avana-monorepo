// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {MarketStatus} from "../../src/policy/market-registry/types/MarketStatus.sol";
import {Market} from "../../src/types/Market.sol";
import {SettlementReport} from "../../src/types/SettlementReport.sol";
import {AccessTrace} from "../utils/AccessTrace.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";
import {Vm, VmSafe} from "forge-std/Vm.sol";

interface ILVSMaxBonusConfigurator {
    function updateMaxLiquidationBonus(
        address spoke,
        uint256 reserveId,
        uint32 dynamicConfigKey,
        uint256 maxLiquidationBonus
    ) external;
}

/// @title LPVaultSwapLivenessUnitTest
/// @notice What never stops LPVaultSwap from liquidating, on the real LPVaultSwap, Collateralization, vault token,
/// `DexPathRoute` swap routes and local Aave V4: market offboarding (TEST-213), the absence of any restriction state
/// on LPVaultSwap (TEST-168), circuit breakers it never writes (TEST-228), a bonus too small for any slippage
/// (TEST-245), debts of any size (TEST-278), and the backup route when the primary fails (TEST-054).
/// forge-config: default.isolate = false
contract LPVaultSwapLivenessUnitTest is LPVaultSwapUnitBase {
    using AccessTrace for Vm.AccountAccess[];

    address internal proxy;
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
    }

    /// @notice An offboarding market still liquidates and settles its pending balance: with the market's status
    /// `Offboarding` in the MarketRegistry record LPVaultSwap reads, `liquidate` and `settlePending` complete as before.
    // TEST-213 verifies: REQ-SWAP-004, REQ-SWAP-066
    function test_TEST_213_offboardingMarketStillLiquidates() public {
        uint256 kept = _seizeAndKeep(proxy, 1000e6);
        Market memory m = registry.getMarket(MARKET_ID);
        m.status = MarketStatus.Offboarding;
        registry.setMarket(MARKET_ID, m);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 500e6));
        assertGt(r.unitsSeized, 0, "liquidated while Offboarding");
        assertEq(coll.getPending(address(vt)).units, kept, "earlier units reconciled");
        vm.prank(stranger);
        (uint256 units,,) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(units, kept, "pending settled while Offboarding");
    }

    /// @notice No restriction state on LPVaultSwap: no pause, freeze, keeper-suspension, quarantine or incident
    /// selector exists on it (each call fails, from the timelock too); a liquidation by an address outside the
    /// committed-operator list settles; and a liquidation writes no word of LPVaultSwap's storage.
    // TEST-168 verifies: REQ-SWAP-001, REQ-SWAP-003, REQ-SWAP-034
    function test_TEST_168_noRestrictionStateOnLPVaultSwap() public {
        bytes[8] memory calls = [
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("unpause()"),
            abi.encodeWithSignature("freeze()"),
            abi.encodeWithSignature("setPaused(bool)", true),
            abi.encodeWithSignature("pauseLiquidations(uint256)", MARKET_ID),
            abi.encodeWithSignature("suspendKeeper(address)", keeper),
            abi.encodeWithSignature("quarantine(address)", proxy),
            abi.encodeWithSignature("setMarketFrozen(uint256,bool)", MARKET_ID, true)
        ];
        for (uint256 i = 0; i < calls.length; ++i) {
            vm.prank(timelock);
            (bool ok,) = address(lvs).call(calls[i]);
            assertFalse(ok, "no restriction selector");
        }
        assertFalse(lvs.isApprovedKeeper(stranger), "not a committed operator");
        vm.startStateDiffRecording();
        LiquidationResult memory r = _liquidateAs(stranger, _params(proxy, 1950e6));
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        assertGt(r.unitsSeized, 0, "any caller liquidates");
        assertEq(acc.writes(address(lvs)), 0, "no storage word of LPVaultSwap written");
    }

    /// @notice LPVaultSwap writes no breaker counter: three liquidations that each fail the primary route (falling to
    /// the backup) and seize most of the market leave the MarketRegistry's storage untouched, with no state-changing
    /// call from LPVaultSwap to it; liquidation and pending settlement settle under the registry's Paused state.
    // TEST-228 verifies: REQ-SWAP-003, REQ-SWAP-066
    function test_TEST_228_noBreakerWrittenByLiquidations() public {
        (address carolProxy,) = _openAccount(carol, 10_000e6, 18_000e6, 250_000_000);
        (address aliceProxy,) = _openAccount(alice, 10_000e6, 18_000e6, 250_000_000);
        _seizeAndKeep(aliceProxy, 500e6);
        registry.setPause(2, 1);
        usdtUsdcPool.setRate(9000, 10_000);
        vm.startStateDiffRecording();
        address[3] memory proxies = [proxy, carolProxy, aliceProxy];
        for (uint256 i = 0; i < 3; ++i) {
            vm.recordLogs();
            LiquidationResult memory r = _liquidateAs(keeper, _params(proxies[i], 6000e6));
            assertGt(r.unitsSeized, 0, "settled under Paused with the primary failing");
            assertEq(_count(vm.getRecordedLogs(), RouteFailed.selector), 1, "primary failed, backup used");
        }
        vm.prank(stranger);
        lvs.settlePending(MARKET_ID, usdcReserveId);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        assertEq(acc.writes(address(registry)), 0, "no breaker counter or flag written");
        for (uint256 i = 0; i < acc.length; ++i) {
            if (acc[i].account == address(registry) && acc[i].accessor == address(lvs)) {
                assertTrue(acc[i].kind == VmSafe.AccountAccessKind.StaticCall, "only view calls to the registry");
            }
        }
    }

    /// @notice With Aave's bonus at 10,000 (no bonus), `s = 0`: the floor is the whole value less `U` and `ε`, a
    /// recovery below it that the caller does not top up reverts `RecoveryBelowFloor`, and the same call with a
    /// shortfall budget settles with the caller paying the gap.
    // TEST-245 verifies: SPEC-LIQ-003, SPEC-LIQ-005, REQ-SWAP-005
    function test_TEST_245_noBonusMeansZeroSlippage() public {
        vm.prank(aaveDao);
        ILVSMaxBonusConfigurator(aave.spokeConfigurator)
            .updateMaxLiquidationBonus(aave.cdpSpoke, vtReserveId, 0, 10_000);
        uint256 bonus = IAaveV4Spoke(aave.cdpSpoke).getLiquidationBonus(vtReserveId, proxy, _hf(proxy));
        assertEq(bonus, BPS, "no bonus");
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.RecoveryBelowFloor.selector));
        LiquidationParams memory p = _params(proxy, 1950e6);
        p.maxShortfall = 50e6;
        vm.recordLogs();
        LiquidationResult memory r = _liquidateAs(keeper, p);
        (SettlementReport memory rep, bool found) = _settledReport(vm.getRecordedLogs());
        assertTrue(found, "report");
        assertEq(rep.effectiveSlippageBps, 0, "s = 0");
        uint256 v = _valueOf(r.unitsSeized, P_VAULT, PRICE_UNIT, 6);
        assertEq(r.minOut, _floorOf(v, 0, 2, FLOOR_ROUNDING_ALLOWANCE_USDC), "minRec = V - U - eps");
        assertLt(r.recovered, r.minOut, "recovery below the floor");
        assertEq(r.shortfall, r.minOut - r.recovered, "the caller tops up the gap");
    }

    /// @notice No minimum debt: an account owing $1 of USDC and one owing 1 base unit become liquidatable when the
    /// collateral price falls, and a committed operator liquidates both: the debt is cleared or the
    /// collateral exhausted, whatever the size.
    // TEST-278 verifies: REQ-SWAP-005, REQ-SWAP-006
    function test_TEST_278_smallestDebtsLiquidate() public {
        (address one,) = _openAccount(carol, 1e6, 1e6, 250_000_000);
        (address unit,) = _openAccount(alice, 1, 1, 250_000_000);
        assertEq(_debtOf(one, usdcReserveId), 1e6, "$1 of debt");
        assertEq(_debtOf(unit, usdcReserveId), 1, "1 base unit of debt");
        lpOracle.setAnswer(int256(100_000_000));
        assertLt(_hf(one), 1e18, "$1 account liquidatable");
        assertLt(_hf(unit), 1e18, "1-unit account liquidatable");
        address[2] memory proxies = [one, unit];
        uint256[2] memory debts = [uint256(1e6), 1];
        for (uint256 i = 0; i < 2; ++i) {
            LiquidationResult memory r = _liquidateAs(keeper, _params(proxies[i], debts[i]));
            assertGt(r.debtRepaid, 0, "debt repaid");
            assertGt(r.unitsSeized, 0, "collateral seized");
            assertTrue(
                _debtOf(proxies[i], usdcReserveId) == 0 || _suppliedUnits(proxies[i]) == 0,
                "debt cleared, or the collateral exhausted with the rest a deficit"
            );
        }
    }

    /// @notice Routes: the USDT leg goes through its primary route, and through the pre-approved backup when the primary
    /// pays below its minimum or the registry marks it unusable; USDC, the debt asset itself, is never swapped; no
    /// call reaches the pool being unwound, and no route spends the debt asset (no buy or sell-back leg).
    // TEST-054 verifies: REQ-SWAP-022, REQ-SWAP-088, REQ-SWAP-089, INV-070
    function test_TEST_054_backupWhenPrimaryFailsAndNoDebtAssetSwap() public {
        (address carolProxy,) = _openAccount(carol, 10_000e6, 18_000e6, 250_000_000);
        vm.startStateDiffRecording();
        _liquidateAs(keeper, _params(proxy, 1000e6));
        assertEq(usdtUsdcPool.swaps(), 1, "primary");
        usdtUsdcPool.setRate(9000, 10_000);
        _liquidateAs(keeper, _params(proxy, 1000e6));
        assertEq(usdtUsdcPool2.swaps(), 1, "backup after the primary paid below its minimum");
        usdtUsdcPool.setRate(9995, 10_000);
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(usdtPrimary), false);
        _liquidateAs(keeper, _params(carolProxy, 1000e6));
        assertEq(usdtUsdcPool.swaps(), 1, "unusable primary never called");
        assertEq(usdtUsdcPool2.swaps(), 2, "backup");
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        assertEq(acc.touches(pool), 0, "the market's own pool is never used");
        address[4] memory routes = [address(usdtPrimary), address(usdtBackup), address(usdcToGho), address(usdtToGho)];
        for (uint256 i = 0; i < acc.length; ++i) {
            if (acc[i].accessor != address(lvs) || acc[i].data.length < 4) continue;
            if (bytes4(acc[i].data) == ISettlementRoute.swap.selector) {
                assertTrue(acc[i].account == routes[0] || acc[i].account == routes[1], "only USDT -> USDC routes");
            }
            if (acc[i].account == address(usdc) && bytes4(acc[i].data) == usdc.approve.selector) {
                (address spender,) = abi.decode(_args(acc[i].data), (address, uint256));
                assertTrue(spender != routes[0] && spender != routes[1], "the debt asset is never routed");
            }
        }
    }

    function _args(
        bytes memory data
    ) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }
}
