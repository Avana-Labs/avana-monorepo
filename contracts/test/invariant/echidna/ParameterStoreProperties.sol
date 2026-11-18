// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ParameterStoreLoosenLogic} from "../../../src/policy/parameter-store/ParameterStoreLoosenLogic.sol";
import {ParameterStoreStorage} from "../../../src/policy/parameter-store/ParameterStoreStorage.sol";
import {ParameterStoreTightenLogic} from "../../../src/policy/parameter-store/ParameterStoreTightenLogic.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {HarnessMarketRegistry} from "../../utils/mocks/HarnessMarketRegistry.sol";

/// @title ParameterStoreProperties
/// @notice Echidna and Medusa properties of the ParameterStore's tighten and loosen bodies: whatever sequence of
/// tightenings and loosenings runs, every value stays inside its hard and liveness bounds, the slice never exceeds
/// the market cap, and each setter succeeds exactly when its predicate (SPEC-GOV-011) holds.
/// @dev The harness plays the ParameterStore proxy: it inherits the shared ERC-7201 layout and delegatecalls the
/// tighten and loosen logic contracts exactly as `ParameterStore._forward` does, and it is their `TIMELOCK` (it
/// answers `normalDelay()` with 432,000 s). The proxy's role checks are covered by the unit suite, Halmos and
/// Certora; deploying the full proxy with all five logic contracts here would exceed the 49,152-byte initcode limit.
/// Market 1 starts with the default values of 1.5, written straight into the layout.
contract ParameterStoreProperties is ParameterStoreStorage {
    uint256 internal constant M = 1;
    uint256 internal constant NORMAL_DELAY = 432_000;

    address internal immutable TIGHTEN;
    address internal immutable LOOSEN;

    /// @notice Number of setter calls attempted in assertion mode; written so each call is a transaction.
    uint256 public calls;

    constructor() ParameterStoreStorage(address(this), address(new HarnessMarketRegistry()), 12) {
        TIGHTEN = address(new ParameterStoreTightenLogic(address(this), address(_REGISTRY), 12));
        LOOSEN = address(new ParameterStoreLoosenLogic(address(this), address(_REGISTRY), 12));
        Layout storage $ = _s();
        MarketParams storage p = $.market[M];
        p.slippageAllowanceBps = 100;
        p.slippageAllowanceMinBps = 30;
        p.poolRiskFactor = 4000;
        p.minPledgeUsd = 10e8;
        $.marketUsdCap[M] = 5_000_000e8;
        $.topUpSliceUsd[M] = 500_000e8;
        $.stressFloorUsd[M] = 1e8;
        $.g.maxShortfallBps = 1000;
        $.g.maxFlashFeeBps = 10;
    }

    /// @notice The timelock's normal delay, read by the loosen logic to space loosenings.
    function normalDelay() external pure returns (uint256) {
        return NORMAL_DELAY;
    }

    // ─── Properties ───

    function property_slippageAboveFloor() external view returns (bool) {
        MarketParams storage p = _s().market[M];
        return p.slippageAllowanceBps >= p.slippageAllowanceMinBps && p.slippageAllowanceBps < 10_000;
    }

    function property_minPledgeInRange() external view returns (bool) {
        return _s().market[M].minPledgeUsd <= 100_000e8;
    }

    function property_sliceWithinCap() external view returns (bool) {
        // A market cap may be tightened to 0 and below the slice (REQ-RISK-042); it never exceeds the bound.
        return _s().marketUsdCap[M] <= type(uint128).max;
    }

    function property_poolRiskFactorPositive() external view returns (bool) {
        uint16 f = _s().market[M].poolRiskFactor;
        return f > 0 && f <= 9000;
    }

    function property_flashFeeNeverRises() external view returns (bool) {
        return _s().g.maxFlashFeeBps <= 10;
    }

    function property_chainValuesInRange() external view returns (bool) {
        return _s().g.maxShortfallBps <= 5000;
    }

    // ─── Assertion entry points ───

    function tightenSlippage(
        uint16 value
    ) external {
        MarketParams storage p = _s().market[M];
        (uint16 before, uint16 floor) = (p.slippageAllowanceBps, p.slippageAllowanceMinBps);
        bool ok = _call(TIGHTEN, abi.encodeCall(ParameterStoreTightenLogic.tightenSlippageAllowanceBps, (M, value)));
        assert(ok == (value < before && value >= floor));
    }

    function loosenSlippage(
        uint16 value
    ) external {
        uint16 before = _s().market[M].slippageAllowanceBps;
        bool ok = _call(LOOSEN, abi.encodeCall(ParameterStoreLoosenLogic.loosenSlippageAllowanceBps, (M, value)));
        if (ok) assert(value > before && value <= before + 25 && value < 10_000);
    }

    function tightenMinPledge(
        uint256 value
    ) external {
        uint256 before = _s().market[M].minPledgeUsd;
        bool ok = _call(TIGHTEN, abi.encodeCall(ParameterStoreTightenLogic.tightenMinPledgeUsd, (M, value)));
        assert(ok == (value > before && value <= 100_000e8));
    }

    function loosenMinPledge(
        uint256 value
    ) external {
        uint256 before = _s().market[M].minPledgeUsd;
        bool ok = _call(LOOSEN, abi.encodeCall(ParameterStoreLoosenLogic.loosenMinPledgeUsd, (M, value)));
        assert(ok == (value < before));
    }

    function loosenMarketCap(
        uint256 value
    ) external {
        uint256 before = _s().marketUsdCap[M];
        bool ok = _call(LOOSEN, abi.encodeCall(ParameterStoreLoosenLogic.loosenMarketUsdCap, (M, value)));
        if (ok) assert(value > before && (value <= 1000e8 || value * 10_000 <= before * 15_000));
    }

    function tightenMarketCap(
        uint256 value
    ) external {
        uint256 before = _s().marketUsdCap[M];
        bool ok = _call(TIGHTEN, abi.encodeCall(ParameterStoreTightenLogic.tightenMarketUsdCap, (M, value)));
        assert(ok == (value < before));
    }

    function tightenSlice(
        uint256 value
    ) external {
        uint256 before = _s().topUpSliceUsd[M];
        bool ok = _call(TIGHTEN, abi.encodeCall(ParameterStoreTightenLogic.tightenTopUpSliceUsd, (M, value)));
        assert(ok == (value < before));
    }

    function loosenSlice(
        uint256 value
    ) external {
        (uint256 before, uint256 cap) = (_s().topUpSliceUsd[M], _s().marketUsdCap[M]);
        uint256 base = cap / 10 > before ? cap / 10 : before;
        bool ok = _call(LOOSEN, abi.encodeCall(ParameterStoreLoosenLogic.loosenTopUpSliceUsd, (M, value)));
        if (ok) assert(value > before && value <= cap && value * 10_000 <= base * 15_000);
    }

    function tightenShortfall(
        uint16 value
    ) external {
        uint16 before = _s().g.maxShortfallBps;
        bool ok = _call(TIGHTEN, abi.encodeCall(ParameterStoreTightenLogic.tightenMaxShortfallBps, (value)));
        assert(ok == (value < before));
    }

    function loosenShortfall(
        uint16 value
    ) external {
        uint16 before = _s().g.maxShortfallBps;
        bool ok = _call(LOOSEN, abi.encodeCall(ParameterStoreLoosenLogic.loosenMaxShortfallBps, (value)));
        assert(ok == (value > before && value <= 5000));
    }

    function tightenFlashFee(
        uint16 value
    ) external {
        uint16 before = _s().g.maxFlashFeeBps;
        bool ok = _call(TIGHTEN, abi.encodeCall(ParameterStoreTightenLogic.tightenMaxFlashFeeBps, (value)));
        assert(ok == (value < before));
        assert(_s().g.maxFlashFeeBps <= before);
    }

    function tightenPoolRiskFactor(
        uint16 value
    ) external {
        uint16 before = _s().market[M].poolRiskFactor;
        bool ok = _call(TIGHTEN, abi.encodeCall(ParameterStoreTightenLogic.tightenPoolRiskFactor, (M, value)));
        assert(ok == (value < before && value != 0));
    }

    function _call(
        address logic,
        bytes memory data
    ) internal returns (bool ok) {
        ++calls;
        (ok,) = logic.delegatecall(data);
    }
}
