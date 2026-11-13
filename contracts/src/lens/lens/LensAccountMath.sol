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
/// @notice The account arithmetic the position, action and sizing views share: Aave's health factor of an account with
/// one collateral market, its liquidation price, collateral factors, the rescue exclusion, Aave's repay arithmetic and
/// the account's records.
/// @dev Health factors in WAD, Aave values in USD × 1e26 (`amount × price × 10^(18 − decimals)`, Aave's `toValue`),
/// debt values in Aave value × RAY. Aave's health factor of an account whose one collateral reserve has factor `CF`
/// (bps) and value `C` is `⌊CF × C × 1e14 × RAY / debtRay⌋` (`Spoke._processUserAccountData`).
/// @custom:spec REQ-LENS-047, REQ-LENS-049, REQ-LENS-052, REQ-LENS-053, REQ-LENS-054, REQ-LENS-056
// View calls in a loop over the at most 16 records of one account-market (REQ-LENS-020).
// forge-lint: disable-start(calls-loop)
abstract contract LensAccountMath is LensBase {
    /// @dev RAY.
    uint256 internal constant RAY_ = 1e27;
    /// @dev WAD.
    uint256 internal constant WAD_ = 1e18;

    /// @dev `CF × assets × 10^(18 − d)`: the account's collateral value per unit of 8-decimal price, times its CF (bps).
    /// @custom:spec REQ-LENS-047
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

    /// @dev The collateral factor of the reserve's latest dynamic configuration, bps: the one Aave moves an account to
    /// when a borrow, a withdrawal or `setUsingAsCollateral` refreshes it.
    function _latestCf(
        Market memory m
    ) internal view returns (uint256) {
        uint32 key = IAaveV4Spoke(m.spoke).getReserve(m.reserveId).dynamicConfigKey;
        return IAaveV4Spoke(m.spoke).getDynamicReserveConfig(m.reserveId, key).collateralFactor;
    }

    /// @dev The AaveOracle's served price of the vault-token reserve, 8 decimals.
    function _servedPrice(
        Market memory m
    ) internal view returns (uint256) {
        return IAaveV4Oracle(IAaveV4Spoke(m.spoke).ORACLE()).getReservePrice(m.reserveId);
    }

    /// @dev SPEC-CF-005 rescue exclusion of the account at the served LPOracle price, with collateral factor `cf`.
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

    /// @dev Aave's health factor of one collateral of value `collateralValue` and factor `cf` against `debtRay`:
    /// `⌊cf × collateralValue × 1e14 × RAY / debtRay⌋`.
    /// @custom:spec REQ-LENS-052, REQ-LENS-053
    function _hfOf(
        uint256 cf,
        uint256 collateralValue,
        uint256 debtRay
    ) internal pure returns (uint256) {
        if (debtRay == 0) return type(uint256).max;
        return Math.mulDiv(cf * collateralValue * 1e14, RAY_, debtRay);
    }

    /// @dev The vault-token price at which the health factor reaches 1.00 with every debt price fixed (REQ-LENS-047):
    /// `⌈debtRay × 10⁴ / (cf × assets × 10^(18 − d) × RAY)⌉`; 0 without debt, `type(uint256).max` with debt and no
    /// counted collateral.
    /// @custom:spec REQ-LENS-047, REQ-LENS-052
    function _liquidationPrice(
        uint256 debtRay,
        uint256 cfAssets
    ) internal pure returns (uint256) {
        if (debtRay == 0) return 0;
        if (cfAssets == 0) return type(uint256).max;
        return Math.mulDiv(debtRay, 1e4, cfAssets * RAY_, Math.Rounding.Ceil);
    }

    /// @dev The reserve's debt (asset units × RAY) left after repaying `amount`, as
    /// `UserPositionUtils.calculateRestoreAmount` and `Spoke.repay` compute it: the whole debt (drawn rounded up plus
    /// premium rounded up) clears it; below the premium the premium falls by `amount`; otherwise the premium clears and
    /// `⌊(amount − premium) × RAY / index⌋` drawn shares are restored.
    /// @custom:spec REQ-LENS-052
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

    /// @dev The account's records in seizure-list order with their credited units after reconciliation.
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
