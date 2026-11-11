// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IRiskModuleAdmin} from "./IRiskModuleAdmin.sol";
import {IRiskModuleChecks} from "./IRiskModuleChecks.sol";
import {IRiskModuleErrors} from "./IRiskModuleErrors.sol";
import {IRiskModuleViews} from "./IRiskModuleViews.sol";

/// @title IRiskModule
/// @notice Avana's risk checks on one chain, holding no funds: the pledge check Collateralization calls inside each
/// pledge, and the borrow-side pre- and post-checks the AaveAdapter calls on every borrow and withdraw-with-debt.
/// @dev One per chain. UUPS proxy (ERC-1967) whose `_authorizeUpgrade` requires `APPLICATION_ADMIN`, held only by the
/// chain's timelock (normal delay). Implementation immutables `MARKET_REGISTRY`, `PARAMETER_STORE`,
/// `COLLATERALIZATION`, `ADAPTER`, `LP_VAULT_SWAP`, `TIMELOCK`; constant
/// `rescueHealthFactor = 1.10e18` (rescue top-up threshold, not a borrow gate); the record limit is `AmmConstants.MAX_RECORDS_PER_ACCOUNT_MARKET = 16`. No Hub, AMM protocol or debt asset is an
/// immutable: each market's home Hub, AMM integration (position manager, factory, pricing) and each debt reserve's
/// funding Hub and asset come from the MarketRegistry, so one RiskModule serves every Hub, CDP Spoke and AMM
/// integration on the chain. The token and depositor caps are keyed by Hub and the pool-share cap by pool,
/// summed over every market (range) of that pool on the chain, all counted in the one chain-wide Collateralization
/// ledger, so adding a Spoke or a range never multiplies them (AMMN-RT-05); other limits are keyed by Spoke and market
/// where they apply. There is no minimum debt (`Q-381`). Each account is one PositionProxy bound to one market, so the
/// checks cover exactly one collateral market and the account's debt reserves on its Spoke. Every value it uses is
/// read from the ParameterStore and the MarketRegistry; it has no setter, pause or guardian function and stores no
/// counter.
/// The `checkPledge` interface the immutable Collateralization calls stays unchanged across upgrades. Its only
/// state-changing external call is LPOracle `poke()` in the pre-checks. Never called by repay, fee collection,
/// debt-free withdrawal, zero-credit release or liquidation. USD amounts are 8-decimal integers.
/// @custom:spec REQ-RISK-001, REQ-RISK-002, REQ-RISK-003, REQ-RISK-004, REQ-RISK-005, REQ-RISK-007, REQ-RISK-008, REQ-RISK-039, REQ-RISK-040, REQ-RISK-053, REQ-RISK-054, REQ-RISK-055, REQ-RISK-072, Q-226, Q-229, Q-240, Q-259, Q-376, Q-380
interface IRiskModule is IRiskModuleErrors, IRiskModuleChecks, IRiskModuleAdmin, IRiskModuleViews {}
