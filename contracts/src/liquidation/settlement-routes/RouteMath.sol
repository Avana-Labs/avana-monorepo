// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RouteMath
/// @notice Arithmetic of the swap routes: the LitePSM gem amount a `PegModule` route buys with the DAI it holds.
/// @dev Pure functions, no state. The LitePSM (`DssLitePsm.buyGem`, dss-lite-psm dbf0022) charges
/// `cost(g) = g × c + ⌊g × c × tout / 10¹⁸⌋` DAI wei for `g` gem units, with `c = 10^(18 − gemDecimals)` (10¹² for
/// USDC) and `tout` the WAD buy fee (`type(uint256).max` halts buying).
/// @custom:spec REQ-ROUTE-012
library RouteMath {
    /// @notice WAD, the LitePSM fee unit (10¹⁸ = 100 %).
    uint256 internal constant WAD = 1e18;

    /// @notice Fees at or above this value buy nothing: the route sends all its DAI back instead of calling the
    /// LitePSM. It covers the `HALTED` value `type(uint256).max` and keeps `(WAD + tout) × c` below 2²⁵⁶.
    uint256 internal constant MAX_TOUT = 1e36;

    /// @notice The largest gem amount `g` with `cost(g) ≤ dai` (REQ-ROUTE-012).
    /// @dev `g₀ = ⌊dai × 10¹⁸ / ((10¹⁸ + tout) × c)⌋` satisfies `cost(g₀) ≤ g₀ × c × (10¹⁸ + tout) / 10¹⁸ ≤ dai`. The
    /// floor in the fee can let `g₀ + 1` fit as well, and never `g₀ + 2`: `cost(g₀ + 2) > (g₀ + 1) × c × (10¹⁸ + tout) /
    /// 10¹⁸ + c − 1 > dai + c − 1 ≥ dai`. So the answer is `g₀ + 1` when `cost(g₀ + 1) ≤ dai`, else `g₀` (MATH-ST-120).
    /// Example: `tout = 0`, `dai` = 1,000.0000005 × 10¹⁸, `c = 10¹²` gives 1,000,000,000 (1,000 USDC) and leaves
    /// 5 × 10¹¹ wei. Overflow-free for `dai < 2²⁵⁴` and `c ≤ 10¹⁸`: `(g₀ + 1) × c ≤ dai + c` and the fee term of
    /// `g₀ + 1` is at most `dai + c × tout / 10¹⁸ < dai + 10³⁶`.
    /// @param dai DAI wei the route holds for the leg.
    /// @param tout The LitePSM's `tout()`.
    /// @param conversion `c = 10^(18 − gemDecimals)`, between 1 and 10¹⁸.
    /// @return gemAmt Gem units to buy; 0 when `tout ≥ MAX_TOUT` or `dai` buys less than one unit.
    /// @custom:spec REQ-ROUTE-012
    function litePsmGemAmt(
        uint256 dai,
        uint256 tout,
        uint256 conversion
    ) internal pure returns (uint256 gemAmt) {
        if (tout >= MAX_TOUT) return 0;
        gemAmt = Math.mulDiv(dai, WAD, (WAD + tout) * conversion);
        if (litePsmCost(gemAmt + 1, tout, conversion) <= dai) gemAmt += 1;
    }

    /// @notice LitePSM DAI cost of `gemAmt` gem units: `gemAmt × c + ⌊gemAmt × c × tout / 10¹⁸⌋`.
    /// @param gemAmt Gem units.
    /// @param tout The LitePSM's `tout()`, below `MAX_TOUT`.
    /// @param conversion `c = 10^(18 − gemDecimals)`.
    /// @return daiInWad DAI wei the LitePSM pulls.
    /// @custom:spec REQ-ROUTE-012
    function litePsmCost(
        uint256 gemAmt,
        uint256 tout,
        uint256 conversion
    ) internal pure returns (uint256 daiInWad) {
        uint256 gemAmt18 = gemAmt * conversion;
        daiInWad = gemAmt18 + Math.mulDiv(gemAmt18, tout, WAD);
    }
}
