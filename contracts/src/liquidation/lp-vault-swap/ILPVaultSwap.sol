// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashReceiver} from "../../flash/IFlashReceiver.sol";
import {ILPVaultSwapAdmin} from "./ILPVaultSwapAdmin.sol";
import {ILPVaultSwapDeleverage} from "./ILPVaultSwapDeleverage.sol";
import {ILPVaultSwapErrors} from "./ILPVaultSwapErrors.sol";
import {ILPVaultSwapEvents} from "./ILPVaultSwapEvents.sol";
import {ILPVaultSwapLiquidation} from "./ILPVaultSwapLiquidation.sol";
import {ILPVaultSwapViews} from "./ILPVaultSwapViews.sol";

/// @title ILPVaultSwap
/// @notice The chain's only Avana contract that liquidates, for every Hub, CDP Spoke and AMM integration on the chain.
/// For one borrower account (one market) and one enabled debt reserve per call it checks the caller against the
/// address freeze only, the market's price state and the account's health, pulls the repayment in the debt asset from
/// the caller (it takes no flash loan in a liquidation; a caller without the debt asset uses a flash liquidation
/// helper, an ordinary caller to LPVaultSwap), calls Aave's standard 5-argument `Spoke.liquidationCall` with
/// `receiveShares = false` on the unmodified Spoke, has the AaveAdapter burn the seized vault tokens and Collateralization
/// debit them while the market's LPVault removes exactly the seized units and returns n tokens, swaps each token over the
/// market's swap routes into the debt asset, enforces the recovery floor (the caller tops up a floor gap), and pays out in
/// the debt asset: Avana's fee (20 % of the oracle value the seizure gained, never above the realized surplus), the
/// borrower's surplus and the caller's payout, which includes its unused funding and the recovered principal and is never
/// escrowed. `liquidate` is the one liquidation entry point, open to every address that is not frozen with either route
/// mode (Q-404); `settlePending` sends recovered value to the First-Loss Reserve of the market's (funding Hub, settlement
/// asset); `deleverage` runs the swap side of a repay with collateral and is the only path that flash-borrows, through
/// the chain's `IFlashSource` (`IFlashReceiver.onFlashLoan`). The keeper list is a registry of committed operators that
/// gates no call.
/// @dev One per chain. UUPS proxy (ERC-1967) at a fixed address that is an immutable of every vault token,
/// Collateralization, the AaveAdapter, the PayoutEscrow (payout escrow), the flash source, the flash liquidation helpers
/// and the swap-route contracts; `_authorizeUpgrade` requires `APPLICATION_ADMIN`, held only by the chain's AvanaTimelock
/// (normal delay, cancellable). ERC-7201 storage; the implementation constructor calls `_disableInitializers()` and takes
/// the implementation immutables `LOCK`, `AAVE_ADAPTER`, `COLLATERALIZATION`, `MARKET_REGISTRY`, `PARAMETER_STORE`,
/// `PAYOUT_ESCROW` and `KEEPER_FLOOR`; no debt asset, Hub, First-Loss Reserve or flash source is an immutable (the flash
/// source is `MARKET_REGISTRY.flashSource()`, replaceable through the timelock, read only by `deleverage`). It is one of
/// the Lock's two members. LPVaultSwap never reads the MarketRegistry pause state, pause reason or circuit breakers:
/// liquidation and pending settlement stay open in None, Frozen and both Paused reasons of every Hub; the address freeze
/// refuses only a frozen direct caller; only the price states of the seized market and the repaid debt reserve (Q-247),
/// Aave-side reserve pauses and the checks listed on each function stop them. Every parameter is read from the
/// ParameterStore and every market, debt reserve and route from the MarketRegistry during the call, never cached. Every
/// `liquidate` call ends with no change in LPVaultSwap's balances of the debt asset, vault tokens or any pool token, and
/// every allowance it granted at 0; `settlePending` ends with its vault-token balance lower by the units burned and its
/// settlement-asset balance changed only by its carry of less than one Hub share. Proceeds are before/after deltas, never
/// `balanceOf(this)`. Every swap-route call carries an oracle-derived `minOut >= 1`. LPVaultSwap swaps only through
/// swap-route contracts and never calls an AMM pool directly, so it implements no AMM swap callback. LPVaultSwap writes
/// no breaker state, so no breaker write can revert or slow a liquidation (Q-399). There is no rescue, sweep or
/// arbitrary-call function.
/// @custom:spec REQ-SWAP-002, REQ-SWAP-003, REQ-SWAP-019, REQ-SWAP-032, REQ-SWAP-040, REQ-SWAP-041, REQ-SWAP-042, REQ-SWAP-043, REQ-SWAP-044, REQ-SWAP-045, REQ-SWAP-046, REQ-SWAP-047, REQ-SWAP-077, REQ-SWAP-084, REQ-SWAP-085, REQ-SWAP-100, REQ-SWAP-104, REQ-SWAP-108, Q-148, Q-201, Q-211, Q-213, Q-214, Q-216, Q-217, Q-281, Q-224, Q-226, Q-227, Q-235, Q-240, Q-241, Q-242, Q-247, Q-250, Q-256, Q-271, Q-377, Q-379, Q-404
interface ILPVaultSwap is
    ILPVaultSwapEvents,
    ILPVaultSwapErrors,
    ILPVaultSwapLiquidation,
    ILPVaultSwapAdmin,
    ILPVaultSwapViews,
    ILPVaultSwapDeleverage,
    IFlashReceiver
{}
