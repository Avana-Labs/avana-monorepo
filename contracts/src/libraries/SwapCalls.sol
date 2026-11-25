// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice One swap of a caller-built route: a call to `target` that spends `tokenIn`.
/// @param tokenIn The token the call spends; the target is approved for this contract's whole balance of it.
/// @param target The router, aggregator or pool to call.
/// @param data The call. Its own minimum-output field is the swap's slippage bound.
/// @param amountInOffset Byte offset in `data` of a 32-byte input amount to overwrite with this contract's balance of
/// `tokenIn` before the call (the amount is known only once earlier steps ran); zero leaves `data` as it is.
struct Swap {
    address tokenIn;
    address target;
    bytes data;
    uint256 amountInOffset;
}

/// @title SwapCalls
/// @notice Runs a caller-built list of swaps for the periphery helpers, each with an exact, reset approval.
/// @dev The helpers hold no funds and no allowances between transactions, so a swap can only spend the tokens of the
/// transaction that supplied it. Targets that could act for other users are refused by the caller's `forbidden` list.
library SwapCalls {
    using SafeERC20 for IERC20;

    /// @notice A swap targets this contract, an address with no code, or an address on the forbidden list.
    error ForbiddenTarget(address target);
    /// @notice `amountInOffset` does not leave room for 32 bytes inside `data`.
    error InvalidOffset(uint256 index, uint256 offset);
    /// @notice A swap call reverted.
    error SwapFailed(uint256 index, bytes reason);

    /// @notice Runs `swaps` in order. Each target is approved for this contract's balance of its `tokenIn`, called,
    /// then approved for zero.
    function run(
        Swap[] memory swaps,
        address[] memory forbidden
    ) internal {
        // Each swap is one step of the caller's route: any failure must revert the whole route.
        // forge-lint: disable-start(calls-loop, require-revert-in-loop)
        for (uint256 i; i < swaps.length; ++i) {
            Swap memory s = swaps[i];
            _check(s.target, forbidden);
            uint256 amountIn = IERC20(s.tokenIn).balanceOf(address(this));
            if (s.amountInOffset != 0) {
                if (s.amountInOffset < 4 || s.amountInOffset + 32 > s.data.length) {
                    revert InvalidOffset(i, s.amountInOffset);
                }
                bytes memory data = s.data;
                uint256 offset = s.amountInOffset;
                // Writes the live input amount into the route's calldata at its checked offset, in place.
                // solhint-disable-next-line no-inline-assembly
                assembly ("memory-safe") {
                    mstore(add(add(data, 32), offset), amountIn)
                }
            }
            IERC20(s.tokenIn).forceApprove(s.target, amountIn);
            // The route is the caller's own calldata to a target outside Avana's contracts (`_check`); the revert
            // reason is kept for the caller.
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, bytes memory reason) = s.target.call(s.data);
            if (!ok) revert SwapFailed(i, reason);
            IERC20(s.tokenIn).forceApprove(s.target, 0);
        }
        // forge-lint: disable-end(calls-loop, require-revert-in-loop)
    }

    function _check(
        address target,
        address[] memory forbidden
    ) private view {
        // forge-lint: disable-start(require-revert-in-loop)
        if (target == address(this) || target.code.length == 0) revert ForbiddenTarget(target);
        for (uint256 j; j < forbidden.length; ++j) {
            if (target == forbidden[j]) revert ForbiddenTarget(target);
        }
        // forge-lint: disable-end(require-revert-in-loop)
    }
}
