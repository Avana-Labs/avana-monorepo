// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashReceiver} from "../../../src/flash/IFlashReceiver.sol";
import {IFlashSource} from "../../../src/flash/IFlashSource.sol";
import {IAaveV3FlashLoanReceiver} from "../../../src/interfaces/external/aave/IAaveV3FlashLoanReceiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockFlashReceiver
/// @notice LPVaultSwap's side of the flash path (`IFlashReceiver`), deployed at the flash source's `LP_VAULT_SWAP`
/// address. `borrow` calls `flashLoan` as LPVaultSwap; `onFlashLoan` records what arrived (balance delta) and repays by
/// balance delta as `REQ-SWAP-122` states, or misbehaves as `mode` selects.
/// @dev Modes: `Repay` (at most 4 transfers topping the source up to `amount + premium`), `RepayShort` (one unit short),
/// `NoRepay`, `WrongMagic`, `ReenterLoan` (calls `flashLoan` again), `ReenterCallback` (calls the source's
/// `executeOperation` itself with the live arguments), `Overpay` (`overpay` units above what is owed). As REQ-SWAP-013
/// requires of LPVaultSwap, the receipt must satisfy `0 < Fr ≤ amount` (else `InvalidFlashCallback`); `setLenient`
/// lifts that for the zero-amount case.
contract MockFlashReceiver is IFlashReceiver {
    using SafeERC20 for IERC20;

    error InvalidFlashCallback();

    enum Mode {
        Repay,
        RepayShort,
        NoRepay,
        WrongMagic,
        ReenterLoan,
        ReenterCallback,
        Overpay
    }

    bytes32 public constant MAGIC = keccak256("IFlashReceiver.onFlashLoan");
    uint256 public constant MAX_REPAY_TRANSFERS = 4;

    IFlashSource public source;
    Mode public mode;
    uint256 public overpay;
    bool public lenient;
    address public reenterHub;

    uint256 public calls;
    address public lastAsset;
    uint256 public lastAmount;
    uint256 public lastPremium;
    bytes public lastContext;
    uint256 public lastReceived;
    uint256 public balanceBeforeLoan;

    function setSource(
        address source_
    ) external {
        source = IFlashSource(source_);
    }

    function setMode(
        Mode mode_
    ) external {
        mode = mode_;
    }

    function setLenient(
        bool on
    ) external {
        lenient = on;
    }

    function setOverpay(
        uint256 units
    ) external {
        overpay = units;
    }

    /// @notice LPVaultSwap's call: records its balance, then borrows.
    function borrow(
        address asset,
        uint256 amount,
        address spokeHub,
        bytes calldata context
    ) external returns (uint256 premium) {
        balanceBeforeLoan = IERC20(asset).balanceOf(address(this));
        reenterHub = spokeHub;
        premium = source.flashLoan(asset, amount, spokeHub, context);
    }

    function onFlashLoan(
        address asset,
        uint256 amount,
        uint256 premium,
        bytes calldata context
    ) external override returns (bytes32) {
        require(msg.sender == address(source), "not source");
        ++calls;
        (lastAsset, lastAmount, lastPremium, lastContext) = (asset, amount, premium, context);
        lastReceived = IERC20(asset).balanceOf(address(this)) - balanceBeforeLoan;
        if (!lenient && (lastReceived == 0 || lastReceived > amount)) revert InvalidFlashCallback();
        Mode m = mode;
        if (m == Mode.ReenterLoan) {
            source.flashLoan(asset, amount, reenterHub, context);
        } else if (m == Mode.ReenterCallback) {
            address[] memory assets = new address[](1);
            assets[0] = asset;
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = amount;
            uint256[] memory premiums = new uint256[](1);
            premiums[0] = premium;
            IAaveV3FlashLoanReceiver(address(source))
                .executeOperation(assets, amounts, premiums, address(source), context);
        }
        uint256 owed = amount + premium;
        if (m == Mode.RepayShort) owed -= 1;
        if (m == Mode.Overpay) owed += overpay;
        if (m != Mode.NoRepay) _repay(IERC20(asset), owed);
        return m == Mode.WrongMagic ? bytes32(uint256(MAGIC) ^ 1) : MAGIC;
    }

    /// @dev REQ-SWAP-122: read the source's balance, stop at `owed`, else send the difference; at most 4 times.
    function _repay(
        IERC20 asset,
        uint256 owed
    ) internal {
        for (uint256 i = 0; i < MAX_REPAY_TRANSFERS; ++i) {
            uint256 b = asset.balanceOf(address(source));
            if (b >= owed) return;
            asset.safeTransfer(address(source), owed - b);
        }
    }
}

/// @title MockFlashFeeCap
/// @notice Stand-in for the ParameterStore's `maxFlashFeeBps()` where the full proxy is too heavy (Halmos, Echidna);
/// unit and fuzz suites read the real ParameterStore.
contract MockFlashFeeCap {
    uint16 public maxFlashFeeBps;

    constructor(
        uint16 cap
    ) {
        maxFlashFeeBps = cap;
    }

    function setMaxFlashFeeBps(
        uint16 cap
    ) external {
        maxFlashFeeBps = cap;
    }
}
