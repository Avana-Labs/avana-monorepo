// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {Market} from "../../types/Market.sol";
import {IMarketRegistryCreditLines} from "./IMarketRegistryCreditLines.sol";
import {IMarketRegistryHubs} from "./IMarketRegistryHubs.sol";
import {IMarketRegistryLogic} from "./IMarketRegistryLogic.sol";
import {IMarketRegistryWindDown} from "./IMarketRegistryWindDown.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {DebtReserveDef} from "./types/DebtReserveDef.sol";
import {MarketRegistryImmutables} from "./types/MarketRegistryImmutables.sol";
import {MarketStatus} from "./types/MarketStatus.sol";
import {RiskTier} from "./types/RiskTier.sol";
import {WindDownState} from "./types/WindDownState.sol";

/// @title MarketRegistryWindDownLogic
/// @notice Bodies of the end of a market's life (`stepWindDown`, `closeMarket`), of `setSettlementReserve` and of the
/// credit-line registry (`recordCreditLine`, `syncDrawCap`).
/// @dev Reached only by delegatecall from the MarketRegistry, which checks the caller first (`APPLICATION_ADMIN` for
/// `setSettlementReserve` and `recordCreditLine`; anyone for the others); see `IMarketRegistryLogic`. Every external
/// call is a view. The wind-down schedule is fixed by constants (notice 5 days, ramp 30 days, final liquidation
/// threshold 5,000 bps, one step a day): a change is an upgrade at the normal delay.
/// @custom:spec REQ-CONFIG-080, REQ-CONFIG-081, REQ-MREG-033, SPEC-CAP-010, Q-338, Q-355, Q-358
// Each function carries the body of a selector declared in an IMarketRegistry piece that the MarketRegistry itself
// implements; this contract inherits no piece, since each piece also declares functions another contract serves.
// solhint-disable comprehensive-interface
// Every external call made here is a view (STATICCALL), so none can re-enter the registry or reorder its events.
// forge-lint: disable-start(reentrancy-events)
contract MarketRegistryWindDownLogic is MarketRegistryStorage, IMarketRegistryLogic {
    /// @dev Notice from `offboardedAt` before the first step, at least the normal delay (REQ-CONFIG-080).
    uint64 internal constant _OFFBOARD_NOTICE_SECONDS = 5 days;
    /// @dev Length of the linear ramp of the liquidation threshold.
    uint64 internal constant _WIND_DOWN_RAMP_SECONDS = 30 days;
    /// @dev Shortest interval between two steps.
    uint64 internal constant _WIND_DOWN_STEP_SECONDS = 1 days;
    /// @dev Liquidation threshold at the end of the ramp, bps.
    uint16 internal constant _WIND_DOWN_FINAL_LT_BPS = 5000;

    /// @notice Fixes the implementation immutables; they must equal the MarketRegistry's.
    /// @param im The per-chain Avana addresses.
    /// @custom:spec REQ-CONFIG-005
    constructor(
        MarketRegistryImmutables memory im
    ) MarketRegistryStorage(im) {}

    /// @inheritdoc IMarketRegistryLogic
    /// @custom:spec REQ-CONFIG-005
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("MarketRegistryWindDownLogic"), _IMMUTABLES_HASH);
    }

    /// @notice Body of `stepWindDown`: records and announces the next point of the linear ramp
    /// `LT(t) = LT0 − ⌊(LT0 − LTf) × min(t − t0, R) / R⌋`, `t0 = offboardedAt + notice`.
    /// @custom:spec REQ-CONFIG-080, Q-355
    function stepWindDown(
        uint256 marketId
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        if (l.markets[marketId].status != MarketStatus.Offboarding) {
            revert IMarketRegistryWindDown.MarketNotOffboarding(marketId);
        }
        WindDownState storage w = l.windDown[marketId];
        uint64 start = w.offboardedAt + _OFFBOARD_NOTICE_SECONDS;
        uint64 next = start;
        if (w.lastStepAt != 0 && w.lastStepAt + _WIND_DOWN_STEP_SECONDS > next) {
            next = w.lastStepAt + _WIND_DOWN_STEP_SECONDS;
        }
        // Block timestamps and chain identifiers fit 64 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs < next) revert IMarketRegistryWindDown.WindDownStepTooEarly(next);
        uint16 lt = _rampAt(w.startLtBps, nowTs - start);
        w.lastStepAt = nowTs;
        w.currentLtBps = lt;
        emit IMarketRegistryWindDown.WindDownStepped(marketId, lt);
    }

    /// @notice Body of `closeMarket`.
    /// @custom:spec REQ-CONFIG-080, REQ-COLL-040, Q-355
    function closeMarket(
        uint256 marketId
    ) external {
        _onlyDelegated();
        Market storage m = _s().markets[marketId];
        if (m.status != MarketStatus.Offboarding) revert IMarketRegistryWindDown.MarketNotOffboarding(marketId);
        // The notice runs in full before a close, so an offboarding announced at t stays listed until t + 5 days.
        uint256 notBefore = uint256(_s().windDown[marketId].offboardedAt) + _OFFBOARD_NOTICE_SECONDS;
        if (block.timestamp < notBefore) revert IMarketRegistryWindDown.WindDownStepTooEarly(notBefore);
        if (!ICollateralizationViews(_COLLATERALIZATION).getMarketDebtFree(m.vaultToken)) {
            revert IMarketRegistryWindDown.MarketHasDebt(marketId);
        }
        m.status = MarketStatus.Closed;
        emit IMarketRegistryWindDown.MarketClosed(marketId);
    }

    /// @notice Body of `setSettlementReserve`.
    /// @custom:spec REQ-MREG-033, Q-358
    function setSettlementReserve(
        uint256 marketId,
        uint256 debtReserveId
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        Market storage m = l.markets[marketId];
        if (m.status == MarketStatus.None) revert UnknownMarket(marketId);
        if (!l.debtReserves[m.spoke][debtReserveId].approved) revert UnknownDebtReserve(m.spoke, debtReserveId);
        l.settlementReserve[marketId] = debtReserveId;
        emit IMarketRegistryWindDown.SettlementReserveSet(marketId, debtReserveId);
    }

    /// @notice Body of `recordCreditLine`.
    /// @custom:spec REQ-CONFIG-081, SPEC-CAP-010
    function recordCreditLine(
        address fundingHub,
        address asset,
        uint256 line
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        if (l.hubTier[fundingHub] == RiskTier.None) revert IMarketRegistryHubs.InvalidHub(fundingHub);
        CreditLine storage cl = l.creditLines[fundingHub][asset];
        uint256 sum = cl.drawCapSum;
        if (sum > line) revert IMarketRegistryCreditLines.CreditLineExceeded(fundingHub, asset, sum, line);
        _requireCovered(fundingHub, asset, line);
        cl.line = line;
        emit IMarketRegistryCreditLines.CreditLineSet(fundingHub, asset, line, sum);
    }

    /// @notice Body of `syncDrawCap`: records the Spoke's live draw cap and the new sum whatever the coverage or the
    /// line, so the recorded sum never hides a raise; coverage is the separate gate `creditLineCoverage` serves.
    /// @custom:spec REQ-CONFIG-081, SPEC-CAP-010
    function syncDrawCap(
        address spoke,
        uint256 debtReserveId
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        DebtReserveDef storage d = l.debtReserves[spoke][debtReserveId];
        if (!d.approved) revert UnknownDebtReserve(spoke, debtReserveId);
        uint256 cap = _drawCapOf(d.fundingHub, d.hubAssetId, spoke);
        uint256 old = l.recordedDrawCap[spoke][debtReserveId];
        CreditLine storage cl = l.creditLines[d.fundingHub][d.asset];
        uint256 sum = cl.drawCapSum - old + cap;
        l.recordedDrawCap[spoke][debtReserveId] = cap;
        cl.drawCapSum = sum;
        emit IMarketRegistryCreditLines.CreditLineRecorded(d.fundingHub, d.asset, spoke, cap, sum);
    }

    /// @dev Ramp value `elapsed` seconds after the notice ended; never above the start, `LTf` from the end of the ramp.
    function _rampAt(
        uint16 startLt,
        uint64 elapsed
    ) private pure returns (uint16) {
        if (startLt <= _WIND_DOWN_FINAL_LT_BPS) return startLt;
        uint256 span = elapsed < _WIND_DOWN_RAMP_SECONDS ? elapsed : _WIND_DOWN_RAMP_SECONDS;
        uint256 drop = (uint256(startLt - _WIND_DOWN_FINAL_LT_BPS) * span) / _WIND_DOWN_RAMP_SECONDS;
        // `drop ≤ startLt − LTf`, so the result lies in [LTf, startLt].
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(startLt - drop);
    }
}
