// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketSpeedLimits} from "../parameter-store/types/MarketSpeedLimits.sol";
import {SpeedLimit} from "../parameter-store/types/SpeedLimit.sol";
import {RiskModuleBase} from "./RiskModuleBase.sol";
import {SpeedLimitMath} from "./SpeedLimitMath.sol";
import {BorrowSpeedInputs} from "./types/BorrowSpeedInputs.sol";
import {SpeedView} from "./types/SpeedView.sol";
import {SpeedWindow} from "./types/SpeedWindow.sol";

/// @title RiskModuleSpeed
/// @notice The speed windows of the RiskModule (Q-411): the market borrow window in 8-decimal USD, the (funding Hub,
/// debt asset) borrow window in asset base units and the market pledge window in 8-decimal USD, each two τ-long buckets
/// in one slot (SPEC-CAP-011), tested against the clamped limit of SPEC-CAP-012.
/// @dev The windows sit in the ERC-7201 namespace `avana.storage.RiskModule.speed`, apart from OpenZeppelin's role and
/// initializer namespaces. A check writes only when `write` is set, which the RiskModule sets only for the AaveAdapter's
/// `preBorrowCheck` and Collateralization's `checkPledge` (REQ-RISK-095); there is no setter and no reset.
/// @custom:spec REQ-RISK-092, REQ-RISK-093, REQ-RISK-095, REQ-RISK-096, REQ-RISK-097, SPEC-CAP-011, SPEC-CAP-012, Q-411
abstract contract RiskModuleSpeed is RiskModuleBase {
    /// @custom:storage-location erc7201:avana.storage.RiskModule.speed
    struct SpeedLayout {
        mapping(uint256 marketId => SpeedWindow) marketBorrow;
        mapping(bytes32 hubAssetKey => SpeedWindow) debtBorrow;
        mapping(uint256 marketId => SpeedWindow) marketPledge;
    }

    /// @dev `keccak256(abi.encode(uint256(keccak256("avana.storage.RiskModule.speed")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _SPEED_SLOT = 0x1858dc028745fe2a4f37a8a31dd3ca321a1f7863f165bffa26e588c97f1ff200;

    /// @dev The namespace.
    function _speed() internal pure returns (SpeedLayout storage $) {
        // ERC-7201 namespaced storage: the slot is a compile-time constant.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _SPEED_SLOT
        }
    }

    /// @dev REQ-RISK-092: the market window first, then the (funding Hub, asset) window; both charged only when both fit
    /// and `write` is set.
    function _chargeBorrow(
        BorrowSpeedInputs memory s,
        uint256 amount,
        bool write
    ) internal {
        SpeedLayout storage $ = _speed();
        MarketSpeedLimits memory p = s.market;
        (SpeedWindow memory wm, uint256 lm) =
            _rolled($.marketBorrow[s.marketId], p.window, p.borrowRateBps, p.borrowMinUsd, p.borrowMaxUsd, s.marketBase);
        if (!SpeedLimitMath.fits(wm, lm, s.amountUsd)) {
            SpeedView memory v = SpeedLimitMath.viewOf(wm, p.window, lm);
            revert BorrowSpeedExceeded(s.marketId, v.available, v.moreAt);
        }
        SpeedLimit memory q = s.debt;
        (SpeedWindow memory wd, uint256 ld) =
            _rolled($.debtBorrow[s.debtKey], q.window, q.rateBps, q.min, q.max, s.debtBase);
        if (!SpeedLimitMath.fits(wd, ld, amount)) {
            SpeedView memory v = SpeedLimitMath.viewOf(wd, q.window, ld);
            revert DebtSpeedExceeded(s.hub, s.asset, v.available, v.moreAt);
        }
        if (write) {
            $.marketBorrow[s.marketId] = SpeedLimitMath.add(wm, s.amountUsd);
            $.debtBorrow[s.debtKey] = SpeedLimitMath.add(wd, amount);
        }
    }

    /// @dev REQ-RISK-093: the market's pledge window, base `bookedUsd = regularUsed + sliceUsed` before the pledge.
    function _chargePledge(
        uint256 marketId,
        uint256 bookedUsd,
        uint256 usdCharge,
        bool write
    ) internal {
        MarketSpeedLimits memory p = _store().marketSpeedLimits(marketId);
        SpeedLayout storage $ = _speed();
        (SpeedWindow memory w, uint256 lim) =
            _rolled($.marketPledge[marketId], p.window, p.pledgeRateBps, p.pledgeMinUsd, p.pledgeMaxUsd, bookedUsd);
        if (!SpeedLimitMath.fits(w, lim, usdCharge)) {
            SpeedView memory v = SpeedLimitMath.viewOf(w, p.window, lim);
            revert PledgeSpeedExceeded(marketId, v.available, v.moreAt);
        }
        if (write) $.marketPledge[marketId] = SpeedLimitMath.add(w, usdCharge);
    }

    /// @dev Views of both borrow windows of `s` (REQ-RISK-097).
    function _borrowViews(
        BorrowSpeedInputs memory s
    ) internal view returns (SpeedView memory market, SpeedView memory debt) {
        SpeedLayout storage $ = _speed();
        MarketSpeedLimits memory p = s.market;
        (SpeedWindow memory wm, uint256 lm) =
            _rolled($.marketBorrow[s.marketId], p.window, p.borrowRateBps, p.borrowMinUsd, p.borrowMaxUsd, s.marketBase);
        market = SpeedLimitMath.viewOf(wm, p.window, lm);
        SpeedLimit memory q = s.debt;
        (SpeedWindow memory wd, uint256 ld) =
            _rolled($.debtBorrow[s.debtKey], q.window, q.rateBps, q.min, q.max, s.debtBase);
        debt = SpeedLimitMath.viewOf(wd, q.window, ld);
    }

    /// @dev View of the pledge window of a market (REQ-RISK-097).
    function _pledgeView(
        uint256 marketId,
        MarketSpeedLimits memory p,
        uint256 bookedUsd
    ) internal view returns (SpeedView memory v) {
        (SpeedWindow memory w, uint256 lim) = _rolled(
            _speed().marketPledge[marketId], p.window, p.pledgeRateBps, p.pledgeMinUsd, p.pledgeMaxUsd, bookedUsd
        );
        v = SpeedLimitMath.viewOf(w, p.window, lim);
    }

    /// @dev The stored window rolled to now and its limit; a never-written scope (`window == 0`) has limit 0
    /// (REQ-RISK-096).
    function _rolled(
        SpeedWindow storage stored,
        uint256 window,
        uint256 rateBps,
        uint256 min,
        uint256 max,
        uint256 base
    ) private view returns (SpeedWindow memory r, uint256 lim) {
        r = SpeedLimitMath.roll(stored, window, block.timestamp);
        if (window != 0) lim = SpeedLimitMath.limit(rateBps, min, max, base, SpeedLimitMath.used(r));
    }
}
