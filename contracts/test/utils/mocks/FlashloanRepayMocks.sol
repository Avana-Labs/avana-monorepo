// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV3FlashLoanReceiver} from "../../../src/interfaces/external/aave/IAaveV3FlashLoanReceiver.sol";
import {IWithdrawReceiver} from "../../../src/policy/aave-adapter/IWithdrawReceiver.sol";
import {LPVaultTestToken} from "./LPVaultMocks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice An Aave V3 Pool stand-in: lends what it holds, calls `executeOperation`, pulls back amount plus premium.
contract MockFlashPool {
    error CallbackFailed();

    uint256 public premiumBps = 5;
    mapping(address borrower => bool) public isFlashBorrower;

    function setPremiumBps(
        uint256 bps
    ) external {
        premiumBps = bps;
    }

    function setFlashBorrower(
        address borrower,
        bool on
    ) external {
        isFlashBorrower[borrower] = on;
    }

    function FLASHLOAN_PREMIUM_TOTAL() external view returns (uint128) {
        return uint128(premiumBps);
    }

    function flashLoan(
        address receiver,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata,
        address,
        bytes calldata params,
        uint16
    ) external {
        uint256[] memory premiums = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            premiums[i] = isFlashBorrower[msg.sender] ? 0 : (amounts[i] * premiumBps + 9999) / 10_000;
            IERC20(assets[i]).transfer(receiver, amounts[i]);
        }
        if (!IAaveV3FlashLoanReceiver(receiver).executeOperation(assets, amounts, premiums, msg.sender, params)) {
            revert CallbackFailed();
        }
        for (uint256 i; i < assets.length; ++i) {
            IERC20(assets[i]).transferFrom(receiver, address(this), amounts[i] + premiums[i]);
        }
    }
}

/// @notice A router stand-in: takes `amountIn` of `tokenIn` and mints `tokenOut` at `rateBps` of it.
contract MockSwapRouter {
    error TooLittleOut(uint256 out, uint256 minOut);

    /// @dev The amount in is the third argument, at byte offset 68 of the call.
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        uint256 rateBps
    ) external returns (uint256 out) {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        out = amountIn * rateBps / 10_000;
        if (out < minOut) revert TooLittleOut(out, minOut);
        LPVaultTestToken(tokenOut).mint(msg.sender, out);
    }
}

/// @notice A withdrawal operator that runs the calls in its `data` (as itself) when the adapter calls it back.
contract MockWithdrawOperator is IWithdrawReceiver {
    function onWithdrawAllowed(
        address,
        bytes32,
        uint128,
        bytes calldata data
    ) external {
        (address[] memory targets, bytes[] memory calls) = abi.decode(data, (address[], bytes[]));
        for (uint256 i; i < targets.length; ++i) {
            (bool ok, bytes memory ret) = targets[i].call(calls[i]);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    function approve(
        address token,
        address spender
    ) external {
        IERC20(token).approve(spender, type(uint256).max);
    }
}
