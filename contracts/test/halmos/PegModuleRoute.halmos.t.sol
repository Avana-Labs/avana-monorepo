// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ISettlementRoute} from "../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {PegModuleRoute} from "../../src/liquidation/settlement-routes/PegModuleRoute.sol";
import {
    PegModuleKind,
    PegModuleStep,
    RouteConfig
} from "../../src/liquidation/settlement-routes/types/SettlementRouteTypes.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {RouteMathHarness} from "../utils/harness/RouteMathHarness.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {MockLitePsm} from "../utils/mocks/SwapRouteMocks.sol";
import {Test} from "forge-std/Test.sol";

/// @title PegModuleRouteHalmosTest
/// @notice Symbolic checks of the `PegModule` swap route (DAI → USDC through the LitePSM) for every caller, Lock state,
/// amount and minimum: the caller and Lock rule, the callback always refused, a completed swap delivering at least
/// `minOut` with the DAI conserved between the LitePSM and LPVaultSwap, and the gem amount of REQ-ROUTE-012 being the
/// largest the DAI buys with no overflow.
/// @dev The LitePSM fee is 0 in the swap checks and a literal (0, 1, 10 or 100 bps) in each gem-amount check; DAI
/// amounts are bounded to uint96 (79 billion DAI); the symbolic-fee form is fuzzed. The gem-amount and swap checks prove
/// that the code computes the reference formula of `RouteMath` with the same divisions (equal terms, no division
/// reasoning for the solver); MATH-ST-120 (`docs/spec/05-verification/z3/settlement/st15_debt_asset_settlement.py`)
/// proves the formula's bounds with exact integers. Asserting those bounds here made the solver derive floor-division
/// facts through 256- and 512-bit division circuits, and neither check finished within 5 hours (run 43492412351).
contract PegModuleRouteHalmosTest is Test {
    address internal constant ADAPTER = address(0xADA9);
    address internal constant SWAP = address(0x5A9);
    uint256 internal constant WAD = 1e18;

    Lock internal lock;
    PayoutToken internal dai;
    PayoutToken internal usdc;
    MockLitePsm internal psm;
    PegModuleRoute internal route;
    RouteMathHarness internal math;

    function setUp() public {
        lock = new Lock(ADAPTER, SWAP);
        dai = new PayoutToken("DAI", 18);
        usdc = new PayoutToken("USDC", 6);
        psm = new MockLitePsm(address(dai), address(usdc), 6);
        usdc.mint(address(psm), type(uint128).max);
        route = new PegModuleRoute(
            RouteConfig({
                lpVaultSwap: SWAP,
                lock: address(lock),
                aaveAdapter: ADAPTER,
                tokenIn: address(dai),
                tokenOut: address(usdc),
                tokenClassMask: 2,
                uniswapV3Factory: address(0),
                slipstreamFactory: address(0),
                curveFactory: address(0),
                curveLegacyPools: new address[](0)
            }),
            PegModuleStep({
                kind: PegModuleKind.LitePsm, module: address(psm), wrapper: address(0), intermediate: address(0)
            })
        );
        math = new RouteMathHarness();
    }

    function _setLock(
        uint8 state
    ) internal {
        if (state % 3 == 1) {
            vm.prank(SWAP);
            lock.acquire();
        } else if (state % 3 == 2) {
            vm.prank(ADAPTER);
            lock.acquire();
        }
    }

    function _fund(
        address from,
        uint256 amount
    ) internal {
        dai.mint(from, amount);
        vm.prank(from);
        dai.approve(address(route), amount);
    }

    // PROP-037 verifies: REQ-ROUTE-007, REQ-ROUTE-025, INV-054
    function check_PROP_037_swapOnlyForLPVaultSwapUnderLock(
        address caller,
        uint8 lockState,
        uint128 amountIn,
        uint128 minOut
    ) public {
        _setLock(lockState);
        _fund(caller, amountIn);
        vm.prank(caller);
        try route.swap(amountIn, minOut) {
            assert(caller == SWAP);
            assert(lockState % 3 != 0);
        } catch (bytes memory reason) {
            if (caller != SWAP) {
                assert(bytes4(reason) == ISettlementRoute.NotLPVaultSwap.selector);
            } else if (lockState % 3 == 0) {
                assert(bytes4(reason) == ISettlementRoute.NotLocked.selector);
            }
        }
    }

    // PROP-036 verifies: REQ-ROUTE-013, REQ-ROUTE-029, INV-040
    function check_PROP_036_callbackAlwaysRefused(
        address caller,
        int256 amount0,
        int256 amount1
    ) public {
        dai.mint(address(route), 1e18);
        vm.prank(caller);
        try route.uniswapV3SwapCallback(amount0, amount1, "") {
            assert(false);
        } catch (bytes memory reason) {
            assert(bytes4(reason) == ISettlementRoute.InvalidCallback.selector);
        }
        assert(dai.balanceOf(address(route)) == 1e18);
    }

    // PROP-068 verifies: REQ-ROUTE-009, REQ-ROUTE-012, REQ-ROUTE-014, REQ-ROUTE-015, REQ-ROUTE-016, REQ-ROUTE-042, INV-021, INV-083
    /// @notice A swap with a zero amount or a zero minimum is refused (`TransferMismatch`, then `ZeroMinOut`). The three
    /// `swapDeliversAtLeastMinOut` checks split the inputs of the check before the split (`amountIn < 2^96`,
    /// `minOut < 2^128`): `Refused` when `amountIn` or `minOut` is 0; `Delivered` when both are positive and
    /// `minOut ≤ g`; `Short` when both are positive and `minOut > g`, with `g` the gem amount the route buys
    /// (`_gemRef`). Every input falls in exactly one case, and each case runs the same assertions (`_swapAndCheck`).
    function check_PROP_068_swapDeliversAtLeastMinOutRefused(
        uint256 amountIn,
        uint256 minOut
    ) public {
        vm.assume(amountIn < 2 ** 96 && minOut < 2 ** 128 && (amountIn == 0 || minOut == 0));
        _swapAndCheck(amountIn, minOut, _gemRef(amountIn));
    }

    // PROP-068 verifies: REQ-ROUTE-009, REQ-ROUTE-012, REQ-ROUTE-014, REQ-ROUTE-015, REQ-ROUTE-016, REQ-ROUTE-042, INV-021, INV-083
    /// @notice `check_PROP_068_swapDeliversAtLeastMinOutRefused` when `amountIn` and `minOut` are positive and the
    /// route buys at least `minOut`: the swap completes, delivers exactly `g ≥ minOut` USDC to LPVaultSwap and returns
    /// the DAI the LitePSM did not take.
    function check_PROP_068_swapDeliversAtLeastMinOutDelivered(
        uint256 amountIn,
        uint256 minOut
    ) public {
        vm.assume(amountIn < 2 ** 96 && minOut < 2 ** 128 && amountIn != 0 && minOut != 0);
        uint256 g = _gemRef(amountIn);
        vm.assume(minOut <= g);
        _swapAndCheck(amountIn, minOut, g);
    }

    // PROP-068 verifies: REQ-ROUTE-009, REQ-ROUTE-012, REQ-ROUTE-014, REQ-ROUTE-015, REQ-ROUTE-016, REQ-ROUTE-042, INV-021, INV-083
    /// @notice `check_PROP_068_swapDeliversAtLeastMinOutRefused` when `amountIn` and `minOut` are positive and the
    /// route buys less than `minOut`: the swap reverts `MinOutNotMet(g, minOut)`.
    function check_PROP_068_swapDeliversAtLeastMinOutShort(
        uint256 amountIn,
        uint256 minOut
    ) public {
        vm.assume(amountIn < 2 ** 96 && minOut < 2 ** 128 && amountIn != 0 && minOut != 0);
        uint256 g = _gemRef(amountIn);
        vm.assume(minOut > g);
        _swapAndCheck(amountIn, minOut, g);
    }

    /// @dev The assertions of the check before the split, with `g` (`_gemRef`) for the gem amount: a completed swap
    /// delivers `g ≥ minOut` USDC to LPVaultSwap, which gets back the DAI the LitePSM did not take (`amountIn − g × 10¹²`
    /// at tout = 0), and leaves the route with no balance and no allowance; a refused swap names the first failed rule,
    /// and reverts `MinOutNotMet` only when `g < minOut` (an assertion the check before the split did not make).
    /// Before the split the check also asserted that the DAI returned is below 10¹² and named `⌊amountIn / 10¹²⌋` in
    /// `MinOutNotMet`. Both are facts about `g`, proved in MATH-ST-120: at tout = 0, `cost(x) = x × 10¹²`, so
    /// `cost(g) ≤ amountIn < cost(g + 1)` gives `g = ⌊amountIn / 10¹²⌋` and `amountIn − g × 10¹² < 10¹²`.
    function _swapAndCheck(
        uint256 amountIn,
        uint256 minOut,
        uint256 g
    ) internal {
        _setLock(1);
        _fund(SWAP, amountIn);
        vm.prank(SWAP);
        try route.swap(amountIn, minOut) returns (uint256 out) {
            assert(out >= minOut);
            assert(out == g);
            assert(usdc.balanceOf(SWAP) == out);
            // At tout = 0 the LitePSM takes out × 10¹² DAI and the rest comes back. Unchecked: a wrapped value would fail
            // the assertion rather than end the path in a revert.
            unchecked {
                assert(dai.balanceOf(SWAP) == amountIn - out * 1e12);
            }
            assert(dai.balanceOf(address(route)) == 0 && usdc.balanceOf(address(route)) == 0);
            assert(dai.allowance(address(route), address(psm)) == 0);
        } catch (bytes memory reason) {
            if (amountIn == 0) {
                assert(bytes4(reason) == ISettlementRoute.TransferMismatch.selector);
            } else if (minOut == 0) {
                assert(bytes4(reason) == ISettlementRoute.ZeroMinOut.selector);
            } else {
                assert(g < minOut);
                assert(
                    keccak256(reason)
                        == keccak256(abi.encodeWithSelector(ISettlementRoute.MinOutNotMet.selector, g, minOut))
                );
            }
        }
    }

    /// @dev The gem amount `g` the route buys with `amountIn` DAI, computed as `RouteMath.litePsmGemAmt` computes it,
    /// with the LitePSM's `tout` (0) and conversion factor `c` (10¹²) read as the route reads them:
    /// `g0 = ⌊amountIn × 10¹⁸ / ((10¹⁸ + tout) × c)⌋`, and `g = g0 + 1` when `cost(g0 + 1) ≤ amountIn`, else `g0`.
    /// The checks then compare the route's results with `g` term for term, so the solver never reasons about a division.
    /// The assumptions below hold for every `amountIn < 2^96`, so none removes an input; each states a fact the solver
    /// would otherwise have to derive through a multiplication or division circuit to rule out a branch the code
    /// cannot take, each ending in a revert the catch branch would test:
    /// - `mulmod(x, y, 2^256 − 1) == x × y` for the two products `Math.mulDiv` forms in `litePsmGemAmt`
    ///   (`amountIn × 10¹⁸ < 2^156`, and `(g0 + 1) × c × tout = 0`): below `2^256 − 1` both sides are the exact
    ///   product, so the 512-bit branch of `mulDiv` is ruled out;
    /// - `x × y / x == y`, the overflow test of a checked product, for `gemAmt * conversion` in `litePsmCost`
    ///   (`x = g0 + 1`) and in the LitePSM's `buyGem` (`x = g` when `g > 0`); both products are below 2^97;
    /// - `g0 ≤ amountIn`, `g ≤ amountIn` and `g × c ≤ amountIn`: `g0 = ⌊amountIn / 10¹²⌋` (since
    ///   `(10¹⁸ + 0) × 10¹² = 10¹⁸ × 10¹²`), and MATH-ST-120 gives `cost(g) ≤ amountIn` with `cost(g) = g × c` at
    ///   tout = 0. So `g0 + 1` does not overflow, the LitePSM's USDC balance (`2^128 − 1`) covers `g`, and the route's
    ///   DAI balance and the allowance it grants (`amountIn`) cover the `g × c` the LitePSM pulls.
    function _gemRef(
        uint256 amountIn
    ) internal view returns (uint256 g) {
        uint256 tout = psm.tout();
        uint256 c = psm.to18ConversionFactor();
        uint256 g0;
        uint256 g1c;
        unchecked {
            g0 = amountIn * WAD / ((WAD + tout) * c);
            g1c = (g0 + 1) * c;
        }
        vm.assume(g0 <= amountIn);
        g = _cost(g0 + 1, tout, c) <= amountIn ? g0 + 1 : g0;
        vm.assume(g <= amountIn);
        unchecked {
            vm.assume(g * c <= amountIn);
        }
        _assumeExactProduct(amountIn, WAD);
        _assumeExactProduct(g1c, tout);
        _assumeNoMulOverflow(g0 + 1, c);
        if (g != 0) _assumeNoMulOverflow(g, c);
    }

    // PROP-044 verifies: REQ-ROUTE-012
    /// @notice The gem amount of REQ-ROUTE-012 at a LitePSM fee of 0, for every DAI amount below 2^96: the code computes
    /// the reference formula, which MATH-ST-120 proves is the largest gem amount the DAI buys, with no overflow (see
    /// `_gemAmtIsTheReference`). The four `litePsmGemAmtLargestNoOverflow` checks take the four fees of the check before
    /// the split (0, 1, 10 and 100 bps, which it selected by `feeCase % 4`), one per check, so together they cover its
    /// inputs.
    function check_PROP_044_litePsmGemAmtLargestNoOverflowFee0(
        uint256 dai_
    ) public view {
        _gemAmtIsTheReference(dai_, 0);
    }

    // PROP-044 verifies: REQ-ROUTE-012
    /// @notice `check_PROP_044_litePsmGemAmtLargestNoOverflowFee0` at a LitePSM fee of 1 bp (`tout = 10¹⁴`).
    function check_PROP_044_litePsmGemAmtLargestNoOverflowFee1Bp(
        uint256 dai_
    ) public view {
        _gemAmtIsTheReference(dai_, 1e14);
    }

    // PROP-044 verifies: REQ-ROUTE-012
    /// @notice `check_PROP_044_litePsmGemAmtLargestNoOverflowFee0` at a LitePSM fee of 10 bps (`tout = 10¹⁵`).
    function check_PROP_044_litePsmGemAmtLargestNoOverflowFee10Bps(
        uint256 dai_
    ) public view {
        _gemAmtIsTheReference(dai_, 1e15);
    }

    // PROP-044 verifies: REQ-ROUTE-012
    /// @notice `check_PROP_044_litePsmGemAmtLargestNoOverflowFee0` at a LitePSM fee of 100 bps (`tout = 10¹⁶`).
    function check_PROP_044_litePsmGemAmtLargestNoOverflowFee100Bps(
        uint256 dai_
    ) public view {
        _gemAmtIsTheReference(dai_, 1e16);
    }

    /// @dev For `dai_ < 2^96`, the fee `tout` and `c = 10¹²` (USDC): `litePsmGemAmt(dai_, tout, c)` is `g = g0 + 1` when
    /// `cost(g0 + 1) ≤ dai_`, else `g0`, with `g0 = ⌊dai_ × 10¹⁸ / ((10¹⁸ + tout) × c)⌋` and
    /// `cost(x) = x × c + ⌊x × c × tout / 10¹⁸⌋`; and `litePsmCost` at `g` and at `g + 1` is `cost`. The code forms the
    /// same products and divisions, so each assertion holds by equal terms. MATH-ST-120
    /// (`docs/spec/05-verification/z3/settlement/st15_debt_asset_settlement.py`) proves with exact integers, for every
    /// `D < 2^128`, `tout < 10³⁶` and `1 ≤ c ≤ 10¹⁸`, that this `g` has `cost(g) ≤ D < cost(g + 1)` and that no step
    /// overflows (`(g0 + 1) × c ≤ D + c`, fee below `D + 10³⁶`). Together they give the assertions of the check before
    /// the split, `litePsmCost(g) ≤ dai_` and `litePsmCost(g + 1) > dai_`, which made the solver derive floor-division
    /// facts through division circuits. The assumptions hold for every input, so none removes one: `g0 ≤ dai_` (as
    /// `(10¹⁸ + tout) × c ≥ 10¹⁸`), and the 512-bit branch of each `Math.mulDiv` the code runs is ruled out
    /// (`_assumeExactProduct`) since `dai_ × 10¹⁸ < 2^156` and `g0 < 2^57`, so `(g0 + 2) × c × tout < 2^151`.
    function _gemAmtIsTheReference(
        uint256 dai_,
        uint256 tout
    ) internal view {
        vm.assume(dai_ < 2 ** 96);
        uint256 c = 1e12;
        uint256 g0;
        unchecked {
            g0 = dai_ * WAD / ((WAD + tout) * c);
        }
        vm.assume(g0 <= dai_);
        uint256 g = _cost(g0 + 1, tout, c) <= dai_ ? g0 + 1 : g0;
        unchecked {
            _assumeExactProduct(dai_, WAD);
            _assumeExactProduct((g0 + 1) * c, tout);
            _assumeExactProduct(g * c, tout);
            _assumeExactProduct((g + 1) * c, tout);
        }
        assert(math.litePsmGemAmt(dai_, tout, c) == g);
        assert(math.litePsmCost(g, tout, c) == _cost(g, tout, c));
        assert(math.litePsmCost(g + 1, tout, c) == _cost(g + 1, tout, c));
    }

    /// @dev The LitePSM cost of `x` gem units, `x × c + ⌊x × c × tout / 10¹⁸⌋`, in the shape `RouteMath.litePsmCost`
    /// computes it. Unchecked: the callers pass `x × c × tout < 2^151`.
    function _cost(
        uint256 x,
        uint256 tout,
        uint256 c
    ) internal pure returns (uint256) {
        unchecked {
            return x * c + x * c * tout / WAD;
        }
    }

    /// @dev Assumes `mulmod(x, y, 2^256 − 1) == x × y` (and `== y × x`). Every caller passes `x × y < 2^256 − 1`, where
    /// both sides are the exact product, so the assumption removes no input. It states, without a multiplication, the
    /// fact `Math.mulDiv` tests first: the high word of the 512-bit product is 0. Both operand orders are given because
    /// the optimizer may emit either order for the code's `x * y`.
    function _assumeExactProduct(
        uint256 x,
        uint256 y
    ) internal pure {
        unchecked {
            vm.assume(mulmod(x, y, type(uint256).max) == x * y);
            vm.assume(mulmod(x, y, type(uint256).max) == y * x);
        }
    }

    /// @dev Assumes `x × y / x == y` (both operand orders), the overflow test Solidity runs for a checked `x * y`.
    /// Every caller passes `x > 0` and `x × y < 2^256`, where the test passes, so the assumption removes no input.
    function _assumeNoMulOverflow(
        uint256 x,
        uint256 y
    ) internal pure {
        unchecked {
            vm.assume(x * y / x == y);
            vm.assume(y * x / x == y);
        }
    }
}
