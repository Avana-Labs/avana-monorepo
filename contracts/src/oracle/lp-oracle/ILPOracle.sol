// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4PriceFeed} from "../../interfaces/external/aave/IAaveV4PriceFeed.sol";
import {OracleConfig} from "../../types/OracleConfig.sol";
import {PriceState} from "../../types/PriceState.sol";
import {PriceStateView} from "../../types/PriceStateView.sol";
import {ILPOracleErrors} from "./ILPOracleErrors.sol";
import {ILPOracleEvents} from "./ILPOracleEvents.sol";
import {InitParams} from "./types/InitParams.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title ILPOracle
/// @notice AMM-neutral price feed for one Avana market: the USD value of one whole vault token with 8 decimals for the
/// CDP Spoke's AaveOracle, and the price state, source timestamps, disagreement pause, recovery grace window, last accepted
/// price and hourly checkpoint that the RiskModule and LPVaultSwap enforce their gates from.
/// @dev The AaveOracle uses this contract as a reserve price source: `setReserveSource` requires `decimals() == 8`, and
/// `getReservePrice` reads `latestAnswer()`; `description()` completes Aave's price-feed interface. The interface extends
/// `IAaveV4PriceFeed`, so those three selectors are identical to the ones AaveOracle calls. The value is fair
/// composition at the oracle price vector: `(a_i) = integration.composition(marketId, 10^d, v)` and
/// `price8 = max(1, sum_i floor(a_i * v_i / 10^d_i))`, where `d` is the vault-token decimals, `d_i` the token decimals
/// and `v_i` the validated Chainlink price of token i capped at `stableCeilingUsd`. It is unhaircut, never computed
/// from spot reserves, never 50/50 and never weights times prices; each `a_i` is floored and reduced by 1 raw unit, so
/// rounding only lowers the price. Example: a Uniswap v3 USDC/USDT market on [-10, 10] with `d = 10` (`SPEC-ORC-005`:
/// the smallest `d` in [6, 18] whose whole token is worth at least 1 USD), v = (1.0000e8, 1.0000e8): each
/// `a_i = floor(10^10 * (1 - 1.0001^-5)) - 1 = 4,998,499` raw 6-decimal units, so `price8 = 2 * 4,998,499 * 1e8 / 1e6 =
/// 9.996998e8`, about 10.00 USD per whole vault token; `d = 9` would give 0.999698e8, below 1 USD. AMM-protocol detail is in an extension interface
/// (`ILPOracleCL` for concentrated liquidity). Each feed sits behind an ERC-1967 proxy (UUPS) whose `_authorizeUpgrade`
/// requires `APPLICATION_ADMIN`, held only by the Avana timelock (normal delay); its address is the Aave price source
/// for life. The arithmetic lives in the internal library LPPriceMath. ERC-7201 namespace
/// `avana.storage.LPOracle`; the implementation constructor calls `_disableInitializers()`. Implementation constants:
/// `stableCeilingUsd`, `DECIMALS = 8`, `POKE_MIN_GAS_FLOOR`, `POKE_MIN_GAS_CEILING`, `MAX_ROUTE_ANSWER`,
/// `LISTING_SHOCK_FACTOR`, `CHECKPOINT_INTERVAL = 3,600`, `MAX_POOL_TOKENS = 8`, `CHAIN_BLOCK_TIME` (12 s on Ethereum,
/// 2 s on Base), `FEED_CALL_GAS = 50,000`, `CONFIG_CALL_GAS = 40,000`, `POOL_CALL_GAS = 100,000` (`SPEC-ORC-023`),
/// `TIMELOCK`. Every evaluation reads its configuration in one call,
/// `ParameterStore.getOracleInputs(address(this), tokens, withSecondSources)`: the routes in force and route versions
/// the store reads from `MarketRegistry.activePriceRoutes(token)` and `priceRouteVersion(token)` in that call, each
/// leg's feed definition, tolerances, consistency-check settings, band, timers, the sequencer check and (for
/// `getPriceState` and `poke`) the second sources, applied exactly; no override exists. Token decimals are those stored
/// at `initialize`; `poke()` re-reads them and a changed or unreadable value fails the market until a `poke()` reads
/// the stored values again (`decimalsStatus`). The quote-change cap is the chain constant 100 bps. A guardian's standby switch reaches the
/// feed only through those routes; a route-version change restarts `disagreeSince` and never `failedSince`.
/// Only `poke()` writes price, timer, latch, route-version or checkpoint storage; no role can push a price. Views never
/// revert except `InsufficientGas`, and return the same result for every caller in a block. No token, ETH or approval
/// ever moves through LPOracle. Repay, fee collection and debt-free withdrawal never read it. A market that is not Live
/// is served at no more than its accepted price: the lower routes during a disagreement, the accepted price while Cached
/// and 1 once Expired (SPEC-ORC-017); its own seizure waits, while the account's other fresh markets stay liquidatable.
/// Freshness is per feed: a leg is fresh while `now - updatedAt <= heartbeat + heartbeatMargin` of that feed. On an L2
/// the chain's sequencer-uptime feed must report up and past its grace period, and every token's independent second
/// source must agree within its tolerance, before `borrowAllowed` is true; an invalid, unreadable or disagreeing
/// second source only leaves its token unconfirmed (token bits 4 and 5, market bit 16), never changes the state, the
/// served price or a timer, and `latestAnswer`, `getPriceState` and `poke` price the market with the same primary
/// computation. The second source never gates
/// liquidation; while the sequencer feed reports down this market's seizure is paused (`liquidationPaused`), during
/// its grace period `inGrace` applies the grace bound, and an unreadable feed blocks borrowing only (REQ-ORACLE-099).
/// `_grantRole` reverts `AdminRoleOnlyTimelock` for `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` and any account other
/// than `TIMELOCK`.
/// @custom:spec REQ-ORACLE-011, REQ-ORACLE-012, REQ-ORACLE-013, REQ-ORACLE-016, REQ-ORACLE-045, REQ-ORACLE-060, REQ-ORACLE-061, REQ-ORACLE-062, REQ-ORACLE-063, REQ-ORACLE-064, REQ-ORACLE-065, REQ-ORACLE-066, REQ-ORACLE-078, REQ-ORACLE-079, REQ-ORACLE-080, REQ-ORACLE-081, REQ-ORACLE-083, REQ-ORACLE-084, REQ-ORACLE-094, REQ-ORACLE-095, REQ-ORACLE-097, REQ-ORACLE-099, REQ-ORACLE-100, REQ-ORACLE-102, REQ-ORACLE-103, REQ-ORACLE-107, SPEC-ORC-005, SPEC-ORC-008, SPEC-ORC-017, SPEC-ORC-023, Q-028, Q-128, Q-208, Q-226, Q-247, Q-248, Q-259, Q-370, Q-321, Q-322, Q-323, Q-324
interface ILPOracle is IAaveV4PriceFeed, IAccessControl, ILPOracleEvents, ILPOracleErrors {
    /// @notice Initializes the feed, runs the listing checks and seeds the accepted price.
    /// @dev Runs once, in the same transaction as the proxy deployment, before the listing batch is scheduled
    /// (`MKT-019`), so the market's identity comes from `params`: the tokens in the configuration's pool order, each
    /// token's `decimals()`, the integration and the pricing module's pool and shape. Stores the identifier,
    /// integration, tokens, decimals, stable flags, description, `pokeMinGas`, the vault-token decimals `d`
    /// (`SPEC-ORC-005`), `seen` for every leg of the configured routes and `routeVersion`; grants
    /// `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN` only to `TIMELOCK` (reverts `AdminRoleOnlyTimelock` if
    /// `params.timelock != TIMELOCK`); reverts `PokeMinGasOutOfBounds`, `ConfigCheckFailed` unless
    /// `checkConfig(params.config) == 0`, and `NotLive` unless the evaluation is Live; stores that price as accepted with
    /// its original timestamp and as the checkpoint with `block.timestamp`, and emits `PriceSeeded` and
    /// `PriceCheckpointed`.
    /// @param params Initialization arguments.
    /// @custom:spec REQ-ORACLE-010, REQ-ORACLE-058, REQ-ORACLE-059, REQ-ORACLE-076, REQ-ORACLE-088, REQ-ORACLE-097, SPEC-ORC-005, MKT-019
    function initialize(
        InitParams calldata params
    ) external;

