// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationSeizure} from "../../src/custody/collateralization/ICollateralizationSeizure.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwap} from "../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {ILPVaultSwapEvents} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapEvents.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {LVSRevertingRoute} from "../utils/mocks/LPVaultSwapMocks.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";

interface ILVSSpokePause {
    function updatePaused(
        address spoke,
        uint256 reserveId,
        bool paused
    ) external;
}

/// @notice A caller batching several liquidations in one transaction (2.11 `REQ-SWAP-118`): funds each call from its
/// own balance and records every result.
contract LVSMulticaller {
    LiquidationResult[] internal results;

    function run(
        ILPVaultSwap lvs,
        PayoutToken asset,
        LiquidationParams[] calldata calls
    ) external {
        for (uint256 i = 0; i < calls.length; ++i) {
            asset.approve(address(lvs), calls[i].debtToCover);
            results.push(lvs.liquidate(calls[i]));
        }
    }

    function result(
        uint256 i
    ) external view returns (LiquidationResult memory) {
        return results[i];
    }
}

/// @title LPVaultSwapSequencingUnitTest
/// @notice The order and scope of LPVaultSwap's calls inside one liquidation (2.11 `REQ-SWAP-015`, `REQ-SWAP-045`,
/// `REQ-SWAP-067`), valuation at the oracle's leg prices rather than pool spot (`SPEC-LIQ-012`), liquidations batched
/// in one transaction (`SPEC-LIQ-021`, `REQ-SWAP-118`), Aave-side halts no Avana call overrides (`REQ-SWAP-119`), and
/// the absence of a flash-source setter (`REQ-SWAP-120`).
/// forge-config: default.isolate = false
contract LPVaultSwapSequencingUnitTest is LPVaultSwapUnitBase {
    address internal proxy;
    address internal aliceProxy;

    function setUp() public override {
        super.setUp();
        (proxy,) = _bobAccount();
        (aliceProxy,) = _openAccount(alice, 6000e6, 10_300e6, 250_000_000);
    }

    /// @notice `beginSeizure(proxy, vaultToken)` is called exactly once, for the liquidated proxy and the market's
    /// vault token, and before `liquidationCall`: Collateralization's `settleSeizure` measures the share drop from the
    /// snapshot `beginSeizure` took, so a liquidation that seized `c > 0` units and settled proves the snapshot preceded
    /// Aave's transfer of the shares.
    // TEST-055 verifies: REQ-SWAP-015, REQ-SWAP-045
    function test_REQ_SWAP_015_beginSeizureBeforeLiquidationCall() public {
        vm.expectCall(
            address(coll), abi.encodeCall(ICollateralizationSeizure.beginSeizure, (proxy, address(vt))), uint64(1)
        );
        vm.expectCall(
            address(coll), abi.encodeCall(ICollateralizationSeizure.beginSeizure, (aliceProxy, address(vt))), uint64(0)
        );
        vm.expectCall(
            aave.cdpSpoke,
            abi.encodeCall(IAaveV4Spoke.liquidationCall, (vtReserveId, usdcReserveId, proxy, uint256(1950e6), false)),
            uint64(1)
        );
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertGt(r.unitsSeized, 0, "c > 0: the snapshot preceded the share transfer");
        assertEq(coll.getPending(address(vt)).units, 0, "the whole seizure settled in this call");
    }

    /// @notice Without a snapshot the seizure does not settle: a `settleSeizure` for the proxy outside a liquidation
    /// (no `beginSeizure`) reverts in Collateralization, so LPVaultSwap cannot settle a seizure it did not open.
    // TEST-055 verifies: REQ-SWAP-015
    function test_REQ_SWAP_015_settleWithoutSnapshotRefused() public {
        vm.prank(address(lvs));
        (bool ok,) = address(coll)
            .call(abi.encodeCall(ICollateralizationSeizure.settleSeizure, (proxy, address(vt), 1, new uint256[](0))));
        assertFalse(ok, "settleSeizure without beginSeizure");
    }

    /// @notice `burnSeized` and `settleSeizure` run once each, for the market and proxy named in the call and the
    /// units Aave seized; the other account of the market is never named.
    // TEST-055 verifies: REQ-SWAP-045
    function test_REQ_SWAP_045_callsScopedToActiveLiquidation() public {
        vm.expectCall(address(adapter), abi.encodeWithSelector(adapter.burnSeized.selector, MARKET_ID, address(vt)), 1);
        vm.expectCall(
            address(coll),
            abi.encodeWithSelector(ICollateralizationSeizure.settleSeizure.selector, proxy, address(vt)),
            uint64(1)
        );
        vm.expectCall(
            address(coll),
            abi.encodeWithSelector(ICollateralizationSeizure.settleSeizure.selector, aliceProxy),
            uint64(0)
        );
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(adapter.lastBurnUnits(), r.unitsSeized, "burned exactly c");
        assertEq(adapter.burnCalls(), 1, "one burn");
    }

    /// @notice `settlePending` burns and releases only the named market's vault token: with a pending balance in
    /// market 4 and a second market listed, the burn names market 4 and its token.
    // TEST-170 verifies: REQ-SWAP-045, REQ-SWAP-066
    function test_REQ_SWAP_045_settlePendingScopedToMarket() public {
        _seizeAndKeep(proxy, 1000e6);
        _liquidateAs(keeper, _params(proxy, 500e6));
        uint256 pending = coll.getPending(address(vt)).units;
        assertGt(pending, 0, "pending balance");
        _deploySecondMarket();
        vm.expectCall(address(adapter), abi.encodeWithSelector(adapter.burnSeized.selector, MARKET_ID, address(vt)), 1);
        vm.expectCall(address(adapter), abi.encodeWithSelector(adapter.burnSeized.selector, MARKET_B), 0);
        vm.prank(makeAddr("anyone"));
        lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(coll.getPending(address(vt)).units, 0, "market 4 settled");
    }

    /// @notice `settleSeizure` reconciles an earlier gap before settling the current seizure: units an earlier
    /// seizure left unsettled move to the pending balance, and the liquidation's `c`, `aᵢ` and `R` are those of its own
    /// seizure alone (equal to the same liquidation on an account with no gap).
    // TEST-170 verifies: REQ-SWAP-067, REQ-SWAP-006, Q-201; shared: the earlier gap TEST-170's pending settlement later settles is moved to pending here
    function test_REQ_SWAP_067_earlierGapToPendingNotToCaller() public {
        uint256 snapshot = vm.snapshotState();
        LiquidationResult memory clean = _liquidateAs(keeper, _params(proxy, 500e6));
        vm.revertToState(snapshot);
        uint256 kept = _seizeAndKeep(proxy, 1000e6);
        uint256 pendingBefore = coll.getPending(address(vt)).units;
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 500e6));
        assertEq(coll.getPending(address(vt)).units, pendingBefore + kept, "earlier gap moved to pending");
        assertApproxEqAbs(r.unitsSeized, clean.unitsSeized, 1, "c is the current seizure only");
        assertApproxEqAbs(r.recovered, clean.recovered, 2, "R measures only the current c");
        assertEq(r.amountsOut.length, clean.amountsOut.length, "same legs");
        assertEq(vt.balanceOf(address(lvs)), kept, "the gap's units stay for settlePending");
    }

    /// @notice Valuation uses LPOracle's prices only: moving both pools' spot rates leaves `minRec` unchanged and
    /// changes only `R`; the USDT leg minimum follows the oracle's USDT leg price, so routes paying 0.988 fail the leg
    /// minimum at the oracle's $0.9995 (`NoRouteAvailable`) and pass it once the oracle serves $0.985, with `minRec`
    /// (the vault price) unchanged by the leg price.
    // TEST-050 verifies: SPEC-LIQ-012, SPEC-LIQ-018, REQ-SWAP-042; shared: TEST-050's floor from the oracle value with no spot-price input, shown by moving pool spot
    function test_SPEC_LIQ_012_floorFromOracleLegsNotSpot() public {
        uint256 snapshot = vm.snapshotState();
        LiquidationResult memory base = _liquidateAs(keeper, _params(proxy, 1950e6));
        vm.revertToState(snapshot);
        usdtUsdcPool.setRate(10_200, 10_000);
        usdtUsdcPool2.setRate(10_200, 10_000);
        LiquidationResult memory moved = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(moved.minOut, base.minOut, "floor independent of pool spot");
        assertGt(moved.recovered, base.recovered, "the spot move changes only R");
        vm.revertToState(snapshot);
        usdtUsdcPool.setRate(9880, 10_000);
        usdtUsdcPool2.setRate(9880, 10_000);
        _fund(usdc, keeper, 1950e6);
        vm.prank(keeper);
        vm.expectRevert(ILPVaultSwapErrors.NoRouteAvailable.selector);
        lvs.liquidate(_params(proxy, 1950e6));
        uint256[] memory prices = new uint256[](2);
        (prices[0], prices[1]) = (PRICE_UNIT, 98_500_000);
        lpOracle.setPrices(prices);
        LiquidationResult memory lower = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertEq(lower.minOut, base.minOut, "minRec values seized units at the vault price");
        assertEq(lower.recovered, lower.amountsOut[0] + lower.amountsOut[1] * 9880 / 10_000, "USDT leg routed at 0.988");
    }

    /// @notice Liquidations of two accounts batched in one transaction both settle: each call takes and frees the
    /// Lock, so the second never waits on the first, and the Lock is free at the end.
    // TEST-093 verifies: SPEC-LIQ-021, REQ-SWAP-118, REQ-SWAP-002
    function test_SPEC_LIQ_021_batchedCallsInOneTransaction() public {
        LVSMulticaller m = new LVSMulticaller();
        LiquidationParams[] memory calls = new LiquidationParams[](2);
        calls[0] = _params(proxy, 1950e6);
        calls[1] = _params(aliceProxy, 1000e6);
        usdc.mint(address(m), 2950e6);
        uint256 hfBob = _hf(proxy);
        uint256 hfAlice = _hf(aliceProxy);
        m.run(lvs, usdc, calls);
        LiquidationResult memory r0 = m.result(0);
        LiquidationResult memory r1 = m.result(1);
        assertGt(r0.unitsSeized, 0, "first");
        assertGt(r1.unitsSeized, 0, "second");
        assertGt(_hf(proxy), hfBob, "Bob's HF rose");
        assertGt(_hf(aliceProxy), hfAlice, "Alice's HF rose");
        assertEq(usdc.balanceOf(address(m)), 2950e6 - r0.callerFunds - r1.callerFunds + r0.keeperOut + r1.keeperOut);
        assertFalse(lock.isLocked(), "Lock free");
        assertEq(usdc.balanceOf(address(lvs)), 0, "neutral");
    }

    /// @notice An Aave pause of the vault-token reserve, then of the debt reserve, blocks the liquidation with Aave's
    /// `ReservePaused`; no LPVaultSwap path overrides it, and the account liquidates in the first call after unpause.
    // TEST-169 verifies: REQ-SWAP-119; shared: TEST-169's Aave reserve pause run locally against LPVaultSwap, blocked until the unpause
    function test_REQ_SWAP_119_aavePauseBlocksUntilUnpause() public {
        uint256[2] memory reserves = [vtReserveId, usdcReserveId];
        for (uint256 i = 0; i < 2; ++i) {
            vm.prank(aaveDao);
            ILVSSpokePause(aave.spokeConfigurator).updatePaused(aave.cdpSpoke, reserves[i], true);
            _fund(usdc, keeper, 1950e6);
            vm.prank(keeper);
            vm.expectRevert(bytes4(keccak256("ReservePaused()")));
            lvs.liquidate(_params(proxy, 1950e6));
            vm.prank(aaveDao);
            ILVSSpokePause(aave.spokeConfigurator).updatePaused(aave.cdpSpoke, reserves[i], false);
        }
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertGt(r.unitsSeized, 0, "liquidated after the unpause");
    }

    /// @notice LPVaultSwap has no flash-source setter: the registry's `setFlashSource` is the only way to change the
    /// source, and selectors a setter would use are not served by the proxy.
    // TEST-046 verifies: REQ-SWAP-120, REQ-FLASH-006
    function test_REQ_SWAP_120_noFlashSourceSetter() public {
        bytes4[3] memory selectors = [
            bytes4(keccak256("setFlashSource(address)")),
            bytes4(keccak256("setFlashSource(address,address)")),
            bytes4(keccak256("flashSource()"))
        ];
        for (uint256 i = 0; i < selectors.length; ++i) {
            vm.prank(timelock);
            (bool ok,) = address(lvs).call(abi.encodePacked(selectors[i], abi.encode(address(flashSource))));
            assertFalse(ok, "no flash-source selector");
        }
        assertEq(registry.flashSource(), address(flashSource), "the registry names the source");
    }

    /// @notice No pause-state read: with the registry answering nothing for `pauseState()` and `pauseReason()` (the
    /// stand-in has neither, so any call would revert), `liquidate` and `settlePending` complete and make no such call:
    /// liquidation and pending settlement are open in None, Frozen and Paused alike.
    // TEST-162 verifies: REQ-SWAP-065, REQ-ACCESS-068, INV-043, INV-045
    // TEST-192 verifies: REQ-ACCESS-068, INV-045
    function test_TEST_162_liquidationAndPendingReadNoPauseState() public {
        vm.expectCall(address(registry), abi.encodeWithSignature("pauseState()"), 0);
        vm.expectCall(address(registry), abi.encodeWithSignature("pauseReason()"), 0);
        _seizeAndKeep(proxy, 1000e6);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 500e6));
        assertGt(r.unitsSeized, 0, "liquidated");
        vm.prank(makeAddr("anyone"));
        lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(coll.getPending(address(vt)).units, 0, "pending settled");
    }

    /// @notice The caller-funded sequence for the GHO reserve (the USDC reserve is the other tests of this file):
    /// `Kf` measured, `beginSeizure` for the proxy and token, `liquidationCall` with exactly `Kf` and `receiveShares =
    /// false`, `burnSeized` of `c`, `settleSeizure` of `c`, both legs into GHO, the caller paid in GHO.
    // TEST-047 verifies: REQ-SWAP-011, REQ-SWAP-015, REQ-SWAP-045, REQ-SWAP-088, SPEC-LIQ-006
    function test_TEST_047_ghoReserveSequence() public {
        address ghoProxy = _ghoDebtAccount(carol);
        LiquidationParams memory p = _params(ghoProxy, 1950e18);
        p.debtReserveId = ghoReserveId;
        vm.expectCall(
            address(coll), abi.encodeCall(ICollateralizationSeizure.beginSeizure, (ghoProxy, address(vt))), uint64(1)
        );
        vm.expectCall(
            aave.cdpSpoke,
            abi.encodeCall(
                IAaveV4Spoke.liquidationCall, (vtReserveId, ghoReserveId, ghoProxy, uint256(1950e18), false)
            ),
            uint64(1)
        );
        vm.expectCall(address(adapter), abi.encodeWithSelector(adapter.burnSeized.selector, MARKET_ID, address(vt)), 1);
        LiquidationResult memory r = _liquidateAs(keeper, p);
        assertEq(r.debtAsset, address(gho), "GHO reserve");
        assertEq(r.callerFunds, 1950e18, "Kf measured");
        assertEq(adapter.lastBurnUnits(), r.unitsSeized, "c burned");
        assertEq(gho.balanceOf(address(lvs)), 0, "neutral in GHO");
        assertEq(usdc.balanceOf(address(lvs)), 0, "the USDC leg swapped into GHO");
    }

    /// @notice The route loop's half of the GSM rule: for GHO debt a GSM primary that refuses (a seized GSM, or one
    /// whose capacity is below the leg, reverts) sends the leg to the backup route in the same call; a liquidation of
    /// USDC debt never calls the GSM, which is keyed to GHO only. The GSM's own checks are TEST-054 on the PegModule
    /// route; the fork half (the live GSM, Base) is the route suite's.
    // TEST-119 verifies: REQ-SWAP-022, REQ-SWAP-058, SPEC-LIQ-013, Q-062, Q-187
    function test_TEST_119_usdcDebtNeverCallsGsm() public {
        _gsmPrimary();
        vm.expectCall(address(gsmRoute), abi.encodeWithSignature("swap(uint256,uint256)"), 0);
        LiquidationResult memory usdcDebt = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertGt(usdcDebt.unitsSeized, 0, "USDC debt settles without the GSM");
    }

    // TEST-119 verifies: REQ-SWAP-022, REQ-SWAP-058, SPEC-LIQ-013, Q-062, Q-187
    function test_TEST_119_refusingGsmPrimaryFallsToBackup() public {
        _gsmPrimary();
        LVSRevertingRoute gsm = gsmRoute;
        address ghoProxy = _ghoDebtAccount(carol);
        LiquidationParams memory p = _params(ghoProxy, 1950e18);
        p.debtReserveId = ghoReserveId;
        _fund(gho, keeper, 1950e18);
        vm.expectEmit(address(lvs));
        emit ILPVaultSwapEvents.RouteFailed(
            MARKET_ID, address(usdc), address(gsm), LVSRevertingRoute.RouteDown.selector
        );
        vm.prank(keeper);
        LiquidationResult memory r = lvs.liquidate(p);
        assertEq(r.debtAsset, address(gho), "GHO debt settled through the backup");
        assertEq(usdc.balanceOf(address(lvs)), 0, "the USDC leg swapped on the backup");
    }

    LVSRevertingRoute internal gsmRoute;

    /// @dev A GSM stand-in as the primary USDC-to-GHO route (it refuses every swap, as a seized GSM or one short of
    /// capacity does), the DEX path as the backup.
    function _gsmPrimary() internal {
        gsmRoute = new LVSRevertingRoute();
        registry.setRoute(MARKET_ID, address(usdc), address(gho), 0, address(gsmRoute), true);
        registry.setRoute(MARKET_ID, address(usdc), address(gho), 1, address(usdcToGho), true);
    }

    function _ghoDebtAccount(
        address wallet
    ) internal returns (address ghoProxy) {
        (ghoProxy,) = _openAccount(wallet, 10_000e6, 0, 250_000_000);
        lpOracle.setAnswer(250_000_000);
        adapter.borrow(ghoProxy, ghoReserveId, address(gho), 18_000e18, wallet);
        lpOracle.setAnswer(int256(P_VAULT));
    }
}
