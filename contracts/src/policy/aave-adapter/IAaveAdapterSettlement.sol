// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionRef} from "../../types/PositionRef.sol";

/// @title IAaveAdapterSettlement
/// @notice Steps LPVaultSwap asks the Adapter to run: the seized-unit burn of a liquidation or pending settlement, and
/// the repay and release steps of a repay with collateral. None reads the MarketRegistry, the pause state, the address
/// freeze or a breaker.
interface IAaveAdapterSettlement {
    /// @notice Burns `units` of a market's vault token from LPVaultSwap's balance.
    /// @dev The call reverts with `NotLPVaultSwap` unless `msg.sender == LP_VAULT_SWAP` and `LOCK.holder() ==
    /// LP_VAULT_SWAP`, `UnknownMarket` unless `vaultToken` is the vault token the Adapter bound for `marketId` (or the
    /// VaultTokenFactory's token of that market), `ZeroAmount` if `units == 0`. Calls `vaultToken.burn(LP_VAULT_SWAP,
    /// units)` and emits `SeizedUnitsBurned`. Takes no lock, reads no MarketRegistry state and calls no RiskModule
    /// function: liquidation runs in every pause state. LPVaultSwap calls it between `Collateralization.beginSeizure`
    /// and `settleSeizure`, and before `Collateralization.settlePending`; Collateralization then checks the supply drop.
    /// @param marketId The market.
    /// @param vaultToken The market's vault token.
    /// @param units Seized units LPVaultSwap holds.
    /// @custom:spec REQ-ADAPTER-070, REQ-ADAPTER-046, REQ-ADAPTER-047, REQ-ADAPTER-086, REQ-PROXY-075, WDR-030, Q-224, Q-227, Q-260
    function burnSeized(
        uint256 marketId,
        address vaultToken,
        uint256 units
    ) external;

    /// @notice Repays `amount` of the session's debt reserve on the session's proxy with funds from LPVaultSwap.
    /// @dev `NotLPVaultSwap` unless `msg.sender == LP_VAULT_SWAP` and `LOCK.holder() == address(this)`;
    /// `NoDeleverageSession` unless an open session names `proxy` and `debtReserveId` and this step has not run;
    /// `ZeroAmount` if `amount == 0`. Moves `amount` with `safeTransferFrom(LP_VAULT_SWAP, proxy, amount)`, measures
    /// `received`, repays through `proxy.execute` (unconsumed part returned to LPVaultSwap) and marks the step done.
    /// @param proxy The session's proxy.
    /// @param debtReserveId The session's debt reserve.
    /// @param amount Debt asset LPVaultSwap provides, base units.
    /// @return repaid Amount Aave took.
    /// @custom:spec REQ-ADAPTER-081, REQ-ADAPTER-092, REQ-PROXY-088, REP-018, Q-255, Q-271
    function deleverageRepay(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external returns (uint256 repaid);

    /// @notice Withdraws and burns the session's units and has Collateralization release them to LPVaultSwap.
    /// @dev `NotLPVaultSwap` and `NoDeleverageSession` as in `deleverageRepay`; runs only after it. Withdraws `units`
    /// through `proxy.execute`, calls `vaultToken.burn(proxy, units)` and `Collateralization.releaseForDeleverage(proxy,
    /// vaultToken, position.positionKey, units, minAmounts)` (reconcile, debit, counters, rescue units, the LPVault unwinds exactly
    /// `units` and sends each token to LPVaultSwap, position returned to the depositor when credited reaches 0) and
    /// marks the step done.
    /// @param proxy The session's proxy; its market is the session's.
    /// @param position The session's position.
    /// @param units The session's units.
    /// @param minAmounts Least raw amount of each pool token, market token order.
    /// @return amounts Raw amount of each pool token sent to LPVaultSwap.
    /// @return closed True when the record's credited units reached 0 and the position returned to its depositor.
    /// @custom:spec REQ-ADAPTER-081, REQ-ADAPTER-092, REQ-PROXY-089, REP-019, Q-255, Q-376
    function deleverageRelease(
        address proxy,
        PositionRef calldata position,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts, bool closed);
}
