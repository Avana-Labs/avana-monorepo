// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDaoDeficitOffset} from "../../coverage/dao-deficit-offset/IDaoDeficitOffset.sol";
import {IAvanaFirstLossReserve} from "../../coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {DebtReserveDef, MarketStatus} from "../../policy/market-registry/types/MarketRegistryTypes.sol";
import {IRiskModule} from "../../policy/risk-module/IRiskModule.sol";
import {Market} from "../../types/Market.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {ILensRisk} from "./ILensRisk.sol";
import {LensBase} from "./LensBase.sol";
import {HubAssetExposureView, SpokeDraw} from "./types/HubAssetExposureView.sol";
import {SpokeKind} from "./types/SpokeKind.sol";
import {TailCoverageView} from "./types/TailCoverageView.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensRisk
/// @notice Risk views of the Lens: breaker status, address freezes, tail coverage, uncovered deficit and exposure.
// Loops are bounded by governance listings, one page of at most LENS_MAX_PAGE records, or the caller's arrays.
// forge-lint: disable-start(calls-loop)
abstract contract LensRisk is LensBase, ILensRisk {
    /// @dev Aave's `MAX_ALLOWED_SPOKE_CAP`, which leaves a Spoke's draw unlimited.
    uint256 internal constant MAX_SPOKE_CAP = type(uint40).max;

    /// @dev Pool tokens of the markets drawing a (Hub, asset), with their summed exposure and largest CF.
    struct Tails {
        address[] tokens;
        uint256[] usd;
        uint256[] cf;
        uint256 count;
        address[] pairToken;
        address[] pairHub;
        uint256 pairs;
    }

    /// @inheritdoc ILensRisk
    function getBreakerStatus(
        uint256 marketId
    ) external view override returns (uint32 reasons, uint64 reopensAt) {
        _unlocked();
        (reasons, reopensAt) = IRiskModule(_RISK_MODULE).getBreakerStatus(marketId);
    }

    /// @inheritdoc ILensRisk
    function getDebtBreakerStatus(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (uint32 reasons, uint64 reopensAt) {
        _unlocked();
        (reasons, reopensAt) = IRiskModule(_RISK_MODULE).getDebtBreakerStatus(spoke, debtReserveId);
    }

    /// @inheritdoc ILensRisk
    function isFrozenAddress(
        address account
    ) external view override returns (bool frozen) {
        _unlocked();
        frozen = _registry().isFrozenAddress(account);
    }

    /// @inheritdoc ILensRisk
    function getTailCoverage(
        address hub,
        address debtAsset
    ) external view override returns (TailCoverageView memory t) {
        _unlocked();
        (t.blockNumber, t.timestamp, t.hub, t.debtAsset) = (block.number, block.timestamp, hub, debtAsset);
        address[] memory spokes = _registry().getSpokes();
        bool[] memory draws = new bool[](spokes.length);
        (uint256 price, uint8 decimals) = _drawCaps(t, spokes, draws);
        if (t.firstLossReserve == address(0)) revert UnknownDebtAsset(debtAsset);
        t.funded = IAvanaFirstLossReserve(t.firstLossReserve).fundedBalance();
        t.minimum = IAvanaFirstLossReserve(t.firstLossReserve).firstLossReserveMinimum();
        t.fundedUsd = Math.mulDiv(t.funded, price, 10 ** decimals);
        (t.deficitOffset, t.offsetFunded) = _offset(hub, IAaveV4Hub(hub).getAssetId(debtAsset), t.firstLossReserve);
        Tails memory x = _tails(debtAsset, spokes, draws);
        for (uint256 j = 0; j < x.count; ++j) {
            uint256 tail = Math.mulDiv(x.usd[j], x.cf[j], 1e4, Math.Rounding.Ceil);
            if (tail > t.drawCapUsd) tail = t.drawCapUsd;
            if (tail > t.tailUsd) (t.tailUsd, t.worstToken) = (tail, x.tokens[j]);
        }
        t.ratioBps = t.tailUsd == 0 ? type(uint256).max : Math.mulDiv(t.fundedUsd, 1e4, t.tailUsd);
    }

    /// @inheritdoc ILensRisk
    function uncoveredDeficit(
        address hub,
        address asset
    ) external view override returns (uint256 uncovered) {
        _unlocked();
        (, uncovered,,,) = _deficit(hub, asset);
    }

    /// @inheritdoc ILensRisk
    function getHubAssetExposure(
        address hub,
        address asset
    ) external view override returns (HubAssetExposureView memory v) {
        _unlocked();
        (v.blockNumber, v.timestamp, v.hub, v.asset) = (block.number, block.timestamp, hub, asset);
        uint256 assetId;
        (assetId, v.uncovered, v.firstLossReserve, v.fundedBalance, v.deficitOffset, v.offsetFunded) =
            _exposure(hub, asset);
        // forge-lint: disable-next-line(unused-return)
        (v.line,) = _registry().creditLine(hub, asset);
        // forge-lint: disable-next-line(unused-return)
        (, uint8 decimals) = IAaveV4Hub(hub).getAssetUnderlyingAndDecimals(assetId);
        uint256 ratio = _store().coverageRatioBps();
        v.coverageBoundHolds = v.line * 10 ** decimals * ratio <= v.fundedBalance * 1e4;
        uint256 shares = IAaveV4Hub(hub).getAddedShares(assetId);
        uint256 assets = IAaveV4Hub(hub).getAddedAssets(assetId);
        if (shares != 0 && assets > v.uncovered) {
            v.priceAdj = Math.mulDiv(assets - v.uncovered, 10 ** decimals, shares);
        }
        v.spokes = _spokeDraws(hub, assetId);
    }

    function _drawCaps(
        TailCoverageView memory t,
        address[] memory spokes,
        bool[] memory draws
    ) internal view returns (uint256 price, uint8 decimals) {
        uint256 capSum = 0;
        bool unlimited = false;
        for (uint256 i = 0; i < spokes.length; ++i) {
            uint256[] memory ids = _registry().getDebtReserveIds(spokes[i]);
            for (uint256 k = 0; k < ids.length; ++k) {
                DebtReserveDef memory def = _registry().getDebtReserve(spokes[i], ids[k]);
                if (def.asset != t.debtAsset || def.fundingHub != t.hub) continue;
                draws[i] = true;
                if (t.firstLossReserve == address(0)) {
                    t.firstLossReserve = def.firstLossReserve;
                    price = IAaveV4Oracle(IAaveV4Spoke(spokes[i]).ORACLE()).getReservePrice(ids[k]);
                    decimals = def.decimals;
                }
                uint256 cap = IAaveV4Hub(t.hub).getSpokeConfig(def.hubAssetId, spokes[i]).drawCap;
                if (cap == MAX_SPOKE_CAP) unlimited = true;
                else capSum += cap;
            }
        }
        t.drawCapUsd = unlimited ? type(uint256).max : capSum * price;
    }

    function _tails(
        address debtAsset,
        address[] memory spokes,
        bool[] memory draws
    ) internal view returns (Tails memory x) {
        uint256 n = _registry().marketCount();
        uint256 slots = n * 8;
        (x.tokens, x.usd, x.cf) = (new address[](slots), new uint256[](slots), new uint256[](slots));
        (x.pairToken, x.pairHub) = (new address[](slots), new address[](slots));
        for (uint256 id = 1; id <= n; ++id) {
            Market memory m = _registry().getMarket(id);
            if (!_listed(m.status) || !_drawsFrom(m.spoke, spokes, draws)) continue;
            uint256 slice = _store().topUpSliceUsd(id);
            uint32 key = IAaveV4Spoke(m.spoke).getReserve(m.reserveId).dynamicConfigKey;
            uint256 cf = IAaveV4Spoke(m.spoke).getDynamicReserveConfig(m.reserveId, key).collateralFactor;
            for (uint256 i = 0; i < m.tokens.length; ++i) {
                if (m.tokens[i] != debtAsset) _addToken(x, m.tokens[i], m.hub, slice, cf);
            }
        }
    }

    /// @dev Adds one market's slice and CF to `token`, and the Hub-token cap the first time `(token, home)` is met.
    function _addToken(
        Tails memory x,
        address token,
        address home,
        uint256 slice,
        uint256 cf
    ) internal view {
        uint256 j = 0;
        while (j < x.count && x.tokens[j] != token) ++j;
        if (j == x.count) {
            x.tokens[j] = token;
            ++x.count;
        }
        x.usd[j] += slice;
        if (cf > x.cf[j]) x.cf[j] = cf;
        for (uint256 p = 0; p < x.pairs; ++p) {
            if (x.pairToken[p] == token && x.pairHub[p] == home) return;
        }
        (x.pairToken[x.pairs], x.pairHub[x.pairs]) = (token, home);
        ++x.pairs;
        x.usd[j] += _store().tokenUsdCap(home, token);
    }

    function _listed(
        MarketStatus s
    ) internal pure returns (bool) {
        return s == MarketStatus.Registered || s == MarketStatus.Active || s == MarketStatus.Offboarding;
    }

    function _drawsFrom(
        address spoke,
        address[] memory spokes,
        bool[] memory draws
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < spokes.length; ++i) {
            if (spokes[i] == spoke) return draws[i];
        }
        return false;
    }

    function _exposure(
        address hub,
        address asset
    )
        internal
        view
        returns (
            uint256 assetId,
            uint256 uncovered,
            address firstLossReserve,
            uint256 funded,
            address offset,
            uint256 offsetFunded
        )
    {
        (assetId, uncovered, funded, offset, offsetFunded) = _deficit(hub, asset);
        firstLossReserve = _registry().firstLossReserveOf(hub, asset);
    }

    function _deficit(
        address hub,
        address asset
    ) internal view returns (uint256 assetId, uint256 uncovered, uint256 funded, address offset, uint256 offsetFunded) {
        assetId = IAaveV4Hub(hub).getAssetId(asset);
        uint256 count = IAaveV4Hub(hub).getSpokeCount(assetId);
        uint256 deficit = 0;
        for (uint256 i = 0; i < count; ++i) {
            address s = IAaveV4Hub(hub).getSpokeAddress(assetId, i);
            deficit += Math.ceilDiv(IAaveV4Hub(hub).getSpokeDeficitRay(assetId, s), 1e27);
        }
        address firstLossReserve = _registry().firstLossReserveOf(hub, asset);
        if (firstLossReserve != address(0)) funded = IAvanaFirstLossReserve(firstLossReserve).fundedBalance();
        (offset, offsetFunded) = _offset(hub, assetId, firstLossReserve);
        uint256 layers = funded + offsetFunded;
        uncovered = deficit > layers ? deficit - layers : 0;
    }

    /// @dev The pair's DAO deficit offset: Spokes whose `FIRST_LOSS_LAYER()` is `firstLossReserve`.
    function _offset(
        address hub,
        uint256 assetId,
        address firstLossReserve
    ) internal view returns (address offset, uint256 offsetFunded) {
        if (firstLossReserve == address(0)) return (address(0), 0);
        uint256 count = IAaveV4Hub(hub).getSpokeCount(assetId);
        for (uint256 i = 0; i < count; ++i) {
            address s = IAaveV4Hub(hub).getSpokeAddress(assetId, i);
            if (!_standsBehind(s, firstLossReserve)) continue;
            if (offset == address(0)) offset = s;
            offsetFunded += IAaveV4Hub(hub).getSpokeAddedAssets(assetId, s);
        }
    }

    /// @dev Exact 32-byte match of `FIRST_LOSS_LAYER()`; a revert or other return is no match, 32 bytes copied max.
    function _standsBehind(
        address spoke,
        address layer
    ) internal view returns (bool matches) {
        bytes4 selector = IDaoDeficitOffset.FIRST_LOSS_LAYER.selector;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, selector)
            let ok := staticcall(gas(), spoke, p, 4, p, 32)
            matches := and(and(ok, eq(returndatasize(), 32)), eq(mload(p), layer))
        }
    }

    function _spokeDraws(
        address hub,
        uint256 assetId
    ) internal view returns (SpokeDraw[] memory out) {
        IAaveV4Hub h = IAaveV4Hub(hub);
        // forge-lint: disable-next-line(unused-return)
        (address underlying,) = h.getAssetUnderlyingAndDecimals(assetId);
        address[3] memory roles = [
            _registry().firstLossReserveOf(hub, underlying),
            h.getAssetConfig(assetId).feeReceiver,
            _registry().marketOfHubAsset(hub, assetId) == 0 ? address(0) : address(1)
        ];
        uint256 count = h.getSpokeCount(assetId);
        out = new SpokeDraw[](count);
        for (uint256 i = 0; i < count; ++i) {
            out[i] = _slice(hub, assetId, h.getSpokeAddress(assetId, i), roles);
        }
    }

    /// @dev One Spoke's slice of the asset (deficit rounded up) and its kind from `roles`.
    function _slice(
        address hub,
        uint256 assetId,
        address s,
        address[3] memory roles
    ) internal view returns (SpokeDraw memory d) {
        IAaveV4Hub h = IAaveV4Hub(hub);
        ILensHubReads r = ILensHubReads(hub);
        IAaveV4Hub.SpokeConfig memory c = h.getSpokeConfig(assetId, s);
        (d.spoke, d.homeHub, d.drawCap, d.addCap, d.active, d.halted) =
        (s, _registry().hubOf(s), c.drawCap, c.addCap, c.active, c.halted);
        d.drawn = h.getSpokeTotalOwed(assetId, s);
        d.deficit = Math.ceilDiv(h.getSpokeDeficitRay(assetId, s), 1e27);
        (d.drawnOwed, d.premiumOwed) = r.getSpokeOwed(assetId, s);
        (d.added, d.addedShares) = (h.getSpokeAddedAssets(assetId, s), h.getSpokeAddedShares(assetId, s));
        d.drawnShares = r.getSpokeDrawnShares(assetId, s);
        // forge-lint: disable-next-line(unused-return)
        (d.premiumShares,) = r.getSpokePremiumData(assetId, s);
        if (d.homeHub != address(0)) d.kind = SpokeKind.Cdp;
        else if (s == roles[0]) d.kind = SpokeKind.Coverage;
        else if (s == roles[1]) d.kind = SpokeKind.FeeReceiver;
        else if (roles[0] != address(0) && _standsBehind(s, roles[0])) d.kind = SpokeKind.DeficitOffset;
        else d.kind = roles[2] == address(0) ? SpokeKind.Lend : SpokeKind.Other;
    }
}
// forge-lint: disable-end(calls-loop)
