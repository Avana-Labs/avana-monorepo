// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DrawHeadroom} from "../lens/lens/types/LensTypes.sol";
import {MarketStatus} from "../policy/market-registry/types/MarketRegistryTypes.sol";
import {PriceState} from "./OracleTypes.sol";
import {PositionShape} from "./PositionTypes.sol";

/// @notice Stored market definition.
/// @dev Every n-token array in Avana uses the order of `tokens`.
struct Market {
    uint64 chainId;
    // Hub of the market's CDP Spoke.
    address hub;
    address spoke;
    uint32 integrationId;
    // AMM integration (the AMM protocol's LPVault on this chain).
    address integration;
    // Pool address (address(0) for an AMM protocol keyed by identifier).
    address pool;
    // Pool identifier (bytes32(0) for an AMM protocol keyed by address).
    bytes32 poolId;
    PositionShape shape;
    // Pool tokens in pool order.
    address[] tokens;
    uint8[] tokenDecimals;
    address vaultToken;
    // Vault-token decimals, fixed by the integration's unit definition.
    uint8 decimals;
    address lpOracle;
    // Hub asset identifier of the vault token (set at activation).
    uint256 hubAssetId;
    // CDP Spoke reserve identifier of the vault token (set at activation).
    uint256 reserveId;
    MarketStatus status;
    uint64 registeredAt;
    uint64 activatedAt;
}

/// @notice Input of the MarketRegistry's `listCollateralMarket`.
/// @dev Exactly one of `pool` and `poolId` is set.
struct MarketDef {
    // Hub the market's CDP Spoke draws from.
    address hub;
    // CDP Spoke that lists the market as a collateral reserve.
    address spoke;
    // AMM integration identifier (the AMM protocol's LPVault on this chain).
    uint32 integrationId;
    // Pool address, or address(0) for an AMM protocol keyed by identifier.
    address pool;
    // Pool identifier, or bytes32(0) for an AMM protocol keyed by address.
    bytes32 poolId;
    PositionShape shape;
    // Vault token deployed by the VaultTokenFactory for the market.
    address vaultToken;
    // The market's seeded LPOracle feed proxy.
    address lpOracle;
    // Integration-specific listing data, decoded and checked by the integration.
    bytes integrationData;
}

/// @notice Borrow-side gate outcome for one collateral market of an account.
struct MarketGateStatus {
    // MarketRegistry market identifier (0 when the reserve maps to no market).
    uint256 marketId;
    // CDP Spoke reserve identifier of the market's vault token.
    uint256 reserveId;
    PriceState priceState;
    // Age of the oldest price input, seconds.
    uint256 oldestFeedAge;
    // True when some input is older than its borrowPriceMaxAge.
    bool feedTooOld;
    bool offboarding;
    // The market's vault-token reserve is paused on the CDP Spoke.
    bool aaveReservePaused;
    // The market's vault-token reserve is frozen on the CDP Spoke.
    bool aaveReserveFrozen;
    // HUB.getAddedAssets == HUB.getAddedShares for the vault-token asset.
    bool hubSharesEqualAssets;
    // Some pool token other than the debt asset has no usable swap route.
    bool noSettlementPath;
    bool liquidationHalted;
    // Bitmap of tripped BreakerReasons of the market (condition and latched).
    uint32 breakerReasons;
    // End of the market's latched breaker; 0 or past when none.
    uint64 breakerLatchedUntil;
}

/// @notice Every borrow-side gate outcome for one account on one CDP Spoke, returned without reverting.
/// @dev A reserve ID field holds `type(uint256).max` when no reserve fails (reserve 0 is valid).
struct AccountGateStatus {
    // True when `spoke` is an approved Avana CDP Spoke.
    bool spokeApproved;
    // Per-market outcomes for the collateral scope.
    MarketGateStatus[] markets;
    // First collateral reserve that maps to no Active or Offboarding market.
    uint256 unknownCollateralReserveId;
    // First debt reserve of the account that the MarketRegistry has not enabled for the Spoke.
    uint256 unapprovedDebtReserveId;
    // First debt reserve of the account paused on Aave.
    uint256 pausedDebtReserveId;
    // First debt reserve of the account on an unexpected price source or with a stale or non-Live DebtOracle.
    uint256 staleDebtReserveId;
    // First debt reserve of the account whose flash source and caller-funded path are both unavailable.
    uint256 haltedDebtReserveId;
    // Market of the first drift failure (0 for Spoke-wide and debt-reserve reasons).
    uint256 driftMarketId;
    DriftReason driftReason;
    // LPVaultSwap.activeKeeperCount() == 0 (no approved keeper that is not frozen).
    bool noApprovedKeeper;
    PauseState pauseState;
    // Current health factor, WAD.
    uint256 healthFactor;
    // True when every preBorrowCheck check that does not depend on the reserve borrowed passes now.
    bool borrowAllowed;
    // True when preWithdrawCheck would pass now, every held debt reserve's debt breaker included.
    bool withdrawWithDebtAllowed;
    // MarketRegistry pause reason (None unless Paused).
    PauseReason pauseReason;
    // Health factor with rescue units valued at zero, WAD.
    uint256 healthFactorExcludingRescue;
    // First debt reserve of the account whose debt breaker is tripped.
    uint256 breakerDebtReserveId;
    // Bitmap of tripped BreakerReasons of that debt reserve.
    uint32 debtBreakerReasons;
    bool statusUnavailable;
}

