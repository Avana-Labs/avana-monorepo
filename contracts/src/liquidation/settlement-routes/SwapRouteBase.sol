// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILock} from "../../lock/lock/ILock.sol";
import {ISettlementRoute} from "./ISettlementRoute.sol";
import {RouteReads} from "./RouteReads.sol";
import {RouteConfig} from "./types/RouteConfig.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title SwapRouteBase
/// @notice Shared swap-route logic: caller and Lock checks, measured input pull, residue return and `minOut` check.
/// @dev Accounting is by balance deltas over one `swap` call; a token sent outside a call never counts.
abstract contract SwapRouteBase is ISettlementRoute {
    using SafeERC20 for IERC20;

    address internal immutable _LP_VAULT_SWAP;

    address internal immutable _LOCK;

    address internal immutable _AAVE_ADAPTER;

    address internal immutable _TOKEN_IN;

    address internal immutable _TOKEN_OUT;

    /// @dev Bit `c` set when the route was tested for token class `c`.
    uint8 internal immutable _TOKEN_CLASS_MASK;

    address internal immutable _UNISWAP_V3_FACTORY;

    address internal immutable _SLIPSTREAM_FACTORY;

    address internal immutable _CURVE_FACTORY;

    /// @notice Checks and fixes the shared immutables.
    constructor(
        RouteConfig memory config
    ) {
        if (
            config.lpVaultSwap == address(0) || config.lock == address(0) || config.aaveAdapter == address(0)
                || config.tokenIn == address(0) || config.tokenOut == address(0)
                || config.lpVaultSwap == config.aaveAdapter || config.tokenIn == config.tokenOut
        ) revert InvalidRouteConfig();
        // Bits 1 to 3 only, at least one: 0x0E = 0b1110.
        if (config.tokenClassMask == 0 || config.tokenClassMask & ~uint8(0x0E) != 0) revert InvalidRouteConfig();
        (bool okSwap, address lockSwap) = RouteReads.addressOf(config.lock, abi.encodeCall(ILock.LP_VAULT_SWAP, ()));
        (bool okAdapter, address lockAdapter) =
            RouteReads.addressOf(config.lock, abi.encodeCall(ILock.AAVE_ADAPTER, ()));
        if (!okSwap || !okAdapter || lockSwap != config.lpVaultSwap || lockAdapter != config.aaveAdapter) {
            revert InvalidRouteConfig();
        }
        _LP_VAULT_SWAP = config.lpVaultSwap;
        _LOCK = config.lock;
        _AAVE_ADAPTER = config.aaveAdapter;
        _TOKEN_IN = config.tokenIn;
        _TOKEN_OUT = config.tokenOut;
        _TOKEN_CLASS_MASK = config.tokenClassMask;
        _UNISWAP_V3_FACTORY = config.uniswapV3Factory;
        _SLIPSTREAM_FACTORY = config.slipstreamFactory;
        _CURVE_FACTORY = config.curveFactory;
    }

    /// @inheritdoc ISettlementRoute
    function swap(
        uint256 amountIn,
        uint256 minOut
    ) external override returns (uint256 amountOut) {
        if (msg.sender != _LP_VAULT_SWAP) revert NotLPVaultSwap();
        address lockHolder = ILock(_LOCK).holder();
        if (lockHolder != _LP_VAULT_SWAP && lockHolder != _AAVE_ADAPTER) revert NotLocked();
        // A zero request never reaches the token, so a token that reverts on zero transfers cannot mask the error.
        if (amountIn == 0) revert TransferMismatch();
        if (minOut == 0) revert ZeroMinOut();

        address[] memory held = _heldTokens();
        uint256[] memory before = new uint256[](held.length);
        // At most five fixed tokens, checked at construction.
        for (uint256 k = 0; k < held.length; ++k) {
            // forge-lint: disable-next-line(calls-loop)
            before[k] = IERC20(held[k]).balanceOf(address(this));
        }
        uint256 deliveredBefore = IERC20(_TOKEN_OUT).balanceOf(_LP_VAULT_SWAP);

        IERC20(_TOKEN_IN).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 inBalance = IERC20(_TOKEN_IN).balanceOf(address(this));
        if (inBalance <= before[0] || inBalance - before[0] > amountIn) revert TransferMismatch();

        _runLegs(inBalance - before[0]);

        // Every rise of a held token during the call goes to LPVaultSwap; a zero rise is skipped.
        for (uint256 k = 0; k < held.length; ++k) {
            // forge-lint: disable-next-line(calls-loop)
            uint256 balance = IERC20(held[k]).balanceOf(address(this));
            if (balance > before[k]) IERC20(held[k]).safeTransfer(_LP_VAULT_SWAP, balance - before[k]);
        }

        // Measured at LPVaultSwap, so output paid directly by a peg module counts too.
        uint256 deliveredAfter = IERC20(_TOKEN_OUT).balanceOf(_LP_VAULT_SWAP);
        amountOut = deliveredAfter > deliveredBefore ? deliveredAfter - deliveredBefore : 0;
        if (amountOut < minOut) revert MinOutNotMet(amountOut, minOut);
    }

    /// @inheritdoc ISettlementRoute
    function uniswapV3SwapCallback(
        int256,
        int256,
        bytes calldata
    ) external virtual override {
        revert InvalidCallback();
    }

    /// @inheritdoc ISettlementRoute
    function tokenIn() external view override returns (address token) {
        token = _TOKEN_IN;
    }

    /// @inheritdoc ISettlementRoute
    function tokenOut() external view override returns (address token) {
        token = _TOKEN_OUT;
    }

    /// @inheritdoc ISettlementRoute
    function intermediates() external view override returns (address[] memory tokens) {
        tokens = _intermediates();
    }

    /// @inheritdoc ISettlementRoute
    function poolFactories() external view override returns (address uniswapV3, address slipstream, address curve) {
        (uniswapV3, slipstream, curve) = (_UNISWAP_V3_FACTORY, _SLIPSTREAM_FACTORY, _CURVE_FACTORY);
    }

    /// @inheritdoc ISettlementRoute
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc ISettlementRoute
    function AAVE_ADAPTER() external view override returns (address adapter) {
        adapter = _AAVE_ADAPTER;
    }

    /// @inheritdoc ISettlementRoute
    function supportsTokenClass(
        uint8 tokenClass
    ) external view override returns (bool supported) {
        supported = tokenClass >= 1 && tokenClass <= 3 && (_TOKEN_CLASS_MASK >> tokenClass) & 1 == 1;
    }

    /// @notice Runs the route type's legs on `amount` of `TOKEN_IN` the route has just received.
    /// @dev Each leg approves exactly its input and resets the allowance to 0 after it.
    function _runLegs(
        uint256 amount
    ) internal virtual;

    /// @notice Tokens the route holds between legs, in leg order, each distinct from `TOKEN_IN` and `TOKEN_OUT`.
    function _intermediates() internal view virtual returns (address[] memory tokens);

    /// @notice `[TOKEN_IN, intermediates..., TOKEN_OUT]`, the tokens whose rise `swap` returns to LPVaultSwap.
    function _heldTokens() private view returns (address[] memory held) {
        address[] memory mid = _intermediates();
        held = new address[](mid.length + 2);
        held[0] = _TOKEN_IN;
        for (uint256 k = 0; k < mid.length; ++k) {
            held[k + 1] = mid[k];
        }
        held[mid.length + 1] = _TOKEN_OUT;
    }

    /// @notice Approves `spender` for exactly `amount` of `token` (USDT-safe: `forceApprove`).
    function _approve(
        address token,
        address spender,
        uint256 amount
    ) internal {
        IERC20(token).forceApprove(spender, amount);
    }

    function _balance(
        address token
    ) internal view returns (uint256) {
        // Read in the hop loop of `DexHops` (at most three fixed hop outputs).
        // forge-lint: disable-next-line(calls-loop)
        return IERC20(token).balanceOf(address(this));
    }

    function _rise(
        address token,
        uint256 before
    ) internal view returns (uint256) {
        // Read in the hop loop of `DexHops` (at most three fixed hop outputs).
        // forge-lint: disable-next-line(calls-loop)
        uint256 balance = IERC20(token).balanceOf(address(this));
        return balance > before ? balance - before : 0;
    }
}
