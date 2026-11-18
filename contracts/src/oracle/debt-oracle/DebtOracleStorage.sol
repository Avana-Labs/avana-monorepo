// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title DebtOracleStorage
/// @notice Storage layout and constants of the DebtOracle.
abstract contract DebtOracleStorage {
    /// @notice The aggregator and round a writing call last read for one leg.
    struct Seen {
        address feed;
        uint80 roundId;
        uint64 updatedAt;
    }

    /// @notice The last accepted price of one whole token and the source timestamp of its route.
    struct Accepted {
        // 8-decimal USD; at most MAX_ROUTE_ANSWER.
        uint128 price8;
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
        // cachedWindow read by the last writing call; used when the read fails.
        uint32 lastCachedWindow;
        // debtStressRiseBps read by the last writing call, capped; used when the read fails.
        uint16 lastStressRiseBps;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("avana.storage.DebtOracle")) - 1)) & ~bytes32(uint256(0xff)).
    bytes32 private constant _STORAGE_SLOT = 0x5df50d85f2e1cf43c7e32c2711fc5766191be64ab3bc12b0ee03012ed4ae9e00;

    uint256 internal constant FEED_CALL_GAS = 50_000;
    uint256 internal constant CONFIG_CALL_GAS = 40_000;
    uint32 internal constant POKE_MIN_GAS_FLOOR_VALUE = 600_000;
    uint32 internal constant POKE_MIN_GAS_CEILING_VALUE = 2_000_000;
    /// @dev Upper bound of the stress rise; a larger store value is read as it.
    uint16 internal constant MAX_STRESS_RISE_BPS = 5000;

    /// @dev Reason bits of `DebtPriceView.reasons`.
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

    function _s() internal pure returns (DebtOracleLayout storage $) {
        // ERC-7201 namespaced storage: the slot is a compile-time constant.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _STORAGE_SLOT
        }
    }
}
