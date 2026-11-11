// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title ICLFactory
/// @notice Subset of the Aerodrome Slipstream pool factory interface that Avana reads, copied from
/// `contracts/core/interfaces/ICLFactory.sol` of aerodrome-finance/slipstream `main` (read 2026-11-10), with identical selectors.
/// @dev Called by: the Slipstream LPVault and the MarketRegistry listing check. Pools are looked up by `tickSpacing`,
/// not by fee; the fee of a pool is set per pool by fee modules and is not derivable from its tick spacing. Base runs
/// four factory and NPM generations; a market binds to exactly one (factory, NPM) pair.
interface ICLFactory {
    /// @notice Returns the pool of a token pair and tick spacing, or address 0. Source: `ICLFactory.sol`.
    /// @dev Called by: Slipstream LPVault (`bindMarket`, `receivePosition`).
    function getPool(
        address tokenA,
        address tokenB,
        int24 tickSpacing
    ) external view returns (address pool);

    /// @notice Returns the pool implementation every pool of this factory is an EIP-1167 clone of. Source:
    /// `ICLFactory.sol`.
    /// @dev Called by: Slipstream LPVault (`bindMarket`, the clone-code check of `SPEC-AMM-SLIP-001`).
    function poolImplementation() external view returns (address);

    /// @notice Returns true when `pool` was created by this factory. Source: `ICLFactory.sol`.
    /// @dev Called by: Slipstream LPVault (`bindMarket`).
    function isPool(
        address pool
    ) external view returns (bool);

    /// @notice Returns the current swap fee of a pool in pips. Source: `ICLFactory.sol`.
    /// @dev Called by: the Lens and the listing check (information only; never a pricing input).
    function getSwapFee(
        address pool
    ) external view returns (uint24);

    /// @notice Returns the fee share redirected from unstaked liquidity, in pips. Source: `ICLFactory.sol`.
    /// @dev Called by: the Lens (information only).
    function getUnstakedFee(
        address pool
    ) external view returns (uint24);

    /// @notice Returns the default fee of a tick spacing, in pips. Source: `ICLFactory.sol`.
    /// @dev Called by: the listing check (information only).
    function tickSpacingToFee(
        int24 tickSpacing
    ) external view returns (uint24 fee);
}
