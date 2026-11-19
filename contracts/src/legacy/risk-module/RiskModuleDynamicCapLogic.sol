// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {Market} from "../../types/MarketTypes.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/MarketRegistryTypes.sol";
import {MarketDynamicCap} from "../../policy/parameter-store/types/ParameterStoreTypes.sol";
import {DynamicCapMath} from "./DynamicCapMath.sol";
import {ILegacyRiskModule} from "./ILegacyRiskModule.sol";
import {IRiskModuleDynamicCapLogic} from "./IRiskModuleDynamicCapLogic.sol";
import {IRiskModuleLogic} from "./IRiskModuleLogic.sol";
import {RiskModuleBase} from "./RiskModuleBase.sol";
import {DynamicCap, RiskModuleImmutables} from "./types/RiskModuleTypes.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title RiskModuleDynamicCapLogic
/// @notice The per-market dynamic borrow cap: the market's debt, the interval's cap and the borrow check.
/// @dev Reads the stored interval from the caller's `getDynamicCap`; only the LegacyRiskModule proxy stores it.
// View calls in loops over a Spoke's debt reserves, bounded by listings.
// forge-lint: disable-start(calls-loop)
contract RiskModuleDynamicCapLogic is RiskModuleBase, IRiskModuleDynamicCapLogic {
    constructor(
        RiskModuleImmutables memory im
    ) RiskModuleBase(im) {}

    /// @inheritdoc IRiskModuleLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("RiskModuleDynamicCapLogic"), _IMMUTABLES_HASH);
    }

    /// @inheritdoc IRiskModuleDynamicCapLogic
    function borrowCheck(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external view override returns (uint256 marketId, DynamicCap memory next) {
        // The account's Spoke is the market's Spoke; the borrow logic checked it before this read.
        // forge-lint: disable-next-line(unused-return)
        (, marketId) = _account(proxy);
        address spoke = _activeSpoke(marketId);
        DebtReserveDef memory def = _registry().getDebtReserve(spoke, debtReserveId);
        address oracle = IAaveV4Spoke(spoke).ORACLE();
        uint256 amountUsd = amount == 0
            ? 0
            : DynamicCapMath.usdOf(amount, IAaveV4Oracle(oracle).getReservePrice(debtReserveId), def.decimals);
        uint256 debt = _spokeDebtUsd(spoke, oracle);
        next = _interval(marketId, debt);
        uint256 newDebt = debt + amountUsd;
        if (newDebt > next.cap) revert DynamicBorrowCapExceeded(marketId, next.cap, newDebt);
    }

    /// @inheritdoc IRiskModuleDynamicCapLogic
    function capView(
        uint256 marketId
    ) external view override returns (uint256 cap, uint256 debt, uint64 intervalStart) {
        address spoke = _activeSpoke(marketId);
        debt = _spokeDebtUsd(spoke, IAaveV4Spoke(spoke).ORACLE());
        DynamicCap memory d = _interval(marketId, debt);
        (cap, intervalStart) = (d.cap, d.intervalStart);
    }

    /// @dev The market's interval as a borrow now sees it: the stored one while running, else a new one on `debt`.
    function _interval(
        uint256 marketId,
        uint256 debt
    ) internal view returns (DynamicCap memory d) {
        MarketDynamicCap memory terms = _store().marketDynamicCap(marketId);
        d = ILegacyRiskModule(msg.sender).getDynamicCap(marketId);
        if (DynamicCapMath.opensInterval(d.intervalStart, terms.capInterval, block.timestamp)) {
            // Block timestamps stay far below 2^64 seconds.
            // forge-lint: disable-next-line(unsafe-typecast)
            d = DynamicCap({intervalStart: uint64(block.timestamp), cap: DynamicCapMath.target(terms, debt)});
        }
    }

    function _activeSpoke(
        uint256 marketId
    ) internal view returns (address spoke) {
        Market memory m = _market(marketId);
        if (m.vaultToken == address(0)) revert MarketNotActive(marketId);
        spoke = m.spoke;
    }

    /// @dev USD debt of the Spoke over its debt reserves, each rounded down.
    function _spokeDebtUsd(
        address spoke,
        address oracle
    ) internal view returns (uint256 usd) {
        uint256[] memory ids = _registry().getDebtReserveIds(spoke);
        for (uint256 i = 0; i < ids.length; ++i) {
            DebtReserveDef memory d = _registry().getDebtReserve(spoke, ids[i]);
            uint256 owed = IAaveV4Hub(d.fundingHub).getSpokeTotalOwed(d.hubAssetId, spoke);
            if (owed == 0) continue;
            usd += Math.mulDiv(owed, IAaveV4Oracle(oracle).getReservePrice(ids[i]), 10 ** d.decimals);
        }
    }
}
// forge-lint: disable-end(calls-loop)
