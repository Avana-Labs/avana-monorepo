// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4PriceFeed} from "../../interfaces/external/aave/IAaveV4PriceFeed.sol";
import {PriceState} from "../../types/PriceState.sol";
import {IDebtOracleErrors} from "./IDebtOracleErrors.sol";
import {IDebtOracleEvents} from "./IDebtOracleEvents.sol";
import {DebtOracleInitParams} from "./types/DebtOracleInitParams.sol";
import {DebtPriceView} from "./types/DebtPriceView.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title IDebtOracle
/// @notice Price feed for one debt asset with a market price: the USD price of one whole token with 8 decimals for the
/// AaveOracle of every CDP Spoke on this chain that lends the asset, and the price state, source timestamps and age limits the RiskModule and
/// LPVaultSwap enforce their debt gates from.
/// @dev One ERC-1967 proxy (UUPS) per debt asset per chain, for every debt asset whose AaveOracle source is not fixed; `_authorizeUpgrade` requires `APPLICATION_ADMIN`, held only
/// by `TIMELOCK` (normal delay), and `_grantRole` reverts `AdminRoleOnlyTimelock` for an admin role and any account other
/// than `TIMELOCK`. A debt asset with a fixed Aave source (such as GHO) has no DebtOracle. Each leg is fresh while its age is at
/// most its own heartbeat plus margin; on an L2 a down sequencer pauses liquidation (reason `SEQUENCER_DOWN`), the grace
/// after a restart narrows liquidation through `inGrace`, and an unknown sequencer state blocks borrowing only. ERC-7201 namespace `avana.storage.DebtOracle`; the implementation
/// constructor calls `_disableInitializers()`. Every evaluation reads `MarketRegistry.activePriceRoutes(ASSET)`,
/// `priceRouteVersion(ASSET)` and `getToken(ASSET)`, and from the ParameterStore `getFeed` per leg,
/// `feedAgreementToleranceBps(ASSET)`, `cachedWindow`, `disagreementPauseMax`, `graceDuration` and
/// `debtStressRiseBps(ASSET)`, all as static calls inside `try`/`catch`. It applies the LPOracle's leg, route, failover,
/// agreement, Cached/Expired, recovery-evidence (with the phase rule), grace and route-version rules to one token, with no
/// pool, TWAP, USD band or stable ceiling. Invariants every function preserves: solvency (a debt price that cannot be
/// trusted is never below the accepted price, so it only lowers health factors and never admits new debt); no
/// repayment or seizure at a stress price (LPVaultSwap repays this reserve only while Live within its liquidation age);
/// `latestAnswer() >= 1` and never a revert except `InsufficientGas`; exits never read it. Only `poke()` writes price,
/// timer, latch or route-version storage; no role can push a price; no token, ETH or approval moves through it.
/// @custom:spec REQ-ORACLE-091, REQ-ORACLE-092, REQ-ORACLE-093, REQ-ORACLE-097, REQ-ORACLE-098, SPEC-ORC-018, Q-238, Q-247, Q-248, Q-259
interface IDebtOracle is IAaveV4PriceFeed, IAccessControl, IDebtOracleEvents, IDebtOracleErrors {
    /// @notice Initializes the feed and seeds the accepted price.
    /// @dev Preserves: always a price. Runs once, in the same transaction as the proxy deployment. Fixes `ASSET`,
    /// `MARKET_REGISTRY` and `PARAMETER_STORE` for life; grants `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` only to
    /// `TIMELOCK` (reverts `AdminRoleOnlyTimelock` otherwise); reverts `NotDebtAsset` unless the asset is a listed
    /// MarketRegistry token without a fixed Aave source with a primary and an alternate route in force, `PokeMinGasOutOfBounds` outside the
    /// gas bounds, and `NotLive` unless the evaluation is Live; stores that price as accepted, records `seen` and the
    /// route version, and emits `DebtPriceSeeded`.
    /// @param params Initialization arguments.
    /// @custom:spec REQ-ORACLE-091, REQ-ORACLE-097
    function initialize(
        DebtOracleInitParams calldata params
    ) external;

    /// @notice Served debt price: USD price of one whole token of the asset, 8 decimals, always >= 1.
    /// @dev Preserves: solvency; always a price. SPEC-ORC-018: the fresh quote when Live; `max(primary, alternate,
    /// accepted)` while the routes disagree; the accepted price when Cached; `ceil(accepted * (1e4 + debtStressRiseBps) /
    /// 1e4)` when Expired. Never capped; never below the accepted price unless Live. Never reverts except
    /// `InsufficientGas`.
    /// @return answer Served price.
    /// @custom:spec REQ-ORACLE-093, SPEC-ORC-018, Q-247
    function latestAnswer() external view override returns (int256 answer);

    /// @notice Decimals of the served price.
    /// @return Always 8.
    /// @custom:spec REQ-ORACLE-091
    function decimals() external view override returns (uint8);

    /// @notice Fixed description stored at `initialize`.
    /// @return Description text.
    /// @custom:spec REQ-ORACLE-091
    function description() external view override returns (string memory);

