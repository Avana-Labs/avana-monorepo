// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IGsm
/// @notice Subset of the GHO Stability Module interface that Avana swap routes and the MarketRegistry call. Declarations
/// match `src/contracts/facilitators/gsm/interfaces/IGsm.sol` of aave/gho-core at commit
/// c6335a0bb9cba099960c5378b1ff0db190b8da8f, with identical selectors.
/// @dev Called by: `PegModule` swap routes of kind `Gsm` (Ethereum, backup slot of a GHO debt reserve only), and the
/// MarketRegistry's GSM health check in `setRoute` and `restoreRoute`.
interface IGsm {
    /// @notice Sells up to `maxAmount` of the underlying asset, pulled from `msg.sender` with `transferFrom`, for GHO
    /// sent to `receiver`; reverts while the GSM is frozen or seized, for a zero sold amount, and above the exposure cap.
    /// Source: `IGsm.sol` and `Gsm.sol` `_sellAsset` (gho-core c6335a0).
    /// @dev Called by: `PegModule` swap routes of kind `Gsm`.
    /// @param maxAmount The maximum amount of the underlying asset to sell.
    /// @param receiver Recipient of the GHO bought.
    /// @return The amount of underlying asset sold and the amount of GHO bought.
    function sellAsset(
        uint256 maxAmount,
        address receiver
    ) external returns (uint256, uint256);

    /// @notice Returns the GHO token. Source: `IGsm.sol` (gho-core c6335a0).
    /// @dev Called by: `PegModule` swap routes of kind `Gsm`, in the constructor.
    function GHO_TOKEN() external view returns (address);

    /// @notice Returns the GSM's underlying asset (a static aToken for a `Gsm4626`). Source: `IGsm.sol` (gho-core
    /// c6335a0).
    /// @dev Called by: `PegModule` swap routes of kind `Gsm`, in the constructor.
    function UNDERLYING_ASSET() external view returns (address);

    /// @notice Returns whether the GSM is frozen. Source: `IGsm.sol` (gho-core c6335a0).
    /// @dev Called by: the MarketRegistry in `setRoute` and `restoreRoute` of a route that calls a GSM.
    function getIsFrozen() external view returns (bool);

    /// @notice Returns whether the GSM has been seized. Source: `IGsm.sol` (gho-core c6335a0).
    /// @dev Called by: the MarketRegistry in `setRoute` and `restoreRoute` of a route that calls a GSM.
    function getIsSeized() external view returns (bool);

    /// @notice Returns the exposure limit to the underlying asset. Source: `IGsm.sol` (gho-core c6335a0).
    /// @dev Called by: the MarketRegistry in `setRoute` and `restoreRoute` of a route that calls a GSM.
    function getExposureCap() external view returns (uint128);
}
