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

/// @title MarketRegistryWindDownLogic
/// @notice Bodies of the end of a market's life (`closeMarket`), of `setSettlementReserve` and of the credit-line
/// registry (`recordCreditLine`, `syncDrawCap`).
/// @dev Reached only by delegatecall from the MarketRegistry, which checks the caller first (`APPLICATION_ADMIN` for
/// `setSettlementReserve` and `recordCreditLine`; anyone for the others); see `IMarketRegistryLogic`. Every external
/// call is a view. The offboarding notice is a constant (5 days, `MarketRegistryStorage.OFFBOARD_NOTICE_SECONDS`); the
/// Aave DAO lowers the market's liquidation threshold once after it, so the registry applies no Aave configuration.
/// @custom:spec REQ-CONFIG-080, REQ-CONFIG-081, REQ-MREG-033, SPEC-CAP-010, Q-338, Q-355, Q-358
// Each function carries the body of a selector declared in an IMarketRegistry piece that the MarketRegistry itself
// implements; this contract inherits no piece, since each piece also declares functions another contract serves.
// solhint-disable comprehensive-interface
// Every external call made here is a view (STATICCALL), so none can re-enter the registry or reorder its events.
// forge-lint: disable-start(reentrancy-events)
contract MarketRegistryWindDownLogic is MarketRegistryStorage, IMarketRegistryLogic {
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

    /// @notice Body of `closeMarket`.
    /// @custom:spec REQ-CONFIG-080, REQ-COLL-040, Q-355
    function closeMarket(
        uint256 marketId
    ) external {
        _onlyDelegated();
        Market storage m = _s().markets[marketId];
        if (m.status != MarketStatus.Offboarding) revert IMarketRegistryWindDown.MarketNotOffboarding(marketId);
        // The notice runs in full before a close, so an offboarding announced at t stays listed until t + 5 days.
        uint256 notBefore = uint256(_s().windDown[marketId].offboardedAt) + OFFBOARD_NOTICE_SECONDS;
        if (block.timestamp < notBefore) revert IMarketRegistryWindDown.OffboardNoticeRunning(notBefore);
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
}
