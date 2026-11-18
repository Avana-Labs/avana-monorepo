// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IGsm
/// @notice Subset of the GHO Stability Module that Avana swap routes and the MarketRegistry call.
/// @dev Matches aave/gho-core `IGsm.sol` (c6335a0), identical selectors.
interface IGsm {
    /// @notice Sells up to `maxAmount` of the underlying asset, pulled from `msg.sender` with `transferFrom`, for GHO
    /// sent to `receiver`; reverts while the GSM is frozen or seized, for a zero sold amount, and above the exposure
    /// cap.
    /// @param maxAmount The maximum amount of the underlying asset to sell.
    /// @return The amount of underlying asset sold and the amount of GHO bought.
    function sellAsset(
        uint256 maxAmount,
        address receiver
    ) external returns (uint256, uint256);

    /// @notice Returns the GHO token.
    function GHO_TOKEN() external view returns (address);

    /// @notice Returns the GSM's underlying asset (a static aToken for a `Gsm4626`).
    function UNDERLYING_ASSET() external view returns (address);

    /// @notice Returns whether the GSM is frozen.
    function getIsFrozen() external view returns (bool);

    /// @notice Returns whether the GSM has been seized.
    function getIsSeized() external view returns (bool);

    /// @notice Returns the exposure limit to the underlying asset.
    function getExposureCap() external view returns (uint128);
}