    /// @notice Served price: USD value of one whole vault token, 8 decimals, always >= 1.
    /// @dev SPEC-ORC-017: the fresh `price8` when Live; `min(fresh, accepted)` when Drifting with no disagreement;
    /// `min(price8 from each token's lower route, capped, accepted)` while some token disagrees; the accepted price when
    /// Cached; 1 when Expired. Never above the accepted price unless Live. Read by the AaveOracle for health factor and
    /// seizure sizing; LPVaultSwap never seizes a Cached, Expired or disagreeing market, so the stress values only lower
    /// the account's health factor. Never reverts except `InsufficientGas`.
    /// @return answer Served price.
    /// @custom:spec REQ-ORACLE-020, REQ-ORACLE-085, REQ-ORACLE-086, REQ-ORACLE-060, REQ-ORACLE-061, SPEC-ORC-008, SPEC-ORC-012, SPEC-ORC-017, Q-247
    function latestAnswer() external view override returns (int256 answer);

    /// @notice Decimals of the served price.
    /// @dev Always 8 for the life of the proxy; checked again after every upgrade.
    /// @return Always 8.
    /// @custom:spec REQ-ORACLE-040, REQ-ORACLE-081
    function decimals() external view override returns (uint8);

    /// @notice Fixed description stored at `initialize`.
    /// @return Description text.
    /// @custom:spec REQ-ORACLE-040
    function description() external view override returns (string memory);

