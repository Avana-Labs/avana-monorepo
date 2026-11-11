// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILensAccount} from "./ILensAccount.sol";
import {ILensErrors} from "./ILensErrors.sol";
import {ILensLiquidation} from "./ILensLiquidation.sol";
import {ILensMarket} from "./ILensMarket.sol";
import {ILensPreview} from "./ILensPreview.sol";
import {ILensRisk} from "./ILensRisk.sol";

/// @title ILens
/// @notice Immutable, read-only views of one chain for the app, keepers, monitoring and the public backing proof: an
/// account (one wallet's PositionProxy for one market) with its collateral and every debt reserve, the backing check
/// including pending settlement in n tokens, collateral and debt price states with served and accepted prices, each
/// Hub's pause state and reason, breaker status,
/// address freezes, cap headroom, tail coverage, the escrowed payouts an account can claim, a liquidation preview that
/// returns ready-to-send `LiquidationParams`, and borrow, repay-all, re-credit and repay-with-collateral previews built to
/// stay valid until inclusion.
/// @dev Periphery: one Lens per chain, outside the audited core (AMMN-ARCH-08). Every function is `view`, callable by anyone, and reverts with `Locked()` while `LOCK.isLocked()` is true.
/// Every returned struct carries `blockNumber` and `timestamp`; values within one call come from one block, and
/// consumers combining calls use the same block tag. No proxy, no storage beyond constructor immutables and the
/// compile-time constants of `LensConstants`, no owner, no role, no events. Every account-level function takes the
/// market (or a proxy, whose `MARKET_ID()` names it) and reads the CDP Spoke, home Hub and AMM integration from the
/// MarketRegistry; records are named by `positionKey`, never by an AMM-specific token identifier, and every token
/// amount is an array in the market's token order. No Hub, LPVault or position manager is an immutable. Results are advisory: no core contract stores or calls the
/// Lens, and LPVaultSwap recomputes every liquidation check on execution. Price states never make a function revert;
/// dependency failures propagate (no `try/catch`). The liquidation preview sizes `debtToCover` with the pinned Aave V4
/// liquidation formulas compiled into the Lens. A new Lens is a new deployment, recorded in the verified deployment
/// manifest. Constructor arguments: `collateralization`, `proxyManager`, `adapter`, `lock`, `marketRegistry`,
/// `parameterStore`, `riskModule`, `lpVaultSwap`, `payoutEscrow`.
/// @custom:spec REQ-LENS-001, REQ-LENS-002, REQ-LENS-003, REQ-LENS-004, REQ-LENS-005, REQ-LENS-006, REQ-LENS-007, REQ-LENS-020, REQ-LENS-021, REQ-LENS-022, REQ-LENS-025, Q-226, Q-232, Q-268, Q-375, Q-376
interface ILens is ILensErrors, ILensAccount, ILensMarket, ILensLiquidation, ILensRisk, ILensPreview {
    /// @notice Returns the largest page size `getRecords` and `checkRecordBacking` accept.
    /// @return maxPage `LensConstants.LENS_MAX_PAGE` (200), confirmed by the Foundry gas tests.
    /// @custom:spec REQ-LENS-020
    function LENS_MAX_PAGE() external view returns (uint256 maxPage);

    /// @notice Returns the margin `previewLiquidation` adds to a whole-debt `debtToCover` and keeps above Aave's dust
    /// threshold before it asks for the whole debt.
    /// @return marginBps `LensConstants.LENS_DUST_MARGIN_BPS` (500).
    /// @custom:spec REQ-LENS-028, Q-268
    function LENS_DUST_MARGIN_BPS() external view returns (uint256 marginBps);

    /// @notice Returns Collateralization, read for records, credited units, pending balances and counters.
    /// @return collateralization Constructor immutable.
    /// @custom:spec REQ-LENS-001, REQ-LENS-011, REQ-LENS-012
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice Returns the ProxyManager, read for `predictProxy(wallet, spoke, marketId)`.
    /// @return proxyManager Constructor immutable.
    /// @custom:spec REQ-LENS-001, REQ-LENS-008
    function PROXY_MANAGER() external view returns (address proxyManager);

    /// @notice Returns the AaveAdapter fixed proxy address, read for `proxyOf` and `borrowNonce`.
    /// @return adapter Constructor immutable.
    /// @custom:spec REQ-LENS-001, REQ-LENS-008, REQ-LENS-009
    function ADAPTER() external view returns (address adapter);

    /// @notice Returns the protocol Lock.
    /// @return lock Constructor immutable.
    /// @custom:spec REQ-LENS-001, REQ-LENS-006
    function LOCK() external view returns (address lock);

    /// @notice Returns the MarketRegistry fixed proxy address.
    /// @return marketRegistry Constructor immutable.
    /// @custom:spec REQ-LENS-001, REQ-LENS-031
    function MARKET_REGISTRY() external view returns (address marketRegistry);

    /// @notice Returns the ParameterStore fixed proxy address.
    /// @return parameterStore Constructor immutable.
    /// @custom:spec REQ-LENS-001
    function PARAMETER_STORE() external view returns (address parameterStore);

    /// @notice Returns the RiskModule fixed proxy address, read for gate status and shares == assets.
    /// @return riskModule Constructor immutable.
    /// @custom:spec REQ-LENS-001, REQ-LENS-009, REQ-LENS-016
    function RISK_MODULE() external view returns (address riskModule);

    /// @notice Returns the LPVaultSwap fixed proxy address.
    /// @return lpVaultSwap Constructor immutable.
    /// @custom:spec REQ-LENS-001
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice Returns the PayoutEscrow (payout escrow), read by `getEscrowClaimable`.
    /// @return payoutEscrow Constructor immutable.
    /// @custom:spec REQ-LENS-001, REQ-LENS-027
    function PAYOUT_ESCROW() external view returns (address payoutEscrow);
}
