// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../amm/IAmmIntegration.sol";
import {RiskStatus} from "../../amm/types/RiskStatus.sol";
import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {IFlashSource} from "../../flash/IFlashSource.sol";
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
import {ILensPreview} from "./ILensPreview.sol";
import {LensConstants} from "./LensConstants.sol";
import {LensDeleverage} from "./LensDeleverage.sol";
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
abstract contract LensPreview is LensDeleverage, ILensPreview {
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
        // A re-credit is booked like a pledge, at min(fresh, accepted) (REQ-RISK-026).
        int256 fresh = ILPOracle(m.lpOracle).getPriceState().freshAnswer;
        // A positive int256 is cast.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (fresh > 0 && uint256(fresh) < accepted) accepted = uint256(fresh);
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
        Delev memory d = _deleverageInputs(r);
        uint256 value;
        (debtRepaid, value) = _sizeAt(d, units);
        if (debtRepaid == 0) return (0, 0, healthFactorAfter);
        uint256 premium = IFlashSource(_registry().flashSource()).flashPremium(r.def.asset, debtRepaid);
        debtAssetToWallet = value > debtRepaid + premium ? value - debtRepaid - premium : 0;
        uint256 after_ = _healthAt(d, units, debtRepaid);
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
        uint256 w = Math.mulDiv(a.avgCollateralFactor, a.totalCollateralValue, WAD_);
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
        if (h0 < WAD_) h0 = WAD_;
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
        uint256 maxDebt = Math.mulDiv(b.weighted, WAD_, target);
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
}
// forge-lint: disable-end(calls-loop)
