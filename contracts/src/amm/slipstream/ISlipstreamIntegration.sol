// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IClIntegration} from "../IClIntegration.sol";

/// @title ISlipstreamIntegration
/// @notice The Aerodrome Slipstream LPVault on Base: custody of unstaked Slipstream positions in exact-range markets,
/// reusing the v3 liquidity math.
/// @dev Differences from Uniswap v3, each handled here: (1) the factory looks pools up by `tickSpacing`, so a position
/// matches only when `factory.getPool(token0, token1, tickSpacing) == market pool`; (2) `positions()` returns
/// `int24 tickSpacing` where v3 returns `uint24 fee`; (3) `slot0()` has six fields, decoded only through the Slipstream
/// pool interface; (4) the swap fee is dynamic, read for information and never used in pricing; (5) Base runs four
/// NPM and factory generations (Initial, Gauge Caps, Gauges V3, Aero), fixed in the constructor as
/// `generation -> (npm, factory)` and encoded in the high byte of `positionKey`, and a market binds to one generation
/// whose NPM equals `pool.nft()`; (6) only unstaked NFTs are accepted: a staked NFT is owned by the pool's gauge, so
/// `receivePosition` reverts with `NotTokenOwner` for its staker and with `PositionEncumbered` when the named owner is
/// `pool.gauge()`; the voter's `isGauge` is never called (it reverts on the Aero generation's leaf voter), and the
/// LPVault never stakes. The consistency check needs 901 observations for W = 1,800 s at 2 s blocks (AMMN-RT-08).
/// @custom:spec REQ-AMM-SLIP-001, REQ-AMM-SLIP-002, REQ-AMM-SLIP-003, REQ-AMM-SLIP-004, REQ-AMM-SLIP-005, REQ-AMM-SLIP-006, Q-371
interface ISlipstreamIntegration is IClIntegration {
    /// @notice Returns the number of NPM and factory generations the LPVault accepts.
    /// @return count 4 on Base: Initial, Gauge Caps, Gauges V3, Aero.
    /// @custom:spec REQ-AMM-SLIP-006
    function generationCount() external view returns (uint8 count);

    /// @notice Returns the NPM and factory of a generation.
    /// @dev Reverts with `InvalidPool` for a generation at or above `generationCount()`.
    /// @custom:spec REQ-AMM-SLIP-006
    function generation(
        uint8 index
    ) external view returns (address npm, address factory);

    /// @notice Returns the position key of an NFT of a generation.
    /// @dev Reverts with `UnsupportedNft` for `index >= generationCount()` or `tokenId >= 2^248`.
    /// @return positionKey `bytes32((uint256(index) << 248) | tokenId)`.
    /// @custom:spec REQ-AMM-SLIP-001
    function positionKeyOf(
        uint8 index,
        uint256 tokenId
    ) external pure returns (bytes32 positionKey);

    /// @notice Returns whether an NFT of a market's generation is staked in the pool's gauge.
    /// @dev True when `ownerOf(tokenId) == pool.gauge()` on the market's position manager and the gauge is not
    /// address(0); false when either read fails. Reverts with `MarketBinding` for an unbound market. Read-only.
    /// @custom:spec REQ-AMM-SLIP-004
    function isStaked(
        uint256 marketId,
        uint256 tokenId
    ) external view returns (bool staked);
}
