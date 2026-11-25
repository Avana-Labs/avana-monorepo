// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IFirstLossReserve
/// @notice The money that covers bad debt of one `(Hub, debt asset)` before Aave's suppliers bear any of it. Two layers
/// use this one contract: Avana's First-Loss Reserve (`FIRST_LOSS_LAYER() == 0`) and, behind it, the DAO Deficit
/// Offset (`FIRST_LOSS_LAYER()` names the Avana layer). The offset pays only once the layer in front is empty or the
/// DAO has deactivated it on the Hub.
/// @dev Not an Aave Spoke: it has no users, reserves, oracle or liquidations. The Hub lists its address with a draw cap
/// of 0 only because Aave V4 lets a listed address burn nothing but its own added shares to cancel a deficit. Its
/// funds are those added shares. Every admin call goes through its AccessManager; `withdraw` runs only through a role
/// whose execution delay is 14 days. The design record is `contracts/design/reserve.md`.
interface IFirstLossReserve {
    /// @notice A zero address where one is required.
    error ZeroAddress();
    /// @notice The Hub does not list `asset` with its token decimals under `assetId`.
    error InvalidHubAsset(uint256 assetId);
    /// @notice The layer in front is not a reserve of the same Hub, asset and asset ID, or is itself an offset.
    error InvalidFirstLossLayer(address layer);
    /// @notice A zero amount.
    error ZeroAmount();
    /// @notice The Hub's balance did not rise by exactly the funded amount (a fee-on-transfer or rebasing asset).
    error TransferAmountMismatch(uint256 expected, uint256 received);
    /// @notice The Spoke's deficits may not be covered by this reserve.
    error SpokeNotAllowed(address spoke);
    /// @notice An allowed Spoke must be listed on the Hub asset.
    error SpokeNotListed(address spoke);
    /// @notice The Spoke has no recorded deficit, or this reserve holds nothing to pay with.
    error NothingToCover(address spoke);
    /// @notice The layer in front is active on the Hub and holds enough to cover the whole deficit, so it pays first.
    error FirstLossLayerNotExhausted(address layer, uint256 balance);
    /// @notice A withdrawal recipient that is zero, this reserve or the Hub.
    error InvalidRecipient(address to);
    /// @notice A withdrawal while an allowed Spoke still has a recorded deficit: coverage comes first.
    error DeficitOutstanding(address spoke);

    /// @notice `amount` of the asset was added to the reserve by `funder`, who gets no claim on it.
    event Funded(address indexed funder, uint256 amount, uint256 shares, uint256 balanceAfter);
    /// @notice `covered` of `spoke`'s deficit was cancelled by burning `shares` of the reserve.
    event DeficitCovered(
        address indexed spoke, address indexed caller, uint256 covered, uint256 shares, uint256 balanceAfter
    );
    /// @notice `amount` left the reserve to `to` through the 14-day withdraw role.
    event Withdrawn(address indexed to, uint256 amount, uint256 shares, uint256 balanceAfter);
    /// @notice A Spoke was allowed or disallowed.
    event SpokeAllowed(address indexed spoke, bool allowed);
    /// @notice The minimum balance was set.
    event MinimumSet(uint256 minimum);
    /// @notice A cover or withdrawal left the balance below the minimum; monitoring pages on it.
    event BelowMinimum(uint256 balance, uint256 minimum);

    /// @notice Pulls `amount` of the asset from the caller straight to the Hub and adds it to the reserve.
    /// @dev Open to anyone; the funder gets no claim.
    /// @return shares Hub added shares minted to the reserve.
    function fund(
        uint256 amount
    ) external returns (uint256 shares);

    /// @notice Cancels up to `maxAmount` of `spoke`'s recorded deficit with this reserve's funds.
    /// @dev Restricted (the coverage role). Pays `min(maxAmount, deficit - front, balance)`, where `front` is what the
    /// layer in front holds while it is active on the Hub (zero for Avana's own layer): an offset pays only the part
    /// of the deficit beyond that layer's funds, and reverts `FirstLossLayerNotExhausted` when they cover all of it.
    /// @return shares Added shares burned.
    /// @return covered Deficit cancelled, asset units.
    function coverDeficit(
        address spoke,
        uint256 maxAmount
    ) external returns (uint256 shares, uint256 covered);

    /// @notice Allows or disallows a CDP Spoke whose deficits this reserve covers.
    /// @dev Restricted. Allowing needs the Spoke listed on the Hub asset; disallowing is always possible.
    function setAllowedSpoke(
        address spoke,
        bool allowed
    ) external;

    /// @notice Sets the minimum balance; it never blocks funding, coverage or withdrawal, it only raises an alert.
    /// @dev Restricted.
    function setMinimum(
        uint256 newMinimum
    ) external;

    /// @notice Withdraws `min(amount, balance)` to `to`.
    /// @dev Restricted to the withdraw role, whose AccessManager execution delay is 14 days. Reverts
    /// `DeficitOutstanding` while an allowed Spoke has a recorded deficit.
    /// @return withdrawn The amount sent.
    function withdraw(
        uint256 amount,
        address to
    ) external returns (uint256 withdrawn);

    /// @notice What the reserve's added shares redeem for on the Hub now, rounded down.
    function fundedBalance() external view returns (uint256 balance);

    /// @notice The reserve's Hub added shares.
    function fundedShares() external view returns (uint256 shares);

    /// @notice Whether the balance is below the minimum.
    function isBelowMinimum() external view returns (bool below);

    /// @notice The minimum balance, asset units.
    function minimum() external view returns (uint256 amount);

    /// @notice Whether `spoke`'s deficits may be covered.
    function isAllowedSpoke(
        address spoke
    ) external view returns (bool allowed);

    /// @notice The layer in front of this one; zero for Avana's First-Loss Reserve, set for the DAO Deficit Offset.
    function FIRST_LOSS_LAYER() external view returns (address layer);

    /// @notice The Hub whose asset this reserve covers.
    function HUB() external view returns (address hub);

    /// @notice The covered asset.
    function ASSET() external view returns (address asset);

    /// @notice The asset's ID on the Hub.
    function ASSET_ID() external view returns (uint256 assetId);

    /// @notice The withdraw role's execution delay the deployment must set: 14 days.
    function WITHDRAWAL_DELAY() external view returns (uint32 delay);
}
