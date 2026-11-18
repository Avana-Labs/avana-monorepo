// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../custody/collateralization/ICollateralizationViews.sol";
import {Market} from "../../types/Market.sol";
import {IMarketRegistry} from "./IMarketRegistry.sol";
import {IMarketRegistryLogic} from "./IMarketRegistryLogic.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {DebtReserveDef, MarketRegistryImmutables, MarketStatus, RiskTier} from "./types/MarketRegistryTypes.sol";

/// @title MarketRegistryWindDownLogic
/// @notice Bodies of `closeMarket`, `setSettlementReserve`, `recordCreditLine` and `syncDrawCap`.
/// @dev Runs only by delegatecall from the MarketRegistry, which checks the caller first.
// Bodies of IMarketRegistry selectors; this contract inherits no interface piece.
// solhint-disable comprehensive-interface
// Every external call here is a view, so none can re-enter the registry.
// forge-lint: disable-start(reentrancy-events)
contract MarketRegistryWindDownLogic is MarketRegistryStorage, IMarketRegistryLogic {
    constructor(
        MarketRegistryImmutables memory im
    ) MarketRegistryStorage(im) {}

    /// @inheritdoc IMarketRegistryLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("MarketRegistryWindDownLogic"), _IMMUTABLES_HASH);
    }

    function closeMarket(
        uint256 marketId
    ) external {
        _onlyDelegated();
        Market storage m = _s().markets[marketId];
        if (m.status != MarketStatus.Offboarding) revert IMarketRegistry.MarketNotOffboarding(marketId);
        uint256 notBefore = uint256(_s().windDown[marketId].offboardedAt) + OFFBOARD_NOTICE_SECONDS;
        if (block.timestamp < notBefore) revert IMarketRegistry.OffboardNoticeRunning(notBefore);
        if (!ICollateralizationViews(_COLLATERALIZATION).getMarketDebtFree(m.vaultToken)) {
            revert IMarketRegistry.MarketHasDebt(marketId);
        }
        m.status = MarketStatus.Closed;
        emit IMarketRegistry.MarketClosed(marketId);
    }

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
        emit IMarketRegistry.SettlementReserveSet(marketId, debtReserveId);
    }

    function recordCreditLine(
        address fundingHub,
        address asset,
        uint256 line
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        if (l.hubTier[fundingHub] == RiskTier.None) revert IMarketRegistry.InvalidHub(fundingHub);
        CreditLine storage cl = l.creditLines[fundingHub][asset];
        uint256 sum = cl.drawCapSum;
        if (sum > line) revert IMarketRegistry.CreditLineExceeded(fundingHub, asset, sum, line);
        _requireCovered(fundingHub, asset, line);
        cl.line = line;
        emit IMarketRegistry.CreditLineSet(fundingHub, asset, line, sum);
    }

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
        emit IMarketRegistry.CreditLineRecorded(d.fundingHub, d.asset, spoke, cap, sum);
    }
}
