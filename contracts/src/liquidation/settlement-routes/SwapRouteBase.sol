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
/// @notice The part every swap route shares (2.12): the caller and Lock checks, the measured pull of the input, the
/// return of every residue and of the output to LPVaultSwap, and the minimum-output check on LPVaultSwap's balance.
/// @dev Immutable, with no owner, setter, rescue, sweep, arbitrary call, `receive`, fallback or storage outside
/// transient storage. A route type supplies its legs (`_runLegs`), the tokens it holds between legs (`_intermediates`)
/// and the contracts it calls (`dependencies`). Accounting is by balance deltas over one `swap` call: a token sent to the
/// route outside a call stays where it is and never counts toward an output, a residue or `minOut`.
/// @custom:spec REQ-ROUTE-007, REQ-ROUTE-008, REQ-ROUTE-014, REQ-ROUTE-015, REQ-ROUTE-016, REQ-ROUTE-024, REQ-ROUTE-042, REQ-ROUTE-045, INV-034, INV-054, Q-124, Q-148, Q-250
abstract contract SwapRouteBase is ISettlementRoute {
    using SafeERC20 for IERC20;

    /// @dev The chain's LPVaultSwap proxy, the only caller of `swap`.
    address internal immutable _LP_VAULT_SWAP;

    /// @dev The chain's Lock; `holder()` must be LPVaultSwap or the AaveAdapter during `swap`.
    address internal immutable _LOCK;

    /// @dev The chain's AaveAdapter proxy, the second accepted Lock holder (repay with collateral).
    address internal immutable _AAVE_ADAPTER;

    /// @dev Input token, a released pool token.
    address internal immutable _TOKEN_IN;

    /// @dev Output token, the debt asset.
    address internal immutable _TOKEN_OUT;

    /// @dev Bit `c` set when the route was tested for token class `c`.
    uint8 internal immutable _TOKEN_CLASS_MASK;

    /// @dev The chain's pinned Uniswap v3 factory (0 when the chain has none).
    address internal immutable _UNISWAP_V3_FACTORY;

    /// @dev The chain's pinned Aerodrome Slipstream factory (0 when the chain has none).
    address internal immutable _SLIPSTREAM_FACTORY;

    /// @dev The chain's pinned Curve StableSwap-NG factory (0 when the chain has none).
    address internal immutable _CURVE_FACTORY;

    /// @notice Checks and fixes the shared immutables.
    /// @param config Shared constructor arguments.
    /// @custom:spec REQ-ROUTE-005, REQ-ROUTE-007, REQ-ROUTE-045, Q-379
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
        // A route wired to another Lock would accept calls the chain's Lock never saw (REQ-ROUTE-007); a Lock that does
        // not answer fails the same way.
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
    /// @custom:spec REQ-ROUTE-007, REQ-ROUTE-008, REQ-ROUTE-009, REQ-ROUTE-014, REQ-ROUTE-015, REQ-ROUTE-016, REQ-ROUTE-024, REQ-ROUTE-025, REQ-ROUTE-032, REQ-ROUTE-034, REQ-ROUTE-042, REQ-ROUTE-044, INV-034, INV-054, Q-148, Q-217, Q-250, Q-271
    function swap(
        uint256 amountIn,
        uint256 minOut
    ) external override returns (uint256 amountOut) {
        if (msg.sender != _LP_VAULT_SWAP) revert NotLPVaultSwap();
        address lockHolder = ILock(_LOCK).holder();
        if (lockHolder != _LP_VAULT_SWAP && lockHolder != _AAVE_ADAPTER) revert NotLocked();
        // A zero request never reaches the token, so a token that reverts on zero transfers cannot mask the error.
        if (amountIn == 0) revert TransferMismatch();
        // A swap with no minimum is never a valid LPVaultSwap call (SPEC-LIQ-018 gives at least 1); refuse it.
        if (minOut == 0) revert ZeroMinOut();

        // held = [TOKEN_IN, intermediates..., TOKEN_OUT], all distinct (each route type's constructor checks it).
        address[] memory held = _heldTokens();
        uint256[] memory before = new uint256[](held.length);
        // held has at most five tokens (TOKEN_IN, up to three intermediates, TOKEN_OUT), each fixed and checked at
        // construction; a reverting token reverts the swap and LPVaultSwap uses the other route slot.
        for (uint256 k = 0; k < held.length; ++k) {
            // forge-lint: disable-next-line(calls-loop)
            before[k] = IERC20(held[k]).balanceOf(address(this));
        }
        uint256 deliveredBefore = IERC20(_TOKEN_OUT).balanceOf(_LP_VAULT_SWAP);

        // msg.sender is LP_VAULT_SWAP (checked above).
        IERC20(_TOKEN_IN).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 inBalance = IERC20(_TOKEN_IN).balanceOf(address(this));
        if (inBalance <= before[0] || inBalance - before[0] > amountIn) revert TransferMismatch();

        _runLegs(inBalance - before[0]);

        // Every rise of a held token during the call goes to LPVaultSwap: unconsumed input, intermediate leftovers and the
        // route's own output. Legs spend only what the call produced, so no balance ends below its starting value; a
        // zero rise is skipped (TEST-177).
        for (uint256 k = 0; k < held.length; ++k) {
            // forge-lint: disable-next-line(calls-loop)
            uint256 balance = IERC20(held[k]).balanceOf(address(this));
            if (balance > before[k]) IERC20(held[k]).safeTransfer(_LP_VAULT_SWAP, balance - before[k]);
        }

        // TOKEN_OUT differs from TOKEN_IN and every intermediate, so LPVaultSwap's rise is the output delivered, whether
        // the last leg paid the route (forwarded above) or LPVaultSwap directly (a peg module).
        uint256 deliveredAfter = IERC20(_TOKEN_OUT).balanceOf(_LP_VAULT_SWAP);
        amountOut = deliveredAfter > deliveredBefore ? deliveredAfter - deliveredBefore : 0;
        if (amountOut < minOut) revert MinOutNotMet(amountOut, minOut);
    }

    /// @inheritdoc ISettlementRoute
    /// @dev Routes without a concentrated-liquidity hop never have a hop in progress, so every call reverts.
    /// @custom:spec REQ-ROUTE-013, REQ-ROUTE-029, REQ-ROUTE-033
    function uniswapV3SwapCallback(
        int256,
        int256,
        bytes calldata
    ) external virtual override {
        revert InvalidCallback();
    }

    /// @inheritdoc ISettlementRoute
    /// @custom:spec REQ-ROUTE-005, REQ-ROUTE-036
    function tokenIn() external view override returns (address token) {
        token = _TOKEN_IN;
    }

    /// @inheritdoc ISettlementRoute
    /// @custom:spec REQ-ROUTE-005, REQ-ROUTE-036
    function tokenOut() external view override returns (address token) {
        token = _TOKEN_OUT;
    }

    /// @inheritdoc ISettlementRoute
    /// @custom:spec REQ-ROUTE-003, REQ-ROUTE-036
    function intermediates() external view override returns (address[] memory tokens) {
        tokens = _intermediates();
    }

    /// @inheritdoc ISettlementRoute
    /// @custom:spec REQ-ROUTE-045
    function poolFactories() external view override returns (address uniswapV3, address slipstream, address curve) {
        (uniswapV3, slipstream, curve) = (_UNISWAP_V3_FACTORY, _SLIPSTREAM_FACTORY, _CURVE_FACTORY);
    }

    /// @inheritdoc ISettlementRoute
    /// @custom:spec REQ-ROUTE-005, REQ-ROUTE-007
    function LP_VAULT_SWAP() external view override returns (address lpVaultSwap) {
        lpVaultSwap = _LP_VAULT_SWAP;
    }

    /// @inheritdoc ISettlementRoute
    /// @custom:spec REQ-ROUTE-007, Q-255
    function AAVE_ADAPTER() external view override returns (address adapter) {
        adapter = _AAVE_ADAPTER;
    }

    /// @inheritdoc ISettlementRoute
    /// @custom:spec Q-379
    function supportsTokenClass(
        uint8 tokenClass
    ) external view override returns (bool supported) {
        supported = tokenClass >= 1 && tokenClass <= 3 && (_TOKEN_CLASS_MASK >> tokenClass) & 1 == 1;
    }

    /// @notice Runs the route type's legs on `amount` of `TOKEN_IN` the route has just received.
    /// @dev Each leg approves exactly its input to a contract that pulls with `transferFrom` and resets the allowance to
    /// 0 after it; the last leg leaves the output with the route or pays LPVaultSwap directly.
    /// @param amount `TOKEN_IN` received, `inRecv` of REQ-ROUTE-008.
    function _runLegs(
        uint256 amount
    ) internal virtual;

    /// @notice Tokens the route holds between legs, in leg order, each distinct from `TOKEN_IN` and `TOKEN_OUT`.
    /// @return tokens Intermediate tokens.
    function _intermediates() internal view virtual returns (address[] memory tokens);

    /// @notice `[TOKEN_IN, intermediates..., TOKEN_OUT]`, the tokens whose rise `swap` returns to LPVaultSwap.
    /// @return held Token list.
    /// @custom:spec REQ-ROUTE-015, REQ-ROUTE-016
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
    /// @custom:spec REQ-ROUTE-010
    function _approve(
        address token,
        address spender,
        uint256 amount
    ) internal {
        IERC20(token).forceApprove(spender, amount);
    }

    /// @notice `token` balance of the route.
    function _balance(
        address token
    ) internal view returns (uint256) {
        // Read in the hop loop of `DexHops` (at most three fixed hop outputs).
        // forge-lint: disable-next-line(calls-loop)
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Rise of the route's `token` balance above `before`, 0 if it did not rise.
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
