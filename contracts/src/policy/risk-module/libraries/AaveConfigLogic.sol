// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IAggregatorV3} from "../../../interfaces/external/chainlink/IAggregatorV3.sol";
import {ILPOracle} from "../../../oracle/ILPOracle.sol";
import {LPPriceMath} from "../../../oracle/LPPriceMath.sol";
import {IRiskModule} from "../IRiskModule.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AaveConfigLogic
/// @notice The reads the RiskModule makes of Chainlink and Aave: the listing price, the activation check and the
/// First-Loss coverage of draw caps.
/// @dev View only; every revert names its reason.
// Reads every Spoke of a pair's coverage set; the set is short and governed.
// forge-lint: disable-start(calls-loop)
library AaveConfigLogic {
    uint256 internal constant BPS = 10_000;
    /// @dev Stand-in for an uncapped draw cap: above any balance, yet a sum of them cannot overflow.
    uint256 internal constant UNBOUNDED_DRAW_CAP = 2 ** 128;

    /// @notice A token's 8-decimal USD price from its route: one feed, or two multiplied; a USD stablecoin at most $1.
    /// @dev The same arithmetic as the LPOracle. Reverts `InvalidPriceFeed`.
    function tokenPrice(
        ILPOracle.TokenFeeds calldata route
    ) internal view returns (uint256 price) {
        uint256 n = route.feeds.length;
        if (n == 0 || n > 2) revert IRiskModule.InvalidPriceFeed(address(0));
        price = LPPriceMath.PRICE_UNIT;
        for (uint256 i = 0; i < n; ++i) {
            price = Math.mulDiv(price, _leg(route.feeds[i]), LPPriceMath.PRICE_UNIT);
        }
        if (price == 0 || price > LPPriceMath.MAX_PRICE) revert IRiskModule.InvalidPriceFeed(route.feeds[0]);
        if (route.usdStable && price > LPPriceMath.STABLE_CEILING) price = LPPriceMath.STABLE_CEILING;
    }

    /// @notice Checks a market's Aave reserve and LPOracle; returns the reserve ID.
    /// @dev Reverts `ActivationCheckFailed(marketId, reason)` on the first failure.
    function checkActivation(
        uint256 marketId,
        IRiskModule.Market memory m,
        address hub,
        address lpOracle,
        address lpVault
    ) internal view returns (uint256 reserveId) {
        ILPOracle o = ILPOracle(lpOracle);
        if (
            lpOracle.code.length == 0 || o.lpVault() != lpVault || o.marketId() != marketId
                || o.unitDecimals() != m.unitDecimals
                || keccak256(abi.encode(o.feedsOf(0), o.feedsOf(1))) != m.feedsHash
        ) _fail(marketId, "oracle");
        uint256 assetId;
        try IAaveV4Hub(hub).getAssetId(m.vaultToken) returns (uint256 a) {
            assetId = a;
        } catch {
            _fail(marketId, "hubAsset");
        }
        IAaveV4Spoke spoke = IAaveV4Spoke(m.spoke);
        try spoke.getReserveId(hub, assetId) returns (uint256 id) {
            reserveId = id;
        } catch {
            _fail(marketId, "reserve");
        }
        IAaveV4Spoke.Reserve memory r = spoke.getReserve(reserveId);
        if (r.underlying != m.vaultToken || r.hub != hub) _fail(marketId, "reserve");
        if (IAaveV4Hub(hub).getSpokeConfig(assetId, m.spoke).drawCap != 0) _fail(marketId, "drawCap");
        if (spoke.getReserveConfig(reserveId).receiveSharesEnabled) _fail(marketId, "receiveShares");
        IAaveV4Spoke.DynamicReserveConfig memory dc = spoke.getDynamicReserveConfig(reserveId, r.dynamicConfigKey);
        if (dc.liquidationFee != 0) _fail(marketId, "liquidationFee");
        if (dc.collateralFactor != m.ltvBps) _fail(marketId, "ltv");
        if (IAaveV4Oracle(spoke.ORACLE()).getReserveSource(reserveId) != lpOracle) _fail(marketId, "priceSource");
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

    /// @dev One feed's answer in 8 decimals, positive and below 2^128.
    function _leg(
        address feed
    ) private view returns (uint256 price) {
        if (feed == address(0)) revert IRiskModule.InvalidPriceFeed(feed);
        uint8 d = IAggregatorV3(feed).decimals();
        if (d > LPPriceMath.MAX_DECIMALS) revert IRiskModule.InvalidPriceFeed(feed);
        // Only the answer is used, as in the LPOracle.
        // forge-lint: disable-next-line(unused-return)
        (, int256 answer,,,) = IAggregatorV3(feed).latestRoundData();
        price = LPPriceMath.normalize(answer, d);
        if (price == 0) revert IRiskModule.InvalidPriceFeed(feed);
    }

    function _fail(
        uint256 marketId,
        bytes32 reason
    ) private pure {
        revert IRiskModule.ActivationCheckFailed(marketId, reason);
    }
}
// forge-lint: disable-end(calls-loop)
