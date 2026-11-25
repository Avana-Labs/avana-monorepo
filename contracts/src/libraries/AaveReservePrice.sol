// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Oracle} from "../dependencies/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../dependencies/aave/IAaveV4Spoke.sol";
import {LPPriceMath} from "./LPPriceMath.sol";

/// @title AaveReservePrice
/// @notice A token's USD price as Aave V4 serves it: `AaveOracle.getReservePrice` of a reserve on a price Spoke.
/// @dev The LPOracle (every read) and the RiskModule (the listing price) share it, so both value a token alike.
library AaveReservePrice {
    /// @notice The `AaveOracle` of `spoke` when reserve `reserveId` there is `token` with `tokenDecimals` decimals and
    /// the oracle is the Spoke's and serves 8 decimals; `address(0)` otherwise.
    /// @dev `Spoke.ORACLE` is immutable in Aave V4, so a caller may keep the result. `getReserve` of an unlisted
    /// reserve reverts in the Spoke (or returns a zero underlying, which fails here).
    function oracleOf(
        address spoke,
        uint256 reserveId,
        address token,
        uint8 tokenDecimals
    ) internal view returns (address oracle) {
        if (spoke.code.length == 0 || token == address(0)) return address(0);
        IAaveV4Spoke.Reserve memory r = IAaveV4Spoke(spoke).getReserve(reserveId);
        if (r.underlying != token || r.decimals != tokenDecimals) return address(0);
        oracle = IAaveV4Spoke(spoke).ORACLE();
        if (
            oracle.code.length == 0 || IAaveV4Oracle(oracle).decimals() != LPPriceMath.DECIMALS
                || IAaveV4Oracle(oracle).spoke() != spoke
        ) return address(0);
    }

    /// @notice Aave's 8-decimal price of `reserveId`, and whether it is at most `LPPriceMath.MAX_PRICE`.
    /// @dev Aave's `getReservePrice` itself reverts on a source answering 0 or below, or on no source.
    function read(
        address oracle,
        uint256 reserveId
    ) internal view returns (uint256 price, bool inBound) {
        price = IAaveV4Oracle(oracle).getReservePrice(reserveId);
        inBound = price <= LPPriceMath.MAX_PRICE;
    }
}
