// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashSource} from "../../flash/IFlashSource.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../oracle/ILPOracle.sol";
import {PauseState} from "../../types/MarketTypes.sol";
import {PriceState, PriceView} from "../../types/OracleTypes.sol";
import {LensBase} from "./LensBase.sol";
import {LensDeleverage} from "./LensDeleverage.sol";
import {DebtPriceView, DeleverageSizing} from "./types/LensTypes.sol";

/// @title LensPriceModule
/// @notice Lens module serving the price and pause views of `ILens`, and `previewDeleverageTo`.
contract LensPriceModule is LensDeleverage {
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

    function getPriceState(
        address vaultToken
    ) external view returns (PriceView memory v) {
        _unlocked();
        (, address lpOracle) = _lpOracleOf(vaultToken);
        ILPOracle.PriceStatus memory st = ILPOracle(lpOracle).getPriceStatus();
        (v.blockNumber, v.timestamp, v.vaultToken, v.feed) = (block.number, block.timestamp, vaultToken, lpOracle);
        v.state = st.liquidationFresh ? PriceState.Live : PriceState.Cached;
        v.liquidationState = v.state;
        // The oracle serves at least 1; a non-positive answer is reported as 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        v.price = st.answer > 0 ? uint256(st.answer) : 0;
        (v.acceptedPrice, v.acceptedAt) = (v.price, st.updatedAt);
        v.inputs = _inputs(lpOracle);
        v.borrowAllowed = st.borrowFresh;
    }

    function getDebtPriceState(
        address spoke,
        uint256 debtReserveId
    ) external view returns (DebtPriceView memory v) {
        _unlocked();
        v = _debtView(spoke, _debtReserve(spoke, debtReserveId));
        (v.blockNumber, v.timestamp) = (block.number, block.timestamp);
    }

    function getApplicationState(
        address hub
    ) external view returns (PauseState state) {
        _unlocked();
        state = _registry().pauseState(hub);
    }

    function getPauseReason(
        address hub
    ) external view returns (uint8 reason) {
        _unlocked();
        reason = uint8(_registry().pauseReason(hub));
    }

    function _lpOracleOf(
        address vaultToken
    ) internal view returns (uint256 marketId, address lpOracle) {
        marketId = _registry().marketOfVaultToken(vaultToken);
        lpOracle = _market(marketId).lpOracle;
    }

    /// @param core The nine core addresses, in `LensBase` order.
    constructor(
        address[9] memory core
    ) LensBase(core) {}
}
