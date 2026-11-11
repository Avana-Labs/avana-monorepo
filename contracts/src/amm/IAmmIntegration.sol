// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PositionShape} from "../types/PositionShape.sol";
import {IntegrationCapabilities} from "./types/IntegrationCapabilities.sol";
import {RiskMetadata} from "./types/RiskMetadata.sol";
import {RiskStatus} from "./types/RiskStatus.sol";

/// @title IAmmIntegration
/// @notice Avana's code for one AMM protocol on one chain, implemented by that protocol's LPVault: custody of
/// positions, composition at an oracle price vector, unwind of exactly x units with per-token minimums, fee
/// collection, and risk metadata.
/// @dev A position is `(integrationId, positionKey)`, never a token ID. Every amount is an array in the market's pool
/// token order, of length `n` with 2 <= n <= `MAX_POOL_TOKENS` = 8; a wrong length reverts with `LengthMismatch`.
/// Prices are 8-decimal USD per whole token. Value of a position is always
/// `V = sum_i floor(amount_i * price_i / 10^d_i)` (USD, 8 decimals) with `amount_i` from `composition` at the oracle
/// prices, never from spot reserves, never 50/50 and never weights times prices. Value-moving functions require `msg.sender ==
/// COLLATERALIZATION` and `LOCK.holder()` equal to the AaveAdapter or LPVaultSwap, so they run only inside a call tree
/// opened by one of the Lock's two members and a new AMM protocol never changes them (INV-091); `bindMarket` is
/// MarketRegistry-only, and the LPVault's `returnStray` is timelock-only with the Lock free. Cases one shape does not fit are described by `capabilities()` and served by
/// `IAmmIntegrationHooks`.
/// @custom:spec REQ-AMM-CORE-001, REQ-AMM-CORE-002, REQ-AMM-CORE-005, REQ-AMM-CORE-006, REQ-AMM-CORE-007, REQ-AMM-CORE-008, INV-005, INV-091, Q-369, Q-370, Q-371
interface IAmmIntegration {
    // ------------------------------------------------------------------------------------------------------------
    // Identity and market binding
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Returns the integration identifier assigned at registration in the VaultTokenFactory.
    /// @return integrationId Constructor immutable.
    /// @custom:spec REQ-AMM-CORE-001
    function INTEGRATION_ID() external view returns (uint32 integrationId);

    /// @notice Returns the AMM protocol tag, `keccak256` of its name (for example `keccak256("UNISWAP_V3")`).
    /// @return protocol Constant.
    /// @custom:spec REQ-AMM-CORE-009
    function AMM_PROTOCOL() external view returns (bytes32 protocol);

    /// @notice Returns the fixed description of the integration.
    /// @return caps Pool keying, fee mode, pricing mode, shape kind and hook flags.
    /// @custom:spec REQ-AMM-CORE-009
    function capabilities() external view returns (IntegrationCapabilities memory caps);

    /// @notice Binds a market to its pool and exact shape, once, at listing.
    /// @dev Requires `msg.sender == MARKET_REGISTRY` (`NotMarketRegistry`) and an unbound `marketId`
    /// (`MarketBinding`). Validates the pool against the AMM protocol's canonical factory or singleton (`InvalidPool`)
    /// and the shape (`InvalidShape`): for `TickRange`, `tickLower < tickUpper`, both aligned with signed int24
    /// `tick % tickSpacing == 0` and inside the usable ticks. Reads the tokens, decimals and pool settings (fee tier,
    /// tick spacing, rate providers) on-chain, stores them as the market's integration configuration, never changed
    /// afterwards, and emits `MarketBound`.
    /// @param marketId MarketRegistry identifier.
    /// @param pool Pool address (address(0) for an identifier-keyed protocol).
    /// @param poolId Pool identifier (bytes32(0) for an address-keyed protocol).
    /// @param shape Exact position shape.
    /// @param integrationData Integration-specific listing data.
    /// @return tokens Pool tokens in pool order (native ETH as the wrapped token).
    /// @return unitDecimals Decimals of the market's vault token.
    /// @custom:spec REQ-AMM-CORE-003, REQ-AMM-CORE-004, REQ-AMM-CORE-014
    function bindMarket(
        uint256 marketId,
        address pool,
        bytes32 poolId,
        PositionShape calldata shape,
        bytes calldata integrationData
    ) external returns (address[] memory tokens, uint8 unitDecimals);

    /// @notice Returns a bound market's pool, shape and tokens.
    /// @dev Reverts with `MarketBinding` for a market not bound to this integration.
    /// @custom:spec REQ-AMM-CORE-004
    function marketOf(
        uint256 marketId
    ) external view returns (address pool, bytes32 poolId, PositionShape memory shape, address[] memory tokens);

