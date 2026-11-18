// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaTimelock} from "../../governance/timelock/IAvanaTimelock.sol";
import {Market} from "../../types/MarketTypes.sol";
import {SecondSource, SequencerConfig} from "../../types/OracleTypes.sol";
import {IMarketRegistry} from "../market-registry/IMarketRegistry.sol";
import {MarketStatus} from "../market-registry/types/MarketRegistryTypes.sol";
import {IParameterStoreBase} from "./IParameterStoreBase.sol";
import {FeedDef, GlobalParams, MarketParams, MarketSpeedLimits, SpeedLimit} from "./types/ParameterStoreTypes.sol";

/// @title ParameterStoreStorage
/// @notice Storage layout, immutables, hard bounds and shared checks of the ParameterStore and its logic contracts.
/// @dev Hard and liveness bounds are constants, so each changes only by an upgrade.
abstract contract ParameterStoreStorage is IParameterStoreBase {
    /// @custom:storage-location erc7201:avana.storage.ParameterStore
    struct Layout {
        GlobalParams g;
        SequencerConfig sequencer;
        uint16 poolShareMaxBps;
        uint16 coverageRatioBps;
        mapping(uint256 marketId => MarketParams) market;
        mapping(uint256 marketId => uint256) marketUsdCap;
        mapping(uint256 marketId => uint256) topUpSliceUsd;
        mapping(uint256 marketId => uint256) stressFloorUsd;
        mapping(address hub => mapping(address token => uint256)) tokenUsdCap;
        mapping(bytes32 poolKey => uint16) poolShareOverride;
        mapping(address token => uint16) tokenCollateralFactorBps;
        mapping(address token => uint16) feedAgreementToleranceBps;
        mapping(address token => SecondSource) secondSource;
        mapping(address token => SecondSource) standby;
        mapping(address token => bool) onStandby;
        mapping(address feed => FeedDef) feeds;
        mapping(bytes32 slotKey => uint256) routeDepth;
        mapping(address asset => uint256) floorRoundingAllowance;
        mapping(address hub => mapping(address asset => uint256)) breakerDeficitMax;
        mapping(address asset => uint16) debtStressRiseBps;
        mapping(address spoke => uint256) targetHealthFactor;
        mapping(address spoke => uint16) minLiquidationBonus;
        mapping(bytes32 paramKey => uint64) lastLoosenedAt;
        // Appended members follow; earlier members keep their slots.
        mapping(uint256 marketId => MarketSpeedLimits) marketSpeed;
        mapping(address hub => mapping(address asset => SpeedLimit)) debtSpeed;
        // True for a market with a token that is not USD-pegged, which gets no USD band.
        mapping(uint256 marketId => bool) unbanded;
        // True once `setInitialTokenCap` has written the (Hub, token) cap; stays set when tightened to 0.
        mapping(address hub => mapping(address token => bool)) tokenCapSet;
    }

    /// @dev `keccak256(abi.encode(uint256(keccak256("avana.storage.ParameterStore")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _STORAGE_SLOT = 0x97d60a1f76524429d85918aee5154ffd84c83f78fddb1d1f3d0a0bfeca081800;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant HARD_FLOOR_MAX = 1.25e18;
    uint256 internal constant HF_STEP = 0.03e18;
    uint16 internal constant CAP_STEP_BPS = 15_000;
    uint16 internal constant SLIPPAGE_STEP_BPS = 25;
    uint256 internal constant GRACE_HF_MIN = 0.9e18;
    uint32 internal constant GRACE_DURATION_MAX = 7200;
    uint16 internal constant CONSISTENCY_MIN_BPS = 10;
    uint32 internal constant HEARTBEAT_MARGIN_MAX = 3600;
    uint32 internal constant FEED_HEARTBEAT_MAX = 86_400;
    uint8 internal constant FEED_DECIMALS_MAX = 18;
    uint16 internal constant POOL_RISK_FACTOR_MAX = 9000;
    uint16 internal constant COLLATERAL_FACTOR_MAX = 9999;
    uint256 internal constant MIN_PLEDGE_USD_MAX = 100_000e8;
    uint16 internal constant FEE_SHARE_MAX_BPS = 5000;
    uint16 internal constant FLASH_FEE_MAX_BPS = 100;
    uint16 internal constant SHORTFALL_MAX_BPS = 5000;
    uint64 internal constant GATE_RECOVERY_MIN = 600;
    uint64 internal constant GATE_RECOVERY_MAX = 7200;
    uint16 internal constant STRESS_RISE_MIN_BPS = 100;
    uint16 internal constant STRESS_RISE_MAX_BPS = 5000;
    uint32 internal constant DISAGREEMENT_PAUSE_MAX = 3600;
    uint32 internal constant SEQUENCER_GRACE_MIN = 600;
    uint32 internal constant SEQUENCER_GRACE_MAX = 7200;
    uint256 internal constant USD_CAP_MAX = type(uint128).max;
    /// @dev Value a USD cap below it may be loosened to in one step, so a zero cap can reopen.
    uint256 internal constant USD_CAP_REOPEN_BASE = 1000e8;
    uint16 internal constant SECOND_SOURCE_TOLERANCE_MAX_BPS = 500;
    uint16 internal constant MIN_LIQUIDATION_BONUS_FLOOR = 200;
    uint16 internal constant MAX_QUOTE_CHANGE_BPS = 100;
    uint256 internal constant ONE_USD = 1e8;
    uint256 internal constant ROUNDING_ALLOWANCE_USD_MAX = 1e8;

    /// @dev Scopes of the oracle-configuration re-check: all markets, one token's markets, or one feed's markets.
    uint8 internal constant SCOPE_ALL = 0;
    uint8 internal constant SCOPE_TOKEN = 1;
    uint8 internal constant SCOPE_FEED = 2;

    address internal immutable _TIMELOCK;

    IMarketRegistry internal immutable _REGISTRY;

    uint32 internal immutable _BLOCK_TIME;

    bool internal immutable _HAS_SEQUENCER;

    /// @dev This contract's own address, to detect a direct call to a logic contract.
    address private immutable _SELF;

    /// @notice Fixes the implementation immutables.
    constructor(
        address timelock,
        address marketRegistry,
        uint32 chainBlockTime,
        bool hasSequencer
    ) {
        if (timelock == address(0) || marketRegistry == address(0) || chainBlockTime == 0) revert OutOfBounds();
        _TIMELOCK = timelock;
        _REGISTRY = IMarketRegistry(marketRegistry);
        _BLOCK_TIME = chainBlockTime;
        _HAS_SEQUENCER = hasSequencer;
        _SELF = address(this);
    }

    function _onlyDelegated() internal view {
        if (address(this) == _SELF) revert NotDelegated();
    }

    function _s() internal pure returns (Layout storage $) {
        // ERC-7201 namespaced storage: the slot is a compile-time constant.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := _STORAGE_SLOT
        }
    }

    function _market(
        uint256 marketId
    ) internal view returns (Market memory m) {
        m = _REGISTRY.getMarket(marketId);
        if (m.status == MarketStatus.None) revert UnknownMarket(marketId);
    }

    function _requireMarket(
        uint256 marketId
    ) internal view {
        if (_REGISTRY.getMarket(marketId).status == MarketStatus.None) revert UnknownMarket(marketId);
    }

    /// @dev Markets whose LPOracle reads the configuration: Registered, Active and Offboarding.
    function _configured(
        MarketStatus status
    ) internal pure returns (bool) {
        return status == MarketStatus.Registered || status == MarketStatus.Active || status == MarketStatus.Offboarding;
    }

    /// @dev Markets whose liquidations must stay feasible: Active and Offboarding.
    function _live(
        MarketStatus status
    ) internal pure returns (bool) {
        return status == MarketStatus.Active || status == MarketStatus.Offboarding;
    }

    function _requireHub(
        address hub
    ) internal view {
        if (hub == address(0) || !_REGISTRY.isRecordedHub(hub)) revert UnknownHub(hub);
    }

    function _requireListedToken(
        address token
    ) internal view {
        if (!_REGISTRY.getToken(token).listed) revert TokenNotListed(token);
    }

    function _feed(
        address feed
    ) internal view returns (FeedDef storage def) {
        def = _s().feeds[feed];
        if (def.feedHeartbeat == 0) revert UnknownFeed(feed);
    }

    /// @dev `keccak256(abi.encode(integrationId, pool, poolId))` of a market, as Collateralization keys pool units.
    function _poolKey(
        Market memory m
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(m.integrationId, m.pool, m.poolId));
    }

    function _poolShareOf(
        bytes32 poolKey
    ) internal view returns (uint16) {
        uint16 d = _s().poolShareMaxBps;
        uint16 o = _s().poolShareOverride[poolKey];
        return o != 0 && o < d ? o : d;
    }

    /// @dev Reverts `LoosenTooSoon` within `normalDelay` of the key's previous loosening.
    function _spaceLoosening(
        bytes32 name,
        bytes32 scope
    ) internal {
        bytes32 key = keccak256(abi.encode(name, scope));
        uint256 last = _s().lastLoosenedAt[key];
        if (last != 0) {
            uint256 nextAt = last + IAvanaTimelock(_TIMELOCK).normalDelay();
            if (block.timestamp < nextAt) revert LoosenTooSoon(key, nextAt);
        }
        // Block timestamps stay far below 2^64 seconds.
        // forge-lint: disable-next-line(unsafe-typecast)
        _s().lastLoosenedAt[key] = uint64(block.timestamp);
    }

    function _step(
        bool ok,
        bytes32 name,
        bytes32 scope
    ) internal pure {
        if (!ok) revert LoosenStepTooLarge(keccak256(abi.encode(name, scope)));
    }

    function _a(
        address a
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _pair(
        address a,
        address b
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(a, b));
    }

    function _usdBand(
        uint256 marketId
    ) internal view returns (uint256 low, uint256 high) {
        Layout storage $ = _s();
        if ($.unbanded[marketId]) return (0, type(uint256).max);
        return ($.g.usdBandLow, $.g.usdBandHigh);
    }

    function _hasNonStableToken(
        address[] memory tokens
    ) internal view returns (bool) {
        // A reverting registry reverts the listing (fail closed).
        for (uint256 i = 0; i < tokens.length; ++i) {
            // forge-lint: disable-next-line(calls-loop)
            if (!_REGISTRY.getToken(tokens[i]).isUsdStable) return true;
        }
        return false;
    }
}
