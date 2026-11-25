// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Flash-swap callee of the mock pair (v2-core's `uniswapV2Call`).
interface IMockUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}

/// @notice Uniswap v2-core factory, ported to 0.8: `createPair`, `getPair` both ways, `feeTo`.
contract MockUniswapV2Factory {
    address public feeTo;
    mapping(address => mapping(address => address)) public getPair;

    function setFeeTo(
        address to
    ) external {
        feeTo = to;
    }

    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pair = address(new MockUniswapV2Pair(t0, t1));
        getPair[t0][t1] = pair;
        getPair[t1][t0] = pair;
    }

    /// @notice Registers any address as the pair of two tokens (a malformed factory entry).
    function setPair(
        address tokenA,
        address tokenB,
        address pair
    ) external {
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

/// @notice Uniswap v2-core pair, ported to 0.8 with the same arithmetic: `mint`, `burn` (pro rata, rounded down),
/// `swap` with the 0.3% fee and the flash-swap callback, `skim`, `sync`, the protocol fee of `_mintFee` and the lock.
/// Price accumulators are left out. The LP minimum is locked at `0xdead` (OpenZeppelin refuses address 0).
contract MockUniswapV2Pair is ERC20 {
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint112 private _reserve0;
    uint112 private _reserve1;
    uint256 public kLast;
    bool private _locked;

    modifier lock() {
        require(!_locked, "UniswapV2: LOCKED");
        _locked = true;
        _;
        _locked = false;
    }

    constructor(
        address t0,
        address t1
    ) ERC20("Uniswap V2", "UNI-V2") {
        (factory, token0, token1) = (msg.sender, t0, t1);
    }

    function getReserves() public view returns (uint112, uint112, uint32) {
        return (_reserve0, _reserve1, uint32(block.timestamp));
    }

    function mint(
        address to
    ) external lock returns (uint256 liquidity) {
        (uint112 r0, uint112 r1,) = getReserves();
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 a0 = b0 - r0;
        uint256 a1 = b1 - r1;
        bool feeOn = _mintFee(r0, r1);
        uint256 supply = totalSupply();
        if (supply == 0) {
            liquidity = Math.sqrt(a0 * a1) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
        } else {
            liquidity = Math.min(a0 * supply / r0, a1 * supply / r1);
        }
        require(liquidity > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED");
        _mint(to, liquidity);
        _update(b0, b1);
        if (feeOn) kLast = uint256(_reserve0) * _reserve1;
    }

    function burn(
        address to
    ) external lock returns (uint256 a0, uint256 a1) {
        (uint112 r0, uint112 r1,) = getReserves();
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 liquidity = balanceOf(address(this));
        bool feeOn = _mintFee(r0, r1);
        uint256 supply = totalSupply();
        a0 = liquidity * b0 / supply;
        a1 = liquidity * b1 / supply;
        require(a0 > 0 && a1 > 0, "UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED");
        _burn(address(this), liquidity);
        IERC20(token0).transfer(to, a0);
        IERC20(token1).transfer(to, a1);
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
        if (feeOn) kLast = uint256(_reserve0) * _reserve1;
    }

    function swap(
        uint256 out0,
        uint256 out1,
        address to,
        bytes calldata data
    ) external lock {
        require(out0 > 0 || out1 > 0, "UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT");
        (uint112 r0, uint112 r1,) = getReserves();
        require(out0 < r0 && out1 < r1, "UniswapV2: INSUFFICIENT_LIQUIDITY");
        if (out0 > 0) IERC20(token0).transfer(to, out0);
        if (out1 > 0) IERC20(token1).transfer(to, out1);
        if (data.length > 0) IMockUniswapV2Callee(to).uniswapV2Call(msg.sender, out0, out1, data);
        uint256 b0 = IERC20(token0).balanceOf(address(this));
        uint256 b1 = IERC20(token1).balanceOf(address(this));
        uint256 in0 = b0 > r0 - out0 ? b0 - (r0 - out0) : 0;
        uint256 in1 = b1 > r1 - out1 ? b1 - (r1 - out1) : 0;
        require(in0 > 0 || in1 > 0, "UniswapV2: INSUFFICIENT_INPUT_AMOUNT");
        uint256 adj0 = b0 * 1000 - in0 * 3;
        uint256 adj1 = b1 * 1000 - in1 * 3;
        require(adj0 * adj1 >= uint256(r0) * r1 * 1000 ** 2, "UniswapV2: K");
        _update(b0, b1);
    }

    function skim(
        address to
    ) external lock {
        IERC20(token0).transfer(to, IERC20(token0).balanceOf(address(this)) - _reserve0);
        IERC20(token1).transfer(to, IERC20(token1).balanceOf(address(this)) - _reserve1);
    }

    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)));
    }

    function _update(
        uint256 b0,
        uint256 b1
    ) private {
        require(b0 <= type(uint112).max && b1 <= type(uint112).max, "UniswapV2: OVERFLOW");
        (_reserve0, _reserve1) = (uint112(b0), uint112(b1));
    }

    function _mintFee(
        uint112 r0,
        uint112 r1
    ) private returns (bool feeOn) {
        address feeTo = MockUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 kl = kLast;
        if (feeOn) {
            if (kl != 0) {
                uint256 rootK = Math.sqrt(uint256(r0) * r1);
                uint256 rootKLast = Math.sqrt(kl);
                if (rootK > rootKLast) {
                    uint256 liquidity = totalSupply() * (rootK - rootKLast) / (rootK * 5 + rootKLast);
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (kl != 0) {
            kLast = 0;
        }
    }
}

/// @notice A pair-shaped contract outside the factory: the same tokens and reserves as a real pair (malformed pair).
contract FakeUniswapV2Pair is ERC20 {
    address public immutable token0;
    address public immutable token1;
    uint112 public r0;
    uint112 public r1;

    constructor(
        address t0,
        address t1
    ) ERC20("Fake V2", "FAKE-V2") {
        (token0, token1) = (t0, t1);
    }

    function setReserves(
        uint112 a,
        uint112 b
    ) external {
        (r0, r1) = (a, b);
    }

    function mintLp(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, 0);
    }

    /// @notice `kLast` as v2-core keeps it; 0 unless set.
    uint256 public kLast;

    function setKLast(
        uint256 k
    ) external {
        kLast = k;
    }
}

/// @notice ERC-20 whose balances all scale by a share factor the owner can lower (a negative rebase).
contract RebasingToken is ERC20 {
    uint256 public scaleBps = 10_000;

    constructor() ERC20("Rebase", "REB") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount * 10_000 / scaleBps);
    }

    function rebase(
        uint256 bps
    ) external {
        scaleBps = bps;
    }

    function balanceOf(
        address a
    ) public view override returns (uint256) {
        return super.balanceOf(a) * scaleBps / 10_000;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        super._update(from, to, value * 10_000 / scaleBps);
    }
}
