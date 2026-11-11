// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title ICLPool
/// @notice Subset of the Aerodrome Slipstream pool interface that Avana reads, copied from
/// `contracts/core/interfaces/pool/ICLPoolConstants.sol`, `ICLPoolState.sol` and `ICLPoolDerivedState.sol` of
/// aerodrome-finance/slipstream `main` (read 2026-11-10), with identical selectors.
/// @dev Called by: the Slipstream LPVault and the LPOracle of a Slipstream market. `slot0()` returns six fields (no
/// `feeProtocol`); a Uniswap v3 decoder of seven fields mis-decodes it, so the Slipstream integration uses this
/// interface only.
interface ICLPool {
    /// @notice Returns the factory that created the pool. Source: `ICLPoolConstants.sol`.
    function factory() external view returns (address);

    /// @notice Returns the first token of the pool. Source: `ICLPoolConstants.sol`.
    function token0() external view returns (address);

    /// @notice Returns the second token of the pool. Source: `ICLPoolConstants.sol`.
    function token1() external view returns (address);

    /// @notice Returns the pool's gauge, or address 0. Source: `ICLPoolConstants.sol`.
    /// @dev Called by: Slipstream LPVault to refuse gauge-staked positions.
    function gauge() external view returns (address);

    /// @notice Returns the NPM bound to the pool. Source: `ICLPoolConstants.sol`.
    /// @dev Called by: Slipstream LPVault (`bindMarket` requires it to equal the market's NPM).
    function nft() external view returns (address);

    /// @notice Returns the pool's tick spacing. Source: `ICLPoolConstants.sol`.
    function tickSpacing() external view returns (int24);

    /// @notice Returns the maximum liquidity per tick. Source: `ICLPoolConstants.sol`.
    /// @dev Called by: listing check, to bound `L / (S * 2^96)` (AMM-A3e).
    function maxLiquidityPerTick() external view returns (uint128);

    /// @notice Returns the packed pool state (six fields). Source: `ICLPoolState.sol`.
    /// @dev Called by: Slipstream LPVault (`unlocked`, observation cardinality); the fair price never reads
    /// `sqrtPriceX96` or `tick`.
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );

    /// @notice Returns the current swap fee in pips. Source: `ICLPoolState.sol`.
    function fee() external view returns (uint24);

    /// @notice Returns the in-range liquidity. Source: `ICLPoolState.sol`.
    /// @dev Called by: Slipstream LPVault for the pool-share risk metadata.
    function liquidity() external view returns (uint128);

    /// @notice Returns the in-range liquidity staked in the gauge. Source: `ICLPoolState.sol`.
    function stakedLiquidity() external view returns (uint128);

    /// @notice Returns tick cumulatives for each `secondsAgos` entry. Source: `ICLPoolDerivedState.sol`.
    /// @dev Called by: LPOracle consistency check; reverts when the buffer does not reach back far enough.
    function observe(
        uint32[] calldata secondsAgos
    ) external view returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