/// @notice Avana and Aave cap headroom for a market and depositor.
/// @dev Rounding never overstates headroom.
struct CapView {
    uint256 blockNumber;
    uint256 timestamp;
    address hub;
    address vaultToken;
    address depositor;
    uint256 minPledgeUsd;
    uint256 marketHeadroomUsd;
    uint256 sliceHeadroomUsd;
    address[] tokens;
    uint256[] tokenHeadroomUsd;
    uint256 chargePricePerWholeToken;
    uint256 vaultTokenAddHeadroom;
    DrawHeadroom[] drawHeadroom;
}

/// @notice Reason codes of the RiskModule's Aave configuration drift check.
/// @dev Append only: existing ordinal values never change.
enum DriftReason {
    None,
    // A debt reserve of the account is not a debt reserve the MarketRegistry enabled for the Spoke.
    BorrowedUnapprovedReserve,
    // An approved debt reserve's Aave reserve does not match its recorded definition.
    DebtReserveMismatch,
    ReserveIdentity,
    // A market's collateral reserve has receiveSharesEnabled true.
    ReceiveSharesOn,
    Borrowable,
    // A collateral reserve's liquidationFee is above 0 (a fee pays Hub shares with no token transfer).
    LiquidationFeeNonZero,
    ExtraSpoke,
    DrawCapNonZero,
    DrawnSharesNonZero,
    FeeReceiverAddCap,
    // A collateral reserve has a reinvestment controller.
    ReinvestmentController,
    PriceSource,
    CollateralRiskAboveThreshold,
    // The implementation behind the Spoke proxy is not the approved one, by address and code hash.
    SpokeImplementation,
    // The CDP Spoke's Hub differs from its recorded home Hub.
    HomeHubMismatch,
    // A reserve of the Spoke is borrowable without being a debt reserve the MarketRegistry enabled.
    DebtReserveSet,
    // An approved debt reserve's Aave price source differs from the recorded one.
    DebtPriceSource,
    // A dynamic configuration key's collateral factor is above expectedCollateralFactorBps(m).
    CollateralFactorAboveExpected,
    // ceil(maxLiquidationBonus * CF / 1e4) >= 1e4, or the minimum bonus is below minLiquidationBonus.
    BonusBoundViolated,
    // The Spoke's liquidation target health factor differs from aaveTargetHealthFactor.
    LiquidationConfigChanged,
    // The home Hub reports the CDP Spoke inactive or halted, or an Avana reserve of it is paused.
    SpokeHalted
}

/// @notice Why the application is Paused, held by the MarketRegistry beside `PauseState`.
/// @dev `None` exactly when the state is not Paused; ordinal values are fixed.
enum PauseReason {
    None,
    General,
    MintPathSuspect
}

/// @notice Avana's application pause state, held by the MarketRegistry and read by the AaveAdapter and the Lens.
/// @dev Repay, liquidation and debt-free withdrawal never depend on it. Ordinal values are fixed.
enum PauseState {
    None,
    Frozen,
    Paused
}

/// @notice Constructor bindings of one market's vault token.
struct VaultTokenBindings {
    bytes32 marketKey;
    uint32 integrationId;
    // The LPVault registered for `integrationId`.
    address integration;
    // The home Hub of the CDP Spoke.
    address hub;
    // The CDP Spoke holding the token's reserve.
    address spoke;
    uint256 marketId;
    // The market's LPOracle fixed proxy address.
    address lpOracle;
    // The chain's AaveAdapter fixed proxy address.
    address adapter;
    // The chain's LPVaultSwap fixed proxy address.
    address lpVaultSwap;
    address collateralization;
    uint8 decimals;
    string name;
    string symbol;
}
