// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {OracleConfig} from "../../types/OracleConfig.sol";
import {SecondSource} from "../../types/SecondSource.sol";
import {ILPOracleErrors} from "./ILPOracleErrors.sol";
import {ILPOracleEvents} from "./ILPOracleEvents.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title LPOracleStorage
/// @notice Storage layout, constants and pricing-module hooks of the LPOracle.
abstract contract LPOracleStorage is ILPOracleEvents, ILPOracleErrors {
    /// @notice The aggregator and round a writing call last read for one leg.
    struct Seen {
        address feed;
        uint80 roundId;
        uint64 updatedAt;
    }

    /// @notice The last accepted price, its source timestamp and its valuation prices.
    struct Accepted {
        int256 answer;
        uint64 updatedAt;
        uint128[] prices;
    }

    /// @notice The hourly copy of the accepted price.
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
        // cachedWindow read by the last writing call; used when the config read fails.
        uint32 lastCachedWindow;
        uint8 lastState;
        bool expiredLatched;
        uint64 failedSince;
        uint64 disagreeSince;
        uint64 recoveredAt;
        // Block of the call that stored the accepted price (quote-change cap).
        uint64 acceptedBlock;
        string descriptionText;
        Accepted accepted;
        Checkpoint checkpoint;
        uint64[8] routeVersion;
        uint8[8] lastRoute;
        Seen[2][2][8] seen;
        // Last time every token's `decimals()` matched, and whether the last `poke()` found a mismatch.
        uint64 decimalsCheckedAt;
        bool decimalsInvalid;
        // Valuation prices `initialize` computed `vaultDecimals` at.
        uint128[] listingPrices;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("avana.storage.LPOracle")) - 1)) & ~bytes32(uint256(0xff)).
    bytes32 private constant _STORAGE_SLOT = 0xa4669bdc0496d7e3e6fb1085ffa1fe6df547bcb5a7e81d6911adc6e139bd7300;

    uint8 internal constant DECIMALS = 8;
    /// @notice Explicit gas of an aggregator or uptime-feed read.
    uint256 internal constant FEED_CALL_GAS = 50_000;
    /// @notice Explicit gas of a pool or pricing-module read.
    uint256 internal constant POOL_CALL_GAS = 100_000;
    /// @notice Explicit gas of the pool's `observe` read; covers a cold read over a full observation buffer.
    uint256 internal constant OBSERVE_CALL_GAS = 160_000;
    /// @notice Explicit gas of a registry, store or token read other than the configuration read.
    uint256 internal constant CONFIG_CALL_GAS = 40_000;
    /// @notice Explicit gas of the `getOracleInputs` read, plus `ORACLE_CONFIG_TOKEN_GAS` per token.
    uint256 internal constant ORACLE_CONFIG_BASE_GAS = 150_000;
    uint256 internal constant ORACLE_CONFIG_TOKEN_GAS = 140_000;
    /// @notice Largest change of the fair price from the accepted price within one block, bps.
    uint16 internal constant MAX_QUOTE_CHANGE_BPS = 100;
    /// @notice Interval of the price checkpoint, seconds.
    uint64 internal constant CHECKPOINT_INTERVAL = 3600;
    /// @notice Largest age of the last token-decimals verification at which borrowing is allowed, seconds.
    uint64 internal constant DECIMALS_CHECK_MAX_AGE = 7200;
    /// @notice Price shock a market must survive at listing.
    uint256 internal constant LISTING_SHOCK_FACTOR = 100;
    /// @notice Largest feed heartbeat and heartbeat margin, seconds.
    uint256 internal constant MAX_HEARTBEAT = 86_400;
    uint256 internal constant MAX_HEARTBEAT_MARGIN = 3600;
    /// @notice Smallest price8 a market may reach at the listing shock prices.
    uint256 internal constant MIN_SHOCKED_PRICE8 = 1e6;

    address internal immutable _TIMELOCK;
    /// @dev Seconds per block.
    uint32 internal immutable _CHAIN_BLOCK_TIME;
    /// @dev Bounds of `pokeMinGas`.
    uint32 internal immutable _POKE_MIN_GAS_FLOOR;
    uint32 internal immutable _POKE_MIN_GAS_CEILING;
    /// @dev True on an L2 with a sequencer-uptime feed.
    bool internal immutable _HAS_SEQUENCER;

    /// @dev Reverts `MarketMismatch(0)` for a zero timelock or block time.
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

    function _now64() internal view returns (uint64) {
        return SafeCast.toUint64(block.timestamp);
    }

    function _s() internal pure returns (Layout storage $) {
        // ERC-7201 namespaced storage: the slot is a compile-time constant.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _STORAGE_SLOT
        }
    }

    /// @dev Stores the module's market after checking it against the pool; false refuses initialization.
    function _initMarket(
        bytes calldata market,
        address[] memory tokens
    ) internal virtual returns (bool ok);

    /// @dev Token amounts `units` vault-token units hold at `prices`, rounded down. Never reverts.
    function _composition(
        uint256 units,
        uint256[] memory prices
    ) internal view virtual returns (bool ok, uint256[] memory amounts);

    /// @notice One pricing-module read of the market's pool for an evaluation.
    struct PoolCheck {
        bool readOk;
        // The pool's reentrancy lock is held.
        bool locked;
        // The consistency check could run.
        bool available;
        bool pass;
        uint256 deviationBps;
        // The composition at the valuation prices was clamped to the market's range.
        bool clamped;
    }

    /// @dev The pool's lock state and the consistency check against the pool's TWAP. Never reverts.
    function _poolCheck(
        uint256[] memory quotes,
        uint256[] memory prices,
        uint32 window,
        uint16 toleranceBps
    ) internal view virtual returns (PoolCheck memory p);

    /// @dev Token `index`'s value from its `PoolTwap` second source, 8 decimals. Never reverts.
    function _poolTwapPrice(
        uint256 index,
        SecondSource memory source,
        uint256[] memory quotes
    ) internal view virtual returns (bool ok, uint256 value);

    /// @dev Whether `poolRef` names the market's own pool. Never reverts.
    function _isOwnPool(
        bytes32 poolRef
    ) internal view virtual returns (bool own);

    /// @dev Whether a MarketRegistry record's pool and shape match this module's market. Never reverts.
    function _isOwnMarket(
        uint256 poolWord,
        uint256 poolIdWord,
        uint256 kindWord,
        uint256 tickLowerWord,
        uint256 tickUpperWord
    ) internal view virtual returns (bool own);

    /// @dev The pricing module's listing checks; the caller shifts the bits to `MODULE_CHECKS_SHIFT`.
    function _listingChecks(
        OracleConfig calldata config,
        uint256[] memory quotes
    ) internal view virtual returns (uint256 failedChecks);
}
