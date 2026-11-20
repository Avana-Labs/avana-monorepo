// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title IVaultToken
/// @notice The collateral ERC-20 of one band market, held by Aave. One base unit is one unit of credit: one unit of
/// liquidity spread over the market's band. Only Avana mints and burns it.
/// @dev Units move only from a registered account proxy to the Hub (supply), from the Hub to a registered proxy
/// (withdrawal) and from the Hub to the LiquidationModule (seizure). Assumes the reserve's `liquidationFee` is 0 and
/// receive-shares is off, so a seizure always moves tokens to its caller.
interface IVaultToken is IERC20Metadata {
    /// @notice Constructor arguments.
    /// @param name ERC-20 name.
    /// @param symbol ERC-20 symbol.
    /// @param decimals Token decimals, in [6, 18]; the market's LPOracle prices `10^decimals` units.
    /// @param marketId The LPVault market the token belongs to.
    /// @param hub The Aave V4 Hub that holds supplied tokens.
    /// @param liquidationModule The only receiver of seized tokens.
    /// @param authority The AccessManager: it grants `mint`, `burn` and `addValidProxy` to Avana's roles.
    struct Params {
        string name;
        string symbol;
        uint8 decimals;
        uint256 marketId;
        address hub;
        address liquidationModule;
        address authority;
    }

    /// @notice An account proxy was registered.
    event ProxyAdded(address indexed proxy);

    /// @notice A mint to an address that is not a registered proxy.
    error UnauthorizedRecipient(address to);

    /// @notice A transfer, or the holder of a burn (`to == address(0)`), off the allowed paths, or a zero transfer.
    error UnauthorizedTransfer(address from, address to);

    /// @notice A zero address argument.
    error ZeroAddress();

    /// @notice `addValidProxy` of the Hub, the LiquidationModule, the authority or the token itself.
    error ReservedAddress(address account);

    /// @notice A constructor argument is out of range or two bound addresses are equal.
    error InvalidDeployment();

    /// @notice Mints `amount` units to a registered proxy.
    /// @dev Restricted (AccessManager). Reverts `UnauthorizedRecipient` for any other recipient.
    function mint(
        address to,
        uint256 amount
    ) external;

    /// @notice Burns `amount` units from a registered proxy or the LiquidationModule, without an allowance.
    /// @dev Restricted (AccessManager). Reverts `UnauthorizedTransfer(from, 0)` for any other holder.
    function burn(
        address from,
        uint256 amount
    ) external;

    /// @notice Registers an account proxy as a holder; append-only, a repeat is a no-op.
    /// @dev Restricted (AccessManager).
    function addValidProxy(
        address proxy
    ) external;

    /// @notice Whether `account` is a registered proxy.
    function isValidProxy(
        address account
    ) external view returns (bool valid);

    /// @notice Whether a transfer from `from` to `to` is on an allowed path; a zero amount still reverts.
    function isAllowedTransfer(
        address from,
        address to
    ) external view returns (bool allowed);

    /// @notice The LPVault market ID.
    function marketId() external view returns (uint256 id);

    /// @notice The Aave V4 Hub that holds supplied tokens.
    function hub() external view returns (address hubAddress);

    /// @notice The only receiver of seized tokens.
    function liquidationModule() external view returns (address module);
}