    /// @notice Chainlink-compatible view of the served price with its original source timestamp.
    /// @dev `answer = served`, `startedAt = updatedAt = servedUpdatedAt`, `roundId = answeredInRound =
    /// uint80(servedUpdatedAt)`.
    /// @return roundId uint80(servedUpdatedAt).
    /// @return answer Served price, 8 decimals.
    /// @return startedAt servedUpdatedAt.
    /// @return updatedAt servedUpdatedAt, the oldest input source timestamp.
    /// @return answeredInRound uint80(servedUpdatedAt).
    /// @custom:spec REQ-ORACLE-041, REQ-ORACLE-021, Q-182
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /// @notice Full price-state report computed by the same code as `latestAnswer()` in the same block.
    /// @dev Never reverts except `InsufficientGas`. Consumers that change state call `poke()` first. Every field the
    /// RiskModule, LPVaultSwap, the Lens and keepers read stays in place across upgrades. `liquidationPaused` gates the
    /// seizure of this market only.
    /// @return report State, reasons, served, fresh and accepted prices with timestamps, per-token route data, route
    /// versions and input timestamps, consistency and band data, sequencer and second-source gates, timers,
    /// disagreement pause, grace window and age limits.
    /// @custom:spec REQ-ORACLE-042, REQ-ORACLE-016, REQ-ORACLE-017, REQ-ORACLE-018, REQ-ORACLE-019, REQ-ORACLE-021, REQ-ORACLE-022, REQ-ORACLE-034, REQ-ORACLE-082, REQ-ORACLE-090, SPEC-ORC-013, SPEC-ORC-016, Q-208, Q-247
    function getPriceState() external view returns (PriceStateView memory report);

    /// @notice Capped valuation prices per whole token, for LPVaultSwap's minimum outputs.
    /// @dev The fresh evaluation's prices when the market is not failed, else the accepted ones; the served price is
    /// at most `price8(v)` in every state and equal to it when Live or Cached.
    /// @return prices Valuation price of each token in pool order, 8 decimals.
    /// @return servedUpdatedAt Source timestamp of the served price.
    /// @return state Current price state.
    /// @custom:spec REQ-ORACLE-044, REQ-ORACLE-009, SPEC-ORC-004, Q-247, Q-370
    function getTokenPrices() external view returns (uint256[] memory prices, uint64 servedUpdatedAt, PriceState state);

    /// @notice Borrow age limit of the served price.
    /// @dev SPEC-ORC-015: `min over the legs of each token's route in use of (updatedAt + borrowPriceMaxAge(feed))`
    /// minus `servedUpdatedAt`, so `now - servedUpdatedAt <= borrowPriceMaxAge()` holds exactly when every leg in use is
    /// within its own limit. 0 when the market is failed or the ParameterStore read fails, which makes every age check
    /// fail closed. LPOracle does not enforce it; the RiskModule does for borrow and withdraw-with-debt.
    /// @return age Seconds.
    /// @custom:spec REQ-ORACLE-043, SPEC-ORC-015, Q-182
    function borrowPriceMaxAge() external view returns (uint32 age);

