// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {UniswapV4State} from "../../../src/amm/uniswap-v4/UniswapV4State.sol";
import {IUniswapV4PoolManager} from "../../../src/interfaces/external/uniswap-v4/IUniswapV4PoolManager.sol";
import {IUniswapV4PositionManager} from "../../../src/interfaces/external/uniswap-v4/IUniswapV4PositionManager.sol";
import {ClPriceMath} from "../libraries/ClPriceMath.sol";
import {ClPoolFixture, ClTestToken, IClPool} from "./ClPoolFixture.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Wrapped ether with the WETH9 interface the PositionManager's `WRAP` and `UNWRAP` call.
contract TestWETH9 is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    receive() external payable {
        _mint(msg.sender, msg.value);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    /// @notice Test mint, so reference pools and actors can be funded like the other test tokens.
    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function withdraw(
        uint256 amount
    ) external {
        _burn(msg.sender, amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "eth");
    }
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

/// @notice PositionManager calls the tests make besides the LPVault's subset.
interface IV4TestPositionManager is IUniswapV4PositionManager {
    function nextTokenId() external view returns (uint256);

    function subscribe(
        uint256 tokenId,
        address newSubscriber,
        bytes calldata data
    ) external payable;

    function approve(
        address spender,
        uint256 id
    ) external;
}

/// @notice A subscriber that accepts every notification.
contract V4TestSubscriber {
    function notifySubscribe(
        uint256,
        bytes memory
    ) external {}

    function notifyUnsubscribe(
        uint256
    ) external {}

    function notifyBurn(
        uint256,
        address,
        uint256,
        uint256,
        BalanceDelta
    ) external {}

    function notifyModifyLiquidity(
        uint256,
        int256,
        BalanceDelta
    ) external {}
}

/// @notice Swaps and donates on the PoolManager from its own balances, and runs an arbitrary call inside `unlock`.
contract V4PoolActor is IUnlockCallback {
    IPoolManager internal immutable _PM;

    constructor(
        IPoolManager pm
    ) {
        _PM = pm;
    }

    receive() external payable {}

    function swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 limit
    ) external returns (BalanceDelta delta) {
        bytes memory ret = _PM.unlock(abi.encode(uint8(0), abi.encode(key, zeroForOne, amountSpecified, limit)));
        delta = abi.decode(ret, (BalanceDelta));
    }

    function donate(
        PoolKey memory key,
        uint256 amount0,
        uint256 amount1
    ) external {
        _PM.unlock(abi.encode(uint8(1), abi.encode(key, amount0, amount1)));
    }

    /// @notice Calls `target` with `data` while the PoolManager is unlocked and returns its revert data, if any.
    function callInside(
        address target,
        bytes calldata data
    ) external returns (bool ok, bytes memory ret) {
        (ok, ret) = abi.decode(_PM.unlock(abi.encode(uint8(2), abi.encode(target, data))), (bool, bytes));
    }

    function unlockCallback(
        bytes calldata raw
    ) external returns (bytes memory) {
        require(msg.sender == address(_PM), "pm");
        (uint8 op, bytes memory data) = abi.decode(raw, (uint8, bytes));
        if (op == 2) {
            (address target, bytes memory callData) = abi.decode(data, (address, bytes));
            (bool ok, bytes memory ret) = target.call(callData);
            return abi.encode(ok, ret);
        }
        PoolKey memory key;
        BalanceDelta delta;
        if (op == 0) {
            bool zeroForOne;
            int256 amount;
            uint160 limit;
            (key, zeroForOne, amount, limit) = abi.decode(data, (PoolKey, bool, int256, uint160));
            delta = _PM.swap(key, IPoolManager.SwapParams(zeroForOne, amount, limit), "");
        } else {
            uint256 a0;
            uint256 a1;
            (key, a0, a1) = abi.decode(data, (PoolKey, uint256, uint256));
            delta = _PM.donate(key, a0, a1, "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(
        Currency currency,
        int128 amount
    ) private {
        if (amount > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            _PM.take(currency, address(this), uint256(uint128(amount)));
            return;
        }
        if (amount == 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(uint128(-amount));
        if (Currency.unwrap(currency) == address(0)) {
            _PM.settle{value: owed}();
            return;
        }
        _PM.sync(currency);
        require(ERC20(Currency.unwrap(currency)).transfer(address(_PM), owed), "pay");
        _PM.settle();
    }
}

/// @title UniswapV4WorldFixture
/// @notice A local Uniswap v4 world on the pinned sources: PoolManager, PositionManager and StateView from
/// `out-univ4/`, Permit2 from `out-permit2/`, a WETH9, test tokens, and the Uniswap v3 factory of `ClPoolFixture` for
/// reference pools. Helpers create and initialize v4 pools, mint positions through the PositionManager (paying through
/// Permit2, native ETH by value), swap, donate and run a call inside `unlock`.
/// @dev Needs `FOUNDRY_PROFILE=univ3`, `univ4` and `permit2` builds before the tests (CI builds them).
abstract contract UniswapV4WorldFixture is ClPoolFixture {
    /// @dev PositionManager actions (v4-periphery 1.0.1).
    uint8 internal constant A_MINT_POSITION = 0x02;
    uint8 internal constant A_SETTLE_PAIR = 0x0d;
    uint8 internal constant A_SWEEP = 0x14;
    address internal constant MSG_SENDER = address(1);
    /// @dev Balance each test holder gets of each token: far above any test amount, and the total supply stays below
    /// the 2^127 listing bound (`REQ-AMM-V4-009`).
    uint256 internal constant FUND = 1e36;

    IPoolManager internal pm;
    IV4TestPositionManager internal posm;
    address internal permit2;
    address internal stateView;
    TestWETH9 internal weth;
    V4PoolActor internal v4Actor;

    receive() external payable {}

    function _deployV4World() internal {
        _deployFactory();
        weth = new TestWETH9();
        pm = IPoolManager(deployCode("out-univ4/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        permit2 = deployCode("out-permit2/Permit2.sol/Permit2.json");
        posm = IV4TestPositionManager(
            deployCode(
                "out-univ4/PositionManager.sol/PositionManager.json",
                abi.encode(address(pm), permit2, uint256(100_000), address(0), address(weth))
            )
        );
        stateView = deployCode("out-univ4/StateView.sol/StateView.json", abi.encode(address(pm)));
        v4Actor = new V4PoolActor(pm);
        vm.deal(address(v4Actor), 1e30);
        vm.label(address(pm), "PoolManager");
        vm.label(address(posm), "PositionManager");
        vm.label(permit2, "Permit2");
        vm.label(address(weth), "WETH");
        vm.label(address(v4Actor), "V4PoolActor");
    }

    /// @dev A hookless key of `(c0, c1)` (sorted, `address(0)` for native ETH).
    function _key(
        address c0,
        address c1,
        uint24 fee,
        int24 spacing
    ) internal pure returns (PoolKey memory key) {
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(address(0)));
    }

    function _poolId(
        PoolKey memory key
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    /// @dev Initializes `key` at the prices `p0`, `p1` (8 decimals) of tokens with decimals `d0`, `d1`, and funds the
    /// actor and this fixture with both currencies.
    function _initPool(
        PoolKey memory key,
        uint256 p0,
        uint256 p1,
        uint8 d0,
        uint8 d1
    ) internal {
        pm.initialize(key, ClPriceMath.oracleSqrtPrice(p0, p1, d0, d1));
        _fund(Currency.unwrap(key.currency0));
        _fund(Currency.unwrap(key.currency1));
    }

    function _fund(
        address token
    ) internal {
        if (token == address(0)) {
            vm.deal(address(this), 1e30);
            return;
        }
        ClTestToken(token).mint(address(v4Actor), FUND);
        ClTestToken(token).mint(address(this), FUND);
        ERC20(token).approve(permit2, type(uint256).max);
        IPermit2Approve(permit2).approve(token, address(posm), type(uint160).max, type(uint48).max);
    }

    /// @dev Mints a position of `liquidity` on `[lower, upper]` to `owner` through the PositionManager.
    function _mintV4(
        address owner,
        PoolKey memory key,
        int24 lower,
        int24 upper,
        uint128 liquidity
    ) internal returns (uint256 tokenId) {
        tokenId = posm.nextTokenId();
        bytes memory actions = abi.encodePacked(A_MINT_POSITION, A_SETTLE_PAIR, A_SWEEP);
        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(key, lower, upper, uint256(liquidity), type(uint128).max, type(uint128).max, owner, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(Currency.wrap(address(0)), MSG_SENDER);
        uint256 value = Currency.unwrap(key.currency0) == address(0) ? address(this).balance / 2 : 0;
        posm.modifyLiquidities{value: value}(abi.encode(actions, params), block.timestamp);
    }

    /// @dev Swaps `key` to the exact square-root price `target` with unlimited input.
    function _swapV4To(
        PoolKey memory key,
        uint160 target
    ) internal {
        (uint160 now_,) = UniswapV4State.slot0(IUniswapV4PoolManager(address(pm)), _poolId(key));
        if (target == now_) return;
        v4Actor.swap(key, target < now_, -int256(uint256(type(uint128).max)), target);
    }

    /// @dev Swaps `amount` of exact input one way and back, accruing fees on in-range positions.
    function _washV4(
        PoolKey memory key,
        uint256 amount
    ) internal {
        v4Actor.swap(key, true, -int256(amount), ClPriceMath.MIN_SQRT_RATIO + 1);
        v4Actor.swap(key, false, -int256(amount), ClPriceMath.MAX_SQRT_RATIO - 1);
    }

    function _slot0V4(
        PoolKey memory key
    ) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        return UniswapV4State.slot0(IUniswapV4PoolManager(address(pm)), _poolId(key));
    }

    /// @dev A Uniswap v3 reference pool of the same two tokens (WETH for native ETH) with `cardinality` observation
    /// slots, initialized at the same prices.
    function _referencePool(
        address tokenA,
        address tokenB,
        uint256 pA,
        uint256 pB,
        uint16 cardinality,
        uint128 liquidity
    ) internal returns (IClPool pool) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        (uint256 p0, uint256 p1) = tokenA < tokenB ? (pA, pB) : (pB, pA);
        pool = IClPool(factory.createPool(t0, t1, 500));
        pool.initialize(ClPriceMath.oracleSqrtPrice(p0, p1, ClTestToken(t0).decimals(), ClTestToken(t1).decimals()));
        pool.increaseObservationCardinalityNext(cardinality);
        ClTestToken(t0).mint(address(actor), FUND);
        ClTestToken(t1).mint(address(actor), FUND);
        if (liquidity > 0) actor.mint(pool, -887_270, 887_270, liquidity);
        vm.label(address(pool), "UniswapV3ReferencePool");
    }

    /// @dev Grows the reference pool's observations over `n` blocks of 12 s.
    function _observe(
        IClPool pool,
        uint256 n
    ) internal {
        for (uint256 i = 0; i < n; ++i) {
            _touch(pool);
        }
    }
}
