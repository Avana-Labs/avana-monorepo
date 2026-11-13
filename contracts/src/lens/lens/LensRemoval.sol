// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {IRiskModuleViews} from "../../policy/risk-module/IRiskModuleViews.sol";
import {AccountGateStatus} from "../../types/AccountGateStatus.sol";
import {Market} from "../../types/Market.sol";
import {PauseState} from "../../types/PauseState.sol";
import {LensAccountMath} from "./LensAccountMath.sol";
import {RecordRemoval, RemovalSizing} from "./types/RemovalSizing.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensRemoval
/// @notice `ILensSizing.previewMaxWithdraw`: the largest collateral removal that keeps an account at or above a target
/// health factor, and which of its records it can withdraw alone.
/// @dev The bound is the exact maximum of the inequality the preview checks (REQ-LENS-054, MATH-AR-76), which counts the
/// removal rounded up and the rescue exclusion in full, so it never exceeds what Aave and the RiskModule accept.
/// Bounded by the 16 records of an account-market.
/// @custom:spec REQ-LENS-054
// View calls in a loop over the at most 16 records of one account-market (REQ-LENS-020).
// forge-lint: disable-start(calls-loop)
abstract contract LensRemoval is LensAccountMath {
    /// @notice `ILensSizing.previewMaxWithdraw`.
    /// @custom:spec REQ-LENS-054, REQ-LENS-005, REQ-LENS-006, SPEC-CF-005
    function previewMaxWithdraw(
        address wallet,
        uint256 marketId,
        uint256 targetHealthFactor
    ) external view returns (RemovalSizing memory v) {
        _unlocked();
        Market memory m = _market(marketId);
        bool deployed;
        (v.proxy, deployed) = _proxy(wallet, marketId, m.spoke);
        (v.blockNumber, v.timestamp, v.target, v.bestIndex) =
        (block.number, block.timestamp, targetHealthFactor, type(uint256).max);
        if (!deployed) return v;
        v.records = _removals(m, v.proxy);
        uint256 debtRay = IAaveV4Spoke(m.spoke).getUserAccountData(v.proxy).totalDebtValueRay;
        if (debtRay == 0) {
            for (uint256 i = 0; i < v.records.length; ++i) {
                v.maxUnits += v.records[i].units;
            }
        } else {
            uint256 h0 = _store().hardHealthFloor(marketId);
            if (h0 < WAD_) h0 = WAD_;
            if (v.target < h0) v.target = h0;
            if (_withdrawWithDebtOpen(wallet, v.proxy)) v.maxUnits = _maxRemoval(m, v.proxy, v.target, debtRay);
        }
        uint256 best = 0;
        for (uint256 i = 0; i < v.records.length; ++i) {
            RecordRemoval memory r = v.records[i];
            r.fits = r.units > 0 && r.units <= v.maxUnits;
            if (r.fits && r.units > best) (best, v.bestIndex) = (r.units, i);
        }
    }

    // ------------------------------------------------------------------------------------------------------ internal

    /// @dev The withdraw-with-debt gates of the AaveAdapter: the RiskModule's `withdrawWithDebtAllowed`, the Hub not
    /// `Paused` and the wallet not frozen.
    function _withdrawWithDebtOpen(
        address wallet,
        address proxy
    ) internal view returns (bool) {
        AccountGateStatus memory st = IRiskModuleViews(_RISK_MODULE).getAccountGateStatus(proxy);
        return st.withdrawWithDebtAllowed && st.pauseState != PauseState.Paused && !_registry().isFrozenAddress(wallet);
    }

    /// @dev REQ-LENS-054: with `W = ⌊CF × assets × v / 10⁴⌋`, `need = ⌈target × debtRay / (WAD × RAY)⌉` and the rescue
    /// exclusion `E`, the largest `u ≤ assets` with `W − E − ⌈u × v × CF / 10⁴⌉ ≥ need` is
    /// `⌊(W − E − need) × 10⁴ / (v × CF)⌋`; 0 when `W − E < need` or nothing is counted. `v` is the served value per
    /// unit and `CF` the reserve's latest collateral factor, which the withdrawal moves the account to.
    /// @custom:spec REQ-LENS-054, SPEC-CF-005
    function _maxRemoval(
        Market memory m,
        address proxy,
        uint256 target,
        uint256 debtRay
    ) internal view returns (uint256 units) {
        uint256 cf = _latestCf(m);
        uint256 per = _servedPrice(m) * 10 ** (18 - m.decimals) * cf;
        // forge-lint: disable-next-line(unused-return)
        (bool enabled,) = IAaveV4Spoke(m.spoke).getUserReserveStatus(m.reserveId, proxy);
        uint256 assets = enabled ? _assetsOf(m, proxy) : 0;
        if (per == 0 || assets == 0) return 0;
        uint256 need = Math.mulDiv(target, debtRay, WAD_ * RAY_, Math.Rounding.Ceil);
        units = _removalBound(assets, per, _rescueAt(m, proxy, cf), need);
    }

    /// @dev REQ-LENS-054, MATH-AR-76: `min(assets, ⌊(W − E − need) × 10⁴ / per⌋)` with `W = ⌊assets × per / 10⁴⌋`, 0 when
    /// `W < E + need` or `per = 0`. The quotient never exceeds `assets` (`W × 10⁴ ≤ assets × per`, MATH-AR-76e), so the
    /// minimum needs no separate cap.
    /// @custom:spec REQ-LENS-054
    function _removalBound(
        uint256 assets,
        uint256 per,
        uint256 e,
        uint256 need
    ) internal pure returns (uint256 units) {
        if (per == 0) return 0;
        uint256 w = assets * per / 1e4;
        if (w < e || w - e < need) return 0;
        units = (w - e - need) * 1e4 / per;
    }
}
// forge-lint: disable-end(calls-loop)
