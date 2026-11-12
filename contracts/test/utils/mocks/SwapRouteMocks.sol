// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IUniswapV3SwapCallback} from "../../../src/interfaces/external/uniswap/IUniswapV3SwapCallback.sol";
import {ISettlementRoute} from "../../../src/liquidation/settlement-routes/ISettlementRoute.sol";
import {ILock} from "../../../src/lock/lock/ILock.sol";
import {PayoutToken} from "./PayoutToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockRouteCaller
/// @notice Stand-in for LPVaultSwap (contract 23 is not written yet): it is the Lock's LPVaultSwap member and calls a
/// route the way 2.11 does, with an exact allowance of `amountIn` that it resets after the call (REQ-ROUTE-035), and
/// measures its own balance delta of the debt asset.
contract MockRouteCaller {
    using SafeERC20 for IERC20;

    ILock public lock;

    function setLock(
        ILock lock_
    ) external {
        require(address(lock) == address(0), "lock set");
        lock = lock_;
    }

    /// @notice Production path: acquire the Lock, swap, release.
    function swapUnderLock(
        ISettlementRoute route,
        uint256 amountIn,
        uint256 minOut
    ) external returns (uint256 out) {
        lock.acquire();
        out = _swap(route, amountIn, minOut);
        lock.release();
    }

    /// @notice A swap without acquiring: used when the AaveAdapter already holds the Lock (repay with collateral), and
    /// to show a call with the Lock free is refused.
    function swapHeld(
        ISettlementRoute route,
        uint256 amountIn,
        uint256 minOut
    ) external returns (uint256 out) {
        out = _swap(route, amountIn, minOut);
    }

    /// @notice A swap that leaves the allowance in place (to check the route pulls exactly `amountIn`).
    function swapWithAllowance(
        ISettlementRoute route,
        uint256 allowance,
        uint256 amountIn,
        uint256 minOut
    ) external returns (uint256 out) {
        lock.acquire();
        IERC20(route.tokenIn()).forceApprove(address(route), allowance);
        out = route.swap(amountIn, minOut);
        IERC20(route.tokenIn()).forceApprove(address(route), 0);
        lock.release();
    }

    function _swap(
        ISettlementRoute route,
        uint256 amountIn,
        uint256 minOut
    ) private returns (uint256 out) {
        IERC20 tokenIn = IERC20(route.tokenIn());
        tokenIn.forceApprove(address(route), amountIn);
        out = route.swap(amountIn, minOut);
        tokenIn.forceApprove(address(route), 0);
    }
}

/// @title MockCLPool
/// @notice A Uniswap v3 / Slipstream pool stand-in with a fixed rate (`out = in × num / den`) and an optional input
/// cap that models a pool running out of liquidity at the price limit. It sends the output first, then calls
/// `uniswapV3SwapCallback` on the caller and checks it was paid, as the real pool does. Hostile modes ask for too much,
/// call back twice, ask on the wrong side or skip the callback.
contract MockCLPool {
    enum Mode {
        Normal,
        OverAsk,
        DoubleCallback,
        WrongSide,
        NoCallback
    }

    address public immutable token0;
    address public immutable token1;
    /// @notice Fee and tick spacing the pinned factory stand-in keys the pool by.
    uint24 public fee = 500;
    int24 public tickSpacing = 10;
    uint256 public num = 1;
    uint256 public den = 1;
    uint256 public maxIn = type(uint256).max;
    Mode public mode;
    uint160 public lastLimit;
    bool public lastZeroForOne;
    uint256 public swaps;

    constructor(
        address tokenA,
        address tokenB
    ) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function setRate(
        uint256 num_,
        uint256 den_
    ) external {
        (num, den) = (num_, den_);
    }

    function setMaxIn(
        uint256 maxIn_
    ) external {
        maxIn = maxIn_;
    }

    function setMode(
        Mode mode_
    ) external {
        mode = mode_;
    }

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        require(amountSpecified > 0, "exact input only");
        lastLimit = sqrtPriceLimitX96;
        lastZeroForOne = zeroForOne;
        ++swaps;
        uint256 inAmt = uint256(amountSpecified) < maxIn ? uint256(amountSpecified) : maxIn;
        uint256 out = inAmt * num / den;
        (address tin, address tout) = zeroForOne ? (token0, token1) : (token1, token0);
        if (out != 0) IERC20(tout).transfer(recipient, out);
        uint256 owed = mode == Mode.OverAsk ? inAmt + 1 : inAmt;
        (amount0, amount1) = zeroForOne ? (int256(owed), -int256(out)) : (-int256(out), int256(owed));
        if (mode == Mode.WrongSide) (amount0, amount1) = (amount1, amount0);
        uint256 before = IERC20(tin).balanceOf(address(this));
        if (mode != Mode.NoCallback) IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        if (mode == Mode.DoubleCallback) {
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        }
        require(IERC20(tin).balanceOf(address(this)) >= before + inAmt, "IIA");
    }

    /// @notice Calls the route's callback directly, as an attacker contract posing as a pool would.
    function poke(
        address route,
        int256 amount0,
        int256 amount1
    ) external {
        IUniswapV3SwapCallback(route).uniswapV3SwapCallback(amount0, amount1, "");
    }
}

