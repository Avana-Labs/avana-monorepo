// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationAdapter} from "../../../src/custody/collateralization/ICollateralizationAdapter.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILock} from "../../../src/lock/lock/ILock.sol";
import {IPositionProxy} from "../../../src/proxy/position-proxy/IPositionProxy.sol";
import {IVaultToken} from "../../../src/vault-token/vault-token/IVaultToken.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title HostileAdapter
/// @notice A hostile AaveAdapter implementation for the blast-radius tests (TEST-130, TEST-195, TEST-210): installed
/// behind the Adapter's fixed proxy through the timelock, it drives every PositionProxy, mints, burns and registers
/// with the Adapter's own authority, and tries everything outside that authority.
/// @dev Keeps the storage layout: it declares no state, so the Adapter's ERC-7201 namespace, the AccessControl and
/// ERC-1967 slots are untouched. Anyone may call it or upgrade it, as a hostile implementation would allow.
contract HostileAdapter is UUPSUpgradeable {
    function _authorizeUpgrade(
        address
    ) internal override {}

    /// @notice Has `proxy` borrow `amount` of reserve `reserveId` on its own account and send it to `to`.
    function borrowAgainst(
        address proxy,
        address spoke,
        uint256 reserveId,
        uint256 amount,
        address to
    ) external {
        IPositionProxy(proxy).execute(spoke, abi.encodeCall(IAaveV4Spoke.borrow, (reserveId, amount, proxy)));
        address asset = IAaveV4Spoke(spoke).getReserve(reserveId).underlying;
        IPositionProxy(proxy).execute(asset, abi.encodeCall(IERC20.transfer, (to, amount)));
    }

    /// @notice Has `proxy` withdraw `units` of its supplied vault tokens (they land in the proxy).
    function withdrawUnits(
        address proxy,
        address spoke,
        uint256 reserveId,
        uint256 units
    ) external {
        IPositionProxy(proxy).execute(spoke, abi.encodeCall(IAaveV4Spoke.withdraw, (reserveId, units, proxy)));
    }

    /// @notice Has `proxy` supply `units` of `vaultToken` it holds.
    function supplyUnits(
        address proxy,
        address spoke,
        address vaultToken,
        uint256 reserveId,
        uint256 units
    ) external {
        IPositionProxy(proxy).execute(vaultToken, abi.encodeCall(IERC20.approve, (spoke, units)));
        IPositionProxy(proxy).execute(spoke, abi.encodeCall(IAaveV4Spoke.supply, (reserveId, units, proxy)));
    }

    function mintTo(
        address vaultToken,
        address to,
        uint256 amount
    ) external {
        IVaultToken(vaultToken).mint(to, amount);
    }

    function burnFrom(
        address vaultToken,
        address from,
        uint256 amount
    ) external {
        IVaultToken(vaultToken).burn(from, amount);
    }

    function register(
        address vaultToken,
        address account
    ) external {
        IVaultToken(vaultToken).addValidProxy(account);
    }

    /// @notice Takes the Lock as the Adapter and asks Collateralization to release a record's position.
    function releaseRecord(
        address lock,
        address collateralization,
        address proxy,
        address vaultToken,
        bytes32 positionKey,
        uint256 units
    ) external {
        ILock(lock).acquire();
        ICollateralizationAdapter(collateralization).release(proxy, vaultToken, positionKey, units);
        ILock(lock).release();
    }

    /// @notice Any call as the Adapter.
    function callAs(
        address target,
        bytes calldata data
    ) external returns (bool ok, bytes memory ret) {
        (ok, ret) = target.call(data);
    }

    /// @notice Any call as a proxy.
    function execAs(
        address proxy,
        address target,
        bytes calldata data
    ) external returns (bytes memory ret) {
        ret = IPositionProxy(proxy).execute(target, data);
    }
}
