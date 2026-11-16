// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV4PoolKey} from "../../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The PoolManager calls a test network's swaps need (v4-core v4.0.0 `IPoolManager`; `Currency` and `IHooks`
/// are addresses, `BalanceDelta` an `int256` holding amount0 in the upper and amount1 in the lower 128 bits).
interface IV4PoolManagerSwap {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(
        bytes calldata data
    ) external returns (bytes memory);

    function swap(
        UniswapV4PoolKey memory key,
        SwapParams memory params,
        bytes calldata hookData
    ) external returns (int256 delta);

    function sync(
        address currency
    ) external;

    function settle() external payable returns (uint256 paid);

    function take(
        address currency,
        address to,
        uint256 amount
    ) external;
}

/// @title UniswapV4PoolActor
/// @notice Swaps on a hookless Uniswap v4 pool of a test network (anvil) from its own balances, so the local
/// rehearsal can move a v4 pool's price and accrue fees on its positions, as the Uniswap v3 SwapRouter does for v3
/// pools. Anyone may call; whoever funds it (tokens by transfer or mint, ether by value or `anvil_setBalance`) pays the
/// swap, and the output stays here. Never deployed on Ethereum or Base.
contract UniswapV4PoolActor {
    IV4PoolManagerSwap public immutable POOL_MANAGER;

    error NotPoolManager();
    error PaymentFailed();

    constructor(
        address poolManager
    ) {
        POOL_MANAGER = IV4PoolManagerSwap(poolManager);
    }

    receive() external payable {}

    /// @notice Swaps on `key`'s pool: `amountSpecified` negative for an exact input, positive for an exact output, up
    /// to the price limit. Returns the pool's balance delta.
    function swap(
        UniswapV4PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96
    ) external returns (int256 delta) {
        bytes memory ret = POOL_MANAGER.unlock(
            abi.encode(key, IV4PoolManagerSwap.SwapParams(zeroForOne, amountSpecified, sqrtPriceLimitX96))
        );
        delta = abi.decode(ret, (int256));
    }

    function unlockCallback(
        bytes calldata data
    ) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        (UniswapV4PoolKey memory key, IV4PoolManagerSwap.SwapParams memory params) =
            abi.decode(data, (UniswapV4PoolKey, IV4PoolManagerSwap.SwapParams));
        int256 delta = POOL_MANAGER.swap(key, params, "");
        // BalanceDelta: amount0 in the upper 128 bits, amount1 in the lower 128.
        // forge-lint: disable-next-line(unsafe-typecast)
        _settle(key.currency0, int128(delta >> 128));
        // forge-lint: disable-next-line(unsafe-typecast)
        _settle(key.currency1, int128(delta));
        return abi.encode(delta);
    }

    /// @dev Takes a positive delta and pays a negative one (ether by value for the native currency).
    function _settle(
        address currency,
        int128 amount
    ) private {
        if (amount > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            POOL_MANAGER.take(currency, address(this), uint256(uint128(amount)));
            return;
        }
        if (amount == 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(uint128(-amount));
        if (currency == address(0)) {
            POOL_MANAGER.settle{value: owed}();
            return;
        }
        POOL_MANAGER.sync(currency);
        if (!IERC20(currency).transfer(address(POOL_MANAGER), owed)) revert PaymentFailed();
        POOL_MANAGER.settle();
    }
}
