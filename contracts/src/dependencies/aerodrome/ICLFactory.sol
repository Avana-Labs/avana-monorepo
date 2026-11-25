// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title ICLFactory
/// @notice Subset of the Aerodrome Slipstream pool factory that Avana reads.
/// @dev Copied from aerodrome-finance/slipstream `ICLFactory.sol`; pools are keyed by `tickSpacing`, not fee.
interface ICLFactory {
    /// @notice Returns the pool of a token pair and tick spacing, or address 0.
    function getPool(
        address tokenA,
        address tokenB,
        int24 tickSpacing
    ) external view returns (address pool);

    /// @notice Returns the pool implementation every pool of this factory is an EIP-1167 clone of.
    function poolImplementation() external view returns (address);

    /// @notice Returns true when `pool` was created by this factory.
    function isPool(
        address pool
    ) external view returns (bool);

    /// @notice Returns the current swap fee of a pool in pips.
    function getSwapFee(
        address pool
    ) external view returns (uint24);

    /// @notice Returns the fee share redirected from unstaked liquidity, in pips.
    function getUnstakedFee(
        address pool
    ) external view returns (uint24);

    /// @notice Returns the default fee of a tick spacing, in pips.
    function tickSpacingToFee(
        int24 tickSpacing
    ) external view returns (uint24 fee);
}
