// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ClPriceMath} from "../../../src/amm/concentrated-liquidity/ClPriceMath.sol";
import {AvanaTest} from "../AvanaTest.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice The Uniswap v3 core factory functions the fixture calls (`out-univ3/` build of the pinned release).
interface IClFactory {
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address pool);

    function enableFeeAmount(
        uint24 fee,
        int24 tickSpacing
    ) external;
}

/// @notice The Uniswap v3 core pool functions the fixture calls.
interface IClPool {
    function token0() external view returns (address);

    function token1() external view returns (address);

    function tickSpacing() external view returns (int24);

    function liquidity() external view returns (uint128);

    function slot0()
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint16 index, uint16 card, uint16 cardNext, uint8 fee, bool unlocked);

    function initialize(
        uint160 sqrtPriceX96
    ) external;

    function increaseObservationCardinalityNext(
        uint16 next
    ) external;

    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    function burn(
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external returns (uint256 amount0, uint256 amount1);

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

    function observe(
        uint32[] calldata secondsAgos
    ) external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @notice An ERC-20 with chosen decimals whose supply the fixture mints freely.
contract ClTestToken is ERC20 {
    uint8 internal immutable _DEC;

    constructor(
        string memory symbol_,
        uint8 decimals_
    ) ERC20(symbol_, symbol_) {
        _DEC = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DEC;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @notice Mints, swaps and flashes on real Uniswap v3 pools and pays their callbacks from its own balance. A flash
/// runs `target.call(data)` inside the pool's callback, while the pool's lock is held, and keeps the result.
contract ClPoolActor {
    address internal _target;
    bytes internal _data;
    bool public lastOk;
    bytes public lastResult;

    function mint(
        IClPool pool,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) external returns (uint256 a0, uint256 a1) {
        (a0, a1) = pool.mint(address(this), lower, upper, liquidity, abi.encode(pool));
    }

    function burn(
        IClPool pool,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) external returns (uint256 a0, uint256 a1) {
        (a0, a1) = pool.burn(lower, upper, liquidity);
    }

    function swap(
        IClPool pool,
        bool zeroForOne,
        int256 amount,
        uint160 limit
    ) external returns (int256 a0, int256 a1) {
        (a0, a1) = pool.swap(address(this), zeroForOne, amount, limit, abi.encode(pool));
    }

    function flash(
        IClPool pool,
        uint256 amount0,
        uint256 amount1,
        address target,
        bytes calldata data
    ) external {
        (_target, _data) = (target, data);
        pool.flash(address(this), amount0, amount1, abi.encode(pool, amount0, amount1));
    }

    function uniswapV3MintCallback(
        uint256 owed0,
        uint256 owed1,
        bytes calldata
    ) external {
        _pay(IClPool(msg.sender), owed0, owed1);
    }

    function uniswapV3SwapCallback(
        int256 d0,
        int256 d1,
        bytes calldata
    ) external {
        _pay(IClPool(msg.sender), d0 > 0 ? uint256(d0) : 0, d1 > 0 ? uint256(d1) : 0);
    }

    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes calldata data
    ) external {
        (, uint256 amount0, uint256 amount1) = abi.decode(data, (address, uint256, uint256));
        (lastOk, lastResult) = _target.call(_data);
        _pay(IClPool(msg.sender), amount0 + fee0, amount1 + fee1);
    }

    function _pay(
        IClPool pool,
        uint256 a0,
        uint256 a1
    ) internal {
        if (a0 > 0) ClTestToken(pool.token0()).transfer(address(pool), a0);
        if (a1 > 0) ClTestToken(pool.token1()).transfer(address(pool), a1);
    }
}

/// @notice Real Uniswap v3 pools for the concentrated-liquidity LPOracle: the factory and pools of the pinned
/// `uniswap-v3-core` release, built with Solidity 0.7.6 into `out-univ3/` (`FOUNDRY_PROFILE=univ3 forge build`).
/// @dev A pool is created at a time `T` in the past, initialized at the oracle square-root price of the given
/// 8-decimal prices, given an observation buffer of `cardinality` slots and liquidity on its full range, and then
/// swapped once a block later so the buffer reaches its size; `observe([1800, 0])` then works from `T + 1800` on.
abstract contract ClPoolFixture is AvanaTest {
    IClFactory internal factory;
    ClPoolActor internal actor;

    function _deployFactory() internal {
        factory = IClFactory(deployCode("out-univ3/UniswapV3Factory.sol/UniswapV3Factory.json"));
        factory.enableFeeAmount(100, 1);
        actor = new ClPoolActor();
        vm.label(address(factory), "UniswapV3Factory");
        vm.label(address(actor), "PoolActor");
    }

    /// @dev Two tokens in pool order: `(token0, token1)` sorted by address.
    function _sortedTokens(
        string memory symA,
        uint8 decA,
        string memory symB,
        uint8 decB
    ) internal returns (ClTestToken a, ClTestToken b, bool aIsToken0) {
        a = new ClTestToken(symA, decA);
        b = new ClTestToken(symB, decB);
        aIsToken0 = address(a) < address(b);
        vm.label(address(a), symA);
        vm.label(address(b), symB);
    }

    /// @dev Creates `pool` for `t0`/`t1` (pool order) at `fee`, initialized at the prices `p0`, `p1`, with `cardinality`
    /// observation slots and `liquidity` on the full range of its spacing.
    function _createPool(
        ClTestToken t0,
        ClTestToken t1,
        uint24 fee,
        uint256 p0,
        uint256 p1,
        uint16 cardinality,
        uint128 liquidity
    ) internal returns (IClPool pool) {
        pool = IClPool(factory.createPool(address(t0), address(t1), fee));
        pool.initialize(ClPriceMath.oracleSqrtPrice(p0, p1, t0.decimals(), t1.decimals()));
        pool.increaseObservationCardinalityNext(cardinality);
        t0.mint(address(actor), type(uint128).max);
        t1.mint(address(actor), type(uint128).max);
        int24 s = pool.tickSpacing();
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 top = (ClPriceMath.MAX_TICK / s) * s;
        if (liquidity > 0) actor.mint(pool, -top, top, liquidity);
        vm.label(address(pool), "UniswapV3Pool");
    }

    /// @dev A small full-range mint a block later: a position change around the current tick always writes an
    /// observation (a swap writes one only when it moves the tick), which grows the buffer to its next size.
    function _touch(
        IClPool pool
    ) internal {
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
        int24 s = pool.tickSpacing();
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 top = (ClPriceMath.MAX_TICK / s) * s;
        actor.mint(pool, -top, top, 1e6);
    }

    /// @dev Swaps the pool to `target` (exact square-root price) with unlimited input. Reads only the first word of
    /// `slot0()`, so a Slipstream pool (six words, no protocol fee) is swapped as a Uniswap v3 pool is.
    function _swapTo(
        IClPool pool,
        uint160 target
    ) internal {
        (bool ok, bytes memory ret) = address(pool).staticcall(abi.encodeCall(IClPool.slot0, ()));
        require(ok && ret.length >= 32, "slot0");
        uint160 now_ = abi.decode(ret, (uint160));
        if (target == now_) return;
        actor.swap(pool, target < now_, type(int128).max, target);
    }
}
