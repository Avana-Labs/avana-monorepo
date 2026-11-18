// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashSource} from "../../flash/IFlashSource.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {LensDeleverage} from "./LensDeleverage.sol";
import {DeleverageSizing} from "./types/DeleverageSizing.sol";

/// @title LensSizing
/// @notice `ILensSizing.previewDeleverageTo`: the smallest repay with collateral that reaches a target health factor.
/// @dev Bisects over the record's units on inputs read once; at most 2 × 128 steps.
abstract contract LensSizing is LensDeleverage {
    function previewDeleverageTo(
        address wallet,
        uint256 marketId,
        bytes32 positionKey,
        uint256 debtReserveId,
        uint256 targetHealthFactor
    ) external view returns (DeleverageSizing memory v) {
        _unlocked();
        Repay memory r;
        (r.wallet, r.marketId, r.positionKey) = (wallet, marketId, positionKey);
        r.m = _market(marketId);
        r.def = _debtReserve(r.m.spoke, debtReserveId);
        (r.proxy,) = _proxy(wallet, marketId, r.m.spoke);
        (v.blockNumber, v.timestamp, v.proxy) = (block.number, block.timestamp, r.proxy);
        uint256 limit = _deleverageLimit(r);
        if (limit == 0) return v;
        uint256 hf0 = IAaveV4Spoke(r.m.spoke).getUserAccountData(r.proxy).healthFactor;
        uint256 target = targetHealthFactor < WAD_ ? WAD_ : targetHealthFactor;
        if (hf0 >= target) {
            (v.reachable, v.healthFactorAfter) = (true, hf0);
            return v;
        }
        Delev memory d = _deleverageInputs(r);
        uint256 hi = _fullRepayUnits(d, limit);
        if (!_reaches(d, hi, target)) return v;
        uint256 lo = 0;
        // Invariant: `hi` reaches the target and `lo` does not (0 units repay nothing).
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            if (_reaches(d, mid, target)) hi = mid;
            else lo = mid;
        }
        uint256 value;
        (v.reachable, v.units) = (true, hi);
        (v.debtRepaid, value) = _sizeAt(d, hi);
        v.healthFactorAfter = _healthAt(d, hi, v.debtRepaid);
        uint256 premium = IFlashSource(_registry().flashSource()).flashPremium(r.def.asset, v.debtRepaid);
        v.debtAssetToWallet = value > v.debtRepaid + premium ? value - v.debtRepaid - premium : 0;
    }

    /// @dev Fewest units in `[1, limit]` that repay the whole debt on the reserve, else `limit`; bounds the search.
    function _fullRepayUnits(
        Delev memory d,
        uint256 limit
    ) internal pure returns (uint256 hi) {
        // forge-lint: disable-next-line(unused-return)
        (uint256 x,) = _sizeAt(d, limit);
        if (x < d.total) return limit;
        uint256 lo = 0;
        hi = limit;
        while (hi - lo > 1) {
            uint256 mid = lo + (hi - lo) / 2;
            // forge-lint: disable-next-line(unused-return)
            (x,) = _sizeAt(d, mid);
            if (x >= d.total) hi = mid;
            else lo = mid;
        }
    }

    function _reaches(
        Delev memory d,
        uint256 units,
        uint256 target
    ) internal pure returns (bool) {
        if (units == 0) return false;
        // forge-lint: disable-next-line(unused-return)
        (uint256 x,) = _sizeAt(d, units);
        return x > 0 && _healthAt(d, units, x) >= target;
    }
}
