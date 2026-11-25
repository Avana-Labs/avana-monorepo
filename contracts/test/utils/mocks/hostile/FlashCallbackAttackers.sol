// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV3FlashLoanReceiver} from "../../../../src/dependencies/aave/IAaveV3FlashLoanReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title HostileFlashPool
/// @notice An Aave V3 Pool stand-in that lends what it holds and then calls the receiver back the wrong way: with
/// altered params, another initiator, a second asset, or twice. It records the params of every loan, so a test can
/// replay them. In `Mode.Honest` it behaves like the Pool (premium 5 bps, rounded up).
contract HostileFlashPool {
    enum Mode {
        Honest,
        AlterParams,
        WrongInitiator,
        ExtraAsset,
        CallTwice
    }

    error CallbackFailed();

    Mode public mode;
    bytes public lastParams;
    address public extraAsset;

    function setMode(
        Mode m
    ) external {
        mode = m;
    }

    function setExtraAsset(
        address asset
    ) external {
        extraAsset = asset;
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
        lastParams = params;
        uint256[] memory premiums = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            premiums[i] = (amounts[i] * 5 + 9999) / 10_000;
            IERC20(assets[i]).transfer(receiver, amounts[i]);
        }
        _callBack(receiver, assets, amounts, premiums, params);
        for (uint256 i; i < assets.length; ++i) {
            IERC20(assets[i]).transferFrom(receiver, address(this), amounts[i] + premiums[i]);
        }
    }

    function _callBack(
        address receiver,
        address[] memory assets,
        uint256[] memory amounts,
        uint256[] memory premiums,
        bytes memory params
    ) internal {
        address initiator = msg.sender;
        if (mode == Mode.AlterParams) {
            // `abi.encode(Context)`: word 0 is the tuple offset, word 1 the wallet. Point the wallet at this pool.
            assembly ("memory-safe") {
                mstore(add(params, 64), address())
            }
        } else if (mode == Mode.WrongInitiator) {
            initiator = address(this);
        } else if (mode == Mode.ExtraAsset) {
            address[] memory a = new address[](2);
            (a[0], a[1]) = (assets[0], extraAsset);
            uint256[] memory amt = new uint256[](2);
            amt[0] = amounts[0];
            (assets, amounts, premiums) = (a, amt, new uint256[](2));
        }
        if (!IAaveV3FlashLoanReceiver(receiver).executeOperation(assets, amounts, premiums, initiator, params)) {
            revert CallbackFailed();
        }
        if (mode == Mode.CallTwice) {
            IAaveV3FlashLoanReceiver(receiver).executeOperation(assets, amounts, premiums, initiator, params);
        }
    }
}

/// @title ReenteringSwapTarget
/// @notice A swap step of a repay route that, before doing its real swap, tries each call in its list from inside the
/// open flash loan and records whether each one succeeded. It never reverts on a failed attempt, so the route goes on
/// and the test reads the outcomes.
contract ReenteringSwapTarget {
    address[] internal _targets;
    bytes[] internal _calls;
    bool[] public succeeded;
    bytes[] public reasons;

    function setAttempts(
        address[] calldata targets,
        bytes[] calldata calls
    ) external {
        delete _targets;
        delete _calls;
        for (uint256 i; i < targets.length; ++i) {
            _targets.push(targets[i]);
            _calls.push(calls[i]);
        }
    }

    function attempts() external view returns (uint256) {
        return succeeded.length;
    }

    /// @notice Runs the attempts, then forwards `data` to `router` with this contract's whole `tokenIn` balance
    /// pulled from the caller and approved, and sends the router's output token back to the caller.
    function swapVia(
        address router,
        address tokenIn,
        address tokenOut,
        bytes calldata data
    ) external {
        for (uint256 i; i < _targets.length; ++i) {
            (bool ok, bytes memory ret) = _targets[i].call(_calls[i]);
            succeeded.push(ok);
            reasons.push(ret);
        }
        uint256 amount = IERC20(tokenIn).allowance(msg.sender, address(this));
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amount);
        IERC20(tokenIn).approve(router, amount);
        (bool swapped, bytes memory reason) = router.call(data);
        if (!swapped) {
            assembly ("memory-safe") {
                revert(add(reason, 32), mload(reason))
            }
        }
        IERC20(tokenOut).transfer(msg.sender, IERC20(tokenOut).balanceOf(address(this)));
    }
}
