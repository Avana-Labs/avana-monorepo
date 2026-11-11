// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title DebtOracleStorage
/// @notice ERC-7201 storage layout and implementation constants of the DebtOracle (2.10 DebtOracle Storage).
/// @dev Every field lives in the proxy's storage under the namespace `avana.storage.DebtOracle`. Only `initialize` and
/// `poke()` write the price, timer, latch, `seen` and route-version fields; `setPokeMinGas` writes `pokeMinGas`.
/// @custom:spec REQ-ORACLE-091, REQ-ORACLE-080, REQ-ORACLE-098
abstract contract DebtOracleStorage {
    /// @notice The aggregator and round a writing call last read for one leg (`REQ-ORACLE-031`).
    /// @custom:spec REQ-ORACLE-031
    struct Seen {
        // Aggregator proxy of the leg when it was read; a different leg in force makes this no record of it.
        address feed;
        // Proxy round identifier.
        uint80 roundId;
        // Chainlink `updatedAt`.
        uint64 updatedAt;
    }

    /// @notice The last accepted price of one whole token and the source timestamp of its route.
    /// @custom:spec REQ-ORACLE-092, REQ-ORACLE-093
    struct Accepted {
        // 8-decimal USD; at most MAX_ROUTE_ANSWER.
        uint128 price8;
        // Route timestamp of the accepted quote.
        uint64 updatedAt;
    }

    /// @custom:storage-location erc7201:avana.storage.DebtOracle
    struct DebtOracleLayout {
        address asset;
        address marketRegistry;
        address parameterStore;
        string descriptionText;
        Accepted accepted;
        uint64 failedSince;
        uint64 disagreeSince;
        bool expiredLatched;
        uint64 recoveredAt;
        // [route: 0 primary, 1 alternate][leg].
        Seen[2][2] seen;
        uint64 routeVersion;
        uint8 lastState;
        uint8 lastRoute;
        uint32 pokeMinGas;
        // cachedWindow read by the last writing call (or initialize); the window of a failure whose cachedWindow
        // read itself fails.
        uint32 lastCachedWindow;
        // debtStressRiseBps read by the last writing call (or initialize), clamped to at most MAX_STRESS_RISE_BPS; the
        // stress rise of an evaluation whose debtStressRiseBps read itself fails.
        uint16 lastStressRiseBps;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("avana.storage.DebtOracle")) - 1)) & ~bytes32(uint256(0xff)).
    bytes32 private constant _STORAGE_SLOT = 0x5df50d85f2e1cf43c7e32c2711fc5766191be64ab3bc12b0ee03012ed4ae9e00;

    /// @dev Explicit gas of an aggregator or uptime-feed read (`SPEC-ORC-023`).
    uint256 internal constant FEED_CALL_GAS = 50_000;
    /// @dev Explicit gas of a MarketRegistry or ParameterStore read (`SPEC-ORC-023`).
    uint256 internal constant CONFIG_CALL_GAS = 40_000;
    /// @dev Bounds of `pokeMinGas` (`REQ-ORACLE-038`); the floor is `W_poke + ceil(64 * FEED_CALL_GAS / 63) +
    /// POST_CALL_GAS` for the worst-case DebtOracle poke.
    uint32 internal constant POKE_MIN_GAS_FLOOR_VALUE = 600_000;
    uint32 internal constant POKE_MIN_GAS_CEILING_VALUE = 2_000_000;
    /// @dev Upper bound of the stress rise `δ` (`SPEC-ORC-018`): a store value above it is read as it, so the Expired
    /// price never exceeds `1.5 × A + 1` whatever the ParameterStore returns.
    uint16 internal constant MAX_STRESS_RISE_BPS = 5000;

    /// @dev Reason bits of `DebtPriceView.reasons` (2.10 DebtOracle Reason bits).
    uint256 internal constant R_NO_ROUTE = 1 << 0;
    uint256 internal constant R_CONFIG_UNAVAILABLE = 1 << 2;
    uint256 internal constant R_DISAGREE = 1 << 3;
    uint256 internal constant R_ON_ALTERNATE = 1 << 9;
    uint256 internal constant R_SOURCE_TIMESTAMP_FAILURE = 1 << 11;
    uint256 internal constant R_DISAGREEMENT_PAUSE = 1 << 12;
    uint256 internal constant R_IN_GRACE = 1 << 13;
    uint256 internal constant R_DISAGREEMENT_EXPIRED = 1 << 14;
    uint256 internal constant R_ALTERNATE_PAST_BORROW_AGE = 1 << 15;
    uint256 internal constant R_ON_STANDBY = 1 << 16;
    uint256 internal constant R_SEQUENCER_DOWN = 1 << 17;
    uint256 internal constant R_SEQUENCER_GRACE = 1 << 18;
    uint256 internal constant R_SECOND_SOURCE_DISAGREE = 1 << 19;

    /// @dev The namespaced layout.
    function _s() internal pure returns (DebtOracleLayout storage $) {
        // The layout sits at its fixed ERC-7201 slot; Solidity places a storage pointer only through assembly.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _STORAGE_SLOT
        }
    }
}
