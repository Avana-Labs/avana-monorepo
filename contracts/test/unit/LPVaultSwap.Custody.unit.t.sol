// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationErrors} from "../../src/custody/collateralization/ICollateralizationErrors.sol";
import {ICollateralizationEvents} from "../../src/custody/collateralization/ICollateralizationEvents.sol";
import {ICollateralizationSeizure} from "../../src/custody/collateralization/ICollateralizationSeizure.sol";
import {ICollateralizationViews} from "../../src/custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {ILPVaultSwapLiquidation} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {ILock} from "../../src/lock/lock/ILock.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {AccessTrace} from "../utils/AccessTrace.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Re-enters Avana from a pool token's transfer hook during an unwind and records how each attempt ended.
/// Every attempt is caught, so the outer call goes on; the test reads the recorded errors.
contract LVSReentryProbe {
    ILPVaultSwapLiquidation internal immutable LVS;
    ICollateralizationViews internal immutable COLL;
    address internal immutable PROXY;
    address internal immutable VT;
    IERC20 internal immutable USDC;

    LiquidationParams internal params;
    uint256 internal debtReserveId;
    uint256 public attempts;
    bytes[] internal errors;
    bool public anySucceeded;

    constructor(
        address lvs_,
        address coll_,
        address proxy_,
        address vt_,
        address usdc_
    ) {
        (LVS, COLL, PROXY, VT, USDC) =
        (ILPVaultSwapLiquidation(lvs_), ICollateralizationViews(coll_), proxy_, vt_, IERC20(usdc_));
    }

    function arm(
        LiquidationParams calldata p,
        uint256 reserveId
    ) external {
        params = p;
        debtReserveId = reserveId;
        USDC.approve(address(LVS), type(uint256).max);
    }

    function reenter() external {
        ++attempts;
        try LVS.liquidate(params) {
            anySucceeded = true;
        } catch (bytes memory err) {
            errors.push(err);
        }
        try LVS.settlePending(params.marketId, debtReserveId) {
            anySucceeded = true;
        } catch (bytes memory err) {
            errors.push(err);
        }
        try COLL.getAccountCredited(PROXY, VT) returns (uint256) {
            anySucceeded = true;
        } catch (bytes memory err) {
            errors.push(err);
        }
        try COLL.getPending(VT) {
            anySucceeded = true;
        } catch (bytes memory err) {
            errors.push(err);
        }
    }

    function errorCount() external view returns (uint256) {
        return errors.length;
    }

    function errorAt(
        uint256 i
    ) external view returns (bytes memory) {
        return errors[i];
    }
}

