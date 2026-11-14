// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashSource} from "../../src/flash/IFlashSource.sol";
import {IAaveV4Spoke} from "../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {ILPVaultSwapEvents} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapEvents.sol";
import {IAaveAdapterErrors} from "../../src/policy/aave-adapter/IAaveAdapterErrors.sol";
import {IAaveAdapterEvents} from "../../src/policy/aave-adapter/IAaveAdapterEvents.sol";
import {RepayWithCollateralParams} from "../../src/policy/aave-adapter/types/RepayWithCollateralParams.sol";
import {PauseReason} from "../../src/types/PauseReason.sol";
import {PauseState} from "../../src/types/PauseState.sol";
import {RealStackFlows} from "../utils/fixtures/RealStackFlows.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DeleverageRepayWithCollateralIntegrationTest
/// @notice Repay with collateral on the real stack (`RealStackFlows`): the wallet calls the real AaveAdapter, which
/// opens its session and calls the real LPVaultSwap's `deleverage`; LPVaultSwap flash-borrows the debt asset from the
/// real `AaveV3FlashSource` (lending from the Aave V3 Pool stand-in, 5 bps), repays through the Adapter's
/// `deleverageRepay`, has the Adapter release and unwind the units through the real Uniswap v3 LPVault and
/// NonfungiblePositionManager (`deleverageRelease`), swaps the pool tokens into the debt asset through the real
/// `DexPathRoute`s, repays the loan and its premium by balance delta and sends the rest to the wallet. The Lens's
/// `previewRepayWithCollateral` is checked against the execution.
/// @dev Bob: 10,000 vault tokens at $2.00 ($20,000, CF 30 %) against 4,000 USDC (HF 1.50). Releasing 1,500 vault
/// tokens ($3,000 at the oracle) repays what the Lens previews (the oracle value less the market's slippage allowance
/// and loan-fee room); the wallet's rest differs from the preview's (valued at `R = V`) by exactly `V - R`, what the
/// real unwind and route pools recovered below the oracle value. `TEST-287` (a transfer fee on the debt asset) is in
/// `Deleverage.RepayWithCollateral.FeeOnTransfer`, on a debt asset whose issuer can switch on a fee.
/// forge-config: default.isolate = false
contract DeleverageRepayWithCollateralIntegrationTest is RealStackFlows {
    uint128 internal constant RELEASE = 1500e6;

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

    uint256 internal mA;
    address internal vt;
    address internal proxy;
    bytes32 internal key;

    function setUp() public {
        _setUpFullStack();
        mA = _addMarket(poolA);
        vt = mkt[mA].vaultToken;
        (key, proxy) = _pledgeAs(bob, mA, UNITS);
        _borrowAs(bob, mA, usdcReserveId, 4000e6);
    }

    function _rwc(
        uint128 units,
        uint256 reserveId
    ) internal view returns (RepayWithCollateralParams memory p) {
        p = _rwcParams(mA, key, units, reserveId);
    }

    function _aUsdc() internal view returns (address) {
        return v3Pool.getReserveAToken(address(usdc));
    }

    /// @dev The oracle value of `units` vault-token units in USDC base units (USDC at its DebtOracle's $1.00).
    function _valueUsdc(
        uint256 units
    ) internal view returns (uint256) {
        return units * uint256(mkt[mA].oracle.latestAnswer()) / uint256(usdcOracle.latestAnswer());
    }

    function _credited(
        bytes32 k
    ) internal view returns (uint128) {
        return uint128(coll.getRecord(coll.recordIdOf(V3, k)).credited);
    }

    /// @notice The flash path by balance delta (the `deleverage` half of PROP-097 on the deployed contracts): the
    /// amount LPVaultSwap books from the flash source is what it received, the source ends with its principal plus the
    /// premium, no bonus or Avana fee is taken, the health factor rises, and every amount matches the Lens preview.
    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-081, REQ-SWAP-106, REQ-SWAP-122, REQ-FLASH-004, SPEC-LIQ-020, SPEC-PROXY-009, INV-095, Q-255
    function test_TEST_239_repayWithCollateralThroughRealLPVaultSwap() public {
        Snapshot memory b = _snapshot();
        uint256 v = _valueUsdc(RELEASE);
        vm.recordLogs();
        vm.prank(bob);
        (uint256 repaid, uint256 toWallet) = adapterC.repayWithCollateral(_rwc(RELEASE, usdcReserveId));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 flashAmount, uint256 premium) = _flashLog(logs);
        uint256 recovered = _recoveredLog(logs);

        assertEq(repaid, b.pvRepaid, "debt repaid as previewed");
        assertEq(b.debt - _debtOf(proxy, usdcReserveId), repaid, "the Spoke's debt fell by debtRepaid");
        assertEq(flashAmount, repaid, "x: the loan is exactly the repayment LPVaultSwap received and repaid");
        assertEq(premium, (flashAmount * 5 + 5000) / 10_000, "5 bps premium, half-up");
        assertEq(usdc.balanceOf(_aUsdc()), b.lender + premium, "the lender holds principal plus premium");
        assertEq(usdc.balanceOf(flashSource), 0, "the flash source keeps nothing");
        assertEq(usdc.balanceOf(bob) - b.wallet, toWallet, "the rest of the recovery to the wallet");
        assertEq(toWallet, recovered - flashAmount - premium, "wallet gets R - x - premium");
        // The preview converts at the oracle value V = 1,500 x $2.00 (REQ-LENS-029 style) and charges the source's
        // premium quote q, rounded up and never below the Pool's half-up charge (REQ-FLASH-002): it differs by
        // (V - R) - (q - premium).
        uint256 q = IFlashSource(flashSource).flashPremium(address(usdc), flashAmount);
        assertLe(premium, q, "the quote is never below the charge");
        assertLe(q - premium, 1, "the quote rounds up, the Pool half-up");
        assertLt(recovered, v, "the real unwind and routes recover below the oracle value");
        assertEq(b.pvToWallet + q, v - flashAmount, "preview at R = V, with the quoted premium");
        assertEq(b.pvToWallet - toWallet + (q - premium), v - recovered, "preview less execution is V - R");
        _checkAfter(b);
    }

    function _snapshot() internal view returns (Snapshot memory b) {
        (b.pvRepaid, b.pvToWallet, b.pvHf) = lens.previewRepayWithCollateral(bob, mA, key, RELEASE, usdcReserveId);
        (b.hf, b.debt, b.lender) = (_hf(proxy), _debtOf(proxy, usdcReserveId), usdc.balanceOf(_aUsdc()));
        (b.supply, b.credited, b.wallet) = (IERC20(vt).totalSupply(), coll.getTotalCredited(vt), usdc.balanceOf(bob));
    }

    function _checkAfter(
        Snapshot memory b
    ) internal view {
        assertEq(usdc.balanceOf(feeRecipient), 0, "no Avana fee");
        assertEq(b.supply - IERC20(vt).totalSupply(), RELEASE, "the Adapter burned the released units");
        assertEq(b.credited - coll.getTotalCredited(vt), RELEASE, "Collateralization debited them");
        assertEq(IERC20(vt).totalSupply(), coll.getTotalCredited(vt), "supply = credited");
        assertGt(_hf(proxy), b.hf, "health factor rose");
        assertApproxEqRel(_hf(proxy), b.pvHf, 1e15, "health factor after near the preview");
        assertEq(usdc.balanceOf(lpVaultSwap) + usdt.balanceOf(lpVaultSwap), 0, "LPVaultSwap keeps nothing");
        assertEq(usdc.balanceOf(adapter) + usdt.balanceOf(adapter), 0, "the Adapter keeps nothing");
        assertFalse(lock.isLocked(), "Lock released");
    }

    /// @notice Releasing every unit of the only record repays the whole debt, closes the record and returns the NFT
    /// to the wallet.
    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-081, REQ-PROXY-089, Q-255
    function test_TEST_239_fullUnitsToZeroDebtReturnPosition() public {
        (bytes32 k2, address p2) = _pledgeAs(alice, mA, 2000e6);
        _borrowAs(alice, mA, usdcReserveId, 1000e6);
        RepayWithCollateralParams memory p = _rwcParams(mA, k2, _credited(k2), usdcReserveId);
        uint256 debtBefore = _debtOf(p2, usdcReserveId);
        uint256 walletBefore = usdc.balanceOf(alice);
        vm.prank(alice);
        (uint256 repaid, uint256 toWallet) = adapterC.repayWithCollateral(p);
        assertEq(repaid, debtBefore, "the whole debt repaid");
        assertEq(_debtOf(p2, usdcReserveId), 0, "debt-free");
        assertEq(usdc.balanceOf(alice) - walletBefore, toWallet, "the rest to the wallet");
        assertEq(_sharesOf(p2, mkt[mA].reserveId), 0, "nothing left supplied");
        assertEq(_credited(k2), 0, "record closed");
        assertEq(IERC721(address(nfpm)).ownerOf(uint256(k2)), alice, "the NFT returned to its depositor");
    }

    // TEST-239 verifies: REQ-SWAP-106, SPEC-LIQ-020
    function test_TEST_239_minDebtRepaidEnforced() public {
        (uint256 pvRepaid,,) = lens.previewRepayWithCollateral(bob, mA, key, RELEASE, usdcReserveId);
        RepayWithCollateralParams memory p = _rwc(RELEASE, usdcReserveId);
        p.minDebtRepaid = pvRepaid + 1;
        uint256 debtBefore = _debtOf(proxy, usdcReserveId);
        vm.expectPartialRevert(ILPVaultSwapErrors.DeleverageTooSmall.selector);
        vm.prank(bob);
        adapterC.repayWithCollateral(p);
        assertEq(_debtOf(proxy, usdcReserveId), debtBefore, "nothing repaid");
        assertFalse(lock.isLocked(), "Lock free");
    }

    /// @notice Paused(MintPathSuspect) refuses it; Paused(General) and a frozen wallet are served, since it only lowers
    /// debt and never lowers the health factor (REQ-ADAPTER-082, Q-356). The Emergency Guardian sets each state.
    // TEST-239 verifies: REQ-ADAPTER-080, REQ-ADAPTER-082, REQ-LENS-038, Q-347, Q-356
    function test_TEST_239_pauseAndFreeze() public {
        _setPause(PauseState.Paused, PauseReason.MintPathSuspect);
        RepayWithCollateralParams memory p = _rwc(500e6, usdcReserveId);
        (uint256 pvRepaid,,) = lens.previewRepayWithCollateral(bob, mA, key, 500e6, usdcReserveId);
        assertEq(pvRepaid, 0, "the Lens shows it closed under Paused(MintPathSuspect)");
        vm.expectRevert(IAaveAdapterErrors.ApplicationPaused.selector);
        vm.prank(bob);
        adapterC.repayWithCollateral(p);
        _setPause(PauseState.Paused, PauseReason.General);
        _freezeWallet(bob);
        (pvRepaid,,) = lens.previewRepayWithCollateral(bob, mA, key, 500e6, usdcReserveId);
        uint256 hfBefore = _hf(proxy);
        vm.prank(bob);
        (uint256 repaid,) = adapterC.repayWithCollateral(p);
        assertGt(repaid, 0, "served under Paused(General) for a frozen wallet");
        assertEq(pvRepaid, repaid, "the Lens preview agrees with the execution");
        assertGe(_hf(proxy), hfBefore, "health factor not lowered");
    }

    /// @notice A GHO-debt account deleverages with both legs swapped into GHO.
    // TEST-239 verifies: REQ-SWAP-106, SPEC-LIQ-018
    function test_TEST_239_ghoDebtLegsSwapIntoGho() public {
        (bytes32 k3, address p3) = _pledgeAs(carol, mA, 5000e6);
        _borrowAs(carol, mA, ghoReserveId, 2500e18);
        (uint256 pvRepaid,,) = lens.previewRepayWithCollateral(carol, mA, k3, 1000e6, ghoReserveId);
        uint256 debtBefore = _debtOf(p3, ghoReserveId);
        uint256 poolTokensBefore = usdc.balanceOf(carol) + usdt.balanceOf(carol);
        vm.prank(carol);
        (uint256 repaid, uint256 toWallet) = adapterC.repayWithCollateral(_rwcParams(mA, k3, 1000e6, ghoReserveId));
        assertEq(debtBefore - _debtOf(p3, ghoReserveId), repaid, "GHO debt fell");
        assertEq(repaid, pvRepaid, "repaid as previewed");
        assertGt(repaid, 1900e18, "above 95 % of the $2,000 the 1,000 vault tokens are worth");
        assertEq(gho.balanceOf(carol), 2500e18 + toWallet, "GHO rest to the wallet");
        assertEq(usdc.balanceOf(carol) + usdt.balanceOf(carol), poolTokensBefore, "no pool token reached the wallet");
    }

    /// @notice A repay with collateral that leaves the account debt-free and empties its last record runs the
    /// collateral cleanup, as every other debt-free exit does: the vault-token reserve is no longer used as
    /// collateral, so a later pledge enables it afresh on Aave's latest dynamic configuration key.
    // TEST-239 verifies: REQ-PROXY-089, REQ-PROXY-046, REQ-ADAPTER-080
    function test_TEST_239_debtFreeRepayWithCollateralRunsTheCollateralCleanup() public {
        (bytes32 k2, address p2) = _pledgeAs(alice, mA, 2000e6);
        _borrowAs(alice, mA, usdcReserveId, 1000e6);
        uint256 r = mkt[mA].reserveId;
        (bool enabledBefore,) = IAaveV4Spoke(aave.cdpSpoke).getUserReserveStatus(r, p2);
        assertTrue(enabledBefore, "the vault-token reserve is collateral while pledged");
        RepayWithCollateralParams memory p = _rwcParams(mA, k2, _credited(k2), usdcReserveId);
        vm.expectEmit(adapter);
        emit IAaveAdapterEvents.CollateralDisabled(p2, r);
        vm.prank(alice);
        adapterC.repayWithCollateral(p);
        assertEq(_debtOf(p2, usdcReserveId), 0, "debt-free");
        assertEq(_sharesOf(p2, r), 0, "nothing left supplied");
        (bool enabled,) = IAaveV4Spoke(aave.cdpSpoke).getUserReserveStatus(r, p2);
        assertFalse(enabled, "the emptied reserve is no longer used as collateral");
    }

    /// @notice An account below health factor 1 that would stay below 1 after the call cannot repay with collateral:
    /// the withdrawal step is an Aave `withdraw` of collateral, which requires health factor 1 while debt remains. The
    /// Lens previews it as closed, `(0, 0, current health factor)`, rather than as a repayment that improves the health
    /// factor; a release large enough to reach health factor 1 is previewed and executes as previewed.
    // TEST-239 verifies: REQ-LENS-038, REQ-ADAPTER-080
    function test_TEST_239_previewClosedWhenTheHealthFactorStaysBelowOne() public {
        _borrowAs(bob, mA, usdcReserveId, 1880e6);
        _depegUsdt(93_000_000);
        uint256 hf0 = _hf(proxy);
        assertLt(hf0, 1e18, "Bob is below health factor 1");

        uint128 small = 20e6;
        (uint256 pvRepaid, uint256 pvToWallet, uint256 pvHf) =
            lens.previewRepayWithCollateral(bob, mA, key, small, usdcReserveId);
        RepayWithCollateralParams memory p = _rwc(small, usdcReserveId);
        vm.expectRevert(bytes4(keccak256("HealthFactorBelowThreshold()")));
        vm.prank(bob);
        adapterC.repayWithCollateral(p);
        assertEq(pvRepaid, 0, "the preview shows the call closed");
        assertEq(pvToWallet, 0, "nothing to the wallet");
        assertEq(pvHf, hf0, "the current health factor");

        uint128 large = 400e6;
        (pvRepaid,, pvHf) = lens.previewRepayWithCollateral(bob, mA, key, large, usdcReserveId);
        assertGe(pvHf, 1e18, "the larger release reaches health factor 1");
        p = _rwc(large, usdcReserveId);
        vm.prank(bob);
        (uint256 repaid,) = adapterC.repayWithCollateral(p);
        assertEq(repaid, pvRepaid, "executes as previewed");
        assertGe(_hf(proxy), 1e18, "health factor at least 1 after the call");
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
