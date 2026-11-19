// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IVaultToken} from "./IVaultToken.sol";
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title VaultToken
/// @notice The collateral ERC-20 of one band market: one base unit is one unit of credit. Avana's roles mint, burn and
/// register proxies; Aave holds the supplied tokens.
/// @dev Not upgradeable. The AccessManager decides who may mint, burn and register (the AaveAdapter for pledges and
/// withdrawals, the LiquidationModule for seized tokens), so a new adapter needs a role grant, not a new token.
/// `_update` applies the path rule to every balance change, the ERC-20 transfers and the mint and burn alike.
contract VaultToken is ERC20, AccessManaged, IVaultToken {
    uint8 private constant _MIN_DECIMALS = 6;
    uint8 private constant _MAX_DECIMALS = 18;

    uint8 private immutable _DECIMALS;
    uint256 private immutable _MARKET_ID;
    address private immutable _HUB;
    address private immutable _LIQUIDATION_MODULE;

    /// @inheritdoc IVaultToken
    mapping(address account => bool valid) public override isValidProxy;

    /// @dev Reverts `ZeroAddress` for a zero Hub, LiquidationModule or authority, and `InvalidDeployment` for a zero
    /// market, decimals outside [6, 18], an empty name or symbol, or two equal bound addresses.
    constructor(
        Params memory p
    ) ERC20(p.name, p.symbol) AccessManaged(p.authority) {
        if (p.hub == address(0) || p.liquidationModule == address(0) || p.authority == address(0)) {
            revert ZeroAddress();
        }
        if (
            p.marketId == 0 || p.decimals < _MIN_DECIMALS || p.decimals > _MAX_DECIMALS || bytes(p.name).length == 0
                || bytes(p.symbol).length == 0 || p.hub == p.liquidationModule || p.hub == p.authority
                || p.liquidationModule == p.authority
        ) revert InvalidDeployment();
        _DECIMALS = p.decimals;
        _MARKET_ID = p.marketId;
        _HUB = p.hub;
        _LIQUIDATION_MODULE = p.liquidationModule;
    }

    /// @inheritdoc IVaultToken
    function mint(
        address to,
        uint256 amount
    ) external override restricted {
        if (to == address(0)) revert ZeroAddress();
        _mint(to, amount);
    }

    /// @inheritdoc IVaultToken
    function burn(
        address from,
        uint256 amount
    ) external override restricted {
        if (from == address(0)) revert ZeroAddress();
        _burn(from, amount);
    }

    /// @inheritdoc IVaultToken
    function addValidProxy(
        address proxy
    ) external override restricted {
        if (proxy == address(0)) revert ZeroAddress();
        if (proxy == _HUB || proxy == _LIQUIDATION_MODULE || proxy == authority() || proxy == address(this)) {
            revert ReservedAddress(proxy);
        }
        if (isValidProxy[proxy]) return;
        isValidProxy[proxy] = true;
        emit ProxyAdded(proxy);
    }

    /// @inheritdoc IERC20Metadata
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return _DECIMALS;
    }

    /// @inheritdoc IVaultToken
    function isAllowedTransfer(
        address from,
        address to
    ) public view override returns (bool allowed) {
        allowed =
            (to == _HUB && isValidProxy[from]) || (from == _HUB && (isValidProxy[to] || to == _LIQUIDATION_MODULE));
    }

    /// @inheritdoc IVaultToken
    function marketId() external view override returns (uint256) {
        return _MARKET_ID;
    }

    /// @inheritdoc IVaultToken
    function hub() external view override returns (address) {
        return _HUB;
    }

    /// @inheritdoc IVaultToken
    function liquidationModule() external view override returns (address) {
        return _LIQUIDATION_MODULE;
    }

    /// @dev The path rule: a mint goes to a registered proxy, a burn comes from a registered proxy or the
    /// LiquidationModule, and a transfer moves a non-zero amount on an allowed path.
    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from == address(0)) {
            if (!isValidProxy[to]) revert UnauthorizedRecipient(to);
        } else if (to == address(0)) {
            if (!isValidProxy[from] && from != _LIQUIDATION_MODULE) revert UnauthorizedTransfer(from, address(0));
        } else if (value == 0 || !isAllowedTransfer(from, to)) {
            revert UnauthorizedTransfer(from, to);
        }
        super._update(from, to, value);
    }
}
