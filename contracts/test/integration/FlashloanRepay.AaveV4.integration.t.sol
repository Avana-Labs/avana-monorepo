// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {FlashloanRepay} from "../../src/FlashloanRepay.sol";
import {IAaveAdapter} from "../../src/interfaces/IAaveAdapter.sol";
import {IFlashloanRepay} from "../../src/interfaces/IFlashloanRepay.sol";
import {ILPVault} from "../../src/interfaces/ILPVault.sol";
import {INfpmPositions} from "../../src/interfaces/INfpmPositions.sol";
import {IWithdrawReceiver} from "../../src/interfaces/IWithdrawReceiver.sol";
import {ClTickMath} from "../../src/libraries/ClTickMath.sol";
import {Swap, SwapCalls} from "../../src/libraries/SwapCalls.sol";
import {AaveV4MarketTestBase} from "../utils/AaveV4MarketTestBase.sol";
import {ClTestToken, IClPool} from "../utils/fixtures/ClPoolFixture.sol";
import {HostileFlashPool, ReenteringSwapTarget} from "../utils/mocks/hostile/FlashCallbackAttackers.sol";

/// @dev `ISwapRouter.ExactInputSingleParams` of Uniswap v3 periphery 1.0.0.
struct ExactInputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    address recipient;
    uint256 deadline;
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
}

interface ISwapRouterCalls {
    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}

/// @dev The layout of `FlashloanRepay`'s private `Context`, so a forged one decodes as the helper's own would.
struct ForgedContext {
    address wallet;
    bytes32 positionKey;
    uint256 marketId;
    uint256 amount;
    IFlashloanRepay.RepayParams params;
}

