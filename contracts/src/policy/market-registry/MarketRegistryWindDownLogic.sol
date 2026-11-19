// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralization} from "../../legacy/ICollateralization.sol";
import {Market} from "../../types/MarketTypes.sol";
import {IMarketRegistry} from "./IMarketRegistry.sol";
import {IMarketRegistryLogic} from "./IMarketRegistryLogic.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {MarketRegistryImmutables, MarketStatus} from "./types/MarketRegistryTypes.sol";

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
        if (!ICollateralization(_COLLATERALIZATION).getMarketDebtFree(m.vaultToken)) {
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
}
