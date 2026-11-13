// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {IClIntegration} from "../../amm/IClIntegration.sol";
import {ISlipstreamIntegration} from "../../amm/slipstream/ISlipstreamIntegration.sol";
import {ClMarketConfig} from "../../amm/types/ClMarketConfig.sol";
import {FeeMode} from "../../amm/types/FeeMode.sol";
import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {BackingRecord} from "../../custody/collateralization/types/BackingRecord.sol";
import {AmmConstants} from "../../types/AmmConstants.sol";
import {Market} from "../../types/Market.sol";
import {ILensFees} from "./ILensFees.sol";
import {ILensSlipstreamFeeReads} from "./ILensSlipstreamFeeReads.sol";
import {ILensV3FeeReads} from "./ILensV3FeeReads.sol";
import {LensBase} from "./LensBase.sol";
import {LensClPosition, LensSlipstreamTick, LensV3Tick} from "./types/LensClReads.sol";
import {PositionFeesView} from "./types/PositionFeesView.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensFees
/// @notice Uncollected fees of Uniswap v3 and Aerodrome Slipstream positions, computed from the pool's fee growth as the
/// position manager computes them inside `collect`, so the amount shown is the amount `collectFees` pays.
/// @dev `feeGrowthInside` is v3-core's `Tick.getFeeGrowthInside` and the owed update is v3-periphery's
/// `NonfungiblePositionManager.collect`, both in wrapping arithmetic as in the 0.7 sources (Slipstream keeps the same
/// two steps). Bounded by the 16 records of an account-market.
/// @custom:spec REQ-LENS-050, REQ-LENS-051
// View calls in a loop over the at most 16 records of one account-market (REQ-LENS-020).
// forge-lint: disable-start(calls-loop)
abstract contract LensFees is LensBase, ILensFees {
    /// @dev `AMM_PROTOCOL()` of the Uniswap v3 LPVault.
    bytes32 internal constant UNISWAP_V3 = keccak256("UNISWAP_V3");
    /// @dev `AMM_PROTOCOL()` of the Aerodrome Slipstream LPVault.
    bytes32 internal constant AERODROME_SLIPSTREAM = keccak256("AERODROME_SLIPSTREAM");
    /// @dev 2^128, the fixed-point base of fee growth.
    uint256 internal constant Q128 = 1 << 128;

    /// @dev A concentrated-liquidity position and its pool, as read for the fee update.
    struct ClFees {
        address token0;
        address token1;
        // Uniswap v3: the fee tier; Slipstream: the tick spacing (as a non-negative integer).
        int256 poolParam;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256[2] last;
        uint128[2] owed;
        int24 tick;
        uint256[2] global;
        uint256[2] outsideLower;
        uint256[2] outsideUpper;
    }

    /// @inheritdoc ILensFees
    /// @custom:spec REQ-LENS-050, REQ-LENS-005, REQ-LENS-006, REQ-LENS-022
    function getPositionFees(
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (PositionFeesView memory fees) {
        _unlocked();
        fees = _positionFees(marketId, _market(marketId), positionKey);
    }

    /// @inheritdoc ILensFees
    /// @custom:spec REQ-LENS-051, REQ-LENS-005, REQ-LENS-006, REQ-LENS-022
    function getAccountFees(
        address wallet,
        uint256 marketId
    ) external view override returns (PositionFeesView[] memory fees) {
        _unlocked();
        Market memory m = _market(marketId);
        (address proxy, bool deployed) = _proxy(wallet, marketId, m.spoke);
        if (!deployed) return fees;
        // forge-lint: disable-start(unused-return)
        (, BackingRecord[] memory records) = ICollateralizationViews(_COLLATERALIZATION)
            .getAccountRecords(proxy, m.vaultToken, 0, AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET);
        // forge-lint: disable-end(unused-return)
        fees = new PositionFeesView[](records.length);
        for (uint256 i = 0; i < records.length; ++i) {
            fees[i] = _positionFees(marketId, m, records[i].positionKey);
        }
    }

    // ------------------------------------------------------------------------------------------------------ internal

    /// @dev The fee view of one position; `supported` false (amounts 0) for an AMM protocol without a fee reader, fees
    /// that roll into the position, or a position outside the market's pool.
    function _positionFees(
        uint256 marketId,
        Market memory m,
        bytes32 positionKey
    ) internal view returns (PositionFeesView memory v) {
        (v.blockNumber, v.timestamp, v.marketId, v.positionKey) = (block.number, block.timestamp, marketId, positionKey);
        v.tokensOwed = new uint256[](m.tokens.length);
        v.amounts = new uint256[](m.tokens.length);
        IAmmIntegration integration = IAmmIntegration(m.integration);
        v.depositor = integration.depositorOf(positionKey);
        v.inCustody = v.depositor != address(0);
        bytes32 protocol = integration.AMM_PROTOCOL();
        bool v3 = protocol == UNISWAP_V3;
        if (!v3 && protocol != AERODROME_SLIPSTREAM) return v;
        if (integration.capabilities().feeMode != FeeMode.Separate) return v;
        ClMarketConfig memory c = IClIntegration(m.integration).clMarket(marketId);
        uint256 tokenId = IClIntegration(m.integration).tokenIdOf(positionKey);
        if (!v3) {
            // A Slipstream key names its position manager by generation; only the market's generation matches.
            // forge-lint: disable-next-line(unsafe-typecast)
            // forge-lint: disable-next-line(unused-return)
            (address npm,) = ISlipstreamIntegration(m.integration).generation(uint8(uint256(positionKey) >> 248));
            if (npm != c.positionManager) return v;
        }
        ClFees memory f = v3 ? _v3Fees(c, tokenId) : _slipstreamFees(c, tokenId);
        if (f.token0 != c.token0 || f.token1 != c.token1) return v;
        if (f.poolParam != (v3 ? int256(uint256(c.fee)) : int256(c.tickSpacing))) return v;
        v.supported = true;
        v.liquidity = f.liquidity;
        for (uint256 i = 0; i < 2; ++i) {
            v.tokensOwed[i] = f.owed[i];
            v.amounts[i] = _owedAfterUpdate(f, i);
        }
    }

    /// @dev Reads a Uniswap v3 position and its pool's fee growth.
    function _v3Fees(
        ClMarketConfig memory c,
        uint256 tokenId
    ) internal view returns (ClFees memory f) {
        _position(f, ILensV3FeeReads(c.positionManager).positions(tokenId));
        ILensV3FeeReads pool = ILensV3FeeReads(c.pool);
        // forge-lint: disable-next-line(unused-return)
        (, f.tick,,,,,) = pool.slot0();
        (f.global[0], f.global[1]) = (pool.feeGrowthGlobal0X128(), pool.feeGrowthGlobal1X128());
        LensV3Tick memory lower = pool.ticks(f.tickLower);
        LensV3Tick memory upper = pool.ticks(f.tickUpper);
        f.outsideLower = [lower.feeGrowthOutside0X128, lower.feeGrowthOutside1X128];
        f.outsideUpper = [upper.feeGrowthOutside0X128, upper.feeGrowthOutside1X128];
    }

    /// @dev Reads a Slipstream position and its pool's fee growth.
    function _slipstreamFees(
        ClMarketConfig memory c,
        uint256 tokenId
    ) internal view returns (ClFees memory f) {
        _position(f, ILensSlipstreamFeeReads(c.positionManager).positions(tokenId));
        ILensSlipstreamFeeReads pool = ILensSlipstreamFeeReads(c.pool);
        // forge-lint: disable-next-line(unused-return)
        (, f.tick,,,,) = pool.slot0();
        (f.global[0], f.global[1]) = (pool.feeGrowthGlobal0X128(), pool.feeGrowthGlobal1X128());
        LensSlipstreamTick memory lower = pool.ticks(f.tickLower);
        LensSlipstreamTick memory upper = pool.ticks(f.tickUpper);
        f.outsideLower = [lower.feeGrowthOutside0X128, lower.feeGrowthOutside1X128];
        f.outsideUpper = [upper.feeGrowthOutside0X128, upper.feeGrowthOutside1X128];
    }

    /// @dev Copies the position's tokens, pool parameter, range, liquidity, snapshots and owed tokens.
    function _position(
        ClFees memory f,
        LensClPosition memory p
    ) internal pure {
        (f.token0, f.token1, f.poolParam) = (p.token0, p.token1, int256(p.poolParam));
        (f.tickLower, f.tickUpper, f.liquidity) = (p.tickLower, p.tickUpper, p.liquidity);
        f.last = [p.feeGrowthInside0LastX128, p.feeGrowthInside1LastX128];
        f.owed = [p.tokensOwed0, p.tokensOwed1];
    }

    /// @dev Token `i` owed after the position manager's update: `tokensOwed + liquidity × (inside − last) / 2^128`, each
    /// step in the 0.7 sources' wrapping arithmetic (differences mod 2^256, the owed sum mod 2^128).
    function _owedAfterUpdate(
        ClFees memory f,
        uint256 i
    ) internal pure returns (uint256) {
        if (f.liquidity == 0) return f.owed[i];
        uint256 inside =
            _feeGrowthInside(f.tick, f.tickLower, f.tickUpper, f.global[i], f.outsideLower[i], f.outsideUpper[i]);
        unchecked {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint128 growth = uint128(Math.mulDiv(inside - f.last[i], f.liquidity, Q128));
            return uint256(f.owed[i] + growth);
        }
    }

    /// @dev v3-core `Tick.getFeeGrowthInside` for one token: global minus the growth below `lower` and above `upper`,
    /// mod 2^256.
    function _feeGrowthInside(
        int24 tick,
        int24 lower,
        int24 upper,
        uint256 global,
        uint256 outsideLower,
        uint256 outsideUpper
    ) internal pure returns (uint256 inside) {
        unchecked {
            uint256 below = tick >= lower ? outsideLower : global - outsideLower;
            uint256 above = tick < upper ? outsideUpper : global - outsideUpper;
            inside = global - below - above;
        }
    }
}
// forge-lint: disable-end(calls-loop)
