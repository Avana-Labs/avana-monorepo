// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LiquidationMath
/// @notice The arithmetic of a partial liquidation in kind: Avana's share of the bonus, how much credit to unwind from a
/// position for a number of seized units, and the split of the unwound tokens.
/// @dev Pure. Units are vault-token base units, which equal credit units.
library LiquidationMath {
    /// @notice Basis-point denominator; Aave's liquidation bonus is `10,000 + bonus`.
    uint256 internal constant BPS = 10_000;

    /// @notice Avana's share of the bonus inside `seized` units, rounded down.
    /// @dev Aave seizes `repaid · bonusBps / 10,000` worth of collateral, so the bonus part of `seized` is
    /// `seized · (bonusBps − 10,000) / bonusBps`. A bonus at or below 10,000 has no bonus part.
    /// @param seized Vault-token units Aave seized.
    /// @param bonusBps Aave's liquidation bonus, 10,000 meaning none.
    /// @param feeShareBps Avana's share of the bonus, basis points.
    /// @return feeUnits Units whose tokens go to the fee recipient.
    function feeUnits(
        uint256 seized,
        uint256 bonusBps,
        uint256 feeShareBps
    ) internal pure returns (uint256) {
        if (bonusBps <= BPS || feeShareBps == 0) return 0;
        uint256 bonusUnits = Math.mulDiv(seized, bonusBps - BPS, bonusBps);
        return Math.mulDiv(bonusUnits, feeShareBps, BPS);
    }

    /// @notice A position's worth in credit units at the oracle price, never below its credit.
    /// @dev `value · unitScale / unitValue`, rounded down. Floor credit makes a position worth at least its credit at
    /// every price, so the floor at `credit` only absorbs rounding.
    /// @param value 18-decimal USD value of the position's liquidity at the oracle price.
    /// @param unitValue 18-decimal USD value of one whole vault token.
    /// @param unitScale Units in one whole vault token, `10^unitDecimals`.
    /// @param credit The position's recorded credit.
    function capacity(
        uint256 value,
        uint256 unitValue,
        uint256 unitScale,
        uint256 credit
    ) internal pure returns (uint256 cap) {
        cap = Math.mulDiv(value, unitScale, unitValue);
        if (cap < credit) cap = credit;
    }

    /// @notice 18-decimal USD value of raw token amounts at 8-decimal prices, each term rounded down.
    /// @dev Ten more decimals than the oracle's answer, so a position's worth in credit units keeps its precision.
    /// Prices are at most the LPOracle's bound, so `price · 1e10` fits and `mulDiv` holds the product.
    function value(
        uint256 amount0,
        uint256 amount1,
        uint256 price0,
        uint256 price1,
        uint8 decimals0,
        uint8 decimals1
    ) internal pure returns (uint256) {
        return
            Math.mulDiv(amount0, price0 * 1e10, 10 ** decimals0) + Math.mulDiv(amount1, price1 * 1e10, 10 ** decimals1);
    }

    /// @notice Credit to unwind from a position so the liquidity removed is worth `units` at the oracle price.
    /// @dev `floor(units · credit / cap)`, at most `credit` because `units <= cap`. Rounding down leaves the dust with
    /// the borrower: a rounding gap comes out of the liquidator's payout, never out of the account or the reserve.
    function creditFor(
        uint256 units,
        uint256 credit,
        uint256 cap
    ) internal pure returns (uint256) {
        return Math.mulDiv(units, credit, cap);
    }

    /// @notice Excess per unit of credit, 1e18 meaning none: the order key of the unwind.
    function excessRatio(
        uint256 cap,
        uint256 credit
    ) internal pure returns (uint256) {
        return Math.mulDiv(cap, 1e18, credit);
    }

    /// @notice The fee recipient's part of an unwound amount: `amount · feeUnits / seized`, rounded down.
    function feePart(
        uint256 amount,
        uint256 fee,
        uint256 seized
    ) internal pure returns (uint256) {
        return Math.mulDiv(amount, fee, seized);
    }
}
