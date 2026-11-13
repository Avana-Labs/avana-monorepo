// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Oracle} from "../../interfaces/external/aave/IAaveV4Oracle.sol";
import {IAaveV4Spoke} from "../../interfaces/external/aave/IAaveV4Spoke.sol";
import {DebtReserveDef} from "../../policy/market-registry/types/DebtReserveDef.sol";
import {IRiskModuleViews} from "../../policy/risk-module/IRiskModuleViews.sol";
import {SpeedView} from "../../policy/risk-module/types/SpeedView.sol";
import {ILensSpeed} from "./ILensSpeed.sol";
import {LensBase} from "./LensBase.sol";
import {BorrowSpeedView} from "./types/BorrowSpeedView.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title LensSpeedModule
/// @notice The deployed part of the Lens that serves `ILensSpeed`: the RiskModule's speed windows and the amount a
/// borrow of one reserve can take now under both (REQ-LENS-061).
/// @dev Immutable and read-only like the Lens: the nine core addresses as constructor immutables, no storage, no owner,
/// no event; every function is `view` and reverts with `Locked()` while the Lock is held.
/// @custom:spec REQ-LENS-001, REQ-LENS-006, REQ-LENS-061, REQ-RISK-097, Q-411
contract LensSpeedModule is LensBase, ILensSpeed {
    /// @notice Fixes the chain's core addresses (see `LensBase`).
    /// @param core The nine core addresses, in `LensBase` order.
    /// @custom:spec REQ-LENS-001, REQ-LENS-002
    constructor(
        address[9] memory core
    ) LensBase(core) {}

    /// @inheritdoc ILensSpeed
    /// @custom:spec REQ-LENS-061, REQ-LENS-006
    function getBorrowSpeed(
        uint256 marketId,
        uint256 debtReserveId
    ) external view override returns (BorrowSpeedView memory speed) {
        _unlocked();
        (speed.market, speed.debt) = IRiskModuleViews(_RISK_MODULE).getBorrowSpeed(marketId, debtReserveId);
        speed.moreAt = _earlier(speed.market.moreAt, speed.debt.moreAt);
        if (speed.market.unavailable || speed.debt.unavailable) return speed;
        address spoke = _market(marketId).spoke;
        DebtReserveDef memory def = _registry().getDebtReserve(spoke, debtReserveId);
        uint256 price = IAaveV4Oracle(IAaveV4Spoke(spoke).ORACLE()).getReservePrice(debtReserveId);
        if (price == 0) return speed;
        uint256 fromMarket = Math.mulDiv(speed.market.available, 10 ** def.decimals, price);
        speed.availableNow = Math.min(fromMarket, speed.debt.available);
    }

    /// @inheritdoc ILensSpeed
    /// @custom:spec REQ-LENS-061, REQ-LENS-006
    function getPledgeSpeed(
        uint256 marketId
    ) external view override returns (SpeedView memory pledge) {
        _unlocked();
        pledge = IRiskModuleViews(_RISK_MODULE).getPledgeSpeed(marketId);
    }

    /// @dev The earlier of two times, a 0 meaning none.
    function _earlier(
        uint64 a,
        uint64 b
    ) private pure returns (uint64) {
        if (a == 0) return b;
        if (b == 0) return a;
        return a < b ? a : b;
    }
}