    // ------------------------------------------------------------------------------------------------------------
    // Custody: Collateralization only, lock held by the AaveAdapter or LPVaultSwap
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Validates a position against a market, pulls it from its owner into custody and returns its units.
    /// @dev Requires `msg.sender == COLLATERALIZATION` (`NotCollateralization`) and the lock held (`LockNotHeld`);
    /// `owner` is not the LPVault and owns the position (`NotTokenOwner`); the position is in the market's pool
    /// (`PoolMismatch`) with exactly the market's shape (`RangeMismatch`), unencumbered (`PositionEncumbered`), and
    /// the pool lock is free (`PoolLocked`). Pulls without a receiver callback, records `owner` as depositor of
    /// record, reads `units` after custody (`ZeroUnits`) and emits `PositionReceived`.
    /// @param marketId Market the position is pledged into.
    /// @param owner Wallet that owns the position and becomes its depositor of record.
    /// @param positionKey Integration key of the position.
    /// @return units Position units read after custody.
    /// @custom:spec REQ-AMM-CORE-005, REQ-VAULT-147, REQ-VAULT-101, REQ-VAULT-011, REQ-VAULT-156, REQ-VAULT-157, DEP-008, Q-258
    function receivePosition(
        uint256 marketId,
        address owner,
        bytes32 positionKey
    ) external returns (uint128 units);

    /// @notice Sends a custodied position, whole, to its depositor of record.
    /// @dev Requires `msg.sender == COLLATERALIZATION`, the lock held and the position in custody (`NotInCustody`).
    /// Deletes the entry before the transfer, takes no recipient and emits `PositionReturned`.
    /// @param positionKey Position of the record Collateralization is closing.
    /// @return depositor Depositor of record that received the position.
    /// @custom:spec REQ-AMM-CORE-005, REQ-VAULT-148, REQ-VAULT-072, REQ-VAULT-094, INV-045
    function returnPosition(
        bytes32 positionKey
    ) external returns (address depositor);

    /// @notice Adds units to a custodied fungible-share position by pulling the LP amount `topUp` encodes from `owner`.
    /// @dev Requires `msg.sender == COLLATERALIZATION`, the lock held, the position in custody (`NotInCustody`) and
    /// `owner == depositorOf(positionKey)` (`NotDepositor`). An integration whose positions anyone can add to directly
    /// (an NFT position's `increaseLiquidity`) reverts with `TopUpNotSupported`. Example: a Curve record at 1,000e18 LP
    /// units topped up with 250e18 LP: the LPVault's LP balance rises by 250e18 and `unitsAdded = 250e18`.
    /// @param positionKey The custodied position.
    /// @param owner The depositor of record, who approved the LPVault for the amount.
    /// @param topUp Integration-encoded amount.
    /// @return unitsAdded Units added, measured by balance delta.
    /// @custom:spec REQ-AMM-CORE-011, REQ-COLL-037, Q-294, Q-297
    function topUpPosition(
        bytes32 positionKey,
        address owner,
        bytes calldata topUp
    ) external returns (uint128 unitsAdded);

    /// @notice Returns the current owner of a position in the AMM protocol (for an NFT, `ownerOf(tokenId)`), or
    /// address(0) when it does not exist; read by the RiskModule's `previewPledge` and the Lens before a pledge.
    /// @param positionKey The position.
    /// @return owner Current owner.
    /// @custom:spec REQ-AMM-CORE-005, REQ-RISK-031
    function positionOwner(
        bytes32 positionKey
    ) external view returns (address owner);

    /// @notice Returns the units of a position if it is acceptable for a market, and reverts with the error
    /// `receivePosition` would raise otherwise.
    /// @dev Reads ownership, pool, shape, encumbrance and units without moving anything; the Lens uses it before a
    /// pledge.
    /// @custom:spec REQ-AMM-CORE-005
    function validatePosition(
        uint256 marketId,
        address owner,
        bytes32 positionKey
    ) external view returns (uint128 units);

    // ------------------------------------------------------------------------------------------------------------
    // Composition
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Returns the token amounts `units` of the market hold at the oracle price vector `prices`.
    /// @dev Pure function of the market's stored configuration, `units` and `prices`: reads no spot price, reserve
    /// balance or uncollected fee, so moving the pool in the same block cannot raise it (AMM-A1a, AMM-B7). For
    /// concentrated liquidity the oracle sqrt price is clamped to the range (AMMN-RT-02), each amount is floored at
    /// every step, then reduced by 1 raw unit when positive (AMM-A3f). Example: Uniswap v3 USDC/USDT market,
    /// range [-10, 10], prices (1.0000e8, 1.0000e8), L = 1e12: the oracle tick is 0, exact amounts are
    /// 499,850,034.99 raw each, floored to 499,850,034 and reduced to 499,850,033, so V = 999.700066 USD (6-decimal
    /// tokens). Rounding only lowers V, so collateral is never overvalued. `exact` is false for a `LowerBound`
    /// protocol. Reverts with `InvalidPrices` for a zero price and `LengthMismatch` for a wrong length.
    /// @param marketId Bound market.
    /// @param units Position units.
    /// @param prices Oracle prices in pool order, 8 decimals.
    /// @return amounts Raw token amounts in pool order.
    /// @return exact True for an exact closed form, false for a lower bound.
    /// @custom:spec REQ-AMM-CORE-006, REQ-AMM-CORE-012, SPEC-ORC-007
    function composition(
        uint256 marketId,
        uint256 units,
        uint256[] calldata prices
    ) external view returns (uint256[] memory amounts, bool exact);

