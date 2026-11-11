// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV3ACLManager} from "../../../src/interfaces/external/aave/IAaveV3ACLManager.sol";
import {IFlashLiquidator} from "../../../src/periphery/flash-liquidator/IFlashLiquidator.sol";
import {PayoutToken} from "./PayoutToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockGhoFlashMinter
/// @notice `GhoFlashMinter` of aave/gho-core c6335a0 as the flash liquidation helper sees it: `flashLoan` requires the
/// token to be GHO, charges 0 to a `FLASH_BORROWER` of the ACLManager and `percentMul(amount, fee)` (half up)
/// otherwise, mints `amount` to the receiver, calls `onFlashLoan(msg.sender, GHO, amount, fee, data)`, requires
/// `keccak256("ERC3156FlashBorrower.onFlashLoan")`, then pulls `amount + fee` with `transferFrom` and keeps it (the
/// burn); `maxFlashLoan` is the bucket capacity less its level; `flashFee` quotes for `msg.sender`.
/// @dev Test switches (all off after deployment) make it hostile: another initiator, token or amount in the callback,
/// a fee other than the quote, no callback, a second callback.
contract MockGhoFlashMinter {
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    PayoutToken internal immutable _gho;
    IAaveV3ACLManager public immutable aclManager;
    uint256 public feeBps;
    uint256 public capacity;
    uint256 public level;
    uint256 public flashLoanCalls;
    uint256 public burned;

    address public initiatorOverride;
    address public tokenOverride;
    bool public amountBumped;
    bool public feeOverridden;
    uint256 public feeOverride;
    bool public skipCallback;
    bool public callbackTwice;

    constructor(
        PayoutToken gho,
        IAaveV3ACLManager acl,
        uint256 feeBps_,
        uint256 capacity_
    ) {
        _gho = gho;
        aclManager = acl;
        feeBps = feeBps_;
        capacity = capacity_;
    }

    function GHO_TOKEN() external view returns (address) {
        return address(_gho);
    }

    function setFee(
        uint256 feeBps_
    ) external {
        feeBps = feeBps_;
    }

    function setBucket(
        uint256 capacity_,
        uint256 level_
    ) external {
        capacity = capacity_;
        level = level_;
    }

    function setInitiatorOverride(
        address who
    ) external {
        initiatorOverride = who;
    }

    function setTokenOverride(
        address token
    ) external {
        tokenOverride = token;
    }

    function setAmountBumped(
        bool on
    ) external {
        amountBumped = on;
    }

    function setFeeOverride(
        uint256 fee
    ) external {
        feeOverridden = true;
        feeOverride = fee;
    }

    function setSkipCallback(
        bool on
    ) external {
        skipCallback = on;
    }

    function setCallbackTwice(
        bool on
    ) external {
        callbackTwice = on;
    }

    function maxFlashLoan(
        address token
    ) external view returns (uint256) {
        if (token != address(_gho)) return 0;
        return capacity > level ? capacity - level : 0;
    }

    function flashFee(
        address token,
        uint256 amount
    ) external view returns (uint256) {
        require(token == address(_gho), "FlashMinter: Unsupported currency");
        return aclManager.isFlashBorrower(msg.sender) ? 0 : _fee(amount);
    }

    function flashLoan(
        address receiver,
        address token,
        uint256 amount,
        bytes calldata data
    ) external returns (bool) {
        require(token == address(_gho), "FlashMinter: Unsupported currency");
        ++flashLoanCalls;
        uint256 fee = aclManager.isFlashBorrower(msg.sender) ? 0 : _fee(amount);
        if (feeOverridden) fee = feeOverride;
        require(level + amount <= capacity, "FACILITATOR_BUCKET_CAPACITY_EXCEEDED");
        level += amount;
        _gho.mint(receiver, amount);
        if (!skipCallback) {
            _callback(receiver, token, amount, fee, data);
            if (callbackTwice) _callback(receiver, token, amount, fee, data);
        }
        require(IERC20(address(_gho)).transferFrom(receiver, address(this), amount + fee), "pull");
        level -= amount;
        burned += amount;
        return true;
    }

    function _callback(
        address receiver,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) internal {
        address initiator = initiatorOverride == address(0) ? msg.sender : initiatorOverride;
        address t = tokenOverride == address(0) ? token : tokenOverride;
        uint256 a = amountBumped ? amount + 1 : amount;
        require(
            IFlashLiquidator(receiver).onFlashLoan(initiator, t, a, fee, data) == CALLBACK_SUCCESS,
            "FlashMinter: Callback failed"
        );
    }

    /// @dev Aave `PercentageMath.percentMul`: half up.
    function _fee(
        uint256 amount
    ) internal view returns (uint256) {
        return (amount * feeBps + 5000) / 10_000;
    }
}
