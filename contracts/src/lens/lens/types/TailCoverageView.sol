// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Cap-based tail coverage of the First-Loss Reserve of one (funding Hub, debt asset) pair.
/// @dev `coverageSpoke` is `MarketRegistry.coverageSpokeOf(hub, debtAsset)`; `funded` is its
/// `fundedBalance()` and `minimum` its `firstLossReserveMinimum()` (asset base units); `fundedUsd` is `funded` at the
/// asset's served price, rounded down (USD, 8 decimals). For each pool token t of the Hub's markets other than the
/// debt asset, `tail_t = min(ceil((tokenUsdCap[hub][t] + sum of topUpSliceUsd over markets holding t) * CF_t / 1e4),
/// drawCapUsd)`
/// (USD, 8 decimals), with `CF_t` the largest collateral factor of a market holding t and `drawCapUsd` the asset's
/// summed CDP Spoke draw caps on the Hub at its price, cross-Hub lines it funds included, (`type(uint256).max` when any `drawCap` is `MAX_ALLOWED_SPOKE_CAP`; the
/// sum is then not computed). `worstToken` has the largest tail,
/// `tailUsd` is that tail and `ratioBps = floor(fundedUsd * 1e4 / tailUsd)` (`type(uint256).max` when `tailUsd == 0`).
/// `deficitOffset` is the pair's DAO deficit offset, the first Spoke listed on the Hub asset whose `FIRST_LOSS_LAYER()`
/// is `coverageSpoke` (0 when none), and `offsetFunded` the added assets on the Hub of every such Spoke (asset base
/// units), the second loss layer; `ratioBps` measures `funded` alone, the first loss layer SPEC-CAP-008 sizes.
/// @custom:spec REQ-LENS-034, SPEC-CAP-008, REQ-FLR-046, Q-249, Q-378, Q-410
struct TailCoverageView {
    uint256 blockNumber;
    uint256 timestamp;
    address hub;
    address debtAsset;
    address coverageSpoke;
    uint256 funded;
    uint256 minimum;
    uint256 fundedUsd;
    uint256 drawCapUsd;
    address worstToken;
    uint256 tailUsd;
    uint256 ratioBps;
    address deficitOffset;
    uint256 offsetFunded;
}
