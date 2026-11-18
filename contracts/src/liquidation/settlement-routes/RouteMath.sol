// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RouteMath
/// @notice Arithmetic of the swap routes: the LitePSM gem amount a `PegModule` route buys with the DAI it holds.
/// @dev LitePSM cost of `g` gem units: `g × c + ⌊g × c × tout / 10¹⁸⌋` DAI wei, `c = 10^(18 − gemDecimals)`.
library RouteMath {
    /// @notice WAD, the LitePSM fee unit.
    uint256 internal constant WAD = 1e18;

    /// @notice Fees at or above this buy nothing; keeps `(WAD + tout) × c` below 2²⁵⁶.
    uint256 internal constant MAX_TOUT = 1e36;

    /// @notice The largest gem amount `g` with `cost(g) ≤ dai`.
    /// @dev The floored estimate always fits and estimate + 2 never does, so only estimate + 1 is checked.
    /// @param conversion `10^(18 − gemDecimals)`.
    /// @return gemAmt Gem units to buy; 0 when `tout ≥ MAX_TOUT`.
    function litePsmGemAmt(
        uint256 dai,
        uint256 tout,
        uint256 conversion
    ) internal pure returns (uint256 gemAmt) {
        if (tout >= MAX_TOUT) return 0;
        gemAmt = Math.mulDiv(dai, WAD, (WAD + tout) * conversion);
        if (litePsmCost(gemAmt + 1, tout, conversion) <= dai) gemAmt += 1;
    }

    /// @notice LitePSM DAI cost, in wei, of `gemAmt` gem units.
    function litePsmCost(
        uint256 gemAmt,
        uint256 tout,
        uint256 conversion
    ) internal pure returns (uint256 daiInWad) {
        uint256 gemAmt18 = gemAmt * conversion;
        daiInWad = gemAmt18 + Math.mulDiv(gemAmt18, tout, WAD);
    }
}