/// @title MockCurvePool
/// @notice A Curve StableSwap-NG plain-pool stand-in: `coins(i)`, and `exchange(i, j, dx, min_dy)` at a fixed rate,
/// pulling `dx` with `transferFrom` and paying `msg.sender`.
contract MockCurvePool {
    address[] internal _coins;
    uint256 public num = 1;
    uint256 public den = 1;
    uint256 public lastMinDy;
    bool public halted;

    constructor(
        address[] memory coins_
    ) {
        _coins = coins_;
    }

    function coins(
        uint256 i
    ) external view returns (address) {
        return _coins[i];
    }

    function setRate(
        uint256 num_,
        uint256 den_
    ) external {
        (num, den) = (num_, den_);
    }

    function setHalted(
        bool on
    ) external {
        halted = on;
    }

    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 minDy
    ) external returns (uint256 dy) {
        require(!halted, "halted");
        lastMinDy = minDy;
        IERC20(_coins[uint256(int256(i))]).transferFrom(msg.sender, address(this), dx);
        dy = dx * num / den;
        require(dy >= minDy, "Exchange resulted in fewer coins than expected");
        if (dy != 0) IERC20(_coins[uint256(int256(j))]).transfer(msg.sender, dy);
    }
}

/// @title MockVault4626
/// @notice An ERC-4626 vault stand-in (a static aToken or a savings-rate token) on OpenZeppelin's ERC4626, with a pause
/// switch on deposit and redeem.
contract MockVault4626 is ERC4626 {
    bool public paused;

    constructor(
        IERC20 asset_,
        string memory name_
    ) ERC4626(asset_) ERC20(name_, name_) {}

    function setPaused(
        bool on
    ) external {
        paused = on;
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets,
        uint256 shares
    ) internal override {
        require(!paused, "paused");
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override {
        require(!paused, "paused");
        super._withdraw(caller, receiver, owner, assets, shares);
    }
}

/// @title MockGsm
/// @notice A GHO Stability Module stand-in following `Gsm._sellAsset` (gho-core c6335a0): frozen and seized checks,
/// a sold amount rounded down to a lot size (the rest stays with the seller), a zero sale refused, the exposure cap,
/// the underlying pulled with `transferFrom` and GHO minted to the receiver at `num / den` per unit.
contract MockGsm {
    address public immutable UNDERLYING_ASSET;
    address public immutable GHO_TOKEN;
    bool public frozen;
    bool public seized;
    uint256 public cap = type(uint128).max;
    uint256 public exposure;
    uint256 public lot = 1;
    uint256 public num = 1;
    uint256 public den = 1;

    constructor(
        address underlying,
        address gho
    ) {
        UNDERLYING_ASSET = underlying;
        GHO_TOKEN = gho;
    }

    function setFrozen(
        bool on
    ) external {
        frozen = on;
    }

    function setSeized(
        bool on
    ) external {
        seized = on;
    }

    function setCap(
        uint256 cap_
    ) external {
        cap = cap_;
    }

    function setLot(
        uint256 lot_
    ) external {
        lot = lot_;
    }

    function setRate(
        uint256 num_,
        uint256 den_
    ) external {
        (num, den) = (num_, den_);
    }

    function sellAsset(
        uint256 maxAmount,
        address receiver
    ) external returns (uint256, uint256) {
        require(!frozen, "GSM_FROZEN");
        require(!seized, "GSM_SEIZED");
        uint256 sold = maxAmount - maxAmount % lot;
        require(sold > 0, "INVALID_AMOUNT");
        require(exposure + sold <= cap, "EXOGENOUS_ASSET_EXPOSURE_TOO_HIGH");
        exposure += sold;
        IERC20(UNDERLYING_ASSET).transferFrom(msg.sender, address(this), sold);
        uint256 gho = sold * num / den;
        PayoutToken(GHO_TOKEN).mint(receiver, gho);
        return (sold, gho);
    }

    function getIsFrozen() external view returns (bool) {
        return frozen;
    }

    function getIsSeized() external view returns (bool) {
        return seized;
    }

    function getExposureCap() external view returns (uint128) {
        return uint128(cap);
    }
}

/// @title MockLitePsm
/// @notice A Sky LitePSM stand-in following `DssLitePsm.buyGem` (dss-lite-psm dbf0022): the DAI cost
/// `gemAmt × c + ⌊gemAmt × c × tout / 10¹⁸⌋` pulled from the caller, the gem sent to `usr`, and a halt at
/// `tout == type(uint256).max`.
contract MockLitePsm {
    address public immutable dai;
    address public immutable gem;
    uint256 public immutable to18ConversionFactor;
    uint256 public tout;
    uint256 public lastDaiIn;

    constructor(
        address dai_,
        address gem_,
        uint8 gemDecimals
    ) {
        dai = dai_;
        gem = gem_;
        to18ConversionFactor = 10 ** (18 - gemDecimals);
    }

    function setTout(
        uint256 tout_
    ) external {
        tout = tout_;
    }

    function buyGem(
        address usr,
        uint256 gemAmt
    ) external returns (uint256 daiInWad) {
        require(tout != type(uint256).max, "DssLitePsm/halted");
        uint256 gemAmt18 = gemAmt * to18ConversionFactor;
        daiInWad = gemAmt18 + (tout > 0 ? gemAmt18 * tout / 1e18 : 0);
        lastDaiIn = daiInWad;
        IERC20(dai).transferFrom(msg.sender, address(this), daiInWad);
        IERC20(gem).transfer(usr, gemAmt);
    }
}

/// @title MockDaiUsds
/// @notice The Sky DAI/USDS converter stand-in: `usdsToDai(usr, wad)` pulls `wad` USDS and sends `wad` DAI.
contract MockDaiUsds {
    address public immutable usds;
    address public immutable dai;

    constructor(
        address usds_,
        address dai_
    ) {
        usds = usds_;
        dai = dai_;
    }

    function usdsToDai(
        address usr,
        uint256 wad
    ) external {
        IERC20(usds).transferFrom(msg.sender, address(this), wad);
        PayoutToken(dai).mint(usr, wad);
    }
}

/// @title MockPoolFactory
/// @notice The pinned pool factories of a chain in one stand-in: Uniswap v3 `getPool(a, b, fee)`, Aerodrome Slipstream
/// `getPool(a, b, tickSpacing)` and Curve StableSwap-NG `get_coin_indices(pool, from, to)`, answering only for pools
/// registered with it. Suites deploy one instance per family.
contract MockPoolFactory {
    mapping(bytes32 key => address pool) internal _byFee;
    mapping(bytes32 key => address pool) internal _bySpacing;
    mapping(address pool => address[] coins) internal _coins;

    /// @notice Records a concentrated-liquidity pool under its tokens and its `fee()` and `tickSpacing()`.
    function register(
        address pool
    ) external {
        MockCLPool p = MockCLPool(pool);
        (address t0, address t1) = (p.token0(), p.token1());
        _byFee[keccak256(abi.encode(t0, t1, uint256(p.fee())))] = pool;
        _bySpacing[keccak256(abi.encode(t0, t1, int256(p.tickSpacing())))] = pool;
    }

    /// @notice Records a pool under its tokens and a tick spacing only (the Slipstream key), without reading `fee()`.
    function registerSpacing(
        address pool,
        address tokenA,
        address tokenB,
        int24 tickSpacing
    ) external {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        _bySpacing[keccak256(abi.encode(t0, t1, int256(tickSpacing)))] = pool;
    }

    /// @notice Records a Curve pool and its coins.
    function registerCurve(
        address pool,
        address[] calldata coins
    ) external {
        _coins[pool] = coins;
    }

    function getPool(
        address a,
        address b,
        uint24 fee
    ) external view returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return _byFee[keccak256(abi.encode(t0, t1, uint256(fee)))];
    }

    function getPool(
        address a,
        address b,
        int24 tickSpacing
    ) external view returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return _bySpacing[keccak256(abi.encode(t0, t1, int256(tickSpacing)))];
    }

    function get_coin_indices(
        address pool,
        address from,
        address to
    ) external view returns (int128 i, int128 j, bool isUnderlying) {
        address[] storage coins = _coins[pool];
        bool foundI = false;
        bool foundJ = false;
        for (uint256 k = 0; k < coins.length; ++k) {
            if (coins[k] == from) (i, foundI) = (int128(int256(k)), true);
            if (coins[k] == to) (j, foundJ) = (int128(int256(k)), true);
        }
        require(foundI && foundJ, "Coins not found");
        isUnderlying = false;
    }
}

