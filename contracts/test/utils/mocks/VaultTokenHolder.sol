// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IVaultToken} from "../../../src/vault-token/vault-token/IVaultToken.sol";

/// @title VaultTokenHolder
/// @notice Stand-in for an account that moves vault tokens (the Hub, a CDP Spoke, a proxy, LPVaultSwap, an outsider)
/// in property harnesses that cannot prank: each call is made by this contract and a revert bubbles up unchanged.
/// @dev The token is set once after deployment, because the token's constructor needs the holders' addresses.
contract VaultTokenHolder {
    IVaultToken internal TOKEN;

    function setToken(
        IVaultToken token
    ) external {
        require(address(TOKEN) == address(0), "set");
        TOKEN = token;
    }

    function transfer(
        address to,
        uint256 value
    ) external returns (bool) {
        return TOKEN.transfer(to, value);
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool) {
        return TOKEN.transferFrom(from, to, value);
    }

    function approve(
        address spender,
        uint256 value
    ) external returns (bool) {
        return TOKEN.approve(spender, value);
    }

    function mint(
        address to,
        uint256 value
    ) external {
        TOKEN.mint(to, value);
    }

    function burn(
        address from,
        uint256 value
    ) external {
        TOKEN.burn(from, value);
    }

    function addValidProxy(
        address proxy
    ) external {
        TOKEN.addValidProxy(proxy);
    }
}
