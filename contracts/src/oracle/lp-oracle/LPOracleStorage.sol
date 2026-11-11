// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {ILPOracleErrors} from "./ILPOracleErrors.sol";
import {ILPOracleEvents} from "./ILPOracleEvents.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LPOracleStorage
/// @notice ERC-7201 storage, implementation constants and the pricing-module hooks of the LPOracle base (2.10 Storage).
/// @dev Namespace `avana.storage.LPOracle`; every field lives in the proxy. The pricing module of each AMM protocol
/// (concentrated liquidity: `LPOracleCL`) implements the hooks as internal functions and keeps its own market struct
/// (pool and exact shape) in its own namespace. Immutables are per chain and per implementation: `TIMELOCK`,
/// `CHAIN_BLOCK_TIME`, `POKE_MIN_GAS_FLOOR`, `POKE_MIN_GAS_CEILING` and whether the chain runs an L2 sequencer.
/// @custom:spec REQ-ORACLE-080, REQ-ORACLE-097, REQ-ORACLE-103, REQ-ORACLE-107, SPEC-ORC-023, Q-240, Q-321
abstract contract LPOracleStorage is ILPOracleEvents, ILPOracleErrors {
    /// @notice The aggregator and round a writing call last read for one leg (`REQ-ORACLE-031`).
    struct Seen {
        address feed;
        uint80 roundId;
        uint64 updatedAt;
    }

    /// @notice The last accepted price, its oldest-input source timestamp and its valuation price vector.
    struct Accepted {
        int256 answer;
        uint64 updatedAt;
        uint128[] prices;
    }

    /// @notice The hourly copy of the accepted price and the block time of the copy (`REQ-ORACLE-088`).
    struct Checkpoint {
        uint128 price8;
        uint64 at;
    }

    /// @custom:storage-location erc7201:avana.storage.LPOracle
    struct Layout {
        address parameterStore;
        address marketRegistry;
        address integration;
        uint256 marketId;
        address[] tokens;
        uint8[] tokenDecimals;
        bool[] isUsdStable;
        uint8 vaultDecimals;
        uint32 pokeMinGas;
        // cachedWindow read by the last writing call; the window of a failure whose configuration read fails.
        uint32 lastCachedWindow;
        uint8 lastState;
        bool expiredLatched;
        uint64 failedSince;
        uint64 disagreeSince;
        uint64 recoveredAt;
        // block.number of the call that stored the accepted price (quote-change cap, REQ-ORACLE-103).
        uint64 acceptedBlock;
        string descriptionText;
        Accepted accepted;
        Checkpoint checkpoint;
        uint64[8] routeVersion;
        uint8[8] lastRoute;
        Seen[2][2][8] seen;
        // Last time a `poke()` (or `initialize`) read every token's `decimals()` equal to `tokenDecimals`, and whether
        // the last `poke()` found a token's decimals unreadable or different (`REQ-ORACLE-107`).
        uint64 decimalsCheckedAt;
        bool decimalsInvalid;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("avana.storage.LPOracle")) - 1)) & ~bytes32(uint256(0xff)).
    bytes32 private constant _STORAGE_SLOT = 0xa4669bdc0496d7e3e6fb1085ffa1fe6df547bcb5a7e81d6911adc6e139bd7300;

    /// @notice Decimals of every price the feed serves.
    uint8 internal constant DECIMALS = 8;
    /// @notice Explicit gas of an aggregator or uptime-feed read (`SPEC-ORC-023`).
    uint256 internal constant FEED_CALL_GAS = 50_000;
    /// @notice Explicit gas of a pool or pricing-module read (`SPEC-ORC-023`).
    uint256 internal constant POOL_CALL_GAS = 100_000;
    /// @notice Explicit gas of a registry, store or token read other than `getOracleConfig` (`SPEC-ORC-023`).
    uint256 internal constant CONFIG_CALL_GAS = 40_000;
    /// @notice Explicit gas of the configuration read `getOracleInputs`: `ORACLE_CONFIG_BASE_GAS + n *
    /// ORACLE_CONFIG_TOKEN_GAS` (`SPEC-ORC-023`); the store resolves the market and, per token, the routes in force
    /// through the MarketRegistry, every leg's feed definition and the second source in that call. A token with two
    /// two-leg routes and an oracle-network second source measures 90,500 gas cold; the market part about 34,000. The
    /// listing-time `getMarket` read of `checkConfig` takes `ORACLE_CONFIG_BASE_GAS`.
    uint256 internal constant ORACLE_CONFIG_BASE_GAS = 150_000;
    uint256 internal constant ORACLE_CONFIG_TOKEN_GAS = 140_000;
    /// @notice Quote-change cap of `REQ-ORACLE-103`, bps: a chain-wide constant (1 %), the value the ParameterStore
    /// serves as `maxQuoteChangeBps` for every market.
    uint16 internal constant MAX_QUOTE_CHANGE_BPS = 100;
    /// @notice Interval of the price checkpoint, seconds (`REQ-ORACLE-088`).
    uint64 internal constant CHECKPOINT_INTERVAL = 3600;
    /// @notice Largest age of the last successful token-decimals verification at which `borrowAllowed` may be true,
    /// seconds (`REQ-ORACLE-107`): two keeper intervals of `REQ-ORACLE-037`, so one missed keeper run blocks nothing
    /// and a stopped keeper blocks new borrowing and withdraw-with-debt after two hours.
    uint64 internal constant DECIMALS_CHECK_MAX_AGE = 7200;
    /// @notice Price shock a market must survive at listing (`REQ-ORACLE-050`).
    uint256 internal constant LISTING_SHOCK_FACTOR = 100;
    /// @notice Largest feed heartbeat and heartbeat margin a leg may carry, seconds (`REQ-ORACLE-054`, `SPEC-ORC-019`).
    uint256 internal constant MAX_HEARTBEAT = 86_400;
    uint256 internal constant MAX_HEARTBEAT_MARGIN = 3600;
    /// @notice Smallest price8 a market may reach at the listing shock prices (`REQ-ORACLE-050`).
    uint256 internal constant MIN_SHOCKED_PRICE8 = 1e6;

    /// @dev The chain's AvanaTimelock, the only holder of `DEFAULT_ADMIN_ROLE` and `APPLICATION_ADMIN`.
    address internal immutable _TIMELOCK;
    /// @dev Seconds per block (12 on Ethereum, 2 on Base).
    uint32 internal immutable _CHAIN_BLOCK_TIME;
    /// @dev Bounds of `pokeMinGas` (`REQ-ORACLE-038`).
    uint32 internal immutable _POKE_MIN_GAS_FLOOR;
    uint32 internal immutable _POKE_MIN_GAS_CEILING;
    /// @dev True on an L2 whose sequencer-uptime feed every evaluation reads (`REQ-ORACLE-099`).
    bool internal immutable _HAS_SEQUENCER;

    /// @notice Fixes the implementation constants of the chain.
    /// @dev Reverts `PokeMinGasOutOfBounds` for a zero floor or a ceiling below the floor; the timelock and block time
    /// must be non-zero (`MarketMismatch(0)` otherwise), so a misdeployed implementation fails closed.
    /// @param timelock The chain's AvanaTimelock.
    /// @param chainBlockTime Seconds per block.
    /// @param pokeMinGasFloor `POKE_MIN_GAS_FLOOR` from the measured worst-case poke (`SPEC-ORC-023`).
    /// @param pokeMinGasCeiling `POKE_MIN_GAS_CEILING`.
    /// @param hasSequencer True on an L2 with a sequencer-uptime feed.
    /// @custom:spec REQ-ORACLE-038, REQ-ORACLE-097, SPEC-ORC-022, SPEC-ORC-023
    constructor(
        address timelock,
        uint32 chainBlockTime,
        uint32 pokeMinGasFloor,
        uint32 pokeMinGasCeiling,
        bool hasSequencer
    ) {
        if (timelock == address(0) || chainBlockTime == 0) revert MarketMismatch(0);
        if (pokeMinGasFloor == 0 || pokeMinGasCeiling < pokeMinGasFloor) {
            revert PokeMinGasOutOfBounds(pokeMinGasCeiling);
        }
        _TIMELOCK = timelock;
        _CHAIN_BLOCK_TIME = chainBlockTime;
        _POKE_MIN_GAS_FLOOR = pokeMinGasFloor;
        _POKE_MIN_GAS_CEILING = pokeMinGasCeiling;
        _HAS_SEQUENCER = hasSequencer;
    }

    /// @dev `block.timestamp` as stored (`uint64`; reached only after the year 2^64 s).
    function _now64() internal view returns (uint64) {
        return SafeCast.toUint64(block.timestamp);
    }

    /// @dev The ERC-7201 namespace.
    function _s() internal pure returns (Layout storage $) {
        // ERC-7201 namespaced storage: the slot is a compile-time constant.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _STORAGE_SLOT
        }
    }

    // ─── Pricing-module hooks (REQ-ORACLE-103) ───

    /// @dev Stores the module's market (pool and exact shape) from `market` and checks it against the pool's own
    /// answers, including the pool's token order equal to `tokens`; false refuses the initialization.
    /// @custom:spec REQ-ORACLE-048, REQ-ORACLE-058, REQ-ORACLE-103
    function _initMarket(
        bytes calldata market,
        address[] memory tokens
    ) internal virtual returns (bool ok);

    /// @dev Token amounts `units` vault-token units hold at the price vector `prices`, raw units, rounded down; `ok` is
    /// false for a failed or malformed read (reason bit 1). Never reverts.
    /// @custom:spec REQ-ORACLE-011, REQ-ORACLE-103, SPEC-ORC-007
    function _composition(
        uint256 units,
        uint256[] memory prices
    ) internal view virtual returns (bool ok, uint256[] memory amounts);

    /// @dev Whether the pool's reentrancy lock is held (false for an AMM protocol without one); `readOk` false for a
    /// failed read (reason bit 1). Never reverts.
    /// @custom:spec REQ-ORACLE-103
    function _poolLocked() internal view virtual returns (bool readOk, bool locked);

    /// @dev The consistency check of the quotes against the AMM protocol's time-weighted price over `window`, and
    /// whether the composition at `prices` was clamped to the market's shape (reason bit 6). `available` false gives
    /// reason bit 5, `pass` false bit 4. Never reverts.
    /// @custom:spec REQ-ORACLE-014, REQ-ORACLE-103, REQ-ORACLE-104
    function _consistency(
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceBps
    ) internal view virtual returns (bool available, bool pass, uint256 deviationBps, bool clamped);

    /// @dev The value of token `index` from its `PoolTwap` second source: the time-weighted price of the deep pool
    /// times the reference token's validated quote, 8 decimals; `ok` false when unavailable. Never reverts.
    /// @custom:spec SPEC-ORC-020, REQ-ORACLE-100
    function _poolTwapPrice(
        uint256 index,
        SecondSource memory source,
        uint256[] memory quotes
    ) internal view virtual returns (bool ok, uint256 value);

    /// @dev The pricing module's listing checks on `config` at the current quotes; returned bits are shifted to
    /// `MODULE_CHECKS_SHIFT` and above by the caller.
    /// @custom:spec REQ-ORACLE-046, REQ-ORACLE-048, REQ-ORACLE-055, REQ-ORACLE-105
    function _listingChecks(
        OracleConfig calldata config,
        uint256[] memory quotes
    ) internal view virtual returns (uint256 failedChecks);
}