    /// @notice Chainlink-compatible view of the served price with its source timestamp.
    /// @dev `answer = served`, `startedAt = updatedAt = servedUpdatedAt`, `roundId = answeredInRound =
    /// uint80(servedUpdatedAt)`.
    /// @return roundId uint80(servedUpdatedAt).
    /// @return answer Served price, 8 decimals.
    /// @return startedAt servedUpdatedAt.
    /// @return updatedAt servedUpdatedAt: the timestamp of the route whose value is served (the quote's route when Live,
    /// the route of min(p, b) while Drifting), else the accepted timestamp (failed, or Drifting with A served).
    /// @return answeredInRound uint80(servedUpdatedAt).
    /// @custom:spec REQ-ORACLE-093
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Full price-state report computed by the same code as `latestAnswer()` in the same block.
    /// @dev Never reverts except `InsufficientGas`. Consumers that act on it call `poke()` first.
    /// @return report State, reasons, served, accepted and stress prices, route data, timers, disagreement pause, grace
    /// window and age limits.
    /// @custom:spec REQ-ORACLE-093, REQ-ORACLE-092, REQ-ORACLE-090
    function getPriceState() external view returns (DebtPriceView memory report);

    /// @notice Accepted price and its source timestamp: the last Live price `poke()` stored.
    /// @return price8 Accepted price, 8 decimals.
    /// @return updatedAt Source timestamp of the accepted price.
    /// @custom:spec REQ-ORACLE-093
    function lastAcceptedPrice() external view returns (uint256 price8, uint64 updatedAt);

    /// @notice Borrow age limit of the served price.
    /// @dev SPEC-ORC-015 for the served route; 0 when the accepted price is served (failed, or Drifting below it). The
    /// RiskModule allows borrowing and
    /// withdraw-with-debt only while the state is Live and `now - servedUpdatedAt <= borrowPriceMaxAge()`.
    /// @return age Seconds.
    /// @custom:spec REQ-ORACLE-093, SPEC-ORC-015
    function borrowPriceMaxAge() external view returns (uint32 age);

    /// @notice Liquidation age limit of the served price.
    /// @dev SPEC-ORC-015 for the served route, with `min(liquidationPriceMaxAge, borrowPriceMaxAge)` for a leg of a
    /// serving alternate; 0 when the accepted price is served. LPVaultSwap repays this reserve only while `liquidationPaused` is false (true while not Live, while the alternate is past its borrow age, and while the sequencer is down) and `now - servedUpdatedAt` is
    /// within it.
    /// @return age Seconds.
    /// @custom:spec REQ-ORACLE-093, REQ-ORACLE-090, SPEC-ORC-015
    function liquidationPriceMaxAge() external view returns (uint32 age);

    /// @notice Evaluates the asset and stores the accepted price, failure and disagreement timers, the grace latch and the
    /// route version.
    /// @dev Preserves: always a price; no role can choose a price. Permissionless; takes no lock; makes only static calls.
    /// The call reverts `InsufficientGas(gasleft(), pokeMinGas)` at entry before any call or write. Then the LPOracle's
    /// poke steps for one token: route-version restart of `disagreeSince`; `failedSince`; `disagreeSince`; accepted price only when
    /// Live and newer; latch only from source timestamps; `seen`; at most one grace window per outage. The RiskModule
    /// pokes every debt reserve of the account that has a DebtOracle before borrow-side checks, LPVaultSwap every such
    /// debt reserve of the account it liquidates, keepers at least once per heartbeat.
    /// @return state The state evaluated in this call.
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-096, REQ-ORACLE-089, REQ-ORACLE-095
    function poke() external returns (PriceState state);

    /// @notice Changes `pokeMinGas`.
    /// @dev `APPLICATION_ADMIN` through the timelock at the normal delay; reverts `PokeMinGasOutOfBounds` outside
    /// `[POKE_MIN_GAS_FLOOR, POKE_MIN_GAS_CEILING]`. Emits `PokeMinGasUpdated`.
    /// @param value New minimum gas.
    /// @custom:spec REQ-ORACLE-098
    function setPokeMinGas(
        uint32 value
    ) external;

    /// @notice Minimum gas for `poke()` and after every caught failure.
    /// @return value Gas.
    /// @custom:spec REQ-ORACLE-098
    function pokeMinGas() external view returns (uint32 value);

    /// @notice The debt asset this feed prices, fixed at `initialize`.
    /// @return asset Token address.
    /// @custom:spec REQ-ORACLE-091
    function ASSET() external view returns (address asset);

    /// @notice MarketRegistry fixed proxy address, read for the asset's routes in force and route version.
    /// @return registry Address.
    /// @custom:spec REQ-ORACLE-091, REQ-ORACLE-094
    function MARKET_REGISTRY() external view returns (address registry);

    /// @notice ParameterStore fixed proxy address, read for feed settings, tolerance, timers and the stress rise.
    /// @return store Address.
    /// @custom:spec REQ-ORACLE-091
    function PARAMETER_STORE() external view returns (address store);

    /// @notice The AvanaTimelock, the only account that may hold `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN`
    /// (implementation constant).
    /// @return timelock Address.
    /// @custom:spec REQ-ORACLE-097
    function TIMELOCK() external view returns (address timelock);
}
