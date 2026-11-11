// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DrawHeadroom} from "../lens/lens/types/DrawHeadroom.sol";

/// @notice Avana and Aave cap headroom for a market and depositor.
/// @dev Avana headroom is USD with 8 decimals, `max(0, cap - used)` with counters from Collateralization (keyed by the
/// market's Hub) and caps from the ParameterStore. `minPledgeUsd` (USD, 8 decimals) is the market's smallest accepted
/// pledge value. `tokens` and `tokenHeadroomUsd` are in pool order. `poolShareBps` is Avana's share of pool liquidity,
/// summed over every market of the pool on the chain, against `poolShareMaxBps`, the pool's `poolShareMaxBpsOf(poolKey)`. `chargePricePerWholeToken` is `max(oracle price, stressFloorUsd)` (8 decimals).
/// `vaultTokenAddHeadroom` (vault-token base units) and each `drawHeadroom` entry (debt-asset base units, one per
/// approved debt reserve of the market's CDP Spoke) use the Hub's own formulas; a `type(uint40).max` cap reports
/// `type(uint256).max`. Rounding never overstates headroom.
/// @custom:spec REQ-LENS-018, REQ-LENS-019, Q-370
struct CapView {
    uint256 blockNumber;
    uint256 timestamp;
    address hub;
    address vaultToken;
    address depositor;
    uint256 minPledgeUsd;
    uint256 marketHeadroomUsd;
    uint256 sliceHeadroomUsd;
    address[] tokens;
    uint256[] tokenHeadroomUsd;
    uint256 depositorHeadroomUsd;
    uint256 poolShareBps;
    uint256 poolShareMaxBps;
    uint256 chargePricePerWholeToken;
    uint256 vaultTokenAddHeadroom;
    DrawHeadroom[] drawHeadroom;
}
