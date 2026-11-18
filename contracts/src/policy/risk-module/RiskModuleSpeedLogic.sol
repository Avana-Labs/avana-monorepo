// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {Market} from "../../types/Market.sol";
import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {DebtReserveDef} from "../market-registry/types/MarketRegistryTypes.sol";
import {MarketSpeedLimits, SpeedLimit} from "../parameter-store/types/ParameterStoreTypes.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {IRiskModuleSpeedLogic} from "./IRiskModuleSpeedLogic.sol";
import {IRiskModuleViews} from "./IRiskModuleViews.sol";
import {RiskModuleBase} from "./RiskModuleBase.sol";
import {SpeedLimitMath} from "./SpeedLimitMath.sol";
import {BorrowSpeedInputs} from "./types/BorrowSpeedInputs.sol";
import {RiskModuleImmutables} from "./types/RiskModuleImmutables.sol";
import {SpeedScope} from "./types/SpeedScope.sol";
import {SpeedView} from "./types/SpeedView.sol";
import {SpeedWindow} from "./types/SpeedWindow.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RiskModuleSpeedLogic
/// @notice The net-flow speed limits: window bases, charges, credits and each new window.
/// @dev Reads windows from the caller's `getSpeedWindow`; only the RiskModule proxy stores them.
// View calls in loops over the registry's Spokes and a Spoke's debt reserves, bounded by listings.
// forge-lint: disable-start(calls-loop)
contract RiskModuleSpeedLogic is RiskModuleBase, IRiskModuleSpeedLogic {
    constructor(
        RiskModuleImmutables memory im
    ) RiskModuleBase(im) {}

    /// @inheritdoc IRiskModuleLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("RiskModuleSpeedLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IRiskModuleSpeedLogic
    function borrowCharge(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    )
        external
        view
        override
        returns (uint256 marketId, bytes32 debtKey, SpeedWindow memory market, SpeedWindow memory debt)
    {
        // The account's Spoke is the market's Spoke; the borrow logic checked it before this read.
        // forge-lint: disable-next-line(unused-return)
        (, marketId) = _account(proxy);
        BorrowSpeedInputs memory s = _inputs(marketId, debtReserveId, amount);
        debtKey = s.debtKey;
        MarketSpeedLimits memory p = s.market;
        (SpeedWindow memory w, uint256 lim, uint256 base) = _rolled(
            SpeedScope.MarketBorrow,
            bytes32(marketId),
            p.window,
            p.borrowRateBps,
            p.borrowMinUsd,
            p.borrowMaxUsd,
            s.marketBase
        );
        if (!SpeedLimitMath.fits(w, lim, s.amountUsd)) {
            SpeedView memory v = SpeedLimitMath.viewOf(w, p.window, lim);
            revert BorrowSpeedExceeded(marketId, v.available, v.moreAt);
        }
        market = SpeedLimitMath.add(w, s.amountUsd, base);
        SpeedLimit memory q = s.debt;
        (w, lim, base) = _rolled(SpeedScope.DebtBorrow, debtKey, q.window, q.rateBps, q.min, q.max, s.debtBase);
        if (!SpeedLimitMath.fits(w, lim, amount)) {
            SpeedView memory v = SpeedLimitMath.viewOf(w, q.window, lim);
            revert DebtSpeedExceeded(s.hub, s.asset, v.available, v.moreAt);
        }
        debt = SpeedLimitMath.add(w, amount, base);
    }

    /// @inheritdoc IRiskModuleSpeedLogic
    function pledgeCharge(
        uint256 marketId,
        uint256 bookedUsd,
        uint256 usdCharge
    ) external view override returns (SpeedWindow memory pledge) {
        MarketSpeedLimits memory p = _store().marketSpeedLimits(marketId);
        (SpeedWindow memory w, uint256 lim, uint256 base) = _rolled(
            SpeedScope.MarketPledge,
            bytes32(marketId),
            p.window,
            p.pledgeRateBps,
            p.pledgeMinUsd,
            p.pledgeMaxUsd,
            bookedUsd
        );
        if (!SpeedLimitMath.fits(w, lim, usdCharge)) {
            SpeedView memory v = SpeedLimitMath.viewOf(w, p.window, lim);
            revert PledgeSpeedExceeded(marketId, v.available, v.moreAt);
        }
        pledge = SpeedLimitMath.add(w, usdCharge, base);
    }

    /// @inheritdoc IRiskModuleSpeedLogic
    function repayCredit(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    )
        external
        view
        override
        returns (uint256 marketId, bytes32 debtKey, SpeedWindow memory market, SpeedWindow memory debt)
    {
        address spoke;
        (spoke, marketId) = _account(proxy);
        DebtReserveDef memory def = _registry().getDebtReserve(spoke, debtReserveId);
        debtKey = keccak256(abi.encode(def.fundingHub, def.asset));
        uint256 price8 = IAaveV4Oracle(IAaveV4Spoke(spoke).ORACLE()).getReservePrice(debtReserveId);
        uint256 usd = Math.mulDiv(amount, price8, 10 ** def.decimals);
        market = _credited(SpeedScope.MarketBorrow, bytes32(marketId), _store().marketSpeedLimits(marketId).window, usd);
        debt = _credited(
            SpeedScope.DebtBorrow, debtKey, _store().debtSpeedLimit(def.fundingHub, def.asset).window, amount
        );
    }

    /// @inheritdoc IRiskModuleSpeedLogic
    function withdrawCredit(
        uint256 marketId,
        uint256 usd
    ) external view override returns (SpeedWindow memory pledge) {
        pledge = _credited(SpeedScope.MarketPledge, bytes32(marketId), _store().marketSpeedLimits(marketId).window, usd);
    }

    /// @inheritdoc IRiskModuleSpeedLogic
    function borrowViews(
        uint256 marketId,
        uint256 debtReserveId
    ) external view override returns (SpeedView memory market, SpeedView memory debt) {
        BorrowSpeedInputs memory s = _inputs(marketId, debtReserveId, 0);
        MarketSpeedLimits memory p = s.market;
        (SpeedWindow memory w, uint256 lim,) = _rolled(
            SpeedScope.MarketBorrow,
            bytes32(marketId),
            p.window,
            p.borrowRateBps,
            p.borrowMinUsd,
            p.borrowMaxUsd,
            s.marketBase
        );
        market = SpeedLimitMath.viewOf(w, p.window, lim);
        SpeedLimit memory q = s.debt;
        (w, lim,) = _rolled(SpeedScope.DebtBorrow, s.debtKey, q.window, q.rateBps, q.min, q.max, s.debtBase);
        debt = SpeedLimitMath.viewOf(w, q.window, lim);
    }

    /// @inheritdoc IRiskModuleSpeedLogic
    function pledgeView(
        uint256 marketId
    ) external view override returns (SpeedView memory pledge) {
        (MarketSpeedLimits memory p, uint256 booked) = _pledgeInputs(marketId);
        (SpeedWindow memory w, uint256 lim,) = _rolled(
            SpeedScope.MarketPledge,
            bytes32(marketId),
            p.window,
            p.pledgeRateBps,
            p.pledgeMinUsd,
            p.pledgeMaxUsd,
            booked
        );
        pledge = SpeedLimitMath.viewOf(w, p.window, lim);
    }

    /// @dev The stored window rolled to now, its limit and its base; a never-written scope has limit 0.
    function _rolled(
        SpeedScope scope,
        bytes32 key,
        uint256 window,
        uint256 rateBps,
        uint256 min,
        uint256 max,
        uint256 liveBase
    ) internal view returns (SpeedWindow memory r, uint256 lim, uint256 base) {
        SpeedWindow memory stored = IRiskModuleViews(msg.sender).getSpeedWindow(scope, key);
        r = SpeedLimitMath.roll(stored, window, block.timestamp);
        base = SpeedLimitMath.windowBase(stored, r, liveBase);
        if (window != 0) lim = SpeedLimitMath.limit(rateBps, min, max, base);
    }

    function _credited(
        SpeedScope scope,
        bytes32 key,
        uint256 window,
        uint256 x
    ) internal view returns (SpeedWindow memory) {
        return
            SpeedLimitMath.credit(IRiskModuleViews(msg.sender).getSpeedWindow(scope, key), window, block.timestamp, x);
    }

    function _pledgeInputs(
        uint256 marketId
    ) internal view returns (MarketSpeedLimits memory limits, uint256 bookedUsd) {
        Market memory m = _market(marketId);
        if (m.vaultToken == address(0)) revert MarketNotActive(marketId);
        limits = _store().marketSpeedLimits(marketId);
        PledgeCounters memory c = ICollateralizationViews(_COLLATERALIZATION).getCounters(m.vaultToken, address(0));
        bookedUsd = uint256(c.regularUsed) + c.sliceUsed;
    }

    function _inputs(
        uint256 marketId,
        uint256 r,
        uint256 amount
    ) internal view returns (BorrowSpeedInputs memory inputs) {
        Market memory m = _market(marketId);
        if (m.vaultToken == address(0)) revert MarketNotActive(marketId);
        address spoke = m.spoke;
        DebtReserveDef memory def = _registry().getDebtReserve(spoke, r);
        address oracle = IAaveV4Spoke(spoke).ORACLE();
        inputs.hub = def.fundingHub;
        inputs.asset = def.asset;
        inputs.debtKey = keccak256(abi.encode(def.fundingHub, def.asset));
        if (amount != 0) {
            inputs.amountUsd = SpeedLimitMath.usdOf(amount, IAaveV4Oracle(oracle).getReservePrice(r), def.decimals);
        }
        inputs.marketBase = _spokeDebtUsd(spoke, oracle);
        inputs.debtBase = _owedToHub(def.fundingHub, def.hubAssetId);
        inputs.market = _store().marketSpeedLimits(marketId);
        inputs.debt = _store().debtSpeedLimit(def.fundingHub, def.asset);
    }

    /// @dev USD debt of the Spoke over its debt reserves, each rounded down.
    function _spokeDebtUsd(
        address spoke,
        address oracle
    ) internal view returns (uint256 usd) {
        uint256[] memory ids = _registry().getDebtReserveIds(spoke);
        for (uint256 i = 0; i < ids.length; ++i) {
            DebtReserveDef memory d = _registry().getDebtReserve(spoke, ids[i]);
            uint256 owed = IAaveV4Hub(d.fundingHub).getSpokeTotalOwed(d.hubAssetId, spoke);
            if (owed == 0) continue;
            usd += Math.mulDiv(owed, IAaveV4Oracle(oracle).getReservePrice(ids[i]), 10 ** d.decimals);
        }
    }

    /// @dev Asset owed to the Hub by every MarketRegistry Spoke listed on the Hub asset.
    function _owedToHub(
        address hub,
        uint256 assetId
    ) internal view returns (uint256 owed) {
        address[] memory spokes = _registry().getSpokes();
        for (uint256 i = 0; i < spokes.length; ++i) {
            if (!IAaveV4Hub(hub).isSpokeListed(assetId, spokes[i])) continue;
            owed += IAaveV4Hub(hub).getSpokeTotalOwed(assetId, spokes[i]);
        }
    }
}
// forge-lint: disable-end(calls-loop)