/// @title FlashloanRepayAaveV4IntegrationTest
/// @notice Attacks on repay-with-collateral on the pinned real Aave V4 Hub and CDP Spoke, the real AaveAdapter and
/// Uniswap v3 LPVault, with the wallet's swaps routed through the real Uniswap v3 SwapRouter and pools: spoofed,
/// replayed and altered flash-loan callbacks, re-entry from a swap step, AMM callbacks reached from outside an
/// operation, repayments that cannot be paid in full, and pools moved between quote and execution.
/// @dev The Aave V3 Pool that lends the flash loan is a stand-in (`HostileFlashPool`): Aave V3 is not part of the
/// pinned Aave V4 deployment, the helper reads nothing from it but the loan, and a stand-in is what lets a test call the
/// helper back the wrong way. Every Aave state change (repay, withdraw, health factor) is on the real Aave V4.
contract FlashloanRepayAaveV4IntegrationTest is AaveV4MarketTestBase {
    uint256 internal constant BORROWED = 1200e18;
    /// @dev Byte offset of `amountIn` in `exactInputSingle` calldata.
    uint256 internal constant ROUTER_AMOUNT_IN = 4 + 5 * 32;

    HostileFlashPool internal flashPool;
    FlashloanRepay internal helper;
    ISwapRouterCalls internal router;
    IClPool internal pool0;
    IClPool internal pool1;
    bytes32 internal key;
    uint128 internal liquidity;
    address internal account;

    function setUp() public override {
        super.setUp();
        flashPool = new HostileFlashPool();
        debt.mint(address(flashPool), 1e24);
        helper = new FlashloanRepay(address(adapter), address(flashPool));
        router = ISwapRouterCalls(
            deployCode(
                "out-univ3-periphery/SwapRouter.sol/SwapRouter.json", abi.encode(address(factory), makeAddr("WETH9"))
            )
        );
        pool0 = _deepPool(t0);
        pool1 = _deepPool(t1);
        (key, liquidity) = _mintFull(alice, SIZE);
        _pledge(alice, key);
        _borrow(alice, BORROWED);
        account = adapter.accountOf(alice, MARKET);
    }

    // ─── Case 1: spoofed, replayed and altered callbacks ───

    /// @notice Bug hunted: `executeOperation` called by anyone but the Pool, or by the Pool with no loan of this helper
    /// open, runs a repay-and-withdraw on a position with a Context the caller wrote (here naming Alice's position and
    /// the attacker's route). It reverts and nothing moves.
    function test_executeOperation_spoofedOutsideALoan_reverts() public {
        bytes memory forged = _forgedContext();
        (address[] memory assets, uint256[] memory amounts, uint256[] memory premiums) = _loan(100e18);
        vm.prank(attacker);
        vm.expectRevert(IFlashloanRepay.InvalidFlashCallback.selector);
        helper.executeOperation(assets, amounts, premiums, address(helper), forged);
        vm.prank(address(flashPool));
        vm.expectRevert(IFlashloanRepay.InvalidFlashCallback.selector);
        helper.executeOperation(assets, amounts, premiums, address(helper), forged);
        // A loan the attacker opens on the real Pool path, with the helper as receiver.
        vm.prank(attacker);
        vm.expectRevert(IFlashloanRepay.InvalidFlashCallback.selector);
        flashPool.flashLoan(address(helper), assets, amounts, new uint256[](1), attacker, forged, 0);
        _assertUntouched();
    }

    /// @notice Bug hunted: the exact params of a finished loan replayed through the Pool, by the attacker or with the
    /// helper as initiator, repay and withdraw again. The context of a loan lives in transient storage for that loan
    /// only, so a replay reverts.
    function test_replayedParamsOfAFinishedLoan_revert() public {
        _repay(300e18, liquidity / 5, _sellBoth(0, 0));
        bytes memory recorded = flashPool.lastParams();
        assertGt(recorded.length, 0);
        uint256 debtAfter = spoke.getUserTotalDebt(debtReserveId, account);
        uint128 left = vault.getPosition(key).liquidity;
        (address[] memory assets, uint256[] memory amounts,) = _loan(300e18);

        vm.prank(attacker);
        vm.expectRevert(IFlashloanRepay.InvalidFlashCallback.selector);
        flashPool.flashLoan(address(helper), assets, amounts, new uint256[](1), attacker, recorded, 0);
        vm.prank(address(helper));
        vm.expectRevert(IFlashloanRepay.InvalidFlashCallback.selector);
        flashPool.flashLoan(address(helper), assets, amounts, new uint256[](1), address(helper), recorded, 0);
        assertEq(spoke.getUserTotalDebt(debtReserveId, account), debtAfter);
        assertEq(vault.getPosition(key).liquidity, left);
    }

    /// @notice Bug hunted: inside a loan the helper opened, the Pool (or anything between it and the helper) alters the
    /// params, names another initiator, adds an asset, or calls back twice. The context hash, the initiator check, the
    /// one-asset check and the one-shot context each refuse it, and the whole repay reverts with nothing moved.
    function test_liveLoan_alteredInitiatorExtraAssetOrSecondCall_revertWhole() public {
        HostileFlashPool.Mode[4] memory modes = [
            HostileFlashPool.Mode.AlterParams,
            HostileFlashPool.Mode.WrongInitiator,
            HostileFlashPool.Mode.ExtraAsset,
            HostileFlashPool.Mode.CallTwice
        ];
        flashPool.setExtraAsset(address(t0));
        for (uint256 i; i < modes.length; ++i) {
            flashPool.setMode(modes[i]);
            vm.prank(alice);
            vm.expectRevert(IFlashloanRepay.InvalidFlashCallback.selector);
            adapter.allowWithdraw(address(helper), key, liquidity / 5, _params(300e18, liquidity / 5, _sellBoth(0, 0)));
            _assertUntouched();
        }
        // The same call goes through once the Pool behaves.
        flashPool.setMode(HostileFlashPool.Mode.Honest);
        _repay(300e18, liquidity / 5, _sellBoth(0, 0));
        assertEq(spoke.getUserTotalDebt(debtReserveId, account), BORROWED - 300e18);
    }

    /// @notice Bug hunted: a swap step of the wallet's route re-enters from inside the open loan: it opens a second
    /// loan with the helper as receiver, calls the callbacks directly, withdraws from the position it is being paid
    /// from, or opens an allowance of its own. Every attempt fails, the route goes on, and the repay ends exactly as one
    /// without the attempts would.
    function test_swapStepReentry_cannotReuseTheLoanOrThePosition() public {
        ReenteringSwapTarget target = new ReenteringSwapTarget();
        (address[] memory assets, uint256[] memory amounts, uint256[] memory premiums) = _loan(100e18);
        address[] memory targets = new address[](6);
        bytes[] memory calls = new bytes[](6);
        (targets[0], calls[0]) =
        (
            address(flashPool),
            abi.encodeCall(
                HostileFlashPool.flashLoan,
                (address(helper), assets, amounts, new uint256[](1), address(target), _forgedContext(), 0)
            )
        );
        (targets[1], calls[1]) =
        (
            address(helper),
            abi.encodeCall(helper.executeOperation, (assets, amounts, premiums, address(helper), _forgedContext()))
        );
        (targets[2], calls[2]) =
        (
            address(helper),
            abi.encodeCall(
                IWithdrawReceiver.onWithdrawAllowed,
                (alice, key, liquidity / 2, _params(1, liquidity / 2, new Swap[](0)))
            )
        );
        (targets[3], calls[3]) =
        (address(adapter), abi.encodeCall(IAaveAdapter.withdraw, (key, liquidity / 2, 0, 0, address(target))));
        (targets[4], calls[4]) =
        (address(adapter), abi.encodeCall(IAaveAdapter.allowWithdraw, (address(target), key, liquidity / 2, bytes(""))));
        (targets[5], calls[5]) =
        (address(vault), abi.encodeCall(ILPVault.removeLiquidity, (key, liquidity / 2, 0, 0, address(target))));
        target.setAttempts(targets, calls);

        Swap[] memory s = _sellBoth(0, 0);
        bytes memory inner = s[0].data;
        s[0] = Swap({
            tokenIn: address(t0),
            target: address(target),
            data: abi.encodeCall(ReenteringSwapTarget.swapVia, (address(router), address(t0), address(debt), inner)),
            amountInOffset: 4 + 4 * 32 + 32 + ROUTER_AMOUNT_IN
        });
        uint256 snap = vm.snapshotState();
        _repay(300e18, liquidity / 5, _sellBoth(0, 0));
        uint256 plainWallet = debt.balanceOf(alice);
        vm.revertToState(snap);

        _repay(300e18, liquidity / 5, s);
        assertEq(target.attempts(), 6);
        for (uint256 i; i < 6; ++i) {
            assertFalse(target.succeeded(i), "every re-entry fails");
        }
        assertEq(spoke.getUserTotalDebt(debtReserveId, account), BORROWED - 300e18);
        assertEq(vault.getPosition(key).liquidity, liquidity - liquidity / 5, "only the allowed part left");
        assertEq(debt.balanceOf(alice), plainWallet, "the wallet gets what a plain route pays");
        _assertHelperEmpty();
    }

    /// @notice Bug hunted: a Uniswap v3 swap, mint or flash callback, a v4 `unlockCallback`, an Aave V3 simple
    /// flash-loan callback or an ERC-721 receipt sent straight to an Avana contract from outside any operation it
    /// started makes it pay, mint, record or approve. None of them implements a callback or a fallback, so every call
    /// reverts, and no balance or allowance of theirs moves. The NonfungiblePositionManager's own mint callback,
    /// called with the vault as payer, refuses a caller that is not the pool.
    function test_ammCallbacksFromOutside_moveNothing() public {
        address[7] memory avana =
            [address(vault), address(adapter), address(module), address(helper), address(oracle), address(vt), account];
        bytes[6] memory calls = [
            abi.encodeWithSignature(
                "uniswapV3SwapCallback(int256,int256,bytes)", int256(1e18), int256(1e18), abi.encode(alice)
            ),
            abi.encodeWithSignature("uniswapV3MintCallback(uint256,uint256,bytes)", 1e18, 1e18, abi.encode(alice)),
            abi.encodeWithSignature("uniswapV3FlashCallback(uint256,uint256,bytes)", 1e18, 1e18, abi.encode(alice)),
            abi.encodeWithSignature("unlockCallback(bytes)", abi.encode(alice)),
            abi.encodeWithSignature(
                "executeOperation(address,uint256,uint256,address,bytes)", address(debt), 1e18, 0, attacker, ""
            ),
            abi.encodeWithSignature(
                "onERC721Received(address,address,uint256,bytes)", attacker, attacker, uint256(key), ""
            )
        ];
        uint256[7][3] memory balances;
        for (uint256 i; i < avana.length; ++i) {
            (balances[0][i], balances[1][i], balances[2][i]) =
            (t0.balanceOf(avana[i]), t1.balanceOf(avana[i]), debt.balanceOf(avana[i]));
        }
        vm.startPrank(attacker);
        for (uint256 i; i < avana.length; ++i) {
            for (uint256 j; j < calls.length; ++j) {
                (bool ok,) = avana[i].call(calls[j]);
                assertFalse(ok, "no callback on an Avana contract");
            }
        }
        (bool paid,) = address(nfpm)
            .call(
                abi.encodeWithSignature(
                    "uniswapV3MintCallback(uint256,uint256,bytes)",
                    1e18,
                    1e18,
                    abi.encode(address(t0), address(t1), _poolFee(), address(vault))
                )
            );
        assertFalse(paid, "the manager's callback checks the pool");
        vm.stopPrank();
        for (uint256 i; i < avana.length; ++i) {
            assertEq(t0.balanceOf(avana[i]), balances[0][i]);
            assertEq(t1.balanceOf(avana[i]), balances[1][i]);
            assertEq(debt.balanceOf(avana[i]), balances[2][i]);
            assertEq(t0.allowance(avana[i], address(nfpm)), 0);
            assertEq(t1.allowance(avana[i], address(nfpm)), 0);
        }
        assertEq(nfpm.ownerOf(uint256(key)), address(vault));
        _assertUntouched();
    }

    // ─── Case 2: repayments that cannot be paid in full ───

    /// @notice Bug hunted: a repay whose swaps raise less than the loan and its premium, whose route fails half way,
    /// or that would leave the account less healthy, leaves the debt partly repaid, liquidity withdrawn and stranded
    /// with the helper, or the adapter's allowance open. Each reverts whole: debt, supply, credit, the NFT's liquidity,
    /// the wallet's balances and the helper are as before, and the wallet can open a new allowance at once.
    function test_shortfallFailedRouteOrLowerHealth_revertWhole() public {
        // Repays 1,000 but withdraws liquidity worth about $200.
        vm.prank(alice);
        vm.expectPartialRevert(IFlashloanRepay.InsufficientProceeds.selector);
        adapter.allowWithdraw(address(helper), key, liquidity / 10, _params(1000e18, liquidity / 10, _sellBoth(0, 0)));
        _assertUntouched();

        // The second swap's minimum cannot be met.
        vm.prank(alice);
        vm.expectPartialRevert(SwapCalls.SwapFailed.selector);
        adapter.allowWithdraw(address(helper), key, liquidity / 5, _params(300e18, liquidity / 5, _sellBoth(0, 1e24)));
        _assertUntouched();

        // Repays 100 and withdraws 30 % of the position: still healthy, but less than before (1.02 < 1.33).
        vm.prank(alice);
        vm.expectPartialRevert(IAaveAdapter.HealthFactorDecreased.selector);
        adapter.allowWithdraw(
            address(helper), key, liquidity * 3 / 10, _params(100e18, liquidity * 3 / 10, _sellBoth(0, 0))
        );
        _assertUntouched();

        // Nothing was left open: the same wallet repays at once.
        _repay(300e18, liquidity / 5, _sellBoth(0, 0));
        assertEq(spoke.getUserTotalDebt(debtReserveId, account), BORROWED - 300e18);
    }

    /// @notice Bug hunted: a full repay with collateral on real Aave leaves debt dust, or the wallet's leftovers stay
    /// with the helper. The debt is zero, the position can leave whole, and the helper holds nothing.
    function test_fullRepayWithCollateral_clearsTheDebt() public {
        _repay(type(uint256).max, liquidity * 7 / 10, _sellBoth(0, 0));
        assertEq(spoke.getUserTotalDebt(debtReserveId, account), 0);
        assertGt(debt.balanceOf(alice), BORROWED, "the borrowed funds plus the leftover");
        vm.prank(alice);
        adapter.withdraw(key, 0, 0, 0, alice);
        assertEq(nfpm.ownerOf(uint256(key)), alice);
        assertEq(vt.totalSupply(), 0);
        _assertHelperEmpty();
    }

    // ─── Case 3: the pool moves between quote and execution ───

    /// @notice Bug hunted: a front-runner moves the position's pool (so the withdrawal returns another mix) or the
    /// pool the route sells into (so the swap returns less) between the wallet's quote and its repay, and the repay
    /// still goes through at the worse price. The withdrawal minimums and the route's own minimum out make it revert
    /// whole.
    function test_sandwichedRepay_minimumsRevertWhole() public {
        uint128 part = liquidity / 5;
        uint256 snap = vm.snapshotState();
        (uint256 a0, uint256 a1) = _quoteWithdrawal(part);
        uint256 out0 = _quoteSale(pool0, address(t0), a0);
        vm.revertToState(snap);

        // The position's pool moves 5 %: token0 out falls below the quote.
        _swapTo(pool, ClTickMath.getSqrtPriceAtTick(500));
        IFlashloanRepay.RepayParams memory p = _repayParams(300e18, part, _sellBoth(0, 0));
        (p.amount0Min, p.amount1Min) = (a0, a1);
        vm.prank(alice);
        vm.expectRevert(bytes("Price slippage check"));
        adapter.allowWithdraw(address(helper), key, part, abi.encode(p));
        _assertUntouched();
        _swapTo(pool, ClTickMath.getSqrtPriceAtTick(0));

        // The sell pool moves: the route's minimum out fails.
        _swapTo(pool0, ClTickMath.getSqrtPriceAtTick(-500));
        vm.prank(alice);
        vm.expectPartialRevert(SwapCalls.SwapFailed.selector);
        adapter.allowWithdraw(address(helper), key, part, _params(300e18, part, _sellBoth(out0, 0)));
        _assertUntouched();
    }

    // ─── Helpers ───

    /// @dev A pool of `token` against the debt asset at $1 each with deep full-range liquidity.
    function _deepPool(
        ClTestToken token
    ) internal returns (IClPool p) {
        (ClTestToken a, ClTestToken b) = address(token) < address(debt) ? (token, debt) : (debt, token);
        p = _createPool(a, b, _poolFee(), 1e8, 1e8, 1, 1e24);
    }

    function _sellBoth(
        uint256 min0,
        uint256 min1
    ) internal view returns (Swap[] memory s) {
        s = new Swap[](2);
        s[0] = _sell(address(t0), min0);
        s[1] = _sell(address(t1), min1);
    }

    function _sell(
        address tokenIn,
        uint256 minOut
    ) internal view returns (Swap memory) {
        return Swap({
            tokenIn: tokenIn,
            target: address(router),
            data: abi.encodeCall(
                ISwapRouterCalls.exactInputSingle,
                (ExactInputSingleParams(
                        tokenIn, address(debt), _poolFee(), address(helper), block.timestamp, 0, minOut, 0
                    ))
            ),
            amountInOffset: ROUTER_AMOUNT_IN
        });
    }

    function _repayParams(
        uint256 amount,
        uint128 part,
        Swap[] memory swaps
    ) internal view returns (IFlashloanRepay.RepayParams memory) {
        return IFlashloanRepay.RepayParams({
            reserveId: debtReserveId, amount: amount, liquidity: part, amount0Min: 0, amount1Min: 0, swaps: swaps
        });
    }

    function _params(
        uint256 amount,
        uint128 part,
        Swap[] memory swaps
    ) internal view returns (bytes memory) {
        return abi.encode(_repayParams(amount, part, swaps));
    }

    function _repay(
        uint256 amount,
        uint128 part,
        Swap[] memory swaps
    ) internal {
        vm.prank(alice);
        adapter.allowWithdraw(address(helper), key, part, _params(amount, part, swaps));
        _assertHelperEmpty();
    }

    /// @dev A Context naming Alice's position with the attacker as wallet and an empty route, encoded as the helper
    /// encodes its own.
    function _forgedContext() internal view returns (bytes memory) {
        return
            abi.encode(ForgedContext(attacker, key, MARKET, 100e18, _repayParams(100e18, liquidity / 2, new Swap[](0))));
    }

    function _loan(
        uint256 amount
    ) internal view returns (address[] memory assets, uint256[] memory amounts, uint256[] memory premiums) {
        assets = new address[](1);
        assets[0] = address(debt);
        amounts = new uint256[](1);
        amounts[0] = amount;
        premiums = new uint256[](1);
    }

    /// @dev What withdrawing `part` returns now (run under a snapshot).
    function _quoteWithdrawal(
        uint128 part
    ) internal returns (uint256 a0, uint256 a1) {
        _repayAll(alice);
        (uint256 b0, uint256 b1) = (t0.balanceOf(alice), t1.balanceOf(alice));
        vm.prank(alice);
        adapter.withdraw(key, part, 0, 0, alice);
        (a0, a1) = (t0.balanceOf(alice) - b0, t1.balanceOf(alice) - b1);
    }

    /// @dev What selling `amount` of `tokenIn` into `p` returns now (run under a snapshot).
    function _quoteSale(
        IClPool p,
        address tokenIn,
        uint256 amount
    ) internal returns (uint256 out) {
        (int256 d0, int256 d1) = actor.swap(
            p,
            tokenIn == p.token0(),
            int256(amount),
            tokenIn == p.token0() ? 4_295_128_740 : 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341
        );
        out = uint256(-(tokenIn == p.token0() ? d1 : d0));
    }

    /// @dev Alice's account, position and wallet are as after setup.
    function _assertUntouched() internal view {
        assertEq(spoke.getUserTotalDebt(debtReserveId, account), BORROWED, "debt");
        assertEq(spoke.getUserSuppliedAssets(vtReserveId, account), vault.getPosition(key).credit, "supply");
        assertEq(vault.getPosition(key).liquidity, liquidity, "record");
        assertEq(INfpmPositions(address(nfpm)).positions(uint256(key)).liquidity, liquidity, "NFT");
        assertEq(debt.balanceOf(alice), BORROWED, "wallet");
        _assertHelperEmpty();
    }

    function _assertHelperEmpty() internal view {
        assertEq(debt.balanceOf(address(helper)), 0, "helper debt");
        assertEq(t0.balanceOf(address(helper)), 0, "helper token0");
        assertEq(t1.balanceOf(address(helper)), 0, "helper token1");
        assertEq(t0.allowance(address(helper), address(router)), 0, "router allowance");
        assertEq(debt.allowance(address(helper), address(adapter)), 0, "adapter allowance");
    }
}