    /// @notice Liquidation age limit of the served price.
    /// @dev SPEC-ORC-015 with each leg's `liquidationPriceMaxAge`, and `min(liquidationPriceMaxAge, borrowPriceMaxAge)`
    /// for a leg of a token served by its alternate (REQ-ORACLE-090); 0 when the market is failed or a configuration read
    /// fails. LPVaultSwap compares `now - servedUpdatedAt` with it.
    /// @return age Seconds.
    /// @custom:spec REQ-ORACLE-043, REQ-ORACLE-090, SPEC-ORC-015, Q-182, Q-274
    function liquidationPriceMaxAge() external view returns (uint32 age);

    /// @notice Evaluates the market and stores the accepted price, failure and disagreement timers and the grace latch.
    /// @dev Permissionless; takes no lock; makes only static calls. The call reverts with `InsufficientGas(gasleft(), pokeMinGas)` at
    /// entry before any call or write. Then, in order: on a route-version change restarts `disagreeSince` and stores the
    /// versions; sets or clears `failedSince`; sets or clears `disagreeSince`; stores `accepted` only when Live and newer
    /// than the stored timestamp; sets `expiredLatched` only from source timestamps; records `seen` aggregators and
    /// rounds; starts at most one grace window per outage, at `now` on a route-version change while latched, from the
    /// newest leg in use when the latch gives no interval, and through the previous phase on a phase's first round; copies the accepted price to the checkpoint once an hour; emits the
    /// matching events. The
    /// RiskModule calls it before its borrow-side checks, Collateralization before `checkPledge`, and LPVaultSwap for
    /// every collateral market of the account before liquidating; keepers call it at least once per heartbeat.
    /// @return state The state evaluated in this call.
    /// @custom:spec REQ-ORACLE-024, REQ-ORACLE-025, REQ-ORACLE-026, REQ-ORACLE-027, REQ-ORACLE-028, REQ-ORACLE-029, REQ-ORACLE-030, REQ-ORACLE-031, REQ-ORACLE-032, REQ-ORACLE-033, REQ-ORACLE-035, REQ-ORACLE-036, REQ-ORACLE-037, REQ-ORACLE-082, REQ-ORACLE-088, REQ-ORACLE-089, REQ-ORACLE-095, SPEC-ORC-014, LIQ-013, MKT-022, Q-241, Q-264, Q-272
    function poke() external returns (PriceState state);

    /// @notice Accepted price and its source timestamp: the last Live price `poke()` stored.
    /// @dev No external call; never reverts. Avana's own valuations of the market (RiskModule caps, minimum pledge value
    /// and restore price, Lens previews) use it, never the stress-served price.
    /// @return price8 Accepted price, 8 decimals.
    /// @return updatedAt Oldest-input source timestamp of the accepted price.
    /// @custom:spec REQ-ORACLE-087, Q-247
    function lastAcceptedPrice() external view returns (uint256 price8, uint64 updatedAt);

    /// @notice Hourly checkpoint of the accepted price, read by the RiskModule's price-drop breaker.
    /// @dev Seeded at `initialize`; `poke()` copies the accepted price with `block.timestamp` once
    /// `now >= at + CHECKPOINT_INTERVAL`. Never a stress-served price.
    /// @return price8 Checkpointed accepted price, 8 decimals.
    /// @return at Block time of the copy.
    /// @custom:spec REQ-ORACLE-088, Q-241
    function priceCheckpoint() external view returns (uint256 price8, uint64 at);

