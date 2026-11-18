// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountGateStatus} from "../../../types/MarketTypes.sol";
import {DebtPosition} from "./DebtPosition.sol";
import {MarketPosition} from "./MarketPosition.sol";

/// @notice Account view of one wallet's PositionProxy for one market.
/// @dev An undeployed proxy reports the predicted address, no markets and zero debt.
struct AccountView {
    uint256 blockNumber;
    uint256 timestamp;
    address wallet;
    address spoke;
    uint256 marketId;
    address proxy;
    bool deployed;
    uint256 borrowNonce;
    uint256 healthFactor;
    uint256 totalCollateralValue;
    uint256 totalDebtValueRay;
    uint256 avgCollateralFactor;
    uint256 riskPremium;
    uint256 activeCollateralCount;
    uint256 borrowCount;
    AccountGateStatus gateStatus;
    bool walletFrozen;
    uint32 breakerReasons;
    DebtPosition[] debts;
    MarketPosition[] markets;
}
