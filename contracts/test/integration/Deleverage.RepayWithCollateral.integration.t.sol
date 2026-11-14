// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {ILPVaultSwapEvents} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapEvents.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {IntegrationFlows} from "../utils/fixtures/IntegrationFlows.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DeleverageRepayWithCollateralIntegrationTest
/// @notice Repay with collateral on the deployed stack: the wallet calls the real AaveAdapter, which opens its session
/// and calls the real LPVaultSwap's `deleverage`; LPVaultSwap flash-borrows the debt asset from the core
/// `AaveV3FlashSource`, repays through the Adapter's `deleverageRepay`, has the Adapter release and unwind the units
/// (`deleverageRelease`), swaps the pool tokens into the debt asset, repays the loan and its premium by balance delta
/// and sends the rest to the wallet. The Lens's `previewRepayWithCollateral` is checked against the execution.
/// @dev Bob: 10,000 vault tokens at $2.10 ($21,000, CF 80 %) against 10,000 USDC (HF 1.68). Releasing 1,500 vault
/// tokens ($3,150 at the oracle) repays about 3,110 USDC at 100 bps slippage, the 1 USDC allowance and 10 bps of loan
/// fee room.
/// forge-config: default.isolate = false
contract DeleverageRepayWithCollateralIntegrationTest is IntegrationFlows {
    uint128 internal constant UNITS = 1500e6;

    struct Snapshot {
        uint256 pvRepaid;
        uint256 pvToWallet;
        uint256 pvHf;
        uint256 hf;
        uint256 debt;
        uint256 lender;
        uint256 supply;
        uint256 credited;
        uint256 wallet;
    }

    address internal proxy;
    bytes32 internal key;

    function setUp() public {
        _deployIntegration();
        (proxy, key) = _openAccount(bob, MARKET_ID, 10_000e6, 10_000e6, P_VAULT);
    }

    function _rwc(
        uint128 units,
        uint256 reserveId
    ) internal view returns (RepayWithCollateralParams memory p) {
        p = _rwcParams(MARKET_ID, key, units, reserveId);
    }

    function _aUsdc() internal view returns (address) {
        return v3Pool.getReserveAToken(address(usdc));
    }

    /// @notice The flash path by balance delta (the `deleverage` half of PROP-097 on the deployed contracts): the
    /// amount LPVaultSwap books from the flash source is what it received, the source ends with its principal plus the
    /// premium, no bonus or Avana fee is taken, the health factor rises, and every amount matches the Lens preview.
    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-081, REQ-SWAP-106, REQ-SWAP-122, REQ-FLASH-004, SPEC-LIQ-020, SPEC-PROXY-009, INV-095, Q-255
    function test_TEST_239_repayWithCollateralThroughRealLPVaultSwap() public {
        Snapshot memory b = _snapshot();
        vm.recordLogs();
        vm.prank(bob);
        (uint256 repaid, uint256 toWallet) = adapterC.repayWithCollateral(_rwc(UNITS, usdcReserveId));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 flashAmount, uint256 premium) = _flashLog(logs);
        uint256 recovered = _recoveredLog(logs);

        assertEq(repaid, b.pvRepaid, "debt repaid as previewed");
        assertEq(b.debt - _debtOf(proxy, usdcReserveId), repaid, "the Spoke's debt fell by debtRepaid");
        assertEq(flashAmount, repaid, "x: the loan is exactly the repayment LPVaultSwap received and repaid");
        assertEq(premium, (flashAmount * 5 + 5000) / 10_000, "5 bps premium, half-up");
        assertEq(usdc.balanceOf(_aUsdc()), b.lender + premium, "the lender holds principal plus premium");
        assertEq(usdc.balanceOf(address(flashSource)), 0, "the flash source keeps nothing");
        assertEq(usdc.balanceOf(bob) - b.wallet, toWallet, "the rest of the recovery to the wallet");
        assertEq(toWallet, recovered - flashAmount - premium, "wallet gets R - x - premium");
        // The preview converts at the oracle value V = 1,500 x $2.10 (REQ-LENS-029 style): it differs by V - R.
        assertEq(b.pvToWallet - toWallet, 3150e6 - recovered, "preview at R = V");
        _checkAfter(b);
    }

    function _snapshot() internal view returns (Snapshot memory b) {
        (b.pvRepaid, b.pvToWallet, b.pvHf) = lens.previewRepayWithCollateral(bob, MARKET_ID, key, UNITS, usdcReserveId);
        (b.hf, b.debt, b.lender) = (_hf(proxy), _debtOf(proxy, usdcReserveId), usdc.balanceOf(_aUsdc()));
        (b.supply, b.credited, b.wallet) = (token.totalSupply(), coll.getTotalCredited(vt), usdc.balanceOf(bob));
    }

    function _checkAfter(
        Snapshot memory b
    ) internal view {
        assertEq(usdc.balanceOf(feeRecipient), 0, "no Avana fee");
        assertEq(b.supply - token.totalSupply(), UNITS, "the Adapter burned the released units");
        assertEq(b.credited - coll.getTotalCredited(vt), UNITS, "Collateralization debited them");
        assertEq(token.totalSupply(), coll.getTotalCredited(vt), "supply = credited");
        assertGt(_hf(proxy), b.hf, "health factor rose");
        assertApproxEqRel(_hf(proxy), b.pvHf, 1e15, "health factor after near the preview");
        assertEq(usdc.balanceOf(lpVaultSwap) + usdt.balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps nothing");
        assertEq(usdc.balanceOf(adapter) + usdt.balanceOf(adapter), 0, "the Adapter keeps nothing");
        assertFalse(lock.isLocked(), "Lock released");
    }

    /// @notice Releasing every unit of the only record repays the whole debt, closes the record and returns the
    /// position to the wallet.
    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-081, REQ-PROXY-089, Q-255
    function test_TEST_239_fullUnitsToZeroDebtReturnPosition() public {
        (address p2, bytes32 k2) = _openAccount(alice, MARKET_ID, 2000e6, 1000e6, P_VAULT);
        RepayWithCollateralParams memory p = _rwcParams(MARKET_ID, k2, 2000e6, usdcReserveId);
        uint256 debtBefore = _debtOf(p2, usdcReserveId);
        uint256 walletBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        (uint256 repaid, uint256 toWallet) = adapterC.repayWithCollateral(p);
        assertEq(repaid, debtBefore, "the whole debt repaid");
        assertEq(_debtOf(p2, usdcReserveId), 0, "debt-free");
        assertEq(usdc.balanceOf(alice) - walletBefore, toWallet, "the rest to the wallet");
        assertEq(_suppliedOf(p2, MARKET_ID), 0, "nothing left supplied");
        assertEq(coll.getRecord(coll.recordIdOf(INTEGRATION, k2)).credited, 0, "record closed");
        assertEq(vault.ownerOf(k2), alice, "the position returned to its depositor");
    }

    // TEST-239 verifies: REQ-SWAP-106, SPEC-LIQ-020
    function test_TEST_239_minDebtRepaidEnforced() public {
        RepayWithCollateralParams memory p = _rwc(UNITS, usdcReserveId);
        p.minDebtRepaid = 3200e6;
        uint256 debtBefore = _debtOf(proxy, usdcReserveId);
        vm.expectPartialRevert(ILPVaultSwapErrors.DeleverageTooSmall.selector);
        vm.prank(bob);
        adapterC.repayWithCollateral(p);
        assertEq(_debtOf(proxy, usdcReserveId), debtBefore, "nothing repaid");
        assertFalse(lock.isLocked(), "Lock free");
    }

    /// @notice Paused(MintPathSuspect) refuses it; Paused(General) and a frozen wallet are served, since it only lowers
    /// debt and never lowers the health factor (REQ-ADAPTER-082, Q-356).
    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-082, REQ-LENS-038, Q-347, Q-356
    function test_TEST_239_pauseAndFreeze() public {
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.MintPathSuspect);
        RepayWithCollateralParams memory p = _rwc(500e6, usdcReserveId);
        (uint256 pvRepaid,,) = lens.previewRepayWithCollateral(bob, MARKET_ID, key, 500e6, usdcReserveId);
        assertEq(pvRepaid, 0, "the Lens shows it closed under Paused(MintPathSuspect)");
        vm.expectRevert(IAaveAdapterErrors.ApplicationPaused.selector);
        vm.prank(bob);
        adapterC.repayWithCollateral(p);
        reg.setPause(aave.hub, PauseState.Paused, PauseReason.General);
        reg.setFrozen(bob, true);
        (pvRepaid,,) = lens.previewRepayWithCollateral(bob, MARKET_ID, key, 500e6, usdcReserveId);
        uint256 hfBefore = _hf(proxy);
        vm.prank(bob);
        (uint256 repaid,) = adapterC.repayWithCollateral(p);
        assertGt(repaid, 0, "served under Paused(General) for a frozen wallet");
        assertEq(pvRepaid, repaid, "the Lens preview agrees with the execution");
        assertGe(_hf(proxy), hfBefore, "health factor not lowered");
    }

    /// @notice `hfBefore` is the health factor at the price Aave applies after LPVaultSwap's pokes. A poke that clears a
    /// token-decimals mark moves the price Aave reads within the block (REQ-ORACLE-107, `LPOraclePokeInvarianceUnitTest`):
    /// the market serves its accepted $2.10 (Cached) until the poke, then its fresh $1.50 (Live). At $1.50 Bob's HF is
    /// 1.20 and releasing 1,500 units raises it to about 1.31; compared with the pre-poke 1.68 the call would revert
    /// `HealthFactorNotImproved` although it improves the account at the price Aave applies, and with the prices the
    /// other way round it would let a call that lowers the health factor through. Regression for `hfBefore` read
    /// before the pokes.
    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-081, SPEC-PROXY-009, REQ-ORACLE-107
    function test_TEST_239_hfBeforeIsReadAfterThePokes() public {
        uint256 snap = vm.snapshotState();
        _setPrice(MARKET_ID, 150_000_000);
        uint256 hfFresh = _hf(proxy);
        vm.revertToState(snap);
        uint256 hfAccepted = _hf(proxy);
        _lpoOf(MARKET_ID).setState(PriceState.Cached, 0, false);
        _lpoOf(MARKET_ID).setAnswerOnPoke(150_000_000);
        vm.recordLogs();
        vm.prank(bob);
        (uint256 repaid,) = adapterC.repayWithCollateral(_rwc(UNITS, usdcReserveId));
        (uint256 hfBefore, uint256 hfAfter) = _hfLog(vm.getRecordedLogs());
        assertGt(repaid, 0, "settled");
        assertLt(hfFresh, hfAccepted, "the poke lowered the health factor Aave reads");
        assertEq(hfBefore, hfFresh, "hfBefore is the post-poke health factor");
        assertGt(hfAfter, hfBefore, "the call improved the account at the price Aave applies");
        assertLt(hfAfter, hfAccepted, "below the pre-poke health factor the old check compared with");
        assertEq(hfAfter, _hf(proxy), "hfAfter is Aave's");
    }

    function _hfLog(
        Vm.Log[] memory logs
    ) internal view returns (uint256 hfBefore, uint256 hfAfter) {
        bytes32 sig = IAaveAdapterEvents.RepaidWithCollateral.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == adapter && logs[i].topics[0] == sig) {
                (,,,,, hfBefore, hfAfter) =
                    abi.decode(logs[i].data, (bytes32, uint128, uint256, uint256, uint256, uint256, uint256));
                return (hfBefore, hfAfter);
            }
        }
        revert("no RepaidWithCollateral");
    }

    /// @notice A GHO-debt account deleverages with every leg swapped into GHO.
    // TEST-239 verifies: REQ-SWAP-106, SPEC-LIQ-018
    function test_TEST_239_ghoDebtLegsSwapIntoGho() public {
        _setPrice(MARKET_ID, P_VAULT);
        (bytes32 k3,) = _pledgeVia(carol, MARKET_ID, 5000e6);
        _borrowVia(carol, MARKET_ID, debtReserveId, 5000e18);
        address p3 = adapterC.proxyOf(carol, MARKET_ID);
        uint256 debtBefore = _debtOf(p3, debtReserveId);
        vm.prank(carol);
        (uint256 repaid, uint256 toWallet) =
            adapterC.repayWithCollateral(_rwcParams(MARKET_ID, k3, 1000e6, debtReserveId));
        assertEq(debtBefore - _debtOf(p3, debtReserveId), repaid, "GHO debt fell");
        assertGt(repaid, 2000e18, "about $2,079 repaid for 1,000 vault tokens");
        assertEq(debt.balanceOf(carol), 5000e18 + toWallet, "GHO rest to the wallet");
        assertEq(usdc.balanceOf(carol) + usdt.balanceOf(carol), 0, "no pool token reached the wallet");
    }

    /// @notice A transfer fee on the debt asset: LPVaultSwap measures the loan it received by balance delta and the
    /// Aave V4 Hub refuses the short repayment, so the whole call reverts with no state change; with the fee back at 0
    /// the same call settles in the next block (2.11 REQ-SWAP-123).
    // TEST-287 verifies: REQ-SWAP-108, REQ-SWAP-123, INV-095, ATTACK-197, Q-390
    function test_TEST_287_deleverageRefusedByHubUnderFee() public {
        (bytes32 k3,) = _pledgeVia(carol, MARKET_ID, 5000e6);
        _borrowVia(carol, MARKET_ID, debtReserveId, 5000e18);
        address p3 = adapterC.proxyOf(carol, MARKET_ID);
        RepayWithCollateralParams memory p = _rwcParams(MARKET_ID, k3, 1000e6, debtReserveId);
        uint256 debtBefore = _debtOf(p3, debtReserveId);
        uint256 supplyBefore = token.totalSupply();
        debt.setFeeBps(10);
        vm.prank(carol);
        (bool ok, bytes memory err) = address(adapterC).call(abi.encodeCall(adapterC.repayWithCollateral, (p)));
        assertFalse(ok, "refused under the fee");
        assertEq(
            bytes4(err), bytes4(keccak256("InsufficientTransferred(uint256)")), "the Hub's InsufficientTransferred"
        );
        assertEq(_debtOf(p3, debtReserveId), debtBefore, "no debt moved");
        assertEq(token.totalSupply(), supplyBefore, "no unit moved");
        assertFalse(lock.isLocked(), "Lock free");
        debt.setFeeBps(0);
        vm.roll(block.number + 1);
        vm.prank(carol);
        (uint256 repaid,) = adapterC.repayWithCollateral(p);
        assertGt(repaid, 0, "settles once the fee is 0");
    }

    function _recoveredLog(
        Vm.Log[] memory logs
    ) internal view returns (uint256 recovered) {
        bytes32 sig = ILPVaultSwapEvents.Deleveraged.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == lpVaultSwap && logs[i].topics[0] == sig) {
                (,, recovered,,) = abi.decode(logs[i].data, (uint128, uint256, uint256, uint256, uint256));
                return recovered;
            }
        }
        revert("no Deleveraged");
    }

    function _flashLog(
        Vm.Log[] memory logs
    ) internal view returns (uint256 amount, uint256 premium) {
        bytes32 sig = ILPVaultSwapEvents.FlashLoanUsed.selector;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == lpVaultSwap && logs[i].topics[0] == sig) {
                (amount, premium) = abi.decode(logs[i].data, (uint256, uint256));
                return (amount, premium);
            }
        }
        revert("no FlashLoanUsed");
    }
}
