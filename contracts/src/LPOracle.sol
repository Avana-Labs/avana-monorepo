// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPOracle} from "./interfaces/ILPOracle.sol";
import {ILPVault} from "./interfaces/ILPVault.sol";
import {AaveReservePrice} from "./libraries/AaveReservePrice.sol";
import {ClTickMath} from "./libraries/ClTickMath.sol";
import {LPPriceMath} from "./libraries/LPPriceMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LPOracle
/// @notice Stateless price of one band market's vault token, read by Aave V4 as the reserve's price source.
/// @dev Each read takes token0's and token1's prices from Aave V4 (`AaveOracle.getReservePrice` of their reserves
/// on the price Spoke, with whatever source Aave governance has set, CAPO included), takes the fair square-root price
/// of the two, clamps it to the band, and values the amounts one whole vault token holds there, rounded down. The
/// band, tokens and decimals are fixed at construction from the LPVault's market, so the oracle and the credit always
/// describe the same liquidity. Works unchanged for a full-range market (the band is the pool's
/// usable tick range, where the clamp never binds) and for any custom band.
contract LPOracle is ILPOracle {
    uint8 internal constant _ANSWER_DECIMALS = 8;
    uint8 internal constant _MIN_UNIT_DECIMALS = 6;
    uint8 internal constant _MAX_UNIT_DECIMALS = 18;

    address internal immutable _LP_VAULT;
    uint256 internal immutable _MARKET_ID;
    int24 internal immutable _BAND_LOWER;
    int24 internal immutable _BAND_UPPER;
    uint160 internal immutable _SQRT_LOWER;
    uint160 internal immutable _SQRT_UPPER;
    address internal immutable _TOKEN0;
    address internal immutable _TOKEN1;
    uint8 internal immutable _DECIMALS0;
    uint8 internal immutable _DECIMALS1;
    uint8 internal immutable _UNIT_DECIMALS;
    uint128 internal immutable _UNIT;
    address internal immutable _PRICE_SPOKE;
    address internal immutable _AAVE_ORACLE;
    uint256 internal immutable _RESERVE_ID0;
    uint256 internal immutable _RESERVE_ID1;

    string internal _description;

    /// @dev Reads the market from the LPVault, each token's decimals and the price Spoke's oracle once, then both
    /// prices, as `AaveOracle.setReserveSource` reads a new source once. Reverts `InvalidParams` for an unlisted market,
    /// vault-token decimals outside [6, 18], a token with more than 18 decimals, or a price Spoke reserve that is not
    /// the market's token in pool order with the token's decimals, or whose oracle is not the Spoke's 8-decimal one.
    constructor(
        Params memory p
    ) {
        if (p.lpVault == address(0) || p.unitDecimals < _MIN_UNIT_DECIMALS || p.unitDecimals > _MAX_UNIT_DECIMALS) {
            revert InvalidParams();
        }
        ILPVault.Market memory m = ILPVault(p.lpVault).getMarket(p.marketId);
        if (m.pool == bytes32(0) || m.bandLower >= m.bandUpper) revert InvalidParams();
        (_LP_VAULT, _MARKET_ID, _BAND_LOWER, _BAND_UPPER) = (p.lpVault, p.marketId, m.bandLower, m.bandUpper);
        _SQRT_LOWER = ClTickMath.getSqrtPriceAtTick(m.bandLower);
        _SQRT_UPPER = ClTickMath.getSqrtPriceAtTick(m.bandUpper);
        (_TOKEN0, _TOKEN1) = (m.token0, m.token1);
        _DECIMALS0 = _decimalsOf(m.token0);
        _DECIMALS1 = _decimalsOf(m.token1);
        _UNIT_DECIMALS = p.unitDecimals;
        // At most 10^18 < 2^128.
        // forge-lint: disable-next-line(unsafe-typecast)
        _UNIT = uint128(10 ** p.unitDecimals);
        address oracle = AaveReservePrice.oracleOf(p.priceSpoke, p.reserveId0, m.token0, _DECIMALS0);
        if (
            oracle == address(0)
                || AaveReservePrice.oracleOf(p.priceSpoke, p.reserveId1, m.token1, _DECIMALS1) != oracle
        ) {
            revert InvalidParams();
        }
        (_PRICE_SPOKE, _AAVE_ORACLE, _RESERVE_ID0, _RESERVE_ID1) = (p.priceSpoke, oracle, p.reserveId0, p.reserveId1);
        _description = p.description;
        // Both reserves are priced now, so a source Aave cannot read fails the deployment, not the first health check.
        _prices();
    }

    /// @inheritdoc ILPOracle
    function latestAnswer() external view override returns (int256 answer) {
        (uint256 p0, uint256 p1, uint160 s) = _prices();
        (uint256 a0, uint256 a1) = LPPriceMath.amounts(s, _SQRT_LOWER, _SQRT_UPPER, _UNIT);
        uint256 v = LPPriceMath.value(a0, a1, p0, p1, _DECIMALS0, _DECIMALS1);
        // Aave V4 refuses an answer of 0; a vault token worth less than 10^-8 USD is served at the smallest price.
        return SafeCast.toInt256(Math.max(v, 1));
    }

    /// @inheritdoc ILPOracle
    function decimals() external pure override returns (uint8) {
        return _ANSWER_DECIMALS;
    }

    /// @inheritdoc ILPOracle
    function description() external view override returns (string memory) {
        return _description;
    }

    /// @inheritdoc ILPOracle
    function getPrices() external view override returns (uint256 price0, uint256 price1, uint160 sqrtPriceX96) {
        return _prices();
    }

    /// @inheritdoc ILPOracle
    function getUnitAmounts() external view override returns (uint256 amount0, uint256 amount1) {
        (,, uint160 s) = _prices();
        return LPPriceMath.amounts(s, _SQRT_LOWER, _SQRT_UPPER, _UNIT);
    }

    /// @inheritdoc ILPOracle
    function lpVault() external view override returns (address) {
        return _LP_VAULT;
    }

    /// @inheritdoc ILPOracle
    function marketId() external view override returns (uint256) {
        return _MARKET_ID;
    }

    /// @inheritdoc ILPOracle
    function band() external view override returns (int24 bandLower, int24 bandUpper) {
        return (_BAND_LOWER, _BAND_UPPER);
    }

    /// @inheritdoc ILPOracle
    function tokens() external view override returns (address token0, address token1) {
        return (_TOKEN0, _TOKEN1);
    }

    /// @inheritdoc ILPOracle
    function unitDecimals() external view override returns (uint8) {
        return _UNIT_DECIMALS;
    }

    /// @inheritdoc ILPOracle
    function priceSpoke() external view override returns (address) {
        return _PRICE_SPOKE;
    }

    /// @inheritdoc ILPOracle
    function aaveOracle() external view override returns (address) {
        return _AAVE_ORACLE;
    }

    /// @inheritdoc ILPOracle
    function reserveIds() external view override returns (uint256 reserveId0, uint256 reserveId1) {
        return (_RESERVE_ID0, _RESERVE_ID1);
    }

    /// @dev Both tokens' prices and their fair square-root price.
    function _prices() internal view returns (uint256 p0, uint256 p1, uint160 s) {
        p0 = _tokenPrice(_RESERVE_ID0);
        p1 = _tokenPrice(_RESERVE_ID1);
        s = LPPriceMath.sqrtPriceX96(p0, p1, _DECIMALS0, _DECIMALS1);
    }

    /// @dev One token's 8-decimal price as Aave V4 serves it; Aave reverts on 0. The round's time is not read.
    function _tokenPrice(
        uint256 reserveId
    ) internal view returns (uint256 price) {
        bool inBound;
        (price, inBound) = AaveReservePrice.read(_AAVE_ORACLE, reserveId);
        if (!inBound) revert PriceAboveBound(reserveId);
    }

    /// @dev A token's `decimals()`, at most 18.
    function _decimalsOf(
        address target
    ) internal view returns (uint8 d) {
        if (target == address(0)) revert InvalidParams();
        d = IERC20Metadata(target).decimals();
        if (d > LPPriceMath.MAX_DECIMALS) revert InvalidParams();
    }
}
