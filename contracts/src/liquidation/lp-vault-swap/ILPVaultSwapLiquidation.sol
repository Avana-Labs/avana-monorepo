// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "./types/LiquidationParams.sol";
import {LiquidationResult} from "./types/LiquidationResult.sol";

/// @title ILPVaultSwapLiquidation
/// @notice The entry points of LPVaultSwap open to any caller: `liquidate`, the one liquidation entry point, funded by
/// the caller, and `settlePending`, which sends recovered value to the Coverage Spoke of the market's (funding Hub,
/// settlement asset).
/// @dev Neither reads the MarketRegistry pause state, a breaker or the committed-operator registry (Q-404).
interface ILPVaultSwapLiquidation {
    /// @notice Liquidates one account (one market) against one debt reserve and settles it in the same call, in the
    /// debt asset.
    /// @dev Caller: any address that is not frozen, with either route mode; a flash liquidation helper is an ordinary
    /// caller. First check: `DeadlineExpired(deadline)` if `block.timestamp > params.deadline`, before the lock and any
    /// external call; then `AddressIsFrozen(msg.sender)` for a frozen caller (the freeze binds `msg.sender` only, so it
    /// cannot stop a caller using the public helper). Then acquires the lock and releases it last. The pause state,
    /// pause reason, breakers and the committed-operator registry are never read. Entry checks:
    /// `params.marketId == proxy.MARKET_ID()` and the market's vault token reports `isValidProxy(proxy)`; debt reserve
    /// enabled in the MarketRegistry and on the Spoke; amounts (`InvalidAmount`); `HF < 1e18`; Hub shares == assets;
    /// `poke()` on the market's LPOracle and the price rules for the market and the repaid reserve only (Q-247); the
    /// grace bound. Funding: pulls `X = params.debtToCover` of the debt asset from `msg.sender` with `transferFrom` and
    /// measures the balance rise `Kf`, reverting `FundingMismatch` unless `0 < Kf <= X`. LPVaultSwap takes no flash loan
    /// and calls no flash source in a liquidation (REQ-SWAP-012). Core: `Collateralization.beginSeizure(proxy,
    /// vaultToken)`; exact approval of `Kf` and Aave's standard 5-argument `Spoke.liquidationCall(collateralReserveId,
    /// debtReserveId, proxy, Kf, false)` (the seized vault token comes to LPVaultSwap, the only Hub-to-LPVaultSwap
    /// transfer the vault token's transfer rule allows on seizure, so any other liquidator's call reverts); allowance
    /// reset; `D <= Kf` and `c` as deltas; `AaveAdapter.burnSeized(marketId, vaultToken, c)` and
    /// `Collateralization.settleSeizure(proxy, vaultToken, c, minAmounts)`, where the market's LPVault removes exactly
    /// `c` units and returns n token amounts; each pool token other than the debt asset swapped over its usable swap
    /// route into the debt asset as `swap(a_i, minOut_i)` with the per-leg oracle minimum (SPEC-LIQ-018) and exact
    /// approvals reset to 0 (no pool spot check gates the call, Q-350); recovery floor on `R + shortfall`, pulling the
    /// caller's floor gap up to `maxShortfall` (SPEC-LIQ-019); waterfall with no flash term: `G = max(0, V - D)`,
    /// `S = max(0, R_f - D)`, Avana's fee `A = min(floor(G * share / 1e4), S)`, keeper reward `kr = min(S, G) - A`,
    /// borrower surplus `B = S - A - kr`, and `keeperOut = Kf + R' - D - A - B`, never negative because `D <= Kf`
    /// (`InsufficientProceeds` is defensive); `PayoutTooLow(keeperOut, minPayout)`. Payouts in the debt asset: `A` to
    /// `feeRecipient` and `B` to the bound wallet by gas-limited transfers that fall back to `PayoutEscrow.deposit`
    /// credited to the recipient; `keeperOut` to `msg.sender` by a plain transfer that reverts the call on failure (never
    /// escrowed); route residues and dust legs to `msg.sender` by the gas-limited delivery (escrowed on failure). Every
    /// computed-zero transfer, route call and deposit is skipped. No breaker report (Q-399). Aave records any deficit
    /// inside `liquidationCall`; Aave, Lock, AaveAdapter, Collateralization and LPVault errors pass through.
    /// @param params Liquidation arguments.
    /// @return result D, c, the unwound amounts, Kf, R, the floor, A, kr, the payouts and the shortfall pulled.
    /// @custom:spec REQ-SWAP-001, REQ-SWAP-002, REQ-SWAP-003, REQ-SWAP-004, REQ-SWAP-005, REQ-SWAP-006, REQ-SWAP-007, REQ-SWAP-008, REQ-SWAP-009, REQ-SWAP-010, REQ-SWAP-011, REQ-SWAP-012, REQ-SWAP-014, REQ-SWAP-015, REQ-SWAP-016, REQ-SWAP-017, REQ-SWAP-018, REQ-SWAP-020, REQ-SWAP-021, REQ-SWAP-022, REQ-SWAP-023, REQ-SWAP-024, REQ-SWAP-025, REQ-SWAP-026, REQ-SWAP-027, REQ-SWAP-028, REQ-SWAP-029, REQ-SWAP-030, REQ-SWAP-055, REQ-SWAP-057, REQ-SWAP-061, REQ-SWAP-062, REQ-SWAP-064, REQ-SWAP-067, REQ-SWAP-072, REQ-SWAP-073, REQ-SWAP-074, REQ-SWAP-075, REQ-SWAP-076, REQ-SWAP-077, REQ-SWAP-078, REQ-SWAP-079, REQ-SWAP-082, REQ-SWAP-083, REQ-SWAP-085, REQ-SWAP-086, REQ-SWAP-087, REQ-SWAP-088, REQ-SWAP-089, REQ-SWAP-090, REQ-SWAP-091, REQ-SWAP-092, REQ-SWAP-093, REQ-SWAP-094, REQ-SWAP-098, REQ-SWAP-100, REQ-SWAP-101, REQ-SWAP-103, REQ-SWAP-104, REQ-SWAP-105, REQ-SWAP-108, REQ-SWAP-121, SPEC-LIQ-001, SPEC-LIQ-002, SPEC-LIQ-003, SPEC-LIQ-004, SPEC-LIQ-005, SPEC-LIQ-006, SPEC-LIQ-007, SPEC-LIQ-008, SPEC-LIQ-009, SPEC-LIQ-010, SPEC-LIQ-011, SPEC-LIQ-012, SPEC-LIQ-013, SPEC-LIQ-016, SPEC-LIQ-017, SPEC-LIQ-018, SPEC-LIQ-019, SPEC-LIQ-022, LIQ-011, LIQ-013, LIQ-061, LIQ-069, LIQ-070, Q-208, Q-214, Q-216, Q-217, Q-224, Q-235, Q-241, Q-242, Q-247, Q-250, Q-251, Q-256, Q-267, Q-350, Q-379, Q-380, Q-404
    function liquidate(
        LiquidationParams calldata params
    ) external returns (LiquidationResult memory result);

