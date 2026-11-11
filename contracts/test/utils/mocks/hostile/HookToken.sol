// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title HookToken
/// @notice 18-decimal ERC-20 that, once armed, calls `hookTarget` with `hookData` from inside every `transferFrom`
/// before moving the tokens, and records whether that reentrant call succeeded and what it returned.
contract HookToken is ERC20 {
    address public hookTarget;
    bytes public hookData;
    bool public hookCalled;
    bool public hookSucceeded;
    bytes public hookReturn;

    constructor() ERC20("Hook", "HOOK") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }

    function arm(
        address target,
        bytes calldata data
    ) external {
        hookTarget = target;
        hookData = data;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        address target = hookTarget;
        if (target != address(0)) {
            hookTarget = address(0);
            hookCalled = true;
            (hookSucceeded, hookReturn) = target.call(hookData);
        }
        return super.transferFrom(from, to, value);
    }
}
