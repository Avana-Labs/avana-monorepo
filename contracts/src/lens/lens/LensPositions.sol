// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
import {IRiskModuleViews} from "../../policy/risk-module/IRiskModuleViews.sol";
import {RiskModuleMath} from "../../policy/risk-module/RiskModuleMath.sol";
import {AccountGateStatus} from "../../types/AccountGateStatus.sol";
import {Market} from "../../types/Market.sol";
import {PauseState} from "../../types/PauseState.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {ILensPositions} from "./ILensPositions.sol";
import {LensBase} from "./LensBase.sol";
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
abstract contract LensPositions is LensBase, ILensPositions {
    /// @dev RAY.
    uint256 internal constant RAY_ = 1e27;
    /// @dev WAD.
    uint256 internal constant WAD_ = 1e18;

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
        v.liquidationPrice = cfAssets == 0
            ? type(uint256).max
            : Math.mulDiv(a.totalDebtValueRay, 1e4, cfAssets * RAY_, Math.Rounding.Ceil);
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
        v.units = units == 0 ? limit : units;
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(m.spoke).getUserAccountData(proxy);
        uint256 w = Math.mulDiv(a.avgCollateralFactor, a.totalCollateralValue, WAD_);
        uint256 removed = _weightedValue(m, proxy, v.units);
        uint256 left = w > removed ? w - removed : 0;
        v.healthFactorAfter = _hf(left, a.totalDebtValueRay);
        if (!own || v.units > limit) return v;
        if (a.totalDebtValueRay == 0) {
            v.allowed = true;
            return v;
        }
        AccountGateStatus memory st = IRiskModuleViews(_RISK_MODULE).getAccountGateStatus(proxy);
        uint256 e = _rescue(m, proxy);
        uint256 h0 = _store().hardHealthFloor(marketId);
        if (h0 < WAD_) h0 = WAD_;
        v.allowed = st.withdrawWithDebtAllowed && st.pauseState != PauseState.Paused
            && _hf(left > e ? left - e : 0, a.totalDebtValueRay) >= h0;
    }

    // ------------------------------------------------------------------------------------------------------ internal

    /// @dev `CF × assets × 10^(18 − d)`: the account's collateral value per unit of 8-decimal price, times its CF (bps).
    /// @custom:spec REQ-LENS-047
    function _cfAssets(
        Market memory m,
        address proxy
    ) internal view returns (uint256) {
        uint256 shares = IAaveV4Spoke(m.spoke).getUserSuppliedShares(m.reserveId, proxy);
        uint256 assets = ILensHubReads(m.hub).previewRemoveByShares(m.hubAssetId, shares);
        return _cf(m, proxy) * assets * 10 ** (18 - m.decimals);
    }

    /// @dev The account's own dynamic-configuration collateral factor of the vault-token reserve, bps.
    function _cf(
        Market memory m,
        address proxy
    ) internal view returns (uint256) {
        uint32 key = IAaveV4Spoke(m.spoke).getUserPosition(m.reserveId, proxy).dynamicConfigKey;
        return IAaveV4Spoke(m.spoke).getDynamicReserveConfig(m.reserveId, key).collateralFactor;
    }

    /// @dev `⌈units × Pc × 10^(18 − d) × CF / 10⁴⌉` at the AaveOracle's served price of the vault-token reserve.
    /// @custom:spec REQ-LENS-049
    function _weightedValue(
        Market memory m,
        address proxy,
        uint256 units
    ) internal view returns (uint256) {
        uint256 price = IAaveV4Oracle(IAaveV4Spoke(m.spoke).ORACLE()).getReservePrice(m.reserveId);
        return Math.mulDiv(units * price * 10 ** (18 - m.decimals), _cf(m, proxy), 1e4, Math.Rounding.Ceil);
    }

    /// @dev SPEC-CF-005 rescue exclusion of the account at the served LPOracle price.
    function _rescue(
        Market memory m,
        address proxy
    ) internal view returns (uint256) {
        uint256 u = ICollateralizationViews(_COLLATERALIZATION).getAccountRescueUnits(proxy, m.vaultToken);
        if (u == 0) return 0;
        int256 served = ILPOracle(m.lpOracle).latestAnswer();
        // forge-lint: disable-next-line(unsafe-typecast)
        return RiskModuleMath.rescueValue(u, served > 0 ? uint256(served) : 0, _cf(m, proxy), m.decimals);
    }

    /// @dev Aave's health factor of a weighted collateral value against a debt value, WAD, rounded down.
    function _hf(
        uint256 weighted,
        uint256 debtRay
    ) internal pure returns (uint256) {
        if (debtRay == 0) return type(uint256).max;
        return Math.mulDiv(weighted * WAD_, RAY_, debtRay);
    }
}
// forge-lint: disable-end(calls-loop)
