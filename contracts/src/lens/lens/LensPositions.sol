// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
import {IRiskModuleViews} from "../../policy/risk-module/IRiskModuleViews.sol";
import {AccountGateStatus} from "../../types/AccountGateStatus.sol";
import {Market} from "../../types/Market.sol";
import {PauseState} from "../../types/PauseState.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {ILensPositions} from "./ILensPositions.sol";
import {LensAccountMath} from "./LensAccountMath.sol";
import {AccountRiskView} from "./types/AccountRiskView.sol";
import {PledgePreviewView} from "./types/PledgePreviewView.sol";
import {WithdrawPreview} from "./types/WithdrawPreview.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensPositions
/// @notice Account risk (liquidation price and borrow rates with the account's risk premium) and the pledge and
/// withdrawal previews.
/// @dev Health factors in WAD, Aave values in USD × 1e26, debt values in Aave value × RAY.
/// @custom:spec REQ-LENS-047, REQ-LENS-048, REQ-LENS-049
// View calls in loops over the Spoke's enabled debt reserves (REQ-LENS-020).
// forge-lint: disable-start(calls-loop)
abstract contract LensPositions is LensAccountMath, ILensPositions {
    /// @inheritdoc ILensPositions
    /// @custom:spec REQ-LENS-047, REQ-LENS-005, REQ-LENS-006
    function getAccountRisk(
        address wallet,
        uint256 marketId
    ) external view override returns (AccountRiskView memory v) {
        _unlocked();
        Market memory m = _market(marketId);
        (v.blockNumber, v.timestamp) = (block.number, block.timestamp);
        (v.proxy,) = _proxy(wallet, marketId, m.spoke);
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(m.spoke).getUserAccountData(v.proxy);
        v.reserveIds = _registry().getDebtReserveIds(m.spoke);
        v.borrowRatesRay = new uint256[](v.reserveIds.length);
        for (uint256 i = 0; i < v.reserveIds.length; ++i) {
            DebtReserveDef memory def = _registry().getDebtReserve(m.spoke, v.reserveIds[i]);
            uint256 drawn = ILensHubReads(def.fundingHub).getAssetDrawnRate(def.hubAssetId);
            v.borrowRatesRay[i] = Math.mulDiv(drawn, 1e4 + a.riskPremium, 1e4, Math.Rounding.Ceil);
        }
        if (a.totalDebtValueRay == 0) return v;
        uint256 cfAssets = _cfAssets(m, v.proxy);
        if (cfAssets == 0) {
            v.liquidationPrice = type(uint256).max;
        } else {
            v.liquidationPrice = Math.mulDiv(a.totalDebtValueRay, 1e4, cfAssets * RAY_, Math.Rounding.Ceil);
        }
    }

    /// @inheritdoc ILensPositions
    /// @custom:spec REQ-LENS-048, REQ-LENS-005, REQ-LENS-006
    function previewPledge(
        address depositor,
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (PledgePreviewView memory v) {
        _unlocked();
        (v.blockNumber, v.timestamp) = (block.number, block.timestamp);
        v.preview = IRiskModuleViews(_RISK_MODULE).previewPledge(depositor, marketId, positionKey);
    }

    /// @inheritdoc ILensPositions
    /// @custom:spec REQ-LENS-049, REQ-LENS-005, REQ-LENS-006, SPEC-CF-005
    function previewWithdraw(
        address wallet,
        uint256 marketId,
        bytes32 positionKey,
        uint256 units
    ) external view override returns (WithdrawPreview memory v) {
        _unlocked();
        Market memory m = _market(marketId);
        (v.blockNumber, v.timestamp) = (block.number, block.timestamp);
        (address proxy,) = _proxy(wallet, marketId, m.spoke);
        ICollateralizationViews coll = ICollateralizationViews(_COLLATERALIZATION);
        uint256 id = coll.recordIdOf(m.integrationId, positionKey);
        bool own = id != 0 && coll.getRecord(id).proxy == proxy;
        uint256 limit = own ? coll.previewRelease(m.integrationId, positionKey) : 0;
        v.units = units;
        if (units == 0) v.units = limit;
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(m.spoke).getUserAccountData(proxy);
        // A withdrawal refreshes the account to the reserve's latest collateral factor before Aave checks it.
        uint256 cf = _latestCf(m);
        uint256 left = _weightedLeft(m, a.totalCollateralValue, v.units, cf);
        v.healthFactorAfter = _hf(left, a.totalDebtValueRay);
        if (!own || v.units > limit) return v;
        if (a.totalDebtValueRay == 0) {
            v.allowed = true;
            return v;
        }
        v.allowed = _withdrawGate(m, marketId, proxy, left, cf, a.totalDebtValueRay);
    }

    // ------------------------------------------------------------------------------------------------------ internal

    /// @dev `⌊totalCollateralValue × CF / 10⁴⌋ − ⌈units × Pc × 10^(18 − d) × CF / 10⁴⌉`, floored at 0 (REQ-LENS-049).
    function _weightedLeft(
        Market memory m,
        uint256 collateralValue,
        uint256 units,
        uint256 cf
    ) internal view returns (uint256) {
        uint256 w = collateralValue * cf / 1e4;
        uint256 removed = Math.mulDiv(units * _servedPrice(m) * 10 ** (18 - m.decimals), cf, 1e4, Math.Rounding.Ceil);
        return w - Math.min(w, removed);
    }

    /// @dev The withdraw-with-debt gate of REQ-LENS-049: the gate status, no `Paused`, and the rescue-excluded health
    /// factor after at least `max(1e18, hardHealthFloor)`.
    function _withdrawGate(
        Market memory m,
        uint256 marketId,
        address proxy,
        uint256 left,
        uint256 cf,
        uint256 debtRay
    ) internal view returns (bool) {
        AccountGateStatus memory st = IRiskModuleViews(_RISK_MODULE).getAccountGateStatus(proxy);
        uint256 e = _rescueAt(m, proxy, cf);
        uint256 h0 = Math.max(_store().hardHealthFloor(marketId), WAD_);
        return st.withdrawWithDebtAllowed && st.pauseState != PauseState.Paused
            && _hf(left - Math.min(left, e), debtRay) >= h0;
    }
}
// forge-lint: disable-end(calls-loop)
