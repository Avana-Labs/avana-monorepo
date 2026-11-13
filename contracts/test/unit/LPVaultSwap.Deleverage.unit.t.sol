// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../src/interfaces/external/aave/IAaveV4Hub.sol";
import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {DeleverageRequest} from "../../src/liquidation/lp-vault-swap/types/DeleverageRequest.sol";
import {PriceState} from "../../src/types/PriceState.sol";
import {LVSLyingRoute} from "../utils/mocks/LPVaultSwapMocks.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {LPVaultSwapUnitBase} from "./LPVaultSwap.Base.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title LPVaultSwapDeleverageUnitTest
/// @notice Repay with collateral (2.11 REQ-SWAP-106, SPEC-LIQ-020, REQ-SWAP-122, REQ-FLASH-002, REQ-FLASH-005): the
/// AaveAdapter, holding the Lock, calls `deleverage`; LPVaultSwap sizes the repayment from the oracle value of the
/// units after slippage, unit, rounding and flash-fee allowances, flash-borrows it through the chain's
/// `AaveV3FlashSource` (the only flash loan of LPVaultSwap), repays the debt through the AaveAdapter, has the units
/// released, swaps them at their minimums, repays the source by balance delta and sends the debt asset left to the
/// borrower's wallet. No bonus, fee, keeper payout or escrow applies; the health factor never falls.
/// forge-config: default.isolate = false
contract LPVaultSwapDeleverageUnitTest is LPVaultSwapUnitBase {
    address internal proxy;
    bytes32 internal key;

    function setUp() public override {
        super.setUp();
        (proxy, key) = _openAccount(alice, 10_000e6, 15_000e6, 250_000_000);
    }

    function _repay(
        uint128 units,
        uint256 minDebtRepaid
    ) internal returns (uint256 repaid, uint256 out) {
        vm.prank(alice);
        (repaid, out) =
            adapter.repayWithCollateral(proxy, _position(key), units, usdcReserveId, new uint256[](2), minDebtRepaid);
    }

    function _request(
        uint128 units
    ) internal view returns (DeleverageRequest memory r) {
        r = DeleverageRequest({
            proxy: proxy,
            wallet: alice,
            spoke: aave.cdpSpoke,
            marketId: MARKET_ID,
            vaultToken: address(vt),
            position: _position(key),
            units: units,
            debtReserveId: usdcReserveId,
            minAmounts: new uint256[](2),
            minDebtRepaid: 0
        });
    }

    /// @notice SPEC-LIQ-020 example: 1,000 vault tokens at $2.10 size `x = ⌊(2,079,000,000 − 2 − 10⁶) × 10⁴ / 10,010⌋
    /// = 2,075,924,073`; the Pool charges its half-up 5 bps premium `φ = 1,037,962`; the wallet receives `R − x − φ`;
    /// the debt falls by `x`, the health factor rises and LPVaultSwap and the flash source end with no balance change.
    // TEST-239 verifies: SPEC-LIQ-020, REQ-SWAP-106, REQ-SWAP-122, REQ-FLASH-002, REQ-SWAP-013, INV-089, PROP-072, Q-255
    function test_TEST_239_exampleSizingAndPayout() public {
        uint256 debt = _debtOf(proxy, usdcReserveId);
        uint256 hf = _hf(proxy);
        uint256 wallet = usdc.balanceOf(alice);
        uint256 sourceBefore = usdc.balanceOf(address(flashSource));
        Snap memory s0 = _snap(alice);
        uint256 x = 2_075_924_073;
        uint256 phi = (x * 5 + 5000) / 10_000;
        assertEq(phi, 1_037_962, "half-up premium");
        uint256 recovered = _routedRecovery(1000e6);
        vm.expectEmit(true, true, true, true, address(lvs));
        emit FlashLoanUsed(MARKET_ID, address(flashSource), address(usdc), x, phi);
        vm.expectEmit(true, true, true, true, address(lvs));
        emit Deleveraged(proxy, MARKET_ID, usdcReserveId, 1000e6, x, recovered, phi, recovered - x - phi);
        (uint256 repaid, uint256 out) = _repay(1000e6, 0);
        assertEq(repaid, x, "x");
        assertEq(out, recovered - x - phi, "assetOut = R - x - phi");
        assertEq(_debtOf(proxy, usdcReserveId), debt - x, "debt repaid");
        assertGt(_hf(proxy), hf, "HF rises");
        assertEq(usdc.balanceOf(alice), wallet + out, "wallet paid");
        assertEq(usdc.balanceOf(address(flashSource)), sourceBefore, "source keeps nothing");
        assertEq(usdc.balanceOf(feeRecipient), s0.feeUsdc, "no Avana fee");
        assertEq(escrow.claimable(address(usdc), alice), 0, "no escrow");
        _assertNeutral(s0);
        _assertNoAllowances();
    }

    /// @notice `DeleverageTooSmall(x, minDebtRepaid)` when the repayment is below the borrower's minimum or 0 (zero
    /// units, a debt-free reserve); nothing moves.
    // TEST-239 verifies: SPEC-LIQ-020, REQ-SWAP-106, REQ-SWAP-116, REQ-SWAP-077
    function test_TEST_239_tooSmall() public {
        uint256 x = 2_075_924_073;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DeleverageTooSmall.selector, x, x + 1));
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](2), x + 1);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DeleverageTooSmall.selector, 0, 0));
        adapter.deleverageRaw(_request(0));
        DeleverageRequest memory r = _request(1000e6);
        r.debtReserveId = ghoReserveId; // no GHO debt
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DeleverageTooSmall.selector, 0, 0));
        adapter.deleverageRaw(r);
    }

    /// @notice The repayment is `min(debt, cap)`: a small debt is repaid whole and the rest of the units' value goes to
    /// the wallet.
    // TEST-239 verifies: SPEC-LIQ-020, REQ-SWAP-106
    function test_TEST_239_debtBelowCapRepaidWhole() public {
        (address small, bytes32 smallKey) = _openAccount(carol, 2000e6, 500e6, 250_000_000);
        uint256 debt = _debtOf(small, usdcReserveId);
        vm.prank(carol);
        (uint256 repaid, uint256 out) =
            adapter.repayWithCollateral(small, _position(smallKey), 1000e6, usdcReserveId, new uint256[](2), 0);
        assertEq(repaid, debt, "whole debt");
        assertEq(_debtOf(small, usdcReserveId), 0, "debt-free");
        uint256 phi = (debt * 5 + 5000) / 10_000;
        assertEq(out, _routedRecovery(1000e6) - debt - phi, "rest to the wallet");
    }

    /// @notice `NotAdapter` unless the caller is the AaveAdapter and the AaveAdapter holds the Lock.
    // TEST-239 verifies: REQ-SWAP-106, REQ-SWAP-116
    // TEST-060 verifies: REQ-SWAP-106, REQ-LOCK-023
    function test_TEST_239_onlyAdapterUnderItsLock() public {
        vm.prank(attacker);
        vm.expectRevert(_err(ILPVaultSwapErrors.NotAdapter.selector));
        lvs.deleverage(_request(1000e6));
        vm.expectRevert(_err(ILPVaultSwapErrors.NotAdapter.selector));
        adapter.deleverageUnlocked(_request(1000e6));
        // LPVaultSwap itself holding the Lock does not count.
        vm.prank(address(lvs));
        lock.acquire();
        vm.prank(address(adapter));
        vm.expectRevert(_err(ILPVaultSwapErrors.NotAdapter.selector));
        lvs.deleverage(_request(1000e6));
        vm.prank(address(lvs));
        lock.release();
    }

    /// @notice The request must name the market's own vault token and Spoke (`UnknownMarket`) and an enabled debt
    /// reserve (`UnknownDebtReserve`).
    // TEST-239 verifies: REQ-SWAP-106, REQ-SWAP-116, REQ-SWAP-087
    function test_TEST_239_requestBindings() public {
        DeleverageRequest memory r = _request(1000e6);
        r.vaultToken = address(usdc);
        vm.expectRevert(_err(ILPVaultSwapErrors.UnknownMarket.selector));
        adapter.deleverageRaw(r);
        r = _request(1000e6);
        r.spoke = aave.lendSpoke;
        vm.expectRevert(_err(ILPVaultSwapErrors.UnknownMarket.selector));
        adapter.deleverageRaw(r);
        r = _request(1000e6);
        r.debtReserveId = 77;
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.UnknownDebtReserve.selector, 77));
        adapter.deleverageRaw(r);
    }

    /// @notice Price rules (a) to (d) of the market, the repaid reserve's DebtOracle and the Hub share check gate the
    /// repay with collateral; grace does not.
    // TEST-239 verifies: REQ-SWAP-106, REQ-SWAP-116, REQ-SWAP-008, REQ-SWAP-091
    function test_TEST_239_priceAndSharesGates() public {
        lpOracle.setState(PriceState.Expired);
        vm.prank(alice);
        vm.expectRevert(_err(ILPVaultSwapErrors.StalePrice.selector));
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](2), 0);
        lpOracle.setState(PriceState.Live);
        usdcOracle.setState(PriceState.Cached, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DebtPriceStale.selector, usdcReserveId));
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](2), 0);
        usdcOracle.setState(PriceState.Live, false);
        uint256 assets = IAaveV4Hub(aave.hub).getAddedAssets(vtAssetId);
        vm.mockCall(aave.hub, abi.encodeCall(IAaveV4Hub.getAddedAssets, (vtAssetId)), abi.encode(assets + 1));
        vm.prank(alice);
        vm.expectRevert(_err(ILPVaultSwapErrors.SharesNotEqualAssets.selector));
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](2), 0);
        vm.clearMockedCalls();
        lpOracle.setFlags(false, false, false, true);
        _repay(1000e6, 0);
    }

    /// @notice REQ-FLASH-002: `FlashLiquidityShort(available, F)` when the source cannot lend `x` (a paused reserve
    /// reads 0), `FlashFeeTooHigh` when its quote breaks `φ × 10⁴ ≤ maxFlashFeeBps × F` (read per call).
    // TEST-239 verifies: REQ-FLASH-002, REQ-SWAP-053, REQ-SWAP-099, SPEC-LIQ-015
    // TEST-052 verifies: REQ-FLASH-002, SPEC-LIQ-015
    function test_TEST_239_flashLiquidityAndFee() public {
        uint256 x = 2_075_924_073;
        v3Pool.setVirtualBalance(address(usdc), uint128(x - 1));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.FlashLiquidityShort.selector, x - 1, x));
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](2), 0);
        v3Pool.setVirtualBalance(address(usdc), uint128(18_000_000e6));
        v3Pool.setFlags(address(usdc), true, false, true, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.FlashLiquidityShort.selector, 0, x));
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](2), 0);
        v3Pool.setFlags(address(usdc), true, false, false, true);
        store.setMaxFlashFeeBps(4);
        vm.prank(alice);
        vm.expectRevert(_err(ILPVaultSwapErrors.FlashFeeTooHigh.selector));
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](2), 0);
    }

    /// @notice REQ-FLASH-005: the source is refused when its `LENDER()` is any recorded Hub; liquidation is
    /// unaffected.
    // TEST-285 verifies: REQ-FLASH-005, REQ-SWAP-097, INV-095
    // TEST-239 verifies: REQ-FLASH-005, REQ-FLASH-006
    function test_TEST_285_lenderIsRecordedHubRefused() public {
        registry.setRecordedHub(address(v3Pool), true);
        vm.prank(alice);
        vm.expectRevert(_err(ILPVaultSwapErrors.FlashSourceIsHub.selector));
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](2), 0);
        (address bobProxy,) = _bobAccount();
        _liquidateAs(keeper, _params(bobProxy, 1950e6));
    }

    /// @notice With `FLASH_BORROWER` granted to the source the premium is 0 and the wallet receives `R − x`.
    // TEST-239 verifies: REQ-FLASH-007, SPEC-LIQ-020
    function test_TEST_239_flashBorrowerNoPremium() public {
        acl.addFlashBorrower(address(flashSource));
        (uint256 repaid, uint256 out) = _repay(1000e6, 0);
        assertEq(out, _routedRecovery(1000e6) - repaid, "no premium");
    }

    /// @notice `DeleverageShortfall(R, x + φ)` when the unwind returns less value than the units' oracle value (the
    /// LPVault pays less per unit): the whole repay with collateral reverts and the position is unchanged.
    // TEST-239 verifies: SPEC-LIQ-020, REQ-SWAP-106, REQ-SWAP-116
    function test_TEST_239_shortfallReverts() public {
        uint256[] memory rates = new uint256[](2);
        rates[0] = 900_000;
        rates[1] = USDT_RATE;
        lpVault.bind(MARKET_ID, pool, _pair(address(usdc), address(usdt)), rates);
        uint256 x = 2_075_924_073;
        uint256 phi = (x * 5 + 5000) / 10_000;
        uint256 recovered = 900e6 + uint256(1_036_000_000) * 9995 / 10_000;
        uint256 debt = _debtOf(proxy, usdcReserveId);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ILPVaultSwapErrors.DeleverageShortfall.selector, recovered, x + phi));
        adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](2), 0);
        assertEq(_debtOf(proxy, usdcReserveId), debt, "unchanged");
    }

    /// @notice A residue of the deleverage swaps (a partial fill) goes to the borrower's wallet by a plain transfer;
    /// LPVaultSwap keeps no USDT.
    // TEST-239 verifies: REQ-SWAP-106, REQ-SWAP-121, REQ-SWAP-024
    function test_TEST_239_residueToWallet() public {
        (, uint256 a1) = _released(1000e6);
        usdtUsdcPool.setMaxIn(a1 - 25);
        uint256 walletUsdt = usdt.balanceOf(alice);
        _repay(1000e6, 0);
        assertEq(usdt.balanceOf(alice), walletUsdt + 25, "residue to the wallet");
        assertEq(usdt.balanceOf(address(lvs)), 0, "no USDT kept");
    }

    /// @notice REQ-SWAP-122: a transfer fee switched on during the loan (a route call turns it on) makes LPVaultSwap
    /// top the source up by balance delta: the first transfer arrives short, the loop sends the difference until the
    /// source holds `x + φ`, within four transfers, and the Pool is repaid.
    // TEST-239 verifies: REQ-SWAP-122, REQ-SWAP-123, REQ-SWAP-108, Q-390
    function test_TEST_239_repayByBalanceDeltaUnderFee() public {
        LVSLyingRoute feeSwitch = new LVSLyingRoute(address(usdt), address(usdc));
        uint256 out = uint256(1_036_000_000) * 9995 / 10_000;
        usdc.mint(address(feeSwitch), out);
        feeSwitch.setOut(out);
        feeSwitch.setReenter(address(usdc), abi.encodeCall(PayoutToken.setFeeBps, (10)));
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(feeSwitch), true);
        uint256 x = 2_075_924_073;
        uint256 owed = x + (x * 5 + 5000) / 10_000;
        vm.recordLogs();
        _repay(1000e6, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        uint256 transfers = 0;
        uint256 delivered = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(usdc) || logs[i].topics[0] != transferSig) continue;
            if (address(uint160(uint256(logs[i].topics[1]))) != address(lvs)) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != address(flashSource)) continue;
            ++transfers;
            delivered += abi.decode(logs[i].data, (uint256));
        }
        assertGt(transfers, 1, "a fee-bearing repayment needs more than one transfer");
        assertLe(transfers, 4, "within MAX_REPAY_TRANSFERS");
        assertEq(delivered, owed, "the source received exactly what it owes");
    }

    /// @notice A fee that does not shrink fast enough (50 %) leaves the source short after four transfers:
    /// `FlashRepayShort(balance, owed)`, and the repay with collateral reverts.
    // TEST-239 verifies: REQ-SWAP-122, REQ-SWAP-124
    function test_TEST_239_flashRepayShortAfterFourTransfers() public {
        LVSLyingRoute feeSwitch = new LVSLyingRoute(address(usdt), address(usdc));
        uint256 out = uint256(1_036_000_000) * 9995 / 10_000;
        usdc.mint(address(feeSwitch), out * 10);
        feeSwitch.setOut(out * 10); // enough balance for four transfers; the fee halves each one
        feeSwitch.setReenter(address(usdc), abi.encodeCall(PayoutToken.setFeeBps, (5000)));
        registry.setRoute(MARKET_ID, address(usdt), address(usdc), 0, address(feeSwitch), true);
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(adapter)
            .call(
                abi.encodeCall(
                    adapter.repayWithCollateral,
                    (proxy, _position(key), uint128(1000e6), usdcReserveId, new uint256[](2), 0)
                )
            );
        assertFalse(ok, "reverts");
        assertEq(bytes4(ret), ILPVaultSwapErrors.FlashRepayShort.selector, "FlashRepayShort");
    }
}