    /// @notice Burns vault tokens left at LPVaultSwap by a seizure that was never settled against Collateralization's
    /// pending-settlement balance, swaps the released pool tokens into the market's settlement asset and adds the value
    /// to the Coverage Spoke of that (funding Hub, asset).
    /// @dev Any caller; the caller supplies nothing and receives nothing; no Avana fee applies. The pause state,
    /// breakers and the address freeze are never read. Before acquiring the lock it reverts with `UnknownMarket`,
    /// `InvalidFeeRecipient` or `LockHeld(holder)`; it reads `p`, the units of `Collateralization.getPending(vaultToken)`,
    /// and `h`, its balance of the vault token, and reverts with `NothingPending` if `x = min(h, p) == 0`;
    /// `debtReserveId` must equal `MarketRegistry.settlementReserve(marketId)` (`UnknownDebtReserve`). Under the lock:
    /// (1) `poke()` the market's LPOracle and revert with `StalePrice` if its price fails the collateral price rule; (2)
    /// `AaveAdapter.burnSeized(marketId, vaultToken, x)` then `Collateralization.settlePending(vaultToken, x)`, taking
    /// the n token amounts as deltas; (3) swap each token other than the settlement asset over its usable swap route at
    /// the SPEC-LIQ-018 minimum with `sLeg = min(slippageAllowanceBps, 30)` (`NoRouteAvailable`); (4) `R` from just
    /// before the burn to after the last route call, `RecoveryBelowFloor` if `R < minPending` (SPEC-LIQ-014); (5) fund
    /// `Rt = R + carry[asset]`: if `Rt` is worth at least one Hub share, approve the Coverage Spoke for exactly `Rt`,
    /// call `fund(Rt)`, reset the allowance, clear the carry and require the balance to fall by exactly `Rt`
    /// (`FundingMismatch`); otherwise skip `fund` and carry `Rt` to the next settlement into that asset; (6) send route
    /// residue and dust legs to `feeRecipient` by a gas-limited transfer, or on failure to `PayoutEscrow.deposit`
    /// credited to `feeRecipient`; (7) release the lock and emit `PendingSettlementForwarded`.
    /// @param marketId The market whose vault token is settled.
    /// @param debtReserveId The market's settlement reserve, whose asset and funding Hub receive the value.
    /// @return units Vault-token units settled (`x`).
    /// @return amounts Raw amount of each pool token released, market token order.
    /// @return added `R`, settlement asset recovered by this call.
    /// @custom:spec REQ-SWAP-042, REQ-SWAP-043, REQ-SWAP-044, REQ-SWAP-045, REQ-SWAP-066, REQ-SWAP-068, REQ-SWAP-070, REQ-SWAP-071, REQ-SWAP-092, REQ-SWAP-100, REQ-SWAP-104, REQ-SWAP-121, SPEC-LIQ-014, SPEC-LIQ-018, REQ-FLR-038, Q-201, Q-211, Q-224, Q-236, Q-241, Q-250, Q-379
    function settlePending(
        uint256 marketId,
        uint256 debtReserveId
    ) external returns (uint256 units, uint256[] memory amounts, uint256 added);
}
