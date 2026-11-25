// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../dependencies/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../dependencies/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../dependencies/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../interfaces/ILPOracle.sol";
import {IRiskModule} from "../interfaces/IRiskModule.sol";
import {AaveReservePrice} from "./AaveReservePrice.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AaveConfigLogic
/// @notice The reads the RiskModule makes of Aave: the listing price, the activation check and the First-Loss coverage
/// of draw caps.
/// @dev View only; every revert names its reason.
// Reads every Spoke of a pair's coverage set; the set is short and governed.
// forge-lint: disable-start(calls-loop)
library AaveConfigLogic {
    uint256 internal constant BPS = 10_000;
    /// @dev Stand-in for an uncapped draw cap: above any balance, yet a sum of them cannot overflow.
    uint256 internal constant UNBOUNDED_DRAW_CAP = 2 ** 128;

    /// @notice A token's 8-decimal USD price as Aave V4 serves it: reserve `reserveId` of `priceSpoke`, which must be
    /// `token` with `tokenDecimals` decimals, through the Spoke's 8-decimal `AaveOracle`; the same read as the LPOracle.
    /// @dev Reverts `InvalidPriceReserve`, or with Aave's own error when the source answers 0 or below.
    function tokenPrice(
        address priceSpoke,
        uint256 reserveId,
        address token,
        uint8 tokenDecimals
    ) internal view returns (uint256 price) {
        address oracle = AaveReservePrice.oracleOf(priceSpoke, reserveId, token, tokenDecimals);
        if (oracle == address(0)) revert IRiskModule.InvalidPriceReserve(reserveId);
        bool inBound;
        (price, inBound) = AaveReservePrice.read(oracle, reserveId);
        if (!inBound) revert IRiskModule.InvalidPriceReserve(reserveId);
    }

    /// @notice Checks a market's Aave reserve and LPOracle; returns the reserve ID.
    /// @dev Reverts `ActivationCheckFailed(marketId, reason)` on the first failure.
    function checkActivation(
        uint256 marketId,
        IRiskModule.Market memory m,
        address hub,
        address priceSpoke,
        address lpOracle,
        address lpVault
    ) internal view returns (uint256 reserveId) {
        ILPOracle o = ILPOracle(lpOracle);
        if (lpOracle.code.length == 0) _fail(marketId, "oracle");
        (uint256 r0, uint256 r1) = o.reserveIds();
        if (
            o.lpVault() != lpVault || o.marketId() != marketId || o.unitDecimals() != m.unitDecimals
                || o.priceSpoke() != priceSpoke || r0 != m.priceReserveId0 || r1 != m.priceReserveId1
        ) _fail(marketId, "oracle");
        uint256 assetId;
        try IAaveV4Hub(hub).getAssetId(m.vaultToken) returns (uint256 a) {
            assetId = a;
        } catch {
            _fail(marketId, "hubAsset");
        }
        IAaveV4Spoke spoke = IAaveV4Spoke(m.spoke);
        // Set in the try branch; the catch branch reverts.
        // forge-lint: disable-next-line(uninitialized-local)
        try spoke.getReserveId(hub, assetId) returns (uint256 id) {
            reserveId = id;
        } catch {
            _fail(marketId, "reserve");
        }
        IAaveV4Spoke.Reserve memory r = spoke.getReserve(reserveId);
        _checkReserve(marketId, m, r, hub);
        if (IAaveV4Hub(hub).getSpokeConfig(assetId, m.spoke).drawCap != 0) _fail(marketId, "drawCap");
        if (spoke.getReserveConfig(reserveId).receiveSharesEnabled) _fail(marketId, "receiveShares");
        IAaveV4Spoke.DynamicReserveConfig memory dc = spoke.getDynamicReserveConfig(reserveId, r.dynamicConfigKey);
        if (dc.liquidationFee != 0) _fail(marketId, "liquidationFee");
        if (dc.collateralFactor != m.ltvBps) _fail(marketId, "ltv");
        _checkLiquidationSettings(marketId, m, spoke, priceSpoke, dc.maxLiquidationBonus);
        if (IAaveV4Oracle(spoke.ORACLE()).getReserveSource(reserveId) != lpOracle) _fail(marketId, "priceSource");
    }

    /// @notice The higher of the two tokens' `maxLiquidationBonus` on the price Spoke, at each reserve's current
    /// dynamic config: the bonus an LP market copies, so a liquidation of the LP pays at least what Aave pays for
    /// either token it may end up holding.
    function maxTokenBonus(
        address priceSpoke,
        uint256 reserveId0,
        uint256 reserveId1
    ) internal view returns (uint32) {
        uint32 b0 = _bonus(IAaveV4Spoke(priceSpoke), reserveId0);
        uint32 b1 = _bonus(IAaveV4Spoke(priceSpoke), reserveId1);
        return b0 > b1 ? b0 : b1;
    }

    /// @notice Coverage of the summed draw caps of `spokes` on `(hub, assetId)`.
    /// @dev `required` rounds up; on overflow it is `type(uint256).max`, so the check fails closed.
    /// @return drawCapSum Summed draw caps, whole tokens; an uncapped Spoke counts `UNBOUNDED_DRAW_CAP`.
    /// @return required `drawCapSum · 10^decimals · ratioBps / 10^4`, base units.
    function coverage(
        address hub,
        uint256 assetId,
        address asset,
        address[] storage spokes,
        uint256 ratioBps
    ) internal view returns (uint256 drawCapSum, uint256 required) {
        IAaveV4Hub h = IAaveV4Hub(hub);
        uint40 uncapped = h.MAX_ALLOWED_SPOKE_CAP();
        for (uint256 i = 0; i < spokes.length; ++i) {
            uint40 cap = h.getSpokeConfig(assetId, spokes[i]).drawCap;
            drawCapSum += cap == uncapped ? UNBOUNDED_DRAW_CAP : cap;
        }
        if (drawCapSum == 0 || ratioBps == 0) return (drawCapSum, 0);
        (bool ok, uint256 k) = Math.tryMul(10 ** uint256(IERC20Metadata(asset).decimals()), ratioBps);
        (bool ok2, uint256 product) = Math.tryMul(drawCapSum, k);
        required = ok && ok2 ? Math.ceilDiv(product, BPS) : type(uint256).max;
    }

    /// @dev The settings copied from the price Spoke: the reserve's max bonus is the higher token's, and the CDP Spoke's
    /// liquidation config is the price Spoke's.
    function _checkLiquidationSettings(
        uint256 marketId,
        IRiskModule.Market memory m,
        IAaveV4Spoke spoke,
        address priceSpoke,
        uint32 maxLiquidationBonus
    ) private view {
        if (maxLiquidationBonus != maxTokenBonus(priceSpoke, m.priceReserveId0, m.priceReserveId1)) {
            _fail(marketId, "liquidationBonus");
        }
        if (!_sameLiquidationConfig(spoke.getLiquidationConfig(), IAaveV4Spoke(priceSpoke).getLiquidationConfig())) {
            _fail(marketId, "liquidationConfig");
        }
    }

    function _bonus(
        IAaveV4Spoke spoke,
        uint256 reserveId
    ) private view returns (uint32) {
        return
            spoke.getDynamicReserveConfig(reserveId, spoke.getReserve(reserveId).dynamicConfigKey).maxLiquidationBonus;
    }

    function _sameLiquidationConfig(
        IAaveV4Spoke.LiquidationConfig memory a,
        IAaveV4Spoke.LiquidationConfig memory b
    ) private pure returns (bool) {
        return a.targetHealthFactor == b.targetHealthFactor && a.healthFactorForMaxBonus == b.healthFactorForMaxBonus
            && a.liquidationBonusFactor == b.liquidationBonusFactor;
    }

    /// @dev The reserve is the vault token on `hub`, booked at the vault token's decimals: Aave values each unit at the
    /// decimals recorded when the asset was added, so a slip there (6 for 18) would value every unit 10^12 times off.
    function _checkReserve(
        uint256 marketId,
        IRiskModule.Market memory m,
        IAaveV4Spoke.Reserve memory r,
        address hub
    ) private view {
        if (r.underlying != m.vaultToken || r.hub != hub) _fail(marketId, "reserve");
        if (r.decimals != IERC20Metadata(m.vaultToken).decimals()) _fail(marketId, "decimals");
    }

    function _fail(
        uint256 marketId,
        bytes32 reason
    ) private pure {
        revert IRiskModule.ActivationCheckFailed(marketId, reason);
    }
}
// forge-lint: disable-end(calls-loop)
