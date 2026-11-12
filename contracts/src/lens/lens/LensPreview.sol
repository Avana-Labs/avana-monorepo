// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {RiskStatus} from "../../amm/types/RiskStatus.sol";
import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IFlashSource} from "../../flash/IFlashSource.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {SettlementMath} from "../../liquidation/lp-vault-swap/SettlementMath.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {BreakerReasons} from "../../policy/market-registry/types/Breaker.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
import {IRiskModuleViews} from "../../policy/risk-module/IRiskModuleViews.sol";
import {RiskModuleMath} from "../../policy/risk-module/RiskModuleMath.sol";
import {AccountGateStatus} from "../../types/AccountGateStatus.sol";
import {Market} from "../../types/Market.sol";
import {PauseReason} from "../../types/PauseReason.sol";
import {PauseState} from "../../types/PauseState.sol";
import {PriceStateView} from "../../types/PriceStateView.sol";
import {ILensHubReads} from "./ILensHubReads.sol";
import {ILensPreview} from "./ILensPreview.sol";
import {LensBase} from "./LensBase.sol";
import {LensConstants} from "./LensConstants.sol";
import {PriceInput} from "./types/PriceInput.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensPreview
/// @notice Borrower previews of the Lens, each built to stay valid until inclusion: the protocol maximum borrow and the
/// recommended borrow, the repay-all spend cap, a re-credit and a repay with collateral.
/// @dev Health factors in WAD, Aave values in USD × 1e26 and debt values in Aave value × RAY. Every rounding is against
/// the borrower's expectation: amounts down, the target health factor and the spend cap up.
/// @custom:spec REQ-LENS-035, REQ-LENS-036, REQ-LENS-038, REQ-LENS-041, REQ-LENS-044, SPEC-CF-005, SPEC-LIQ-020, Q-268, Q-269, Q-398
// View calls in loops over listings bounded by governance (Spokes, debt reserves, markets, pool tokens), one
// page of at most LENS_MAX_PAGE records or the caller's own arrays (REQ-LENS-020).
// forge-lint: disable-start(calls-loop)
abstract contract LensPreview is LensBase, ILensPreview {
    /// @dev WAD.
    uint256 internal constant WAD = 1e18;
    /// @dev RAY.
    uint256 internal constant RAY_UNIT = 1e27;
    /// @dev Aave's year for rates (`MathUtils.SECONDS_PER_YEAR`).
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    /// @dev A pool-share cap of 10,000 bps is no limit (SPEC-CAP-005).
    uint256 internal constant NO_POOL_SHARE_CAP = 10_000;

    /// @dev One account's borrow inputs.
    struct Borrow {
        Market m;
        DebtReserveDef def;
        address proxy;
        uint256 marketId;
        uint256 weighted;
        uint256 debtValue;
        uint256 unitValue;
        uint256 headroom;
    }

    /// @dev One repay-with-collateral request.
    struct Repay {
        Market m;
        DebtReserveDef def;
        address wallet;
        address proxy;
        uint256 marketId;
        bytes32 positionKey;
        uint256 units;
    }

    /// @inheritdoc ILensPreview
    /// @custom:spec REQ-LENS-035, REQ-LENS-041, REQ-LENS-006
    function previewBorrowMax(
        address wallet,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 deadline
    ) external view override returns (uint256 amount) {
        _unlocked();
        (, amount) = _borrowPreview(wallet, marketId, debtReserveId, deadline);
    }

    /// @inheritdoc ILensPreview
    /// @custom:spec REQ-LENS-044, REQ-LENS-035, REQ-LENS-006
    function previewBorrowRecommended(
        address wallet,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 deadline
    ) external view override returns (uint256 recommended, uint256 maximum) {
        _unlocked();
        (recommended, maximum) = _borrowPreview(wallet, marketId, debtReserveId, deadline);
    }

    /// @inheritdoc ILensPreview
    /// @custom:spec REQ-LENS-036, REQ-LENS-006
    function quoteRepayAll(
        address borrower,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 deadline
    ) external view override returns (uint256 maxRepaySpend) {
        _unlocked();
        Market memory m = _market(marketId);
        DebtReserveDef memory def = _debtReserve(m.spoke, debtReserveId);
        (address proxy, bool deployed) = _proxy(borrower, marketId, m.spoke);
        if (!deployed) return 0;
        uint256 total = IAaveV4Spoke(m.spoke).getUserTotalDebt(debtReserveId, proxy);
        if (total == 0) return 0;
        uint256 premium = IAaveV4Spoke(m.spoke).getUserAccountData(proxy).riskPremium;
        uint256 growth = _growth(_rate(def, premium), deadline);
        uint256 bps = SettlementMath.BPS;
        maxRepaySpend =
            Math.mulDiv(total, growth * (bps + LensConstants.REPAY_ALL_MARGIN_BPS), RAY_UNIT * bps, Math.Rounding.Ceil);
    }

    /// @inheritdoc ILensPreview
    /// @custom:spec REQ-LENS-038, SPEC-CAP-001, REQ-RISK-066, REQ-LENS-006
    function previewRecredit(
        uint256 marketId,
        bytes32 positionKey
    ) external view override returns (uint128 added, uint256 usdCharge, bool rescueOnly) {
        _unlocked();
        Market memory m = _market(marketId);
        ICollateralizationViews coll = ICollateralizationViews(_COLLATERALIZATION);
        added = coll.previewRecredit(m.integrationId, positionKey);
        if (added == 0) return (0, 0, false);
        // forge-lint: disable-next-line(unused-return)
        (uint256 accepted,) = ILPOracle(m.lpOracle).lastAcceptedPrice();
        uint256 floor = _store().stressFloorUsd(marketId);
        usdCharge = Math.mulDiv(added, accepted > floor ? accepted : floor, 10 ** m.decimals, Math.Rounding.Ceil);
        address depositor = coll.getRecord(coll.recordIdOf(m.integrationId, positionKey)).depositor;
        rescueOnly = _rescueOnly(marketId, m, depositor, added, usdCharge);
    }

    /// @inheritdoc ILensPreview
    /// @custom:spec REQ-LENS-038, SPEC-LIQ-020, REQ-LENS-006, REQ-LENS-007
    function previewRepayWithCollateral(
        address wallet,
        uint256 marketId,
        bytes32 positionKey,
        uint128 units,
        uint256 debtReserveId
    ) external view override returns (uint256 debtRepaid, uint256 debtAssetToWallet, uint256 healthFactorAfter) {
        _unlocked();
        Repay memory r;
        (r.wallet, r.marketId, r.positionKey, r.units) = (wallet, marketId, positionKey, units);
        r.m = _market(marketId);
        r.def = _debtReserve(r.m.spoke, debtReserveId);
        (r.proxy,) = _proxy(wallet, marketId, r.m.spoke);
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(r.m.spoke).getUserAccountData(r.proxy);
        healthFactorAfter = a.healthFactor;
        if (!_deleverageOpen(r)) return (0, 0, healthFactorAfter);
        uint256 value;
        (debtRepaid, value) = _deleverageSize(r);
        if (debtRepaid == 0) return (0, 0, healthFactorAfter);
        uint256 premium = IFlashSource(_registry().flashSource()).flashPremium(r.def.asset, debtRepaid);
        debtAssetToWallet = value > debtRepaid + premium ? value - debtRepaid - premium : 0;
        uint256 after_ = _healthAfter(r, a, debtRepaid);
        // While debt remains the AaveAdapter refuses a repayment that lowers the health factor.
        if (after_ < a.healthFactor) return (0, 0, healthFactorAfter);
        healthFactorAfter = after_;
    }

    // ------------------------------------------------------------------------------------------------------ internal

    /// @dev `(recommended, maximum)` of REQ-LENS-044 and REQ-LENS-035; both 0 when the borrow gate fails.
    function _borrowPreview(
        address wallet,
        uint256 marketId,
        uint256 debtReserveId,
        uint256 deadline
    ) internal view returns (uint256 recommended, uint256 maximum) {
        Borrow memory b;
        b.marketId = marketId;
        b.m = _market(marketId);
        b.def = _debtReserve(b.m.spoke, debtReserveId);
        bool deployed;
        (b.proxy, deployed) = _proxy(wallet, marketId, b.m.spoke);
        if (!deployed || !_borrowGate(b)) return (0, 0);
        IAaveV4Spoke.UserAccountData memory a = IAaveV4Spoke(b.m.spoke).getUserAccountData(b.proxy);
        uint256 e = _rescueExclusion(b);
        uint256 w = Math.mulDiv(a.avgCollateralFactor, a.totalCollateralValue, WAD);
        b.weighted = w > e ? w - e : 0;
        b.debtValue = Math.ceilDiv(a.totalDebtValueRay, RAY_UNIT);
        uint256 price = IAaveV4Oracle(IAaveV4Spoke(b.m.spoke).ORACLE()).getReservePrice(debtReserveId);
        b.unitValue = price * 10 ** (18 - b.def.decimals);
        if (b.unitValue == 0) return (0, 0);
        b.headroom = _drawHeadroom(b.m.spoke, b.def);
        uint256 ht = _targetHealthFactor(b, a.riskPremium, deadline);
        maximum = _capacity(b, ht);
        recommended = _capacity(b, LensConstants.RECOMMENDED_HEALTH_FACTOR);
        if (recommended > maximum) recommended = maximum;
    }

    /// @dev `Ht = H0 × (1 + rate × max(0, deadline − now)) × (10⁴ + BORROW_MAX_MARGIN_BPS) / 10⁴`, rounded up, with
    /// `H0 = max(1e18, hardHealthFloor(marketId))`.
    /// @custom:spec REQ-LENS-035, Q-398
    function _targetHealthFactor(
        Borrow memory b,
        uint256 riskPremium,
        uint256 deadline
    ) internal view returns (uint256 ht) {
        uint256 h0 = _store().hardHealthFloor(b.marketId);
        if (h0 < WAD) h0 = WAD;
        uint256 bps = SettlementMath.BPS;
        uint256 growth = _growth(_maxRate(b, riskPremium), deadline);
        ht = Math.mulDiv(h0, growth * (bps + LensConstants.BORROW_MAX_MARGIN_BPS), RAY_UNIT * bps, Math.Rounding.Ceil);
    }

    /// @dev `⌊max(0, weighted × WAD / target − debtValue) / unitValue⌋`, capped by the draw-cap headroom.
    /// @custom:spec REQ-LENS-035, REQ-LENS-044
    function _capacity(
        Borrow memory b,
        uint256 target
    ) internal pure returns (uint256 amount) {
        uint256 maxDebt = Math.mulDiv(b.weighted, WAD, target);
        if (maxDebt <= b.debtValue) return 0;
        amount = (maxDebt - b.debtValue) / b.unitValue;
        if (amount > b.headroom) amount = b.headroom;
    }

    /// @dev The account's borrow gate as the AaveAdapter applies it: the RiskModule's `borrowAllowed`, no pause, a
    /// computable status, no debt breaker on the reserve and its cross-Hub credit line (REQ-RISK-082).
    /// @custom:spec REQ-LENS-035, REQ-ADAPTER-038, REQ-RISK-082
    function _borrowGate(
        Borrow memory b
    ) internal view returns (bool open) {
        AccountGateStatus memory st = IRiskModuleViews(_RISK_MODULE).getAccountGateStatus(b.proxy);
        if (!st.borrowAllowed || st.pauseState != PauseState.None || st.statusUnavailable) return false;
        // forge-lint: disable-next-line(unused-return)
        (uint32 reasons,) = IRiskModuleViews(_RISK_MODULE).getDebtBreakerStatus(b.m.spoke, b.def.reserveId);
        if (reasons != 0) return false;
        address fundingHub = b.def.fundingHub;
        if (fundingHub == b.m.hub) return true;
        if (!_registry().crossHubLinesEnabled()) return false;
        (uint256 line, uint256 sum) = _registry().creditLine(fundingHub, b.def.asset);
        (uint256 required, uint256 funded) = _registry().creditLineCoverage(fundingHub, b.def.asset);
        open = sum <= line && required <= funded;
    }

    /// @dev SPEC-CF-005 rescue exclusion `E` of the account, Aave value units.
    /// @custom:spec SPEC-CF-005, Q-253
    function _rescueExclusion(
        Borrow memory b
    ) internal view returns (uint256 e) {
        uint256 u = ICollateralizationViews(_COLLATERALIZATION).getAccountRescueUnits(b.proxy, b.m.vaultToken);
        if (u == 0) return 0;
        uint32 key = IAaveV4Spoke(b.m.spoke).getUserPosition(b.m.reserveId, b.proxy).dynamicConfigKey;
        uint256 cf = IAaveV4Spoke(b.m.spoke).getDynamicReserveConfig(b.m.reserveId, key).collateralFactor;
        int256 served = ILPOracle(b.m.lpOracle).latestAnswer();
        // forge-lint: disable-next-line(unsafe-typecast)
        e = RiskModuleMath.rescueValue(u, served > 0 ? uint256(served) : 0, cf, b.m.decimals);
    }

    /// @dev The highest per-year rate (RAY) among the account's debt reserves with debt and the borrowed reserve.
    function _maxRate(
        Borrow memory b,
        uint256 riskPremium
    ) internal view returns (uint256 rate) {
        rate = _rate(b.def, riskPremium);
        uint256[] memory ids = _registry().getDebtReserveIds(b.m.spoke);
        for (uint256 i = 0; i < ids.length; ++i) {
            if (IAaveV4Spoke(b.m.spoke).getUserTotalDebt(ids[i], b.proxy) == 0) continue;
            uint256 r = _rate(_registry().getDebtReserve(b.m.spoke, ids[i]), riskPremium);
            if (r > rate) rate = r;
        }
    }

    /// @dev The account's borrow rate on a reserve: the drawn rate plus its risk-premium share, RAY per year.
    /// @custom:spec REQ-LENS-035, REQ-LENS-036
    function _rate(
        DebtReserveDef memory def,
        uint256 riskPremium
    ) internal view returns (uint256) {
        uint256 drawn = ILensHubReads(def.fundingHub).getAssetDrawnRate(def.hubAssetId);
        return Math.mulDiv(drawn, SettlementMath.BPS + riskPremium, SettlementMath.BPS, Math.Rounding.Ceil);
    }

    /// @dev `RAY × (1 + rate × max(0, deadline − now))`, the interest growth until `deadline`, rounded up.
    function _growth(
        uint256 rate,
        uint256 deadline
    ) internal view returns (uint256) {
        uint256 dt = deadline > block.timestamp ? deadline - block.timestamp : 0;
        return RAY_UNIT + Math.mulDiv(rate, dt, SECONDS_PER_YEAR, Math.Rounding.Ceil);
    }

    /// @dev Whether a regular top-up would be refused, so the re-credit books only as a rescue top-up: `Paused(General)`,
    /// a frozen depositor, a market breaker other than `ORACLE` and `CONFIG_DRIFT`, the pool-share gate, or a charge
    /// below `minPledgeUsd`.
    /// @custom:spec REQ-LENS-038, REQ-RISK-066, SPEC-CAP-005
    function _rescueOnly(
        uint256 marketId,
        Market memory m,
        address depositor,
        uint256 added,
        uint256 usdCharge
    ) internal view returns (bool) {
        if (_registry().pauseState(m.hub) == PauseState.Paused && _registry().pauseReason(m.hub) == PauseReason.General)
        {
            return true;
        }
        if (_registry().isFrozenAddress(depositor) || usdCharge < _store().minPledgeUsd(marketId)) return true;
        // forge-lint: disable-next-line(unused-return)
        (uint32 reasons,) = IRiskModuleViews(_RISK_MODULE).getBreakerStatus(marketId);
        if (reasons & ~(BreakerReasons.ORACLE | BreakerReasons.CONFIG_DRIFT) != 0) return true;
        bytes32 key = keccak256(abi.encode(m.integrationId, m.pool, m.poolId));
        uint256 cap = _store().poolShareMaxBpsOf(key);
        if (cap >= NO_POOL_SHARE_CAP) return false;
        RiskStatus memory rs =
            IAmmIntegration(m.integration).riskStatus(marketId, _store().getMarketParams(marketId).twapWindow);
        if (!rs.depthAvailable) return true;
        uint256 units = ICollateralizationViews(_COLLATERALIZATION).poolUnits(key) + added;
        return RiskModuleMath.poolShareExceeds(units, cap, rs.depthUnits);
    }

    /// @dev Whether `repayWithCollateral` would pass its checks: liquidation-grade prices on the market and the debt
    /// reserve, Hub shares equal to assets, no `Paused`, wallet not frozen, the record is the account's and `units` is
    /// within its credited units after reconciliation, and the account owes on the reserve.
    /// @custom:spec REQ-LENS-038, SPEC-LIQ-020
    function _deleverageOpen(
        Repay memory r
    ) internal view returns (bool) {
        Market memory m = r.m;
        if (r.units == 0 || IAaveV4Spoke(m.spoke).getUserTotalDebt(r.def.reserveId, r.proxy) == 0) return false;
        if (_registry().pauseState(m.hub) == PauseState.Paused || _registry().isFrozenAddress(r.wallet)) return false;
        IAaveV4Hub hub = IAaveV4Hub(m.hub);
        if (hub.getAddedAssets(m.hubAssetId) != hub.getAddedShares(m.hubAssetId)) return false;
        if (!_marketPriceUsable(m) || !_debtView(m.spoke, r.def).liquidationFresh) return false;
        ICollateralizationViews coll = ICollateralizationViews(_COLLATERALIZATION);
        uint256 id = coll.recordIdOf(m.integrationId, r.positionKey);
        if (id == 0 || coll.getRecord(id).proxy != r.proxy) return false;
        return r.units <= coll.previewRelease(m.integrationId, r.positionKey);
    }

    /// @dev The market's collateral price rule (REQ-SWAP-008): not liquidation-paused and every input within its
    /// `liquidationPriceMaxAge`.
    function _marketPriceUsable(
        Market memory m
    ) internal view returns (bool) {
        PriceStateView memory ps = ILPOracle(m.lpOracle).getPriceState();
        if (ps.liquidationPaused) return false;
        PriceInput[] memory inputs = _inputs(ps.tokens);
        for (uint256 i = 0; i < inputs.length; ++i) {
            if (!inputs[i].liquidationFresh) return false;
        }
        return true;
    }

    /// @dev SPEC-LIQ-020: `x = min(debt, cap)` and the oracle value `V` of `units` in the debt asset.
    /// @custom:spec SPEC-LIQ-020, SPEC-LIQ-004, SPEC-LIQ-005
    function _deleverageSize(
        Repay memory r
    ) internal view returns (uint256 x, uint256 value) {
        Market memory m = r.m;
        uint256 pc = _collateralPrice(m);
        uint256 pd = _debtPrice(m.spoke, r.def);
        if (pc == 0 || pd == 0) return (0, 0);
        value = SettlementMath.seizedValue(r.units, pc, m.decimals, r.def.decimals, pd);
        // forge-lint: disable-next-line(unused-return)
        (uint256[] memory prices,,) = ILPOracle(m.lpOracle).getTokenPrices();
        uint256 u = 0;
        for (uint256 i = 0; i < m.tokens.length; ++i) {
            if (m.tokens[i] == r.def.asset) ++u;
            else if (prices[i] != 0) u += _tokenValue(1, prices[i], m.tokenDecimals[i], r.def.decimals, pd, true);
        }
        uint256 cap = SettlementMath.deleverageCap(
            value,
            _store().getMarketParams(r.marketId).slippageAllowanceBps,
            u,
            _store().floorRoundingAllowance(r.def.asset),
            _store().maxFlashFeeBps()
        );
        uint256 total = IAaveV4Spoke(m.spoke).getUserTotalDebt(r.def.reserveId, r.proxy);
        x = total < cap ? total : cap;
    }

    /// @dev Aave's health factor with `units` removed from the market and `x` repaid, at the served prices and the
    /// account's own collateral factor, rounded down.
    /// @custom:spec REQ-LENS-038
    function _healthAfter(
        Repay memory r,
        IAaveV4Spoke.UserAccountData memory a,
        uint256 x
    ) internal view returns (uint256 hf) {
        Market memory m = r.m;
        IAaveV4Oracle oracle = IAaveV4Oracle(IAaveV4Spoke(m.spoke).ORACLE());
        uint32 key = IAaveV4Spoke(m.spoke).getUserPosition(m.reserveId, r.proxy).dynamicConfigKey;
        uint256 cf = IAaveV4Spoke(m.spoke).getDynamicReserveConfig(m.reserveId, key).collateralFactor;
        uint256 removed = r.units * oracle.getReservePrice(m.reserveId) * 10 ** (18 - m.decimals);
        uint256 w = Math.mulDiv(a.avgCollateralFactor, a.totalCollateralValue, WAD);
        uint256 wRemoved = Math.mulDiv(removed, cf, SettlementMath.BPS, Math.Rounding.Ceil);
        w = w > wRemoved ? w - wRemoved : 0;
        uint256 repaid = x * oracle.getReservePrice(r.def.reserveId) * 10 ** (18 - r.def.decimals) * RAY_UNIT;
        if (repaid >= a.totalDebtValueRay) return type(uint256).max;
        hf = Math.mulDiv(w * WAD, RAY_UNIT, a.totalDebtValueRay - repaid);
    }
}
// forge-lint: disable-end(calls-loop)