/// @title LPVaultSwapCustodyUnitTest
/// @notice LPVaultSwap's side of the custody rows on the real Collateralization, vault token, Lock and local Aave V4:
/// the pending settlement only it can drive under the Lock (TEST-152), the debit equalities of a seizure (TEST-056),
/// no vault-token path out of LPVaultSwap (TEST-189), the pending balance funding only the Coverage Spoke (TEST-153)
/// and re-entry from a pool token's transfer hook during the unwind (TEST-222).
/// forge-config: default.isolate = false
contract LPVaultSwapCustodyUnitTest is LPVaultSwapUnitBase {
    using AccessTrace for Vm.AccountAccess[];

    address internal proxy;
    bytes32 internal key;
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        (proxy, key) = _bobAccount();
    }

    function _gap() internal view returns (int256) {
        return int256(coll.getTotalCredited(address(vt))) + int256(coll.getPending(address(vt)).units)
            - int256(vt.totalSupply());
    }

    /// @dev Units kept by an earlier implementation, reconciled into the pending balance by the next honest
    /// liquidation.
    function _pendingBalance() internal returns (uint256 kept) {
        kept = _seizeAndKeep(proxy, 1000e6);
        _liquidateAs(keeper, _params(proxy, 500e6));
    }

    /// @notice Collateralization's `settlePending` refuses every caller but LPVaultSwap, LPVaultSwap without the Lock,
    /// a call while a seizure snapshot is active, zero units, units above the pending balance and a call without the
    /// matching burn (`SupplyDropMismatch`); through `LPVaultSwap.settlePending` the Adapter burns exactly the units,
    /// Collateralization emits `PendingSettled` with all remaining tokens (the balance reaches 0), pays them to
    /// LPVaultSwap and the backing gap is unchanged. A market with nothing pending then reverts `NothingPending`.
    // TEST-152 verifies: REQ-VAULT-061, REQ-SWAP-066, REQ-SWAP-092, INV-042
    function test_TEST_152_pendingSettledOnlyByLPVaultSwapUnderTheLock() public {
        uint256 kept = _pendingBalance();
        address v = address(vt);
        assertEq(coll.getPending(v).units, kept, "pending = units kept");
        int256 gap = _gap();
        assertGe(gap, 0, "supply <= credited + pending");

        vm.prank(attacker);
        vm.expectRevert(ICollateralizationErrors.NotLPVaultSwap.selector);
        ICollateralizationSeizure(address(coll)).settlePending(v, kept);
        vm.prank(address(lvs));
        vm.expectRevert(ICollateralizationErrors.LockNotHeld.selector);
        ICollateralizationSeizure(address(coll)).settlePending(v, kept);

        uint256 snap = vm.snapshotState();
        vm.startPrank(address(lvs));
        ILock(address(lock)).acquire();
        vm.expectRevert(ICollateralizationErrors.PendingExceeded.selector);
        ICollateralizationSeizure(address(coll)).settlePending(v, 0);
        vm.expectRevert(ICollateralizationErrors.PendingExceeded.selector);
        ICollateralizationSeizure(address(coll)).settlePending(v, kept + 1);
        uint256 supply = vt.totalSupply();
        uint256 limit = coll.getTotalCredited(v) + kept;
        vm.expectRevert(
            abi.encodeWithSelector(ICollateralizationErrors.SupplyDropMismatch.selector, limit - kept, supply)
        );
        ICollateralizationSeizure(address(coll)).settlePending(v, kept);
        ICollateralizationSeizure(address(coll)).beginSeizure(proxy, v);
        vm.expectRevert(ICollateralizationErrors.SeizureActive.selector);
        ICollateralizationSeizure(address(coll)).settlePending(v, kept);
        vm.stopPrank();
        // Roll back the Lock and the snapshot the refusals above left open.
        vm.revertToState(snap);

        assertEq(usdc.balanceOf(address(coll)) + usdt.balanceOf(address(coll)) > 0, true, "Collateralization holds it");
        (uint256 a0, uint256 a1) = (usdc.balanceOf(address(coll)), usdt.balanceOf(address(coll)));
        uint256[] memory amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (a0, a1);
        vm.expectEmit(true, false, false, true, address(coll));
        emit ICollateralizationEvents.PendingSettled(v, kept, amounts);
        vm.startStateDiffRecording();
        vm.prank(stranger);
        lvs.settlePending(MARKET_ID, usdcReserveId);
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        (bool burned, uint256 iBurn) = acc.firstCall(address(adapter), adapter.burnSeized.selector, address(lvs), 0);
        (bool settled, uint256 iSettle) =
            acc.firstCall(address(coll), ICollateralizationSeizure.settlePending.selector, address(lvs), 0);
        assertTrue(burned && settled, "burn and settlement both ran");
        assertLt(iBurn, iSettle, "the Adapter burns the units before Collateralization debits them");
        assertEq(coll.getPending(v).units, 0, "pending balance 0");
        assertEq(usdc.balanceOf(address(coll)) + usdt.balanceOf(address(coll)), 0, "every pending token released");
        assertEq(_gap(), gap, "backing gap unchanged");
        vm.prank(stranger);
        vm.expectRevert(ILPVaultSwapErrors.NothingPending.selector);
        lvs.settlePending(MARKET_ID, usdcReserveId);
    }

    /// @notice Debit check: the proxy's share drop equals the units LPVaultSwap received, the vault-token supply drop,
    /// the units debited from the account's credit and the liquidity removed from the position; a settlement naming
    /// another proxy reverts; and with the Hub's shares unequal to its assets the liquidation stops before Aave.
    // TEST-056 verifies: REQ-SWAP-015, REQ-SWAP-020, REQ-SWAP-007, INV-013
    function test_TEST_056_shareDropEqualsEverySideOfTheDebit() public {
        uint256 shares = _suppliedUnits(proxy);
        uint256 supply = vt.totalSupply();
        uint256 credited = coll.getAccountCredited(proxy, address(vt));
        uint256 liquidity = lpVault.unitsOf(key);
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1950e6));
        assertGt(r.unitsSeized, 0, "c > 0");
        assertEq(shares - _suppliedUnits(proxy), r.unitsSeized, "share drop = c");
        assertEq(supply - vt.totalSupply(), r.unitsSeized, "supply drop = c");
        assertEq(credited - coll.getAccountCredited(proxy, address(vt)), r.unitsSeized, "units debited = c");
        assertEq(liquidity - lpVault.unitsOf(key), r.unitsSeized, "liquidity removed = c");
        assertEq(vt.balanceOf(address(lvs)), 0, "every seized unit burned");

        (address alice2,) = _openAccount(alice, 6000e6, 10_300e6, 250_000_000);
        vm.startPrank(address(lvs));
        ILock(address(lock)).acquire();
        ICollateralizationSeizure(address(coll)).beginSeizure(proxy, address(vt));
        vm.expectRevert(ICollateralizationErrors.SeizureMismatch.selector);
        ICollateralizationSeizure(address(coll)).settleSeizure(alice2, address(vt), 1, new uint256[](0));
        vm.stopPrank();
    }

    /// @notice Shares unequal to assets on the vault token's Hub asset stop the liquidation with LPVaultSwap's alarm
    /// before any seizure.
    // TEST-056 verifies: REQ-SWAP-007
    function test_TEST_056_sharesUnequalToAssetsStopsTheLiquidation() public {
        uint256 shares = IAaveV4Hub(aave.hub).getAddedShares(vtAssetId);
        vm.mockCall(aave.hub, abi.encodeCall(IAaveV4Hub.getAddedAssets, (vtAssetId)), abi.encode(shares + 1));
        uint256 before = _suppliedUnits(proxy);
        _expectLiquidateRevert(keeper, _params(proxy, 1950e6), _err(ILPVaultSwapErrors.SharesNotEqualAssets.selector));
        assertEq(_suppliedUnits(proxy), before, "nothing seized");
    }

    /// @notice FINDING-092 regression: LPVaultSwap holding vault tokens cannot send them to the Hub, an EOA or the
    /// Spoke (`UnauthorizedTransfer(from, to)`, whatever allowance a spender has); over a liquidation and a pending
    /// settlement it makes no `transfer`, `transferFrom` or `approve` call on the vault token and no `supply` on the
    /// Spoke, and every unit it received is burned in the same call: the units an earlier implementation kept stay
    /// until `settlePending` burns them, after which its vault-token balance is 0.
    // TEST-189 verifies: REQ-SWAP-084, REQ-SWAP-092, INV-013, INV-041
    function test_TEST_189_noVaultTokenPathOutOfLPVaultSwap() public {
        uint256 kept = _seizeAndKeep(proxy, 1000e6);
        assertEq(vt.balanceOf(address(lvs)), kept, "units held by LPVaultSwap");
        address[3] memory to = [aave.hub, stranger, aave.cdpSpoke];
        for (uint256 i = 0; i < to.length; ++i) {
            vm.prank(address(lvs));
            vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, address(lvs), to[i]));
            vt.transfer(to[i], 1);
        }
        vm.prank(address(lvs));
        vt.approve(aave.hub, type(uint256).max);
        vm.prank(aave.hub);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, address(lvs), aave.hub));
        vt.transferFrom(address(lvs), aave.hub, 1);
        vm.prank(address(lvs));
        vt.approve(aave.hub, 0);

        vm.startStateDiffRecording();
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 500e6));
        assertGt(r.unitsSeized, 0, "seized");
        assertEq(vt.balanceOf(address(lvs)), kept, "every unit of this call burned; the earlier units wait for pending");
        lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(vt.balanceOf(address(lvs)), 0, "0 after the pending settlement");
        Vm.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        address v = address(vt);
        assertEq(acc.countCalls(v, IERC20.transfer.selector, address(lvs)), 0, "no transfer");
        assertEq(acc.countCalls(v, IERC20.transferFrom.selector, address(lvs)), 0, "no transferFrom");
        assertEq(acc.countCalls(v, IERC20.approve.selector, address(lvs)), 0, "no approve");
        assertEq(acc.countCalls(aave.cdpSpoke, IAaveV4Spoke.supply.selector, address(lvs)), 0, "no supply");
        assertEq(acc.countCalls(address(adapter), adapter.burnSeized.selector, address(lvs)), 2, "one burn per call");
    }

    /// @notice Reconcile and settle: after the reconcile Collateralization holds exactly the pool tokens of the
    /// pending balance and the LPVault none of them, supply equals credited plus pending; `settlePending` raises the
    /// USDC Coverage Spoke's funded balance by exactly the recovered amount and no other address gains (the caller,
    /// the fee recipient and LPVaultSwap end where they started).
    // TEST-153 verifies: REQ-VAULT-061, REQ-VAULT-154, REQ-SWAP-066, INV-042
    function test_TEST_153_pendingFundsOnlyTheCoverageSpoke() public {
        uint256 kept = _pendingBalance();
        address v = address(vt);
        assertEq(vt.totalSupply(), coll.getTotalCredited(v) + kept, "supply = credited + pending");
        (uint256 c0, uint256 c1) = (usdc.balanceOf(address(coll)), usdt.balanceOf(address(coll)));
        (uint256 a0, uint256 a1) = _released(kept);
        assertEq(c0, a0, "Collateralization holds the pending USDC");
        assertEq(c1, a1, "Collateralization holds the pending USDT");
        uint256 coverage = usdcCoverage.fundedBalance();
        Snap memory s = _snap(stranger);
        vm.prank(stranger);
        (,, uint256 added) = lvs.settlePending(MARKET_ID, usdcReserveId);
        assertEq(usdcCoverage.fundedBalance(), coverage + added, "coverage rises by exactly R");
        Snap memory a = _snap(stranger);
        assertEq(a.callerUsdc, s.callerUsdc, "the caller gains nothing");
        assertEq(a.callerUsdt, s.callerUsdt, "the caller gains no USDT");
        assertEq(a.lvsUsdc, s.lvsUsdc, "LPVaultSwap keeps no USDC");
        assertEq(a.lvsUsdt, s.lvsUsdt, "LPVaultSwap keeps no USDT");
        assertEq(a.escrowUsdc, s.escrowUsdc, "nothing escrowed");
        assertEq(usdc.balanceOf(address(coll)) + usdt.balanceOf(address(coll)), 0, "nothing left in Collateralization");
        assertEq(vt.totalSupply(), coll.getTotalCredited(v), "supply = credited, pending 0");
    }

    /// @notice With a pending balance open, a pool token whose transfer hook re-enters during the unwind of a
    /// liquidation: every re-entry into
    /// `liquidate` and `settlePending` reverts `LockHeld(LPVaultSwap)` and every Collateralization ledger view reverts
    /// `Locked`; the outer liquidation settles exactly as the same liquidation without the hook.
    // TEST-222 verifies: REQ-SWAP-002, REQ-LOCK-016, REQ-VAULT-091, REQ-VAULT-125
    function test_TEST_222_hookReentryDuringUnwindRefused() public {
        _pendingBalance();
        uint256 snap = vm.snapshotState();
        LiquidationResult memory clean = _liquidateAs(keeper, _params(proxy, 1000e6));
        vm.revertToState(snap);
        LVSReentryProbe probe = new LVSReentryProbe(address(lvs), address(coll), proxy, address(vt), address(usdc));
        usdc.mint(address(probe), 10_000e6);
        probe.arm(_params(proxy, 500e6), usdcReserveId);
        usdt.setHook(address(probe), abi.encodeCall(LVSReentryProbe.reenter, ()));
        LiquidationResult memory r = _liquidateAs(keeper, _params(proxy, 1000e6));
        usdt.setHook(address(0), "");
        assertGt(probe.attempts(), 0, "the hook re-entered");
        assertFalse(probe.anySucceeded(), "no re-entry succeeded");
        assertEq(probe.errorCount(), probe.attempts() * 4, "every attempt reverted");
        bytes memory lockHeld = abi.encodeWithSelector(ILock.LockHeld.selector, address(lvs));
        for (uint256 i = 0; i < probe.errorCount(); i += 4) {
            assertEq(probe.errorAt(i), lockHeld, "liquidate: LockHeld");
            assertEq(probe.errorAt(i + 1), lockHeld, "settlePending: LockHeld");
            assertEq(probe.errorAt(i + 2), _err(ICollateralizationErrors.Locked.selector), "credited view: Locked");
            assertEq(probe.errorAt(i + 3), _err(ICollateralizationErrors.Locked.selector), "pending view: Locked");
        }
        assertEq(r.unitsSeized, clean.unitsSeized, "same seizure");
        assertEq(r.recovered, clean.recovered, "same recovery");
        assertEq(r.keeperOut, clean.keeperOut, "same payout");
        assertEq(usdc.balanceOf(address(probe)), 10_000e6, "the probe's funds never moved");
    }
}
