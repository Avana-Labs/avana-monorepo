// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title PayoutToken
/// @notice ERC-20 stand-in for a debt asset or pool token paid out by LPVaultSwap, with the behaviours a payout can
/// meet: an issuer blocklist (USDC, USDT, GHO), a transfer fee switched on after listing (USDT `basisPointsRate`), a
/// `false` return, a revert on zero amounts, a transfer that credits more or takes from the receiver, a fee charged to
/// the sender on top of the amount, an issuer burn from any holder (or a negative rebase), and a hook that calls out
/// during a transfer (reentry).
/// @dev Every switch is off after deployment, so the token starts as a plain ERC-20. `transfer` and `transferFrom`
/// check the switches in this order: zero amount, blocklist, false return; then move the balance with the fee, apply
/// the bonus or drain to the receiver and run the hook.
contract PayoutToken is ERC20 {
    error Blocked(address account);
    error ZeroTransfer();

    uint8 private immutable _DECIMALS;

    /// @notice Addresses the issuer blocks as sender or receiver.
    mapping(address account => bool isBlocked) public blocked;
    /// @notice Transfer fee in basis points, floor-rounded, sent to `FEE_SINK`.
    uint256 public feeBps;
    /// @notice Receiver of the transfer fee.
    address public constant FEE_SINK = address(0xFEE5);
    /// @notice Fee in basis points taken from the sender on top of the amount, which arrives in full.
    uint256 public senderFeeBps;
    /// @notice When true, `transfer` and `transferFrom` return `false` and move nothing.
    bool public returnFalse;
    /// @notice When true, a zero-amount `transfer` or `transferFrom` reverts.
    bool public revertOnZero;
    /// @notice Extra units minted to the receiver of every `transferFrom`.
    uint256 public bonus;
    /// @notice Units burned from the receiver after every `transferFrom` (its balance can fall).
    uint256 public drain;
    /// @notice Called with `hookData` after every balance move while set.
    address public hookTarget;
    bytes public hookData;

    constructor(
        string memory name_,
        uint8 decimals_
    ) ERC20(name_, name_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function setBlocked(
        address account,
        bool isBlocked
    ) external {
        blocked[account] = isBlocked;
    }

    function setFeeBps(
        uint256 bps
    ) external {
        feeBps = bps;
    }

    function setReturnFalse(
        bool on
    ) external {
        returnFalse = on;
    }

    function setRevertOnZero(
        bool on
    ) external {
        revertOnZero = on;
    }

    function setBonus(
        uint256 units
    ) external {
        bonus = units;
    }

    function setSenderFeeBps(
        uint256 bps
    ) external {
        senderFeeBps = bps;
    }

    /// @notice The issuer burns `units` from `account` (a blocklist seizure such as `destroyBlackFunds`, or a negative
    /// rebase).
    function issuerBurn(
        address account,
        uint256 units
    ) external {
        _burn(account, units);
    }

    function setDrain(
        uint256 units
    ) external {
        drain = units;
    }

    function setHook(
        address target,
        bytes calldata data
    ) external {
        hookTarget = target;
        hookData = data;
    }

    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (!_checks(msg.sender, to, amount)) return false;
        _move(msg.sender, to, amount);
        _afterMove();
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        if (!_checks(from, to, amount)) return false;
        _spendAllowance(from, msg.sender, amount);
        _move(from, to, amount);
        if (bonus != 0) _mint(to, bonus);
        if (drain != 0) _burn(to, drain);
        _afterMove();
        return true;
    }

    function _checks(
        address from,
        address to,
        uint256 amount
    ) private view returns (bool) {
        if (amount == 0 && revertOnZero) revert ZeroTransfer();
        if (blocked[from]) revert Blocked(from);
        if (blocked[to]) revert Blocked(to);
        return !returnFalse;
    }

    function _move(
        address from,
        address to,
        uint256 amount
    ) private {
        uint256 fee = amount * feeBps / 10_000;
        if (fee != 0) _transfer(from, FEE_SINK, fee);
        _transfer(from, to, amount - fee);
        uint256 senderFee = amount * senderFeeBps / 10_000;
        if (senderFee != 0) _transfer(from, FEE_SINK, senderFee);
    }

    function _afterMove() private {
        address target = hookTarget;
        if (target == address(0)) return;
        (bool ok, bytes memory reason) = target.call(hookData);
        if (!ok) {
            // Bubble the inner revert unchanged, so the outer call fails with the reentered contract's error.
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }
}