    // ------------------------------------------------------------------------------------------------------------
    // Unwind: Collateralization only, lock held
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Removes exactly `units` from a custodied position and sends exactly the removed principal to
    /// `recipient`.
    /// @dev Requires `msg.sender == COLLATERALIZATION`, the lock held, the position in custody and `recipient`
    /// neither zero nor the LPVault (`InvalidRecipient`). Removes `units`, collects only the principal just removed
    /// (fees stay owed), returns the AMM's removal amounts (the recipient measures receipts by balance delta), reverts
    /// with the AMM slippage error or `BelowMinimum` under any minimum, emits `UnitsUnwound`. Collateralization passes
    /// the units it debited, `recipient = LP_VAULT_SWAP` for a seizure or deleverage and itself to reconcile; its
    /// minimums are the per-leg oracle minimums LPVaultSwap computed, or 0 where the fair-composition bound already
    /// holds (removal at any spot price is worth at least the fair value, AMM-A1a).
    /// @custom:spec REQ-AMM-CORE-007, REQ-VAULT-149, REQ-VAULT-057, REQ-VAULT-058, REQ-VAULT-067, REQ-VAULT-095, REQ-VAULT-135, REQ-VAULT-146, REQ-VAULT-159, SPEC-BACK-008, Q-217, Q-250, Q-255, Q-271
    function unwind(
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts,
        address recipient
    ) external returns (uint256[] memory amounts);

    /// @notice Removes exactly `units` from a custodied position with the depositor's minimums and sends the removed
    /// principal to the depositor of record; the position stays in custody.
    /// @dev Same checks as `unwind`; takes no recipient. Collateralization passes units below the record's credited
    /// units. Emits `UnitsReleased`.
    /// @custom:spec REQ-AMM-CORE-007, REQ-VAULT-161, REQ-VAULT-099, REQ-VAULT-163, SPEC-BACK-008, Q-254
    function releaseToDepositor(
        bytes32 positionKey,
        uint128 units,
        uint256[] calldata minAmounts
    ) external returns (uint256[] memory amounts);

    // ------------------------------------------------------------------------------------------------------------
    // Fees and risk metadata
    // ------------------------------------------------------------------------------------------------------------

    /// @notice Collects every owed fee of a custodied position to its depositor of record.
    /// @dev Requires `msg.sender == COLLATERALIZATION`, the lock held, the position in custody and
    /// `depositor == depositorOf(positionKey)` (`NotDepositor`). No unit changes. Reverts with `FeesRolledIn` for a
    /// `RolledIn` protocol. Reads no pause, breaker, price or policy, so it works in every application state. Emits
    /// `FeesCollected`.
    /// @custom:spec REQ-AMM-CORE-011, REQ-VAULT-064, REQ-VAULT-065, REQ-VAULT-066, REQ-VAULT-126, FEE-001, FEE-002, FEE-006, INV-044
    function collectFees(
        bytes32 positionKey,
        address depositor
    ) external returns (uint256[] memory amounts);

    /// @notice Returns range status, pool share and position units of a market.
    /// @param marketId Bound market.
    /// @param positionKey Position to report (bytes32(0) for none).
    /// @custom:spec REQ-AMM-CORE-008
    function riskMetadata(
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (RiskMetadata memory meta);

    /// @notice Returns the pool's time-weighted depth over `window`, in the market's units.
    /// @dev The RiskModule passes the market's `twapWindow` (`RiskStatus`).
    /// @param marketId Bound market.
    /// @param window Seconds.
    /// @return status Depth and whether the AMM protocol's history covers the window.
    /// @custom:spec REQ-AMM-CORE-013, SPEC-CAP-005, Q-295
    function riskStatus(
        uint256 marketId,
        uint32 window
    ) external view returns (RiskStatus memory status);

    /// @notice Returns the depositor of record of a custodied position, or address(0).
    /// @dev Reverts with `Locked` while the lock is held.
    /// @custom:spec REQ-VAULT-151, REQ-VAULT-152, REQ-VAULT-160
    function depositorOf(
        bytes32 positionKey
    ) external view returns (address depositor);

    /// @notice Returns the market a custodied position was received for (0 when not in custody).
    /// @custom:spec REQ-VAULT-151
    function marketOfPosition(
        bytes32 positionKey
    ) external view returns (uint256 marketId);

    /// @notice Returns the live units of a custodied position.
    /// @dev Reverts with `NotInCustody`, and with `Locked` while the lock is held unless the caller is
    /// Collateralization (which reads it in `recredit`).
    /// @custom:spec REQ-VAULT-162, REQ-VAULT-151, REQ-VAULT-160, Q-254
    function unitsOf(
        bytes32 positionKey
    ) external view returns (uint128 units);
}
