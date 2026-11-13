// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegrationHooks} from "../../src/amm/IAmmIntegrationHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice The swap and flash entry points shared by Uniswap v3 pools and Aerodrome Slipstream CL pools.
interface IClPoolActions {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);
    function flash(
        address recipient,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

/// @title ClPoolMover
/// @notice A fork-test actor on a real concentrated-liquidity pool (Uniswap v3 or Slipstream, which keep the
/// `uniswapV3SwapCallback` and `uniswapV3FlashCallback` names): moves the spot price with a real swap it pays for, and
/// inside a real `flash` (the pool's reentrancy flag set) probes an AMM integration's `checkReadSafe`.
contract ClPoolMover {
    using SafeERC20 for IERC20;

    uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    /// @notice The revert selector `checkReadSafe` gave inside the last flash (zero when it did not revert).
    bytes4 public probed;
    bool public probeRan;

    /// @notice Sells `amountIn` of token0 (`zeroForOne`) or token1 into `pool`, paid from this contract's balance.
    function move(
        IClPoolActions pool,
        bool zeroForOne,
        uint256 amountIn
    ) external {
        pool.swap(
            address(this),
            zeroForOne,
            int256(amountIn),
            zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1,
            abi.encode(address(pool))
        );
    }

    /// @notice Flash-borrows one raw unit of each token and calls `integration.checkReadSafe(marketId)` while the pool
    /// is locked; repays the loan and fee from this contract's balance.
    function probeLocked(
        IClPoolActions pool,
        IAmmIntegrationHooks integration,
        uint256 marketId
    ) external {
        probeRan = false;
        probed = bytes4(0);
        pool.flash(address(this), 1, 1, abi.encode(address(pool), address(integration), marketId));
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        address pool = abi.decode(data, (address));
        require(msg.sender == pool, "pool only");
        if (amount0Delta > 0) IERC20(IClPoolActions(pool).token0()).safeTransfer(pool, uint256(amount0Delta));
        if (amount1Delta > 0) IERC20(IClPoolActions(pool).token1()).safeTransfer(pool, uint256(amount1Delta));
    }

    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external {
        (address pool, address integration, uint256 marketId) = abi.decode(data, (address, address, uint256));
        require(msg.sender == pool, "pool only");
        try IAmmIntegrationHooks(integration).checkReadSafe(marketId) {}
        catch (bytes memory reason) {
            probed = bytes4(reason);
        }
        probeRan = true;
        IERC20(IClPoolActions(pool).token0()).safeTransfer(pool, 1 + fee0);
        IERC20(IClPoolActions(pool).token1()).safeTransfer(pool, 1 + fee1);
    }
}
