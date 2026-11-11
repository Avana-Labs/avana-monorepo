// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IAmmIntegrationHooks
/// @notice Explicit hooks for the cases a single integration shape does not fit: pool reentrancy locks, a time-weighted
/// consistency price, rate tokens, native ETH, Uniswap v4 hook allowlisting and effective supply.
/// @dev Every LPVault implements every hook; a hook that does not apply returns its neutral value, stated per
/// function, so callers never branch on the AMM protocol. `capabilities()` says which hooks are live.
/// @custom:spec REQ-AMM-CORE-009, REQ-AMM-CORE-010, REQ-AMM-CORE-011, REQ-AMM-CORE-012, REQ-AMM-CORE-013, REQ-AMM-CORE-014, Q-371
interface IAmmIntegrationHooks {
    /// @notice Reverts with `PoolLocked` while the market's pool is inside its own reentrancy lock.
    /// @dev Uniswap v3 and Slipstream: `slot0().unlocked == false`. Curve: the pool's read-only reentrancy guard, by a
    /// zero-value call that reverts while it is entered. Balancer: the Vault's reentrancy guard. Uniswap v2: neutral
    /// (never reverts; `getReserves` is consistent between swaps). Every composition read, pledge, re-credit,
    /// partial removal, reconciliation and seizure calls it first, so no read happens inside a pool callback.
    /// @custom:spec REQ-AMM-CORE-013, REQ-VAULT-010, REQ-VAULT-105
    function checkReadSafe(
        uint256 marketId
    ) external view;

    /// @notice Returns the deviation, in bps of the fair price, between the AMM protocol's time-weighted price over
    /// `window` and the price implied by the oracle vector.
    /// @dev Consistency check only: the result gates the LPOracle price and never feeds it. For concentrated liquidity
    /// `|meanTick - tickRef|` in ticks (1 tick is about 1 bps). `available == false` when the protocol has no
    /// time-weighted price (Balancer weighted, Uniswap v4 without an oracle hook) or the buffer does not reach back
    /// `window` seconds; the LPOracle then reports CONSISTENCY_UNAVAILABLE and relies on the per-block quote-change
    /// cap.
    /// @custom:spec REQ-AMM-CORE-009, REQ-ORACLE-046, REQ-ORACLE-103
    function consistencyDeviation(
        uint256 marketId,
        uint32 window,
        uint256[] calldata prices
    ) external view returns (uint256 deviationBps, bool available);

    /// @notice Returns the rate provider of each pool token, address(0) where the token has none.
    /// @dev Rate tokens (wstETH, sDAI) are held by Curve and Balancer pools at balances scaled by a rate; the oracle
    /// prices such a token as `underlying price * rate / 1e18`, floored. Neutral: an array of address(0).
    /// @custom:spec REQ-AMM-CORE-010
    function rateProviders(
        uint256 marketId
    ) external view returns (address[] memory providers);

    /// @notice Returns the wrapped native token used in place of a native ETH pool leg, or address(0).
    /// @dev An unwind wraps native ETH before paying, so every Avana transfer is an ERC-20 transfer and no contract
    /// needs a payable fallback.
    /// @custom:spec REQ-AMM-CORE-010
    function wrappedNative() external view returns (address weth);

    /// @notice Returns whether a Uniswap v4 hook contract is allowlisted for collateral.
    /// @dev Accepts only `hooks == address(0)` or an audited allowlisted hook whose address flags carry no
    /// before/after-remove-liquidity permission and no delta-returning permission (`uint160(hooks) & mask == 0`), so
    /// no hook can block or tax a liquidation's removal. Neutral: true for address(0), false otherwise.
    /// @custom:spec REQ-AMM-CORE-014, REQ-AMM-V4-001
    function isAllowedPoolHook(
        address hooks
    ) external view returns (bool allowed);

    /// @notice Returns the pool units against which one position unit is valued.
    /// @dev Uniswap v2: `totalSupply + pending feeTo liquidity` when `feeTo` is set, so a quote never overstates by the
    /// unminted protocol fee (AMM-B5). Curve, Balancer: LP total supply. Concentrated liquidity: neutral (0; units are
    /// liquidity and value directly).
    /// @custom:spec REQ-AMM-CORE-012
    function effectiveSupply(
        uint256 marketId
    ) external view returns (uint256 supply);
}
