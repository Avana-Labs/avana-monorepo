// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapErrors} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapErrors.sol";
import {LPVaultSwapUnitBase} from "../unit/LPVaultSwap.Base.sol";
import {LVSFlashSourceMock} from "../utils/mocks/LPVaultSwapMocks.sol";

/// @title LPVaultSwapCallbacksFuzzTest
/// @notice `deleverage` against a hostile flash source fuzzed (2.11 REQ-SWAP-013, REQ-SWAP-106, REQ-SWAP-122,
/// REQ-FLASH-002, REQ-FLASH-005): any quoted and charged premium, any available liquidity, any amount forwarded, any
/// asset or amount named in the callback, a tampered context, a skipped or doubled callback. The call settles exactly
/// when the source behaves (forwards `0 < Fr ≤ F`, calls back once with LPVaultSwap's own context, asset and amount,
/// charges within the exact cap) and has the liquidity; otherwise it reverts with the error the spec names for the
/// first failing check, and the debt, LPVaultSwap's balances and the source's balance do not move.
/// forge-config: default.isolate = false
/// forge-config: default.fuzz.runs = 256
contract LPVaultSwapCallbacksFuzzTest is LPVaultSwapUnitBase {
    address internal proxy;
    bytes32 internal key;
    LVSFlashSourceMock internal source;
    uint256 internal constant X = 2_075_924_073;

    function setUp() public override {
        super.setUp();
        (proxy, key) = _openAccount(alice, 10_000e6, 15_000e6, 250_000_000);
        source = new LVSFlashSourceMock(address(lvs), makeAddr("v3Pool"));
        usdc.mint(address(source), X);
        registry.setFlashSource(address(source));
    }

    function _repay() internal returns (bool ok, bytes memory reason) {
        vm.prank(alice);
        try adapter.repayWithCollateral(proxy, _position(key), 1000e6, usdcReserveId, new uint256[](2), 0) {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
    }

    /// @notice Quoted premium, charged premium and liquidity: `FlashLiquidityShort(available, x)` when short, else
    /// `FlashFeeTooHigh` when the quote breaks the exact cap (before the loan) or the charge does (in the callback),
    /// else the source ends with exactly `x + charged` and the wallet with `R − x − charged`.
    // TEST-046 verifies: REQ-SWAP-013, REQ-FLASH-002, REQ-SWAP-097, REQ-SWAP-099, SPEC-LIQ-015
    function testFuzz_TEST_046_quoteChargeAndLiquidity(
        uint256 quoted,
        uint256 charged,
        uint256 available
    ) public {
        quoted = bound(quoted, 0, X / 500);
        charged = bound(charged, 0, X / 500);
        available = bound(available, X - 1000, X + 1000);
        source.setQuote(quoted, charged);
        source.setAvailable(available);
        uint256 cap = MAX_FLASH_FEE_BPS * X;
        uint256 debt = _debtOf(proxy, usdcReserveId);
        uint256 sourceBefore = usdc.balanceOf(address(source));
        uint256 walletBefore = usdc.balanceOf(alice);
        (bool ok, bytes memory reason) = _repay();
        if (available < X) {
            assertEq(
                reason,
                abi.encodeWithSelector(ILPVaultSwapErrors.FlashLiquidityShort.selector, available, X),
                "short liquidity first"
            );
        } else if (quoted * BPS > cap) {
            assertEq(bytes4(reason), ILPVaultSwapErrors.FlashFeeTooHigh.selector, "quote above the cap");
        } else if (charged * BPS > cap) {
            assertEq(bytes4(reason), ILPVaultSwapErrors.FlashFeeTooHigh.selector, "charge above the cap");
        } else {
            assertTrue(ok, "a behaving source settles");
            assertEq(usdc.balanceOf(address(source)), sourceBefore + charged, "source repaid x + charged");
            assertEq(usdc.balanceOf(alice), walletBefore + _routedRecovery(1000e6) - X - charged, "wallet R - x - phi");
            assertEq(_debtOf(proxy, usdcReserveId), debt - X, "debt down by x");
            return;
        }
        assertFalse(ok, "refused");
        assertEq(_debtOf(proxy, usdcReserveId), debt, "a refusal repays nothing");
        assertEq(usdc.balanceOf(address(source)), sourceBefore, "the source keeps its balance");
    }

    /// @notice Forwarded amount, callback asset and amount, context and call count: `InvalidFlashCallback` unless the
    /// source forwards `0 < Fr ≤ F` and calls back exactly once with LPVaultSwap's own context, asset and amount.
    // TEST-046 verifies: REQ-SWAP-013, REQ-SWAP-054, REQ-SWAP-106, INV-040, PROP-036
    function testFuzz_TEST_046_hostileCallbackShapes(
        uint256 forward,
        bool wrongAsset,
        uint256 amountDelta,
        bool tamper,
        uint8 calls
    ) public {
        forward = bound(forward, 0, X + 10);
        amountDelta = bound(amountDelta, 0, 2);
        calls = uint8(bound(calls, 0, 2));
        usdc.mint(address(source), 10);
        source.setForward(forward);
        if (wrongAsset) source.setAssetOverride(address(usdt));
        if (amountDelta == 1) source.setAmountOverride(X - 1);
        if (amountDelta == 2) source.setAmountOverride(X + 1);
        source.setTamper(tamper);
        source.setSkip(calls == 0);
        source.setTwice(calls == 2);
        uint256 debt = _debtOf(proxy, usdcReserveId);
        (bool ok, bytes memory reason) = _repay();
        bool behaves = forward != 0 && forward <= X && !wrongAsset && amountDelta == 0 && !tamper && calls == 1;
        if (behaves && forward == X) {
            assertTrue(ok, "a behaving callback settles");
            assertEq(_debtOf(proxy, usdcReserveId), debt - X, "x repaid");
        } else if (behaves) {
            // A short forward (a transfer fee) repays only `Fr`; the AaveAdapter then refuses a repayment that would
            // release the units for less debt than lowers the health factor.
            if (ok) assertEq(_debtOf(proxy, usdcReserveId), debt - forward, "Fr repaid, never F");
            else assertEq(bytes4(reason), bytes4(keccak256("HealthFactorNotImproved(uint256,uint256)")), "HF rule");
        } else {
            assertFalse(ok, "a hostile callback is refused");
            assertEq(_debtOf(proxy, usdcReserveId), debt, "nothing repaid");
            if (forward != 0 && forward <= X && calls != 2) {
                assertEq(
                    reason,
                    abi.encodeWithSelector(ILPVaultSwapErrors.InvalidFlashCallback.selector),
                    "InvalidFlashCallback"
                );
            }
        }
    }

    /// @notice The source is read from the registry for every deleverage: a source the registry no longer names, or
    /// whose lender is a recorded Hub, is refused.
    // TEST-046 verifies: REQ-FLASH-005, REQ-FLASH-006, REQ-SWAP-120
    function testFuzz_TEST_046_sourceFromRegistry(
        bool lenderIsHub,
        bool switchMidway
    ) public {
        if (lenderIsHub) registry.setRecordedHub(source.LENDER(), true);
        if (switchMidway) source.setRegistrySwitch(address(registry), makeAddr("otherSource"));
        uint256 debt = _debtOf(proxy, usdcReserveId);
        (bool ok, bytes memory reason) = _repay();
        if (lenderIsHub) {
            assertEq(reason, abi.encodeWithSelector(ILPVaultSwapErrors.FlashSourceIsHub.selector), "lender is a Hub");
        } else if (switchMidway) {
            assertEq(
                reason, abi.encodeWithSelector(ILPVaultSwapErrors.InvalidFlashCallback.selector), "replaced mid-call"
            );
        } else {
            assertTrue(ok, "the registry's source settles");
        }
        if (!ok) assertEq(_debtOf(proxy, usdcReserveId), debt, "nothing repaid");
    }
}
