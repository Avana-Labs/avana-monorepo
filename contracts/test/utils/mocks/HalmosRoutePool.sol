// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IUniswapV3SwapCallback} from "../../../src/interfaces/external/uniswap/IUniswapV3SwapCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title HalmosRoutePool
/// @notice A concentrated-liquidity pool for symbolic route checks: it pays a preset amount `payOut` of the other token
/// whatever the input (any pool outcome, a sandwich included), takes the whole input through the swap callback, and
/// checks it was paid, as a Uniswap v3 pool does. Linear arithmetic only, so solvers stay fast.
contract HalmosRoutePool {
    address public immutable token0;
    address public immutable token1;
    /// @notice Fee and tick spacing the pinned factory stand-in keys the pool by.
    uint24 public constant fee = 100;
    int24 public constant tickSpacing = 1;
    uint256 public payOut;
    /// @notice When non-zero, the owed amount the pool reports in the callback instead of the input (a hostile pool);
    /// the payment check is then skipped.
    int256 public owedOverride;

    constructor(
        address tokenA,
        address tokenB
    ) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function setPayOut(
        uint256 amount
    ) external {
        payOut = amount;
    }

    function setOwedOverride(
        int256 owed
    ) external {
        owedOverride = owed;
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        uint256 inAmt = uint256(amountSpecified);
        (address tin, address tout) = zeroForOne ? (token0, token1) : (token1, token0);
        if (payOut != 0) IERC20(tout).transfer(recipient, payOut);
        int256 owed = owedOverride != 0 ? owedOverride : amountSpecified;
        (amount0, amount1) = zeroForOne ? (owed, -int256(payOut)) : (-int256(payOut), owed);
        uint256 before = IERC20(tin).balanceOf(address(this));
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        if (owedOverride == 0) require(IERC20(tin).balanceOf(address(this)) >= before + inAmt, "IIA");
    }
}
