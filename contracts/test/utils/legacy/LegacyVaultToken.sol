// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILegacyVaultToken} from "../../../src/legacy/ILegacyVaultToken.sol";
import {VaultTokenBindings} from "../../../src/types/MarketTypes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title LegacyVaultToken
/// @notice Collateral-only ERC-20 of one market. Only the AaveAdapter mints, burns and registers proxies.
/// @dev Test stand-in for the pre-refactor token, kept so the legacy MarketRegistry and RiskModule tests run until
/// step 4 replaces them. Not upgradeable, no owner. `_update` enforces the transfer path rule on every balance change.
contract LegacyVaultToken is ERC20, ILegacyVaultToken {
    uint8 private constant MIN_DECIMALS = 6;
    uint8 private constant MAX_DECIMALS = 18;

    uint32 private immutable INTEGRATION_ID;
    address private immutable INTEGRATION;
    bytes32 private immutable MARKET_KEY;
    address private immutable HUB;
    address private immutable SPOKE;
    uint256 private immutable MARKET_ID;
    address private immutable LP_ORACLE;
    address private immutable ADAPTER;
    /// @dev LPVaultSwap: the only seizure recipient.
    address private immutable LP_VAULT_SWAP;
    address private immutable COLLATERALIZATION;
    uint8 private immutable DECIMALS;

    /// @inheritdoc ILegacyVaultToken
    mapping(address account => bool valid) public override isValidProxy;

    constructor(
        VaultTokenBindings memory b
    ) ERC20(b.name, b.symbol) {
        _checkAddressBindings(
            [b.integration, b.hub, b.spoke, b.lpOracle, b.adapter, b.lpVaultSwap, b.collateralization]
        );
        if (
            b.integrationId == 0 || b.marketKey == bytes32(0) || b.marketId == 0 || b.decimals < MIN_DECIMALS
                || b.decimals > MAX_DECIMALS
        ) revert InvalidBinding();
        MARKET_KEY = b.marketKey;
        INTEGRATION_ID = b.integrationId;
        INTEGRATION = b.integration;
        HUB = b.hub;
        SPOKE = b.spoke;
        MARKET_ID = b.marketId;
        LP_ORACLE = b.lpOracle;
        ADAPTER = b.adapter;
        LP_VAULT_SWAP = b.lpVaultSwap;
        COLLATERALIZATION = b.collateralization;
        DECIMALS = b.decimals;
    }

    modifier onlyAdapter() {
        if (msg.sender != ADAPTER) revert OnlyAdapter();
        _;
    }

    /// @inheritdoc ILegacyVaultToken
    function mint(
        address to,
        uint256 amount
    ) external override onlyAdapter {
        if (to == address(0)) revert ZeroAddress();
        _mint(to, amount);
    }

    /// @inheritdoc ILegacyVaultToken
    function burn(
        address from,
        uint256 amount
    ) external override onlyAdapter {
        if (from == address(0)) revert ZeroAddress();
        _burn(from, amount);
    }

    /// @inheritdoc ILegacyVaultToken
    function addValidProxy(
        address proxy
    ) external override onlyAdapter {
        if (proxy == address(0)) revert ZeroAddress();
        if (_isReserved(proxy)) revert ReservedAddress(proxy);
        if (isValidProxy[proxy]) return;
        isValidProxy[proxy] = true;
        emit ProxyAdded(proxy);
    }

    /// @inheritdoc IERC20
    function transfer(
        address to,
        uint256 value
    ) public override(ERC20, IERC20) returns (bool) {
        _requireAllowedTransfer(msg.sender, to, value);
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @inheritdoc IERC20
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override(ERC20, IERC20) returns (bool) {
        _requireAllowedTransfer(from, to, value);
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    /// @inheritdoc IERC20Metadata
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return DECIMALS;
    }

    /// @inheritdoc ILegacyVaultToken
    function isAllowedRecipient(
        address account
    ) external view override returns (bool allowed) {
        allowed = account == HUB || account == LP_VAULT_SWAP || isValidProxy[account];
    }

    /// @inheritdoc ILegacyVaultToken
    function isAllowedTransfer(
        address from,
        address to
    ) public view override returns (bool allowed) {
        allowed = (to == HUB && isValidProxy[from]) || (from == HUB && (isValidProxy[to] || to == LP_VAULT_SWAP));
    }

    /// @inheritdoc ILegacyVaultToken
    function marketKey() external view override returns (bytes32 key) {
        key = MARKET_KEY;
    }

    /// @inheritdoc ILegacyVaultToken
    function integrationId() external view override returns (uint32 id) {
        id = INTEGRATION_ID;
    }

    /// @inheritdoc ILegacyVaultToken
    function integration() external view override returns (address lpVault) {
        lpVault = INTEGRATION;
    }

    /// @inheritdoc ILegacyVaultToken
    function hub() external view override returns (address hubAddress) {
        hubAddress = HUB;
    }

    /// @inheritdoc ILegacyVaultToken
    function spoke() external view override returns (address spokeAddress) {
        spokeAddress = SPOKE;
    }

    /// @inheritdoc ILegacyVaultToken
    function marketId() external view override returns (uint256 id) {
        id = MARKET_ID;
    }

    /// @inheritdoc ILegacyVaultToken
    function lpOracle() external view override returns (address oracle) {
        oracle = LP_ORACLE;
    }

    /// @inheritdoc ILegacyVaultToken
    function adapter() external view override returns (address adapterAddress) {
        adapterAddress = ADAPTER;
    }

    /// @inheritdoc ILegacyVaultToken
    function lpVaultSwap() external view override returns (address lpVaultSwapAddress) {
        lpVaultSwapAddress = LP_VAULT_SWAP;
    }

    /// @inheritdoc ILegacyVaultToken
    function collateralization() external view override returns (address collateralizationAddress) {
        collateralizationAddress = COLLATERALIZATION;
    }

    function _update(
        address from,
        address to,
        uint256 value
    ) internal override {
        if (from == address(0)) {
            if (!isValidProxy[to]) revert UnauthorizedRecipient(to);
        } else if (to == address(0)) {
            if (!isValidProxy[from] && from != LP_VAULT_SWAP) revert UnauthorizedTransfer(from, address(0));
        } else {
            _requireAllowedTransfer(from, to, value);
        }
        super._update(from, to, value);
    }

    /// @notice A transfer moves a non-zero amount on an allowed path; a zero amount is on no path.
    function _requireAllowedTransfer(
        address from,
        address to,
        uint256 value
    ) private view {
        if (value == 0 || !isAllowedTransfer(from, to)) revert UnauthorizedTransfer(from, to);
    }

    function _isReserved(
        address account
    ) private view returns (bool reserved) {
        reserved = account == HUB || account == SPOKE || account == ADAPTER || account == LP_VAULT_SWAP
            || account == COLLATERALIZATION || account == INTEGRATION || account == LP_ORACLE
            || account == address(this);
    }

    function _checkAddressBindings(
        address[7] memory bound
    ) private view {
        bool zero = false;
        bool duplicate = false;
        for (uint256 i = 0; i < 7; ++i) {
            if (bound[i] == address(0)) zero = true;
            if (bound[i] == address(this)) duplicate = true;
            for (uint256 j = i + 1; j < 7; ++j) {
                if (bound[i] == bound[j]) duplicate = true;
            }
        }
        if (zero) revert ZeroAddress();
        if (duplicate) revert InvalidBinding();
    }
}