    /// @notice Runs the on-chain listing and configuration checks against a configuration.
    /// @dev Checks one token configuration per market token in pool order, pinned leg decimals and bounds, each leg's
    /// heartbeat and margin, route value range at `minAnswer + 1` and `maxAnswer`, two-leg decimals, the listing shock
    /// bound, no shared aggregators, the feed-agreement lower bound, each second source's kind and tolerance, the
    /// consistency window against the pool's observation buffer at this chain's block time (`twapMinObservations`),
    /// the quote-change cap, the sequencer feed (non-zero on an L2), and the USD band ordering. AMM-protocol listing
    /// guards (exact range, tick alignment, hook flags, minimum supply) are checked by the integration's `bindMarket`.
    /// @param config Configuration to check.
    /// @return failedChecks Bitmap of failed checks; 0 means every on-chain check passes.
    /// @custom:spec REQ-ORACLE-046, REQ-ORACLE-047, REQ-ORACLE-048, REQ-ORACLE-049, REQ-ORACLE-050, REQ-ORACLE-051, REQ-ORACLE-053, REQ-ORACLE-055, REQ-ORACLE-056
    function checkConfig(
        OracleConfig calldata config
    ) external view returns (uint256 failedChecks);

    /// @notice Changes `pokeMinGas`.
    /// @dev `APPLICATION_ADMIN` through the timelock at the normal delay; reverts `PokeMinGasOutOfBounds` outside
    /// `[POKE_MIN_GAS_FLOOR, POKE_MIN_GAS_CEILING]`. Emits `PokeMinGasUpdated`.
    /// @param value New minimum gas.
    /// @custom:spec REQ-ORACLE-038, Q-154, Q-228
    function setPokeMinGas(
        uint32 value
    ) external;

    /// @notice Minimum gas for `poke()` and after every caught failure.
    /// @return value Gas.
    /// @custom:spec REQ-ORACLE-038, REQ-ORACLE-039
    function pokeMinGas() external view returns (uint32 value);

    /// @notice The stored token-decimals result (`REQ-ORACLE-107`).
    /// @dev `poke()` reads every token's `decimals()` and compares it with the value stored at `initialize`. `invalid`
    /// is true while the last `poke()` found one unreadable or different: every evaluation is then failed (reason bit
    /// 1). `verifiedAt` is the last time every value matched; `borrowAllowed` is false once `now - verifiedAt` exceeds
    /// `DECIMALS_CHECK_MAX_AGE` (7,200 s, reason bit 19).
    /// @return invalid A token's decimals were found changed or unreadable by the last `poke()`.
    /// @return verifiedAt Block timestamp of the last successful verification (`initialize` or `poke()`).
    /// @custom:spec REQ-ORACLE-107
    function decimalsStatus() external view returns (bool invalid, uint64 verifiedAt);

    /// @notice MarketRegistry identifier of the market this feed prices, stored at `initialize`.
    /// @return id Market identifier.
    /// @custom:spec REQ-ORACLE-014
    function marketId() external view returns (uint256 id);

    /// @notice The market's AMM integration, used for composition and the consistency check.
    /// @return amm Integration (LPVault) address.
    /// @custom:spec REQ-ORACLE-014, REQ-AMM-CORE-006
    function integration() external view returns (address amm);

    /// @notice The market's tokens in pool order, stored at `initialize`.
    /// @return list Token addresses.
    /// @custom:spec REQ-ORACLE-048
    function tokens() external view returns (address[] memory list);

    /// @notice ParameterStore fixed proxy address whose `getOracleInputs` is read on every evaluation.
    /// @return store Address.
    /// @custom:spec REQ-ORACLE-017, REQ-ORACLE-094, REQ-CONFIG-072
    function parameterStore() external view returns (address store);

    /// @notice MarketRegistry fixed proxy address: maps this feed to its market and supplies each token's routes in force
    /// (`activePriceRoutes`) and route version (`priceRouteVersion`), which the ParameterStore reads for every
    /// evaluation inside `getOracleInputs`.
    /// @return registry Address.
    /// @custom:spec REQ-CONFIG-007, REQ-ORACLE-094, REQ-ORACLE-095
    function marketRegistry() external view returns (address registry);

    /// @notice Valuation ceiling for every USD-pegged stable leg (implementation constant).
    /// @return value 8-decimal USD.
    /// @custom:spec SPEC-ORC-004, Q-177
    function stableCeilingUsd() external view returns (uint256 value);

    /// @notice The chain's AvanaTimelock, the only account that may hold `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN`
    /// (implementation constant).
    /// @return timelock Address.
    /// @custom:spec REQ-ORACLE-097, Q-259
    function TIMELOCK() external view returns (address timelock);
}
