// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FlashLiquidator} from "../src/FlashLiquidator.sol";
import {IFlashLiquidator} from "../src/IFlashLiquidator.sol";
import {
    MockAaveV3Pool,
    MockLiquidationModule,
    MockMarketReads,
    MockRouter,
    MockVaultMarkets,
    TestToken
} from "./mocks/LiquidatorMocks.sol";
import {ILiquidationModule} from "avana/liquidation/liquidation-module/ILiquidationModule.sol";
import {Swap, SwapCalls} from "avana/periphery/libraries/SwapCalls.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Unit and fuzz tests of the bot's flash path: loan, liquidation in kind, sale, repayment, profit; the
/// operator gate, the top-up bound, the profit floor and the callback checks.
contract FlashLiquidatorTest is Test {
    uint256 internal constant AMOUNT_IN_OFFSET = 68;

    TestToken internal usdc;
    TestToken internal weth;
    TestToken internal usdt;
    MockAaveV3Pool internal pool;
    MockMarketReads internal reads;
    MockLiquidationModule internal module;
    MockRouter internal router;
    FlashLiquidator internal liq;
    address internal operator;
    address internal vault;

    function setUp() public {
        // The operator's key is made at run time; no key is stored anywhere.
        (operator,) = makeAddrAndKey(string(abi.encode("operator", block.timestamp)));
        usdc = new TestToken("USDC");
        weth = new TestToken("WETH");
        usdt = new TestToken("USDT");
        pool = new MockAaveV3Pool();
        usdc.mint(address(pool), 1e30);
        reads = new MockMarketReads(address(usdc), address(weth), address(usdt));
        vault = address(new MockVaultMarkets(address(weth), address(usdt)));
        module = new MockLiquidationModule(address(reads), vault, usdc, weth, usdt);
        router = new MockRouter();
        liq = new FlashLiquidator(address(pool), address(module), operator);
    }

    function _request(
        uint256 flashAmount,
        uint256 rateBps
    ) internal view returns (IFlashLiquidator.Request memory r) {
        r.params = ILiquidationModule.LiquidationParams({
            marketId: 1,
            debtReserveId: 10,
            account: address(0xA11CE),
            debtToCover: 0,
            minAmount0: 0,
            minAmount1: 0,
            receiver: address(0)
        });
        r.flashAmount = flashAmount;
        r.swaps = new Swap[](2);
        r.swaps[0] = _sell(address(weth), rateBps);
        r.swaps[1] = _sell(address(usdt), rateBps);
    }

    function _sell(
        address token,
        uint256 rateBps
    ) internal view returns (Swap memory) {
        return Swap({
            tokenIn: token,
            target: address(router),
            data: abi.encodeCall(MockRouter.swap, (token, address(usdc), 0, rateBps)),
            amountInOffset: AMOUNT_IN_OFFSET
        });
    }

    function _assertEmpty() internal view {
        assertEq(usdc.balanceOf(address(liq)), 0);
        assertEq(weth.balanceOf(address(liq)), 0);
        assertEq(usdt.balanceOf(address(liq)), 0);
    }

    function test_constructor() public {
        assertEq(liq.POOL(), address(pool));
        assertEq(liq.LIQUIDATION_MODULE(), address(module));
        assertEq(liq.RISK_MODULE(), address(reads));
        assertEq(liq.LP_VAULT(), vault);
        assertEq(liq.OPERATOR(), operator);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidator.InvalidAddress.selector, address(0)));
        new FlashLiquidator(address(0), address(module), operator);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidator.InvalidAddress.selector, address(0)));
        new FlashLiquidator(address(pool), address(0), operator);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidator.InvalidAddress.selector, address(0)));
        new FlashLiquidator(address(pool), address(module), address(0));
    }

    function test_profitWithPremium() public {
        // 10,000 repaid, 5% bonus paid as 5,250 WETH-units + 5,250 USDT-units, sold at par; premium 5 bps.
        vm.expectEmit(address(liq));
        emit IFlashLiquidator.FlashLiquidated(address(0xA11CE), 1, address(usdc), 10_000e6, 5e6, 10_000e6, 0, 495e6);
        vm.prank(operator);
        uint256 profit = liq.flashLiquidate(_request(10_000e6, 10_000));
        assertEq(profit, 495e6);
        assertEq(usdc.balanceOf(operator), 495e6);
        assertEq(liq.flashPremium(10_000e6), 5e6);
        _assertEmpty();
    }

    function test_flashBorrowerPaysNoPremium() public {
        pool.setFlashBorrower(address(liq), true);
        assertTrue(liq.isFlashBorrower());
        assertEq(liq.flashPremium(10_000e6), 0);
        vm.prank(operator);
        assertEq(liq.flashLiquidate(_request(10_000e6, 10_000)), 500e6);
    }

    function test_unusedDebtIsRefundedIntoTheProfit() public {
        module.set(6000e6, 500);
        vm.prank(operator);
        uint256 profit = liq.flashLiquidate(_request(10_000e6, 10_000));
        // 4,000 refunded + 6,300 sold - 10,005 owed.
        assertEq(profit, 295e6);
    }

    function test_unsoldTokenAndProfitGoToTheRecipient() public {
        IFlashLiquidator.Request memory r = _request(10_000e6, 20_000);
        r.swaps = new Swap[](1);
        r.swaps[0] = _sell(address(weth), 20_000);
        r.recipient = address(0xBEEF);
        vm.prank(operator);
        liq.flashLiquidate(r);
        assertEq(usdc.balanceOf(address(0xBEEF)), 10_500e6 - 10_005e6);
        assertEq(usdt.balanceOf(address(0xBEEF)), 5250e6);
        _assertEmpty();
    }

    function test_topUpFromTheOperator() public {
        // Sold at 90%: 9,450 against 10,005 owed; the operator covers 555.
        usdc.mint(operator, 1000e6);
        vm.prank(operator);
        usdc.approve(address(liq), type(uint256).max);
        IFlashLiquidator.Request memory r = _request(10_000e6, 9000);
        r.maxTopUp = 555e6;
        vm.prank(operator);
        assertEq(liq.flashLiquidate(r), 0);
        assertEq(usdc.balanceOf(operator), 445e6);
        r.maxTopUp = 554e6;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidator.TopUpExceeded.selector, 555e6, 554e6));
        liq.flashLiquidate(r);
    }

    function test_profitFloor() public {
        IFlashLiquidator.Request memory r = _request(10_000e6, 10_000);
        r.minProfit = 496e6;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidator.ProfitTooLow.selector, 495e6, 496e6));
        liq.flashLiquidate(r);
    }

    function test_onlyTheOperator() public {
        vm.expectRevert(abi.encodeWithSelector(IFlashLiquidator.NotOperator.selector, address(this)));
        liq.flashLiquidate(_request(1, 10_000));
        vm.prank(operator);
        vm.expectRevert(IFlashLiquidator.InvalidAmount.selector);
        liq.flashLiquidate(_request(0, 10_000));
    }

    function test_swapsCannotTargetTheModuleOrPool() public {
        IFlashLiquidator.Request memory r = _request(10_000e6, 10_000);
        r.swaps[0].target = address(module);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SwapCalls.ForbiddenTarget.selector, address(module)));
        liq.flashLiquidate(r);
        r.swaps[0].target = address(pool);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(SwapCalls.ForbiddenTarget.selector, address(pool)));
        liq.flashLiquidate(r);
    }

    function test_flashCallbackChecks() public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1e6;
        uint256[] memory premiums = new uint256[](1);
        vm.expectRevert(IFlashLiquidator.InvalidFlashCallback.selector);
        liq.executeOperation(assets, amounts, premiums, address(liq), "");
        vm.prank(address(pool));
        vm.expectRevert(IFlashLiquidator.InvalidFlashCallback.selector);
        liq.executeOperation(assets, amounts, premiums, address(liq), "");
        vm.expectRevert(IFlashLiquidator.InvalidFlashCallback.selector);
        pool.flashLoan(address(liq), assets, amounts, new uint256[](1), address(this), "", 0);
    }

    /// @dev Either the call reverts on the top-up bound, or the profit is exactly the sale plus the refund less the loan
    /// and its premium, the operator paid at most `maxTopUp`, and the contract holds nothing.
    function testFuzz_flashLiquidate(
        uint256 flashAmount,
        uint256 cap,
        uint256 bonusBps,
        uint256 rateBps,
        uint256 premiumBps,
        bool borrower,
        uint256 maxTopUp
    ) public {
        flashAmount = bound(flashAmount, 1, 1e15);
        cap = bound(cap, 1, flashAmount);
        bonusBps = bound(bonusBps, 0, 1500);
        rateBps = bound(rateBps, 8000, 10_500);
        premiumBps = bound(premiumBps, 0, 100);
        maxTopUp = bound(maxTopUp, 0, flashAmount);
        module.set(cap, bonusBps);
        pool.setPremiumBps(premiumBps);
        pool.setFlashBorrower(address(liq), borrower);
        usdc.mint(operator, maxTopUp);
        vm.prank(operator);
        usdc.approve(address(liq), maxTopUp);

        uint256 premium = borrower ? 0 : (flashAmount * premiumBps + 9999) / 10_000;
        uint256 half = cap * (10_000 + bonusBps) / 20_000;
        uint256 proceeds = (flashAmount - cap) + 2 * (half * rateBps / 10_000);
        uint256 owed = flashAmount + premium;

        IFlashLiquidator.Request memory r = _request(flashAmount, rateBps);
        r.maxTopUp = maxTopUp;
        vm.prank(operator);
        try liq.flashLiquidate(r) returns (uint256 profit) {
            if (proceeds >= owed) {
                assertEq(profit, proceeds - owed);
                assertEq(usdc.balanceOf(operator), maxTopUp + profit);
            } else {
                assertEq(profit, 0);
                assertEq(usdc.balanceOf(operator), maxTopUp - (owed - proceeds));
            }
        } catch (bytes memory reason) {
            assertLt(proceeds + maxTopUp, owed);
            assertEq(bytes4(reason), IFlashLiquidator.TopUpExceeded.selector);
        }
        _assertEmpty();
    }
}