/// @title FeeSwitchToken
/// @notice A USDT stand-in: a `PayoutToken` that answers USDT's fee-switch getter `basisPointsRate()` with its current
/// fee, so a route's deployment probe sees the switch whether it is on or off.
contract FeeSwitchToken is PayoutToken {
    constructor(
        string memory name_,
        uint8 decimals_
    ) PayoutToken(name_, decimals_) {}

    function basisPointsRate() external view returns (uint256) {
        return feeBps;
    }
}

/// @title MockPsmAndConverter
/// @notice One contract answering both the LitePSM's and the DAI/USDS converter's token getters, so a route that names
/// it as both module and converter passes every token check and reaches the distinct-contracts check.
contract MockPsmAndConverter {
    address public immutable dai;
    address public immutable gem;
    address public immutable usds;
    uint256 public immutable to18ConversionFactor;

    constructor(
        address dai_,
        address gem_,
        address usds_,
        uint8 gemDecimals
    ) {
        (dai, gem, usds) = (dai_, gem_, usds_);
        to18ConversionFactor = 10 ** (18 - gemDecimals);
    }
}

/// @title VerboseSlipstreamPool
/// @notice A Slipstream-style pool whose `token0()` and `token1()` return two words (the token and a trailing word) and
/// whose `fee()` reverts (a fee module that refuses the read): a route reads only the first word of each answer and
/// recognizes the pool through the Slipstream factory's tick-spacing key.
contract VerboseSlipstreamPool {
    address internal immutable _T0;
    address internal immutable _T1;
    int24 public constant tickSpacing = 1;

    constructor(
        address tokenA,
        address tokenB
    ) {
        (_T0, _T1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function token0() external view returns (address, uint256) {
        return (_T0, type(uint256).max);
    }

    function token1() external view returns (address, uint256) {
        return (_T1, type(uint256).max);
    }

    function fee() external pure returns (uint24) {
        revert("fee module");
    }
}

/// @title MockLegacyCurvePool
/// @notice A legacy (pre-NG) Curve plain pool stand-in: `coins(uint256)` and `exchange(int128, int128, uint256,
/// uint256)`. In `ReturnMode.Nothing` `exchange` returns no data, as the Ethereum 3pool does; in `ReturnMode.Amount` it
/// returns the amount sent; in `ReturnMode.Lie` it returns ten times that amount. Like the 3pool for its fee coin, it
/// credits the input it measured as its own balance rise, so a transfer fee on the input lowers the output.
contract MockLegacyCurvePool {
    enum ReturnMode {
        Nothing,
        Amount,
        Lie
    }

    address[] internal _coins;
    uint256 public num = 1;
    uint256 public den = 1;
    uint256 public lastMinDy;
    uint256 public lastDx;
    uint256 public exchangeCalls;
    ReturnMode public returnMode;

    constructor(
        address[] memory coins_
    ) {
        _coins = coins_;
    }

    function coins(
        uint256 i
    ) external view returns (address) {
        return _coins[i];
    }

    function setRate(
        uint256 num_,
        uint256 den_
    ) external {
        (num, den) = (num_, den_);
    }

    function setReturnMode(
        ReturnMode mode
    ) external {
        returnMode = mode;
    }

    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 minDy
    ) external {
        lastMinDy = minDy;
        lastDx = dx;
        ++exchangeCalls;
        IERC20 input = IERC20(_coins[uint256(int256(i))]);
        uint256 before = input.balanceOf(address(this));
        input.transferFrom(msg.sender, address(this), dx);
        uint256 received = input.balanceOf(address(this)) - before;
        uint256 dy = received * num / den;
        require(dy >= minDy, "Exchange resulted in fewer coins than expected");
        if (dy != 0) IERC20(_coins[uint256(int256(j))]).transfer(msg.sender, dy);
        ReturnMode mode = returnMode;
        if (mode == ReturnMode.Nothing) return;
        uint256 reported = mode == ReturnMode.Amount ? dy : dy * 10;
        // A Vyper `-> uint256` return: one word.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            mstore(0, reported)
            return(0, 32)
        }
    }
}
