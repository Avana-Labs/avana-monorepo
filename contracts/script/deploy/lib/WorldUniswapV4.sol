// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV4PoolKey} from "../../../src/dependencies/uniswap-v4/IUniswapV4PoolManager.sol";
import {UniswapV4PoolActor} from "../local/UniswapV4PoolActor.sol";
import {DeployBase} from "./DeployBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IV4PoolManagerInit {
    function initialize(
        UniswapV4PoolKey memory key,
        uint160 sqrtPriceX96
    ) external returns (int24 tick);
}

interface IV4PositionManagerMint {
    function modifyLiquidities(
        bytes calldata unlockData,
        uint256 deadline
    ) external payable;
}

/// @notice Permit2's `approve` (`IAllowanceTransfer`, Uniswap/permit2 cc56ad0).
interface IPermit2Approve {
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;
}

/// @title WorldUniswapV4
/// @notice Uniswap v4 on a test network, from the pinned builds: Permit2 (cc56ad0, `out-permit2/`), and v4 core v4.0.0
/// and periphery 1.0.1 (`out-univ4/`): the PoolManager, the PositionManager (unsubscribe gas limit 100,000, no token
/// descriptor, the world's WETH as WETH9) and StateView. Pools are hookless; each is initialized at a given price and
/// gets a full-range position minted through the PositionManager, paid through Permit2 (native ETH by value).
abstract contract WorldUniswapV4 is DeployBase {
    string internal constant UNIV4_OUT = "out-univ4";
    /// @dev PositionManager actions (v4-periphery 1.0.1) and its `msg.sender` placeholder.
    uint8 internal constant V4_MINT_POSITION = 0x02;
    uint8 internal constant V4_SETTLE_PAIR = 0x0d;
    uint8 internal constant V4_SWEEP = 0x14;
    address internal constant V4_MSG_SENDER = address(1);

    address internal permit2;
    address internal v4PoolManager;
    address internal v4PositionManager;
    address internal v4StateView;
    /// @notice The rehearsal's swap helper on the PoolManager (`local/UniswapV4PoolActor.sol`, a test-network stand-in).
    address internal v4PoolActor;

    /// @param owner The PoolManager's protocol-fee owner.
    /// @param weth The PositionManager's WETH9 (deposit and withdraw), which the Uniswap v4 LPVault reads as its wrapped
    /// native token.
    function _uniswapV4Core(
        address owner,
        address weth
    ) internal {
        permit2 = _deploy("Permit2", _artifactIn("out-permit2", "Permit2.sol", "Permit2"));
        v4PoolManager = _deploy(
            "UniswapV4PoolManager",
            bytes.concat(_artifactIn(UNIV4_OUT, "PoolManager.sol", "PoolManager"), abi.encode(owner))
        );
        v4PositionManager = _deploy(
            "UniswapV4PositionManager",
            bytes.concat(
                _artifactIn(UNIV4_OUT, "PositionManager.sol", "PositionManager"),
                abi.encode(v4PoolManager, permit2, uint256(100_000), address(0), weth)
            )
        );
        v4StateView = _deploy(
            "UniswapV4StateView",
            bytes.concat(_artifactIn(UNIV4_OUT, "StateView.sol", "StateView"), abi.encode(v4PoolManager))
        );
        v4PoolActor = address(new UniswapV4PoolActor(v4PoolManager));
    }

    /// @notice Initializes hookless `key` at `sqrtPriceX96` and mints a full-range position of at most `amount0` and
    /// `amount1` to `owner`; the sender holds both amounts (ether for a native `currency0`).
    function _v4Pool(
        UniswapV4PoolKey memory key,
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1,
        address owner
    ) internal {
        require(key.hooks == address(0), "world v4 pools are hookless");
        IV4PoolManagerInit(v4PoolManager).initialize(key, sqrtPriceX96);
        int24 upper = (887_272 / key.tickSpacing) * key.tickSpacing;
        if (key.currency0 != address(0)) _permit2Approve(key.currency0, amount0);
        _permit2Approve(key.currency1, amount1);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            key,
            -upper,
            upper,
            uint256(_fullRangeLiquidity(sqrtPriceX96, amount0, amount1)),
            uint128(amount0),
            uint128(amount1),
            owner,
            bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        // Ether left after the settlement goes back to the sender.
        params[2] = abi.encode(address(0), V4_MSG_SENDER);
        uint256 value = key.currency0 == address(0) ? amount0 : 0;
        IV4PositionManagerMint(v4PositionManager).modifyLiquidities{value: value}(
            abi.encode(abi.encodePacked(V4_MINT_POSITION, V4_SETTLE_PAIR, V4_SWEEP), params), block.timestamp + 1 days
        );
    }

    function _permit2Approve(
        address token,
        uint256 amount
    ) private {
        IERC20(token).approve(permit2, amount);
        IPermit2Approve(permit2).approve(token, v4PositionManager, uint160(amount), uint48(block.timestamp + 1 days));
    }

    /// @notice The liquidity a full-range position takes from `amount0` and `amount1` at `sqrtPriceX96`, 0.1 % below the
    /// bound so the rounded-up amounts stay within them: the full range needs less than `L·2^96/√P` of token0 and
    /// `L·√P/2^96` of token1.
    function _fullRangeLiquidity(
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1
    ) private pure returns (uint128) {
        uint256 l0 = Math.mulDiv(amount0, sqrtPriceX96, 2 ** 96);
        uint256 l1 = Math.mulDiv(amount1, 2 ** 96, sqrtPriceX96);
        uint256 l = (Math.min(l0, l1) * 999) / 1000;
        require(l > 0 && l <= type(uint128).max, "world v4 pool liquidity out of range");
        return uint128(l);
    }
}
