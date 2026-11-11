// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveAdapterAdmin} from "./IAaveAdapterAdmin.sol";
import {IAaveAdapterCollateral} from "./IAaveAdapterCollateral.sol";
import {IAaveAdapterErrors} from "./IAaveAdapterErrors.sol";
import {IAaveAdapterEvents} from "./IAaveAdapterEvents.sol";
import {IAaveAdapterSettlement} from "./IAaveAdapterSettlement.sol";
import {IAaveAdapterUser} from "./IAaveAdapterUser.sol";
import {IAaveAdapterViews} from "./IAaveAdapterViews.sol";

/// @title IAaveAdapter
/// @notice The chain's single entry point for every borrower action on every CDP Spoke, Hub and AMM integration of the
/// chain: pledge, re-credit, borrow, repay, withdraw, partial removal, repay-all-and-withdraw, repay with collateral,
/// zero-credit release and fee collection. Calls go wallet → AaveAdapter → the wallet's PositionProxy for that
/// (Spoke, market) → CDP Spoke. One per chain, scoped by Hub inside: every pause, freeze and breaker it reads is the
/// market's home Hub's or the debt reserve's funding Hub's.
/// @dev UUPS proxy (ERC-1967) whose `_authorizeUpgrade` requires `APPLICATION_ADMIN`, held only by the timelock
/// (normal delay, cancellable); ERC-7201 namespace `avana.storage.AaveAdapter`. Implementation constructor takes
/// `proxyManager`, `collateralization`, `riskModule`, `marketRegistry`, `parameterStore`, `lpVaultSwap`, `lock`,
/// `vaultTokenFactory` and `timelock` and calls `_disableInitializers()`; no Hub, AMM protocol or debt asset is an
/// immutable. The Adapter resolves the proxy from `msg.sender` and the market (or the named borrower for repay),
/// creates proxies through the immutable ProxyManager, holds all account logic and drives each logic-free proxy
/// through `execute`, so an Adapter upgrade changes account behaviour without touching any proxy (Q-375), has Collateralization take custody and record backing, is the
/// only minter and burner of every vault token, runs the RiskModule's checks and propagates their errors, keeps the
/// deadline, the per-proxy borrow nonce, the receiver rule and the debt-reserve approval, and reads the application
/// pause state, its reason and the address freeze from the MarketRegistry for new activity only. Repay, debt-free
/// withdrawal and removal, repay-all-and-withdraw, `burnSeized` and the deleverage callbacks read no MarketRegistry
/// state. `_grantRole` gives the admin roles only to `TIMELOCK`. It is one of the Lock's two members. It holds no token at the end of any call and carries no interest fee. Trusted for custody of every
/// proxy position: blast radius stated in REQ-ADAPTER-040.
/// @custom:spec REQ-ADAPTER-001, REQ-ADAPTER-002, REQ-ADAPTER-003, REQ-ADAPTER-004, REQ-ADAPTER-005, REQ-ADAPTER-006, REQ-ADAPTER-007, REQ-ADAPTER-008, REQ-ADAPTER-040, REQ-ADAPTER-041, REQ-ADAPTER-042, REQ-ADAPTER-043, REQ-ADAPTER-044, REQ-ADAPTER-050, REQ-ADAPTER-051, REQ-ADAPTER-060, REQ-ADAPTER-084, REQ-ADAPTER-086, REQ-ADAPTER-093, Q-223, Q-224, Q-226, Q-231, Q-259, Q-260, Q-375, Q-376, Q-377
interface IAaveAdapter is
    IAaveAdapterEvents,
    IAaveAdapterErrors,
    IAaveAdapterUser,
    IAaveAdapterCollateral,
    IAaveAdapterSettlement,
    IAaveAdapterAdmin,
    IAaveAdapterViews
{}
