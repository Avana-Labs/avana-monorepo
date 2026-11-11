// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashSource} from "../../src/flash/IFlashSource.sol";
import {FlashSourceFixture} from "../utils/fixtures/FlashSourceFixture.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";

/// @notice AaveV3FlashSource properties over random amounts, Pool rates, caps, donations and transfer fees: the source
/// lends exactly when the exact premium inequality holds, the cap above the rate admits every loan above
/// `⌈10⁴ / (m − p)⌉`, a donation to the source is never forwarded, and every completed loan repays the Pool
/// `amount + premium` and leaves the source with no allowance.
/// forge-config: default.isolate = false
contract AaveV3FlashSourceFuzzTest is FlashSourceFixture {
    bytes internal constant CTX = hex"c0ffee";

    function setUp() public {
        _deployFlashSource();
    }

    /// @notice The pre-loan premium decision is the exact inequality on the source's ceiling quote, `⌈F p / 10⁴⌉ × 10⁴ ≤
    /// m F`, and its three regimes (`m > p`, `m = p`, `m < p`) behave as `SPEC-LIQ-015` states; a passing loan is
    /// charged the V3.4 half-up premium, never above the quote, which the callback re-check then admits.
    // TEST-052 verifies: SPEC-LIQ-015, REQ-FLASH-001, REQ-FLASH-002, REQ-PSTORE-024, INV-095, Q-135
    // Sources: MATH-ST-68, MATH-ST-115
    function testFuzz_TEST_052_capDecisionIsExact(
        uint256 amount,
        uint256 rate,
        uint256 cap
    ) public {
        amount = bound(amount, 1, IDLE_USDC);
        rate = bound(rate, 0, 100);
        cap = bound(cap, 0, 100);
        aavePool.setPremiumTotal(uint128(rate));
        _setCap(cap);
        uint256 phi = (amount * rate + 9999) / 10_000;
        bool passes = phi * 10_000 <= cap * amount;
        if (cap > rate && amount * (cap - rate) >= 10_000) assertTrue(passes, "cap above the rate admits the loan");
        if (cap < rate) assertFalse(passes, "cap below the rate admits nothing");
        if (cap == rate) assertEq(passes, (amount * rate) % 10_000 == 0, "cap equal to the rate");
        if (rate == 0) assertTrue(passes, "a zero premium passes every cap");
        if (!passes) {
            vm.expectRevert(abi.encodeWithSelector(IFlashSource.FlashFeeTooHigh.selector, phi, cap * amount / 10_000));
        }
        uint256 premium = swap.borrow(address(usdcToken), amount, address(hub), CTX);
        if (passes) {
            uint256 charged = (amount * rate + 5000) / 10_000;
            assertLe(charged, phi, "the half-up charge never exceeds the ceiling quote");
            assertEq(premium, charged);
            assertEq(usdcToken.balanceOf(aUsdc), IDLE_USDC + charged);
        }
        assertEq(usdcToken.balanceOf(address(source)), 0);
        assertEq(usdcToken.allowance(address(source), address(aavePool)), 0);
    }

    /// @notice Liquidity: a loan above the aToken's idle balance is refused with that balance; at or below it, it runs.
    // TEST-052 verifies: REQ-FLASH-001, REQ-FLASH-002, Q-335
    function testFuzz_TEST_052_liquidityBound(
        uint256 idle,
        uint256 amount
    ) public {
        idle = bound(idle, 0, 1e30);
        // From 1,000 base units every loan passes the launch cap of 10 bps at the 5 bps rate (MATH-ST-115).
        amount = bound(amount, 1000, 1e30);
        (PayoutToken t,) = _listToken("DAI", idle);
        t.mint(address(swap), amount / 100 + 1);
        if (amount > idle) {
            vm.expectRevert(abi.encodeWithSelector(IFlashSource.InsufficientFlashLiquidity.selector, idle));
        }
        swap.borrow(address(t), amount, address(hub), CTX);
        assertEq(t.balanceOf(address(source)), 0);
    }

    /// @notice A donation to the source before a loan is never forwarded: LPVaultSwap receives exactly `amount`, the
    /// premium is unchanged, and the donation counts toward the repayment (LPVaultSwap tops the source up to `owed` by
    /// balance delta), so the source keeps only what exceeds `owed`.
    // TEST-080 verifies: REQ-FLASH-001, REQ-FLASH-003, REQ-SWAP-122, INV-021
    function testFuzz_TEST_080_donationNeverForwarded(
        uint256 donation,
        uint256 amount
    ) public {
        donation = bound(donation, 1, 1e12);
        amount = bound(amount, 1000, IDLE_USDC);
        usdcToken.mint(address(source), donation);
        uint256 swapBefore = usdcToken.balanceOf(address(swap));
        uint256 premium = swap.borrow(address(usdcToken), amount, address(hub), CTX);
        assertEq(premium, (amount * 5 + 5000) / 10_000);
        assertEq(swap.lastReceived(), amount, "only the Pool's delivery is forwarded");
        uint256 owed = amount + premium;
        uint256 paidBySwap = donation >= owed ? 0 : owed - donation;
        assertEq(swapBefore + amount - paidBySwap, usdcToken.balanceOf(address(swap)));
        assertEq(usdcToken.balanceOf(aUsdc), IDLE_USDC + premium);
        assertEq(usdcToken.balanceOf(address(source)), donation >= owed ? donation - owed : 0);
        assertEq(usdcToken.allowance(address(source), address(aavePool)), 0);
    }

    /// @notice A transfer fee up to 19 bps: the source forwards what arrived, LPVaultSwap tops it up by balance delta
    /// in at most four transfers, and the Pool is paid `amount + premium` from the source.
    /// @dev `PayoutToken` charges an uncapped percentage; USDT also caps each transfer's fee at 50 USDT, which is what
    /// makes four top-ups enough for large loans. Up to 10,000 USDT four uncapped top-ups close the gap at 19 bps.
    // TEST-287 verifies: REQ-FLASH-003, REQ-SWAP-122, INV-095, ATTACK-197, Q-390
    function testFuzz_TEST_287_transferFeeRepaidByDelta(
        uint256 feeBps,
        uint256 amount
    ) public {
        feeBps = bound(feeBps, 1, 19);
        amount = bound(amount, 1000, 10_000e6);
        (PayoutToken usdt, address aUsdt) = _listToken("USDT", 1_000_000e6);
        usdt.mint(address(swap), amount / 50 + 1);
        usdt.setFeeBps(feeBps);
        uint256 premium = swap.borrow(address(usdt), amount, address(hub), CTX);
        uint256 arrivedAtSource = amount - amount * feeBps / 10_000;
        assertEq(swap.lastReceived(), arrivedAtSource - arrivedAtSource * feeBps / 10_000);
        uint256 owed = amount + premium;
        assertEq(usdt.balanceOf(aUsdt), 1_000_000e6 - amount + owed - owed * feeBps / 10_000);
        assertEq(usdt.balanceOf(address(source)), 0);
        assertEq(usdt.allowance(address(source), address(aavePool)), 0);
    }
}
