// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountGateStatus} from "../../../types/AccountGateStatus.sol";
import {DebtPosition} from "./DebtPosition.sol";
import {MarketPosition} from "./MarketPosition.sol";

/// @notice Account view of one wallet's PositionProxy for one market.
/// @dev `proxy` is `ProxyManager.predictProxy(wallet, spoke, marketId)` (equal to `AaveAdapter.proxyOf(wallet,
/// marketId)` once deployed); `deployed` is `AaveAdapter.proxyOf(wallet, marketId) != address(0)`; `borrowNonce` is `AaveAdapter.borrowNonce(proxy)`. Aave fields come from the Spoke's
/// `getUserAccountData(proxy)`, computed over every collateral and debt reserve of the account: `healthFactor` (WAD),
/// `totalCollateralValue`, `totalDebtValueRay`, `avgCollateralFactor`, `riskPremium`, `activeCollateralCount`,
/// `borrowCount`. `gateStatus` is `RiskModule.getAccountGateStatus(proxy)`. `debts` has one entry per approved
/// debt reserve of the Spoke (zero-debt reserves included); `markets` has the one market the proxy is bound to, when it
/// has supplied shares or credited units. An undeployed proxy reports the predicted address, no markets and zero
/// debt on every approved debt reserve. `walletFrozen` is `MarketRegistry.isFrozenAddress(wallet)`; `breakerReasons` ORs
/// the breaker reasons of the market and every debt reserve with debt (what a borrow or
/// withdraw-with-debt meets).
/// @custom:spec REQ-LENS-009, REQ-LENS-010, REQ-LENS-037, Q-241, Q-242
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
