// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {VaultTokenBindings} from "../../types/VaultTokenBindings.sol";
import {IVaultToken} from "./IVaultToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title VaultToken
/// @notice Collateral-only ERC-20 of one market on one CDP Spoke: one base unit is one unit Collateralization credited
/// in a position the market's LPVault holds. Only the AaveAdapter mints, burns and registers proxies, and units move
/// only on the five paths of `REQ-VTOKEN-006`: mint to a registered proxy, proxy to the home Hub (supply), Hub to a
/// registered proxy (withdrawal), Hub to LPVaultSwap (seizure), and burn from a registered proxy or LPVaultSwap.
/// @dev Immutable, with no owner, admin, role, setter, pause, blocklist, `permit`, hook, callback or `selfdestruct`;
/// OpenZeppelin v5.1.0 `ERC20` for balances, allowances, events and errors. Every balance change passes `_update`,
/// which enforces the path rule; `transfer` and `transferFrom` check the path first, so an off-path call reverts with
/// `UnauthorizedTransfer` before any receiver or allowance check. The token calls no other contract: its bindings are
/// compared and exposed, never called. Deployed by the VaultTokenFactory with CREATE3 at
/// `salt = keccak256(abi.encode(spoke, marketKey))`; the token does not know the factory.
/// @custom:spec REQ-VTOKEN-001, REQ-VTOKEN-002, REQ-VTOKEN-003, REQ-VTOKEN-005, REQ-VTOKEN-006, REQ-VTOKEN-007, REQ-VTOKEN-015, REQ-VTOKEN-016, REQ-VTOKEN-017, REQ-VTOKEN-026, REQ-VTOKEN-027, REQ-VTOKEN-028, REQ-VTOKEN-029, REQ-VTOKEN-048, SPEC-UNIT-002, INV-009, INV-010, INV-011, INV-012, Q-224
contract VaultToken is ERC20, IVaultToken {
    /// @dev Lowest and highest decimals `d` of `SPEC-UNIT-001`.
    uint8 private constant MIN_DECIMALS = 6;
    uint8 private constant MAX_DECIMALS = 18;

    /// @dev The market's AMM integration identifier.
    uint32 private immutable INTEGRATION_ID;
    /// @dev The LPVault registered for `INTEGRATION_ID` in the factory at deployment.
    address private immutable INTEGRATION;
    /// @dev The market's key, `SPEC-AMM-CORE-002`.
    bytes32 private immutable MARKET_KEY;
    /// @dev The home Hub of the CDP Spoke.
    address private immutable HUB;
    /// @dev The CDP Spoke holding the token's reserve.
    address private immutable SPOKE;
    /// @dev The market's MarketRegistry `marketId`.
    uint256 private immutable MARKET_ID;
    /// @dev The market's LPOracle fixed proxy address.
    address private immutable LP_ORACLE;
    /// @dev The chain's AaveAdapter fixed proxy address: the only minter, burner and registry writer.
    address private immutable ADAPTER;
    /// @dev The chain's LPVaultSwap fixed proxy address: the only seizure recipient.
    address private immutable LP_VAULT_SWAP;
    /// @dev The chain's Collateralization.
    address private immutable COLLATERALIZATION;
    /// @dev Token decimals `d`.
    uint8 private immutable DECIMALS;

    /// @inheritdoc IVaultToken
    mapping(address account => bool valid) public override isValidProxy;

    /// @notice Fixes every binding of the market's token; the VaultTokenFactory passes its own `ADAPTER`,
    /// `LP_VAULT_SWAP`, `COLLATERALIZATION` and `lpVaultOf(integrationId)`.
    /// @dev Reverts `ZeroAddress` for a zero address binding, checked first, and `InvalidBinding` for two equal address
    /// bindings, a binding equal to the token's own address, a zero `integrationId`, `marketKey` or `marketId`, or
    /// decimals outside [6, 18]. None of the bound contracts needs code at deployment.
    /// @param b The market's bindings, name and symbol.
    /// @custom:spec REQ-VTOKEN-003, REQ-VTOKEN-004, REQ-VTOKEN-022, REQ-VTOKEN-028, REQ-VTOKEN-038, REQ-VTOKEN-046, SPEC-UNIT-001
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

    /// @custom:spec REQ-VTOKEN-012, REQ-VTOKEN-014, REQ-VTOKEN-027, REQ-VTOKEN-032, REQ-VTOKEN-039
    modifier onlyAdapter() {
        if (msg.sender != ADAPTER) revert OnlyAdapter();
        _;
    }

    // ─── Adapter-only ───

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-012, REQ-VTOKEN-013, REQ-VTOKEN-015, REQ-VTOKEN-027, REQ-VTOKEN-032, REQ-VTOKEN-033, REQ-VTOKEN-043, SPEC-UNIT-002, INV-009
    function mint(
        address to,
        uint256 amount
    ) external override onlyAdapter {
        if (to == address(0)) revert ZeroAddress();
        _mint(to, amount);
    }

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-014, REQ-VTOKEN-015, REQ-VTOKEN-027, REQ-VTOKEN-032, REQ-VTOKEN-033, REQ-VTOKEN-034, REQ-VTOKEN-042, REQ-VTOKEN-043, SPEC-UNIT-002, INV-010
    function burn(
        address from,
        uint256 amount
    ) external override onlyAdapter {
        if (from == address(0)) revert ZeroAddress();
        _burn(from, amount);
    }

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-007, REQ-VTOKEN-027, REQ-VTOKEN-032, REQ-VTOKEN-039, REQ-VTOKEN-042, REQ-VTOKEN-043, REQ-VTOKEN-047, INV-012
    function addValidProxy(
        address proxy
    ) external override onlyAdapter {
        if (proxy == address(0)) revert ZeroAddress();
        if (_isReserved(proxy)) revert ReservedAddress(proxy);
        if (isValidProxy[proxy]) return;
        isValidProxy[proxy] = true;
        emit ProxyAdded(proxy);
    }

    // ─── ERC-20 movement ───

    /// @inheritdoc IERC20
    /// @custom:spec REQ-VTOKEN-006, REQ-VTOKEN-008, REQ-VTOKEN-009, REQ-VTOKEN-030, REQ-VTOKEN-031, REQ-VTOKEN-041, REQ-VTOKEN-048
    function transfer(
        address to,
        uint256 value
    ) public override(ERC20, IERC20) returns (bool) {
        _requireAllowedTransfer(msg.sender, to, value);
        // OpenZeppelin v5.1.0 `ERC20.transfer` body, after the path check.
        _transfer(msg.sender, to, value);
        return true;
    }

    /// @inheritdoc IERC20
    /// @custom:spec REQ-VTOKEN-006, REQ-VTOKEN-008, REQ-VTOKEN-010, REQ-VTOKEN-011, REQ-VTOKEN-030, REQ-VTOKEN-034, REQ-VTOKEN-041, REQ-VTOKEN-048
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override(ERC20, IERC20) returns (bool) {
        _requireAllowedTransfer(from, to, value);
        // OpenZeppelin v5.1.0 `ERC20.transferFrom` body, after the path check: spend the caller's allowance, then move.
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    // ─── Views ───

    /// @inheritdoc IERC20Metadata
    /// @custom:spec REQ-VTOKEN-004, SPEC-UNIT-001
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return DECIMALS;
    }

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-006, REQ-VTOKEN-040
    function isAllowedRecipient(
        address account
    ) external view override returns (bool allowed) {
        allowed = account == HUB || account == LP_VAULT_SWAP || isValidProxy[account];
    }

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-006, REQ-VTOKEN-040, REQ-VTOKEN-041
    function isAllowedTransfer(
        address from,
        address to
    ) public view override returns (bool allowed) {
        allowed = (to == HUB && isValidProxy[from]) || (from == HUB && (isValidProxy[to] || to == LP_VAULT_SWAP));
    }

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-003, REQ-VTOKEN-020
    function marketKey() external view override returns (bytes32 key) {
        key = MARKET_KEY;
    }

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-003
    function integrationId() external view override returns (uint32 id) {
        id = INTEGRATION_ID;
    }

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-003
    function integration() external view override returns (address lpVault) {
        lpVault = INTEGRATION;
    }

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-003, REQ-VTOKEN-028
    function hub() external view override returns (address hubAddress) {
        hubAddress = HUB;
    }

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-003, REQ-VTOKEN-028
    function spoke() external view override returns (address spokeAddress) {
        spokeAddress = SPOKE;
    }

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-003, REQ-VTOKEN-038
    function marketId() external view override returns (uint256 id) {
        id = MARKET_ID;
    }

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-003, REQ-VTOKEN-038
    function lpOracle() external view override returns (address oracle) {
        oracle = LP_ORACLE;
    }

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-003, REQ-VTOKEN-027
    function adapter() external view override returns (address adapterAddress) {
        adapterAddress = ADAPTER;
    }

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-003
    function lpVaultSwap() external view override returns (address lpVaultSwapAddress) {
        lpVaultSwapAddress = LP_VAULT_SWAP;
    }

    /// @inheritdoc IVaultToken
    /// @custom:spec REQ-VTOKEN-003
    function collateralization() external view override returns (address collateralizationAddress) {
        collateralizationAddress = COLLATERALIZATION;
    }

    // ─── Internal ───

    /// @notice The single choke point of every balance change: a mint must reach a registered proxy, a burn must come
    /// from a registered proxy or LPVaultSwap, and a transfer must be a non-zero amount on an allowed path.
    /// @dev `_mint` and `_burn` already refuse `address(0)` as the other side; `mint` and `burn` check it first. A zero
    /// mint or burn by the Adapter keeps the path rule and changes no balance (`REQ-VTOKEN-048`).
    /// @custom:spec REQ-VTOKEN-006, REQ-VTOKEN-008, REQ-VTOKEN-012, REQ-VTOKEN-014, REQ-VTOKEN-015, REQ-VTOKEN-026, REQ-VTOKEN-033, REQ-VTOKEN-041, REQ-VTOKEN-048, INV-011
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
    /// @custom:spec REQ-VTOKEN-008, REQ-VTOKEN-030, REQ-VTOKEN-048
    function _requireAllowedTransfer(
        address from,
        address to,
        uint256 value
    ) private view {
        if (value == 0 || !isAllowedTransfer(from, to)) revert UnauthorizedTransfer(from, to);
    }

    /// @custom:spec REQ-VTOKEN-039, REQ-VTOKEN-047
    function _isReserved(
        address account
    ) private view returns (bool reserved) {
        reserved = account == HUB || account == SPOKE || account == ADAPTER || account == LP_VAULT_SWAP
            || account == COLLATERALIZATION || account == INTEGRATION || account == LP_ORACLE
            || account == address(this);
    }

    /// @notice Reverts `ZeroAddress` if a binding is zero, else `InvalidBinding` if two bindings are equal or one is
    /// the token's own address.
    /// @custom:spec REQ-VTOKEN-046
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
