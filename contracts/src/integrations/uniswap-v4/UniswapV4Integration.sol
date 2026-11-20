// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPVault} from "../../vault/LPVault.sol";
import {IUniswapV4PoolManager, UniswapV4PoolKey} from "../../dependencies/uniswap-v4/IUniswapV4PoolManager.sol";
import {IUniswapV4PositionManager} from "../../dependencies/uniswap-v4/IUniswapV4PositionManager.sol";
import {ClTickMath} from "../shared/ClTickMath.sol";
import {IUniswapV4Integration} from "./interfaces/IUniswapV4Integration.sol";
import {UniswapV4State} from "./UniswapV4State.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title UniswapV4Integration
/// @notice Uniswap v4 LPVault: the shared LPVault over the PositionManager, for hookless pools.
/// @dev Fees are taken in their own batch before every liquidity change, so each batch's token flow is exactly
/// principal and the LPVault measures it by balance. Native ETH is wrapped and unwrapped inside the PositionManager.
contract UniswapV4Integration is LPVault, IUniswapV4Integration {
    using SafeERC20 for IERC20;

    /// @dev PositionManager actions and constants (v4-periphery `Actions`, `ActionConstants`).
    uint8 internal constant INCREASE_LIQUIDITY = 0x00;
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant SETTLE = 0x0b;
    uint8 internal constant TAKE = 0x0e;
    uint8 internal constant TAKE_PAIR = 0x11;
    uint8 internal constant SWEEP = 0x14;
    uint8 internal constant WRAP = 0x15;
    uint8 internal constant UNWRAP = 0x16;
    uint256 internal constant OPEN_DELTA = 0;
    uint256 internal constant CONTRACT_BALANCE = 1 << 255;
    address internal constant ADDRESS_THIS = address(2);
    uint256 private constant Q96 = 1 << 96;

    IUniswapV4PoolManager internal immutable _PM;
    IUniswapV4PositionManager internal immutable _POSM;
    address internal immutable _WETH;

    mapping(bytes32 poolId => UniswapV4PoolKey key) internal _poolKeys;

    struct Batch {
        bytes actions;
        bytes[] params;
        uint256 n;
    }

    /// @notice Fixes the AccessManager and the PositionManager, with its PoolManager and wrapped native token.
    /// @dev Reverts `InvalidDeployment` for a PositionManager that is not a contract or names none.
    constructor(
        address authority,
        address positionManager
    ) LPVault(authority) {
        if (positionManager == address(0) || positionManager.code.length == 0) revert InvalidDeployment();
        address pm = IUniswapV4PositionManager(positionManager).poolManager();
        address weth = IUniswapV4PositionManager(positionManager).WETH9();
        if (pm.code.length == 0 || weth.code.length == 0) revert InvalidDeployment();
        _PM = IUniswapV4PoolManager(pm);
        _POSM = IUniswapV4PositionManager(positionManager);
        _WETH = weth;
    }

    /// @inheritdoc IUniswapV4Integration
    function registerPool(
        UniswapV4PoolKey calldata key
    ) external override returns (bytes32 poolId) {
        poolId = keccak256(abi.encode(key));
        (uint160 sqrtPriceX96,) = UniswapV4State.slot0(_PM, poolId);
        if (key.hooks != address(0) || sqrtPriceX96 == 0 || key.tickSpacing <= 0) revert UnsupportedPool(poolId);
        _poolKeys[poolId] = key;
        emit PoolRegistered(poolId, key.currency0, key.currency1, key.fee, key.tickSpacing);
    }

    /// @inheritdoc IUniswapV4Integration
    function poolKey(
        bytes32 poolId
    ) external view override returns (UniswapV4PoolKey memory) {
        return _poolKeys[poolId];
    }

    /// @inheritdoc IUniswapV4Integration
    function POOL_MANAGER() external view override returns (address) {
        return address(_PM);
    }

    /// @inheritdoc IUniswapV4Integration
    function POSITION_MANAGER() external view override returns (address) {
        return address(_POSM);
    }

    function _nft(
        bytes32 positionKey
    ) internal view override returns (IERC721, uint256) {
        return (IERC721(address(_POSM)), uint256(positionKey));
    }

    /// @dev A token never minted reads as pool 0.
    function _readPosition(
        bytes32 positionKey
    ) internal view override returns (bytes32 pool, int24 tickLower, int24 tickUpper, uint128 liquidity) {
        (UniswapV4PoolKey memory key, uint256 info) = _POSM.getPoolAndPositionInfo(uint256(positionKey));
        if (info == 0) return (bytes32(0), 0, 0, 0);
        (tickLower, tickUpper) = _ticksOf(info);
        pool = keccak256(abi.encode(key));
        liquidity = UniswapV4State.positionLiquidity(
            _PM, pool, UniswapV4State.positionId(address(_POSM), tickLower, tickUpper, positionKey)
        );
    }

    function _poolInfo(
        bytes32 pool
    ) internal view override returns (address token0, address token1, int24 tickSpacing) {
        UniswapV4PoolKey storage key = _poolKeys[pool];
        tickSpacing = key.tickSpacing;
        if (tickSpacing == 0) revert InvalidPool(pool);
        token0 = key.currency0 == address(0) ? _WETH : key.currency0;
        token1 = key.currency1;
    }

    /// @dev Takes the fees first, then pays the desired amounts into the PositionManager, settles the increase from
    /// its balance and sweeps the rest back.
    function _increase(
        Market storage m,
        bytes32 positionKey,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256,
        uint256
    ) internal override returns (uint128 liquidity, uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1) {
        (fee0, fee1) = _collect(m, positionKey);
        (, int24 tickLower, int24 tickUpper,) = _readPosition(positionKey);
        liquidity = _liquidityForAmounts(m.pool, tickLower, tickUpper, amount0Desired, amount1Desired);
        if (liquidity == 0) return (0, 0, 0, fee0, fee1);
        (amount0, amount1) = _payIn(m, positionKey, liquidity, amount0Desired, amount1Desired);
    }

    /// @dev Pays the desired amounts into the PositionManager, runs the increase and returns what was used.
    function _payIn(
        Market storage m,
        bytes32 positionKey,
        uint128 liquidity,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) private returns (uint256 amount0, uint256 amount1) {
        (uint256 b0, uint256 b1) = _balances(m);
        if (amount0Desired != 0) IERC20(m.token0).safeTransfer(address(_POSM), amount0Desired);
        if (amount1Desired != 0) IERC20(m.token1).safeTransfer(address(_POSM), amount1Desired);
        _run(_increaseBatch(m, positionKey, liquidity, amount0Desired, amount1Desired));
        (uint256 a0, uint256 a1) = _balances(m);
        (amount0, amount1) = (b0 - a0, b1 - a1);
    }

    /// @dev `[UNWRAP], INCREASE_LIQUIDITY, SETTLE ×2, [WRAP], SWEEP ×2`, settled from the PositionManager's balance.
    function _increaseBatch(
        Market storage m,
        bytes32 positionKey,
        uint128 liquidity,
        uint256 amount0Max,
        uint256 amount1Max
    ) private view returns (Batch memory b) {
        UniswapV4PoolKey storage key = _poolKeys[m.pool];
        bool native = key.currency0 == address(0);
        b = _batch(8);
        if (native) _push(b, UNWRAP, abi.encode(CONTRACT_BALANCE));
        _push(
            b,
            INCREASE_LIQUIDITY,
            abi.encode(
                uint256(positionKey),
                uint256(liquidity),
                SafeCast.toUint128(amount0Max),
                SafeCast.toUint128(amount1Max),
                bytes("")
            )
        );
        _push(b, SETTLE, abi.encode(key.currency0, OPEN_DELTA, false));
        _push(b, SETTLE, abi.encode(key.currency1, OPEN_DELTA, false));
        if (native) _push(b, WRAP, abi.encode(CONTRACT_BALANCE));
        _push(b, SWEEP, abi.encode(m.token0, address(this)));
        _push(b, SWEEP, abi.encode(m.token1, address(this)));
    }

    /// @dev Fees in one batch, then the principal in another; each is measured by the LPVault's balance.
    function _decrease(
        Market storage m,
        bytes32 positionKey,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) internal override returns (uint256 amount0, uint256 amount1, uint256 fee0, uint256 fee1) {
        (fee0, fee1) = _collect(m, positionKey);
        (amount0, amount1) = _take(m, positionKey, liquidity, amount0Min, amount1Min);
    }

    /// @dev A zero-liquidity decrease credits the fees; a position without liquidity is not touched.
    function _collect(
        Market storage m,
        bytes32 positionKey
    ) internal override returns (uint256 amount0, uint256 amount1) {
        (,,, uint128 live) = _readPosition(positionKey);
        if (live == 0) return (0, 0);
        return _take(m, positionKey, 0, 0, 0);
    }

    function _uncollectedFees(
        Market storage m,
        bytes32 positionKey
    ) internal view override returns (uint256 amount0, uint256 amount1) {
        (, uint256 info) = _POSM.getPoolAndPositionInfo(uint256(positionKey));
        (int24 tickLower, int24 tickUpper) = _ticksOf(info);
        bytes32 id = UniswapV4State.positionId(address(_POSM), tickLower, tickUpper, positionKey);
        UniswapV4State.PositionState memory p = UniswapV4State.position(_PM, m.pool, id);
        if (p.liquidity == 0) return (0, 0);
        (uint256 in0, uint256 in1) = UniswapV4State.feeGrowthInside(_PM, m.pool, tickLower, tickUpper);
        return UniswapV4State.feesOwed(p, in0, in1);
    }

    /// @dev Decreases by `liquidity` and takes both currencies to the LPVault; returns what arrived.
    function _take(
        Market storage m,
        bytes32 positionKey,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min
    ) private returns (uint256 amount0, uint256 amount1) {
        (uint256 b0, uint256 b1) = _balances(m);
        Batch memory b = _batch(5);
        _push(
            b,
            DECREASE_LIQUIDITY,
            abi.encode(
                uint256(positionKey),
                uint256(liquidity),
                SafeCast.toUint128(amount0Min),
                SafeCast.toUint128(amount1Min),
                bytes("")
            )
        );
        address c0 = _poolKeys[m.pool].currency0;
        if (c0 != address(0)) {
            _push(b, TAKE_PAIR, abi.encode(c0, m.token1, address(this)));
        } else {
            _push(b, TAKE, abi.encode(address(0), ADDRESS_THIS, OPEN_DELTA));
            _push(b, WRAP, abi.encode(CONTRACT_BALANCE));
            _push(b, TAKE, abi.encode(m.token1, address(this), OPEN_DELTA));
            _push(b, SWEEP, abi.encode(_WETH, address(this)));
        }
        _run(b);
        (uint256 a0, uint256 a1) = _balances(m);
        (amount0, amount1) = (a0 - b0, a1 - b1);
    }

    /// @dev Uniswap's `LiquidityAmounts.getLiquidityForAmounts` at the pool's price, rounded down.
    function _liquidityForAmounts(
        bytes32 pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) private view returns (uint128) {
        (uint160 sqrtP,) = UniswapV4State.slot0(_PM, pool);
        uint256 sa = ClTickMath.getSqrtPriceAtTick(tickLower);
        uint256 sb = ClTickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtP <= sa) return SafeCast.toUint128(_liquidity0(sa, sb, amount0));
        if (sqrtP >= sb) return SafeCast.toUint128(Math.mulDiv(amount1, Q96, sb - sa));
        uint256 l0 = _liquidity0(sqrtP, sb, amount0);
        uint256 l1 = Math.mulDiv(amount1, Q96, sqrtP - sa);
        return SafeCast.toUint128(l0 < l1 ? l0 : l1);
    }

    function _liquidity0(
        uint256 sa,
        uint256 sb,
        uint256 amount0
    ) private pure returns (uint256) {
        return Math.mulDiv(amount0, Math.mulDiv(sa, sb, Q96), sb - sa);
    }

    function _balances(
        Market storage m
    ) private view returns (uint256, uint256) {
        return (IERC20(m.token0).balanceOf(address(this)), IERC20(m.token1).balanceOf(address(this)));
    }

    function _batch(
        uint256 capacity
    ) private pure returns (Batch memory b) {
        b.params = new bytes[](capacity);
    }

    function _push(
        Batch memory b,
        uint8 action,
        bytes memory params
    ) private pure {
        b.actions = abi.encodePacked(b.actions, action);
        b.params[b.n++] = params;
    }

    function _run(
        Batch memory b
    ) private {
        bytes[] memory params = b.params;
        uint256 n = b.n;
        // Shrinks the array to the actions pushed.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            mstore(params, n)
        }
        _POSM.modifyLiquidities(abi.encode(b.actions, params), block.timestamp);
    }

    function _ticksOf(
        uint256 info
    ) private pure returns (int24 tickLower, int24 tickUpper) {
        // 24-bit two's-complement fields at offsets 8 and 32.
        // forge-lint: disable-next-line(unsafe-typecast)
        tickLower = int24(int256(info >> 8));
        // forge-lint: disable-next-line(unsafe-typecast)
        tickUpper = int24(int256(info >> 32));
    }
}
