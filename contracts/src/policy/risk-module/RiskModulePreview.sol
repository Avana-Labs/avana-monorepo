// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {RiskStatus} from "../../amm/types/RiskStatus.sol";
import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {AmmConstants} from "../../types/AmmConstants.sol";
import {Market} from "../../types/Market.sol";
import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {PledgePreview} from "../../types/PledgePreview.sol";
import {IAaveAdapterViews} from "../aave-adapter/IAaveAdapterViews.sol";
import {IParameterStore} from "../parameter-store/IParameterStore.sol";
import {IRiskModulePledgeLogic} from "./IRiskModulePledgeLogic.sol";
import {RiskModuleBase} from "./RiskModuleBase.sol";
import {RiskModuleMath} from "./RiskModuleMath.sol";
import {PledgeCharge} from "./types/PledgeCharge.sol";
import {RiskModuleImmutables} from "./types/RiskModuleImmutables.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RiskModulePreview
/// @notice The pledge context shared with `checkPledge`, and `previewPledge`: the same checks run before custody, with
/// the position's owner, shape and units from the market's AMM integration and the counters from Collateralization.
/// @dev `previewPledge` runs `checkPledge` itself through an external call to this logic contract, so the reason it
/// reports is exactly the error `checkPledge` would raise (REQ-RISK-031). Before custody it also reports
/// `NotPositionOwner`, the integration's own shape, pool or units error, and `TooManyRecords` for a 17th record. It is
/// called outside the Lock (Collateralization's views revert `Locked` inside one); the RiskModule turns any revert of
/// this body into a non-reverting preview.
/// @custom:spec REQ-RISK-010, REQ-RISK-027, REQ-RISK-031, REQ-RISK-057, REQ-RISK-008
// View calls in a loop over at most 8 pool tokens.
// forge-lint: disable-start(calls-loop)
abstract contract RiskModulePreview is RiskModuleBase, IRiskModulePledgeLogic {
    /// @dev Values of one pledge check.
    struct Ctx {
        Market m;
        uint256 marketId;
        address proxy;
        uint128 units;
        bool topUp;
        uint256 hf;
        uint256 debtRay;
        uint256 minPledge;
        uint256 pledgeUsd;
        uint256 charge;
        bool eligible;
        uint256 restore;
    }

    /// @dev The drift logic.
    address internal immutable _DRIFT;
    /// @dev The breaker logic.
    address internal immutable _BREAKER;

    /// @notice Fixes the implementation immutables and the drift and breaker logic.
    /// @param im The per-chain Avana addresses.
    /// @param drift The drift logic built with `im`.
    /// @param breaker The breaker logic built with `im`.
    /// @custom:spec REQ-RISK-002
    // `_requireLogic` checks each logic address, which rejects zero (REQ-RISK-002).
    // forge-lint: disable-next-item(missing-zero-check)
    constructor(
        RiskModuleImmutables memory im,
        address drift,
        address breaker
    ) RiskModuleBase(im) {
        _requireLogic(drift, keccak256("RiskModuleDriftLogic"));
        _requireLogic(breaker, keccak256("RiskModuleBreakerLogic"));
        _DRIFT = drift;
        _BREAKER = breaker;
    }

    /// @inheritdoc IRiskModulePledgeLogic
    /// @custom:spec REQ-RISK-031, REQ-RISK-057, REQ-RISK-010
    function previewPledge(
        address depositor,
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (PledgePreview memory p) {
        Market memory m = _market(marketId);
        address proxy = IAaveAdapterViews(_ADAPTER).proxyOf(depositor, marketId);
        if (proxy == address(0)) proxy = IAaveAdapterViews(_ADAPTER).predictProxy(depositor, marketId);
        ICollateralizationViews coll = ICollateralizationViews(_COLLATERALIZATION);
        PledgeCounters memory k = coll.getCounters(m.vaultToken, depositor);
        k.accountRecords = coll.getOpenRecordCount(proxy, m.vaultToken);
        p.isTopUp = _accountData(m.spoke, proxy).borrowCount > 0;
        _rooms(p, m, marketId, k);
        uint128 units;
        (p.reason, units) = _position(m, marketId, depositor, positionKey);
        if (p.reason != bytes4(0)) return p;
        p.usdCharge =
            RiskModuleMath.usdCharge(units, _accepted(m.lpOracle), _store().stressFloorUsd(marketId), m.decimals);
        if (k.accountRecords >= AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET) {
            p.reason = TooManyRecords.selector;
            return p;
        }
        try IRiskModulePledgeLogic(address(this))
            .checkPledge(depositor, proxy, marketId, m.integrationId, positionKey, units, k, false) returns (
            PledgeCharge memory ch
        ) {
            p.eligible = true;
            p.usdCharge = ch.usdCharge;
            p.sliceUsd = ch.sliceUsd;
        } catch (bytes memory err) {
            // The revert selector is the first four bytes of the revert data.
            // forge-lint: disable-next-line(unsafe-typecast)
            p.reason = bytes4(err);
        }
    }

    /// @dev Owner, then the integration's validation of shape, pool and units (REQ-RISK-010, REQ-RISK-031).
    function _position(
        Market memory m,
        uint256 marketId,
        address depositor,
        bytes32 positionKey
    ) internal view returns (bytes4 reason, uint128 units) {
        IAmmIntegration amm = IAmmIntegration(m.integration);
        if (amm.positionOwner(positionKey) != depositor) return (NotPositionOwner.selector, 0);
        try amm.validatePosition(marketId, depositor, positionKey) returns (uint128 u) {
            units = u;
        } catch (bytes memory err) {
            // The revert selector is the first four bytes of the revert data.
            // forge-lint: disable-next-line(unsafe-typecast)
            reason = err.length < 4 ? PoolMismatch.selector : bytes4(err);
        }
    }

    /// @dev Remaining room of every cap (REQ-RISK-031).
    function _rooms(
        PledgePreview memory p,
        Market memory m,
        uint256 marketId,
        PledgeCounters memory k
    ) internal view {
        IParameterStore ps = _store();
        p.marketRoomUsd = _room(ps.marketUsdCap(marketId), k.regularUsed);
        p.sliceRoomUsd = _room(ps.topUpSliceUsd(marketId), k.sliceUsed);
        p.depositorRoomUsd = _room(ps.depositorUsdCap(m.hub), k.depositorUsed);
        p.tokenRoomUsd = new uint256[](m.tokens.length);
        for (uint256 i = 0; i < m.tokens.length; ++i) {
            uint256 used = i < k.tokenUsed.length ? k.tokenUsed[i] : 0;
            p.tokenRoomUsd[i] = _room(ps.tokenUsdCap(m.hub, m.tokens[i]), used);
        }
        uint256 open = k.accountRecords;
        uint256 max = AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET;
        p.recordRoom = open < max ? max - open : 0;
        uint256 cap = ps.poolShareMaxBpsOf(_poolKey(m));
        if (cap >= NO_POOL_SHARE_CAP) {
            p.poolShareRoomUnits = type(uint256).max;
        } else {
            RiskStatus memory rs =
                IAmmIntegration(m.integration).riskStatus(marketId, ps.getMarketParams(marketId).twapWindow);
            if (rs.depthAvailable) {
                p.poolShareRoomUnits = RiskModuleMath.poolShareRoom(k.poolUnits, cap, rs.depthUnits);
            }
        }
    }

    /// @dev `cap - used`, floored at 0.
    function _room(
        uint256 cap,
        uint256 used
    ) internal pure returns (uint256 room) {
        room = cap > used ? cap - used : 0;
    }

    /// @dev `ceil(a * b / c)`.
    function _mulDivUp(
        uint256 a,
        uint256 b,
        uint256 c
    ) internal pure returns (uint256) {
        return Math.mulDiv(a, b, c, Math.Rounding.Ceil);
    }
}
// forge-lint: disable-end(calls-loop)
