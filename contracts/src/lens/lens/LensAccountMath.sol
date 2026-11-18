// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {BackingRecord} from "../../custody/collateralization/types/BackingRecord.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {RiskModuleMath} from "../../policy/risk-module/RiskModuleMath.sol";
import {AmmConstants} from "../../types/AmmConstants.sol";
import {Market} from "../../types/Market.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {LensBase} from "./LensBase.sol";
import {RecordRemoval} from "./types/RemovalSizing.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensAccountMath
/// @notice Shared account arithmetic: Aave's health factor, liquidation price, collateral factors and repay math.
/// @dev Health factors in WAD, Aave values as in Aave's `toValue`, debt values in Aave value × RAY.
// Loops over the at most 16 records of one account-market.
// forge-lint: disable-start(calls-loop)
abstract contract LensAccountMath is LensBase {
    uint256 internal constant RAY_ = 1e27;
    uint256 internal constant WAD_ = 1e18;

    /// @dev `CF × assets × 10^(18 − d)`: collateral value per unit of 8-decimal price, times CF (bps).
    function _cfAssets(
        Market memory m,
        address proxy
    ) internal view returns (uint256) {
        return _cf(m, proxy) * _assetsOf(m, proxy) * 10 ** (18 - m.decimals);
    }

    /// @dev The account's vault-token assets on the Hub: its supplied shares at the Hub's removal rate, rounded down.
    function _assetsOf(
        Market memory m,
        address proxy
    ) internal view returns (uint256) {
        uint256 shares = IAaveV4Spoke(m.spoke).getUserSuppliedShares(m.reserveId, proxy);
        return ILensHubReads(m.hub).previewRemoveByShares(m.hubAssetId, shares);
    }

    /// @dev The account's own dynamic-configuration collateral factor of the vault-token reserve, bps.
    function _cf(
        Market memory m,
        address proxy
    ) internal view returns (uint256) {
        uint32 key = IAaveV4Spoke(m.spoke).getUserPosition(m.reserveId, proxy).dynamicConfigKey;
        return IAaveV4Spoke(m.spoke).getDynamicReserveConfig(m.reserveId, key).collateralFactor;
    }

    /// @dev Collateral factor of the reserve's latest dynamic configuration, bps.
    function _latestCf(
        Market memory m
    ) internal view returns (uint256) {
        uint32 key = IAaveV4Spoke(m.spoke).getReserve(m.reserveId).dynamicConfigKey;
        return IAaveV4Spoke(m.spoke).getDynamicReserveConfig(m.reserveId, key).collateralFactor;
    }

    function _servedPrice(
        Market memory m
    ) internal view returns (uint256) {
        return IAaveV4Oracle(IAaveV4Spoke(m.spoke).ORACLE()).getReservePrice(m.reserveId);
    }

    function _rescueAt(
        Market memory m,
        address proxy,
        uint256 cf
    ) internal view returns (uint256) {
        uint256 u = ICollateralizationViews(_COLLATERALIZATION).getAccountRescueUnits(proxy, m.vaultToken);
        if (u == 0) return 0;
        int256 served = ILPOracle(m.lpOracle).latestAnswer();
        // forge-lint: disable-next-line(unsafe-typecast)
        return RiskModuleMath.rescueValue(u, served > 0 ? uint256(served) : 0, cf, m.decimals);
    }

    /// @dev Aave's health factor of a weighted collateral value against a debt value, WAD, rounded down.
    function _hf(
        uint256 weighted,
        uint256 debtRay
    ) internal pure returns (uint256) {
        if (debtRay == 0) return type(uint256).max;
        return Math.mulDiv(weighted * WAD_, RAY_, debtRay);
    }

    function _hfOf(
        uint256 cf,
        uint256 collateralValue,
        uint256 debtRay
    ) internal pure returns (uint256) {
        if (debtRay == 0) return type(uint256).max;
        return Math.mulDiv(cf * collateralValue * 1e14, RAY_, debtRay);
    }

    /// @dev Vault-token price at which the health factor reaches 1.00, rounded up.
    function _liquidationPrice(
        uint256 debtRay,
        uint256 cfAssets
    ) internal pure returns (uint256) {
        if (debtRay == 0) return 0;
        if (cfAssets == 0) return type(uint256).max;
        return Math.mulDiv(debtRay, 1e4, cfAssets * RAY_, Math.Rounding.Ceil);
    }

    /// @dev The reserve's debt (asset units × RAY) left after repaying `amount`; drawn shares round down.
    function _restRay(
        uint256 drawnShares,
        uint256 premiumRay,
        uint256 index,
        uint256 amount
    ) internal pure returns (uint256) {
        uint256 drawnDebt = Math.mulDiv(drawnShares, index, RAY_, Math.Rounding.Ceil);
        uint256 premiumDebt = Math.ceilDiv(premiumRay, RAY_);
        if (amount >= drawnDebt + premiumDebt) return 0;
        if (amount < premiumDebt) return drawnShares * index + premiumRay - amount * RAY_;
        uint256 restored = Math.mulDiv(amount - premiumDebt, RAY_, index);
        return (drawnShares - restored) * index;
    }

    function _removals(
        Market memory m,
        address proxy
    ) internal view returns (RecordRemoval[] memory out) {
        ICollateralizationViews coll = ICollateralizationViews(_COLLATERALIZATION);
        // forge-lint: disable-start(unused-return)
        (, BackingRecord[] memory recs) =
            coll.getAccountRecords(proxy, m.vaultToken, 0, AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET);
        // forge-lint: disable-end(unused-return)
        out = new RecordRemoval[](recs.length);
        for (uint256 i = 0; i < recs.length; ++i) {
            out[i].positionKey = recs[i].positionKey;
            out[i].units = coll.previewRelease(m.integrationId, recs[i].positionKey);
        }
    }
}
// forge-lint: disable-end(calls-loop)
