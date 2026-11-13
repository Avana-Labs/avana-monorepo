// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICoverageSpoke} from "../../coverage/coverage-spoke/ICoverageSpoke.sol";
import {IDeficitOffsetSpoke} from "../../coverage/deficit-offset-spoke/IDeficitOffsetSpoke.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../policy/market-registry/types/MarketStatus.sol";
import {IRiskModuleViews} from "../../policy/risk-module/IRiskModuleViews.sol";
import {Market} from "../../types/Market.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {ILensRisk} from "./ILensRisk.sol";
import {LensBase} from "./LensBase.sol";
import {HubAssetExposureView, SpokeDraw} from "./types/HubAssetExposureView.sol";
import {SpokeKind} from "./types/SpokeKind.sol";
import {TailCoverageView} from "./types/TailCoverageView.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensRisk
/// @notice Risk views of the Lens: breaker status passed through from the RiskModule, address freezes, the cap-based
/// tail coverage of each (funding Hub, debt asset) First-Loss Reserve, the uncovered deficit and the exposure of a
/// (Hub, asset) pair across its Spokes, with both loss layers of the pair: the Coverage Spoke and the DAO deficit
/// offset behind it.
/// @dev Loops over the MarketRegistry's Spokes, their enabled debt reserves and its markets, and over the Spokes
/// registered on a Hub asset, all bounded by governance listings.
/// @custom:spec REQ-LENS-034, REQ-LENS-037, REQ-LENS-039, REQ-LENS-042, REQ-LENS-043, REQ-FLR-046
// View calls in loops over listings bounded by governance (Spokes, debt reserves, markets, pool tokens), one
// page of at most LENS_MAX_PAGE records or the caller's own arrays (REQ-LENS-020).
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
    /// @custom:spec REQ-LENS-037, REQ-LENS-006
    function getBreakerStatus(
        uint256 marketId
    ) external view override returns (uint32 reasons, uint64 reopensAt) {
        _unlocked();
        (reasons, reopensAt) = IRiskModuleViews(_RISK_MODULE).getBreakerStatus(marketId);
    }

    /// @inheritdoc ILensRisk
    /// @custom:spec REQ-LENS-037, REQ-LENS-006
    function getDebtBreakerStatus(
        address spoke,
        uint256 debtReserveId
    ) external view override returns (uint32 reasons, uint64 reopensAt) {
        _unlocked();
        (reasons, reopensAt) = IRiskModuleViews(_RISK_MODULE).getDebtBreakerStatus(spoke, debtReserveId);
    }

    /// @inheritdoc ILensRisk
    /// @custom:spec REQ-LENS-037, REQ-LENS-006
    function isFrozenAddress(
        address account
    ) external view override returns (bool frozen) {
        _unlocked();
        frozen = _registry().isFrozenAddress(account);
    }

    /// @inheritdoc ILensRisk
    /// @custom:spec REQ-LENS-034, REQ-LENS-039, SPEC-CAP-008, REQ-LENS-005, REQ-LENS-006
    function getTailCoverage(
        address hub,
        address debtAsset
    ) external view override returns (TailCoverageView memory t) {
        _unlocked();
        (t.blockNumber, t.timestamp, t.hub, t.debtAsset) = (block.number, block.timestamp, hub, debtAsset);
        address[] memory spokes = _registry().getSpokes();
        bool[] memory draws = new bool[](spokes.length);
        (uint256 price, uint8 decimals) = _drawCaps(t, spokes, draws);
        if (t.coverageSpoke == address(0)) revert UnknownDebtAsset(debtAsset);
        t.funded = ICoverageSpoke(t.coverageSpoke).fundedBalance();
        t.minimum = ICoverageSpoke(t.coverageSpoke).firstLossReserveMinimum();
        t.fundedUsd = Math.mulDiv(t.funded, price, 10 ** decimals);
        (t.deficitOffset, t.offsetFunded) = _offset(hub, IAaveV4Hub(hub).getAssetId(debtAsset), t.coverageSpoke);
        Tails memory x = _tails(debtAsset, spokes, draws);
        for (uint256 j = 0; j < x.count; ++j) {
            uint256 tail = Math.mulDiv(x.usd[j], x.cf[j], 1e4, Math.Rounding.Ceil);
            if (tail > t.drawCapUsd) tail = t.drawCapUsd;
            if (tail > t.tailUsd) (t.tailUsd, t.worstToken) = (tail, x.tokens[j]);
        }
        t.ratioBps = t.tailUsd == 0 ? type(uint256).max : Math.mulDiv(t.fundedUsd, 1e4, t.tailUsd);
    }

    /// @inheritdoc ILensRisk
    /// @custom:spec REQ-LENS-042, REQ-LENS-006
    function uncoveredDeficit(
        address hub,
        address asset
    ) external view override returns (uint256 uncovered) {
        _unlocked();
        (, uncovered,,,) = _deficit(hub, asset);
    }

    /// @inheritdoc ILensRisk
    /// @custom:spec REQ-LENS-043, REQ-LENS-005, REQ-LENS-006
    function getHubAssetExposure(
        address hub,
        address asset
    ) external view override returns (HubAssetExposureView memory v) {
        _unlocked();
        (v.blockNumber, v.timestamp, v.hub, v.asset) = (block.number, block.timestamp, hub, asset);
        uint256 assetId;
        (assetId, v.uncovered, v.coverageSpoke, v.fundedBalance, v.deficitOffset, v.offsetFunded) =
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

    // ------------------------------------------------------------------------------------------------------ internal

    /// @dev Marks the Spokes with an enabled reserve of `t.debtAsset` funded by `t.hub`, sets the Coverage Spoke from
    /// the first such reserve and `drawCapUsd`, and returns the asset's served price and decimals.
    /// @custom:spec REQ-LENS-034
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
                if (t.coverageSpoke == address(0)) {
                    t.coverageSpoke = def.coverageSpoke;
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

    /// @dev Exposure per pool token other than the debt asset over every listed market whose CDP Spoke draws the
    /// asset from the Hub: `tokenUsdCap(h, t)` once per home Hub `h`, every holding market's `topUpSliceUsd`, and the
    /// largest collateral factor (latest dynamic configuration of the vault-token reserve) of a market holding `t`.
    /// @custom:spec REQ-LENS-034, SPEC-CAP-008
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

    /// @dev Adds one market's slice and CF to token `token`, and the Hub-token cap the first time `(token, home)` is
    /// met.
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

    /// @dev A market whose listing is in force: Registered, Active or Offboarding.
    function _listed(
        MarketStatus s
    ) internal pure returns (bool) {
        return s == MarketStatus.Registered || s == MarketStatus.Active || s == MarketStatus.Offboarding;
    }

    /// @dev Whether `spoke` is one of the marked Spokes.
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

    /// @dev `_deficit` with the pair's Coverage Spoke and its DAO deficit offset named.
    function _exposure(
        address hub,
        address asset
    )
        internal
        view
        returns (
            uint256 assetId,
            uint256 uncovered,
            address coverageSpoke,
            uint256 funded,
            address offset,
            uint256 offsetFunded
        )
    {
        (assetId, uncovered, funded, offset, offsetFunded) = _deficit(hub, asset);
        coverageSpoke = _registry().coverageSpokeOf(hub, asset);
    }

    /// @dev The Hub asset of `asset`, the uncovered deficit `max(0, Σ ⌈deficitRay / 1e27⌉ − funded − offsetFunded)` over
    /// every Spoke registered on it, the funded balance of `coverageSpokeOf(hub, asset)` (0 when none is set), and the
    /// pair's DAO deficit offset with its added assets (`_offset`).
    /// @custom:spec REQ-LENS-042, REQ-FLR-046
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
        address coverageSpoke = _registry().coverageSpokeOf(hub, asset);
        if (coverageSpoke != address(0)) funded = ICoverageSpoke(coverageSpoke).fundedBalance();
        (offset, offsetFunded) = _offset(hub, assetId, coverageSpoke);
        uint256 layers = funded + offsetFunded;
        uncovered = deficit > layers ? deficit - layers : 0;
    }

    /// @dev The DAO deficit offset of a pair: every Spoke listed on the Hub asset whose `FIRST_LOSS_LAYER()` returns
    /// `coverageSpoke`, summing their added assets; `offset` is the first in the Hub's order (0 when none, or when the
    /// pair has no Coverage Spoke).
    /// @custom:spec REQ-LENS-042, REQ-FLR-046
    function _offset(
        address hub,
        uint256 assetId,
        address coverageSpoke
    ) internal view returns (address offset, uint256 offsetFunded) {
        if (coverageSpoke == address(0)) return (address(0), 0);
        uint256 count = IAaveV4Hub(hub).getSpokeCount(assetId);
        for (uint256 i = 0; i < count; ++i) {
            address s = IAaveV4Hub(hub).getSpokeAddress(assetId, i);
            if (!_standsBehind(s, coverageSpoke)) continue;
            if (offset == address(0)) offset = s;
            offsetFunded += IAaveV4Hub(hub).getSpokeAddedAssets(assetId, s);
        }
    }

    /// @dev Whether `spoke.FIRST_LOSS_LAYER()` returns exactly the 32-byte word of `layer`. A revert, a return of any
    /// other length or any other word (an address with dirty upper bits included) is no match, and at most 32 bytes
    /// of return data are copied.
    /// @custom:spec REQ-LENS-042, REQ-FLR-046
    function _standsBehind(
        address spoke,
        address layer
    ) internal view returns (bool matches) {
        bytes4 selector = IDeficitOffsetSpoke.FIRST_LOSS_LAYER.selector;
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            let p := mload(0x40)
            mstore(p, selector)
            let ok := staticcall(gas(), spoke, p, 4, p, 32)
            matches := and(and(ok, eq(returndatasize(), 32)), eq(mload(p), layer))
        }
    }

    /// @dev Every Spoke registered on the Hub asset, in the Hub's order, with its slice of the asset (REQ-LENS-059).
    /// @custom:spec REQ-LENS-043, REQ-LENS-059
    function _spokeDraws(
        address hub,
        uint256 assetId
    ) internal view returns (SpokeDraw[] memory out) {
        IAaveV4Hub h = IAaveV4Hub(hub);
        // forge-lint: disable-next-line(unused-return)
        (address underlying,) = h.getAssetUnderlyingAndDecimals(assetId);
        address[3] memory roles = [
            _registry().coverageSpokeOf(hub, underlying),
            h.getAssetConfig(assetId).feeReceiver,
            _registry().marketOfHubAsset(hub, assetId) == 0 ? address(0) : address(1)
        ];
        uint256 count = h.getSpokeCount(assetId);
        out = new SpokeDraw[](count);
        for (uint256 i = 0; i < count; ++i) {
            out[i] = _slice(hub, assetId, h.getSpokeAddress(assetId, i), roles);
        }
    }

    /// @dev One Spoke's slice: configuration, owed split, deficit (rounded up), added assets and shares, drawn and
    /// premium shares, and its kind from `roles` (Coverage Spoke, fee receiver, and a non-zero third entry for a
    /// market's vault-token asset); a Spoke standing behind the Coverage Spoke is the DAO deficit offset.
    /// @custom:spec REQ-LENS-059, REQ-HUB-015, REQ-FLR-046
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
