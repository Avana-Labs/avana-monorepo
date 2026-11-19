// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title ILegacyVaultToken
/// @notice Collateral-only ERC-20 of one market; one base unit equals one position unit Collateralization credited.
/// @dev Units move only between proxies, the Hub and LPVaultSwap. Assumes the reserve's `liquidationFee` is 0.
interface ILegacyVaultToken is IERC20Metadata {
    event ProxyAdded(address indexed proxy);

    error OnlyAdapter();

    /// @notice `to` of a mint is not a registered proxy.
    error UnauthorizedRecipient(address to);

    /// @notice A transfer, or the source of a burn (`to == address(0)`), is off the five allowed paths.
    /// @param from The sender, or the holder of a burn.
    /// @param to The recipient, or `address(0)` for a burn.
    error UnauthorizedTransfer(address from, address to);

    /// @notice `mint` to, `burn` from or `addValidProxy` of `address(0)`, or a zero address binding at construction.
    error ZeroAddress();

    /// @notice `addValidProxy` of one of the token's own bindings or of the token itself.
    error ReservedAddress(address account);

    /// @notice A constructor binding is zero, duplicated or the token itself, or `decimals` is outside [6, 18].
    error InvalidBinding();

    /// @notice Mints credited units.
    /// @dev Adapter only.
    /// @param amount Base units, equal to credited position units.
    function mint(
        address to,
        uint256 amount
    ) external;

    /// @notice Burns from any holder without an allowance.
    /// @dev Adapter only; `from` must be a registered proxy or LPVaultSwap.
    function burn(
        address from,
        uint256 amount
    ) external;

    /// @notice Registers a proxy as a valid recipient; append-only.
    /// @dev Adapter only. Refuses the token's own bindings; a repeat registration is a no-op.
    function addValidProxy(
        address proxy
    ) external;

    /// @notice Returns whether `account` is a registered proxy of this market.
    function isValidProxy(
        address account
    ) external view returns (bool valid);

    /// @notice Returns whether `account` may hold the token: the set any unit can reach on the allowed paths.
    function isAllowedRecipient(
        address account
    ) external view returns (bool allowed);

    /// @notice Returns whether a `transfer` or `transferFrom` from `from` to `to` is on an allowed path.
    /// @dev Supply, withdrawal and seizure only. Ignores the amount; a zero transfer still reverts.
    function isAllowedTransfer(
        address from,
        address to
    ) external view returns (bool allowed);

    /// @notice Returns the market key the token was deployed for.
    function marketKey() external view returns (bytes32 key);

    /// @notice Returns the market's AMM integration identifier.
    function integrationId() external view returns (uint32 id);

    /// @notice Returns the market's LPVault, the integration registered for `integrationId()` at deployment.
    function integration() external view returns (address lpVault);

    /// @notice Returns the Hub of the market's CDP Spoke, which holds the supplied tokens.
    function hub() external view returns (address hubAddress);

    /// @notice Returns the CDP Spoke holding the token's reserve.
    function spoke() external view returns (address spokeAddress);

    /// @notice Returns the market's MarketRegistry `marketId`, non-zero.
    function marketId() external view returns (uint256 id);

    /// @notice Returns the market's LPOracle, the Aave price source of the reserve.
    function lpOracle() external view returns (address oracle);

    /// @notice Returns the AaveAdapter, the only minter, burner and registry writer.
    function adapter() external view returns (address adapterAddress);

    /// @notice Returns LPVaultSwap.
    function lpVaultSwap() external view returns (address lpVaultSwapAddress);

    /// @notice Returns Collateralization, the backing ledger the token is bound to.
    function collateralization() external view returns (address collateralizationAddress);
}
