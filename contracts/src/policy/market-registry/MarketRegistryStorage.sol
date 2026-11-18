// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title MarketRegistryStorage
/// @notice Storage layout, immutables, constants and shared checks of the MarketRegistry and its logic contracts.
/// @dev ERC-7201 namespace `avana.storage.MarketRegistry`; logic contracts touch it only by delegatecall.
// ParameterStore feed-definition reads in loops over a route's one or two feeds and a market's tokens; views only.
// forge-lint: disable-start(calls-loop)

import {IAvanaFirstLossReserve} from "../../coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {IAaveV4ExtSload} from "../../interfaces/external/aave/IAaveV4ExtSload.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {ILPOracle} from "../../oracle/ILPOracle.sol";
import {Market, PauseReason, PauseState} from "../../types/MarketTypes.sol";
import {IParameterStore} from "../parameter-store/IParameterStore.sol";
import {FeedDef} from "../parameter-store/types/ParameterStoreTypes.sol";
import {IMarketRegistry} from "./IMarketRegistry.sol";
import {IMarketRegistryBase} from "./IMarketRegistryBase.sol";
import {BreakerReasons} from "./types/Breaker.sol";
import {
    DebtReserveDef,
    MarketRegistryImmutables,
    MarketStatus,
    RiskTier,
    SpokeDef,
    TokenDef,
    WindDownState
} from "./types/MarketRegistryTypes.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

abstract contract MarketRegistryStorage is IMarketRegistryBase {
    struct RouteRecord {
        address route;
        bool active;
    }

    /// @dev A swap-route slot a market has had set, kept for later re-checks.
    struct RouteSlotRef {
        address token;
        address debtAsset;
        uint8 kind;
    }

    struct IntegrationRecord {
        bytes32 key;
        bool finalized;
    }

    /// @custom:storage-location erc7201:avana.storage.MarketRegistry
    struct Layout {
        uint256 marketCount;
        mapping(uint256 marketId => Market) markets;
        mapping(uint256 marketId => uint256) settlementReserve;
        mapping(uint256 marketId => WindDownState) windDown;
        mapping(uint256 marketId => bytes32) keyOf;
        mapping(bytes32 marketKey => uint256) marketOfKey;
        mapping(address vaultToken => uint256) marketOfVaultToken;
        mapping(address lpOracle => uint256) marketOfLpOracle;
        mapping(address hub => mapping(uint256 hubAssetId => uint256)) marketOfHubAsset;
        mapping(address spoke => mapping(uint256 reserveId => uint256)) marketOfReserve;
        mapping(address spoke => uint256[]) marketsOfSpoke;
        address[] hubList;
        mapping(address hub => RiskTier) hubTier;
        mapping(uint32 integrationId => address) integrationLpVault;
        mapping(uint32 integrationId => address) integrationPricing;
        mapping(address lpVault => uint32) integrationIdOf;
        mapping(address pricing => bool) isPricing;
        address[] spokeList;
        mapping(address spoke => SpokeDef) spokes;
        /// @dev Unused; kept for storage layout.
        mapping(bytes32 tripleKey => address) spokeOfTriple;
        address flashSource;
        mapping(address spoke => mapping(uint256 reserveId => DebtReserveDef)) debtReserves;
        mapping(address spoke => uint256[]) debtReserveIds;
        mapping(address firstLossReserve => bool) knownAvanaFirstLossReserve;
        mapping(address priceSource => bool) knownPriceSource;
        mapping(address asset => bool) isDebtAsset;
        mapping(address hub => mapping(address asset => address)) firstLossReserveOf;
        /// @dev Unused (the recorded credit lines and cross-Hub lines); kept for storage layout.
        mapping(address hub => mapping(address asset => uint256[2])) unusedCreditLines;
        mapping(address spoke => mapping(uint256 reserveId => uint256)) unusedRecordedDrawCap;
        mapping(address hub => mapping(address asset => mapping(address spoke => uint256))) unusedCrossHubLineCap;
        mapping(address hub => mapping(address asset => uint256)) unusedCrossHubLineTotal;
        bool unusedCrossHubLinesEnabled;
        mapping(address token => TokenDef) tokens;
        mapping(bytes32 slotKey => RouteRecord) routes;
        mapping(bytes32 slotKey => mapping(address route => bool)) approvedBefore;
        mapping(address route => bool) knownRoute;
        mapping(address hub => PauseState) pauseState;
        mapping(address hub => PauseReason) pauseReason;
        mapping(bytes32 key => uint32) latched;
        mapping(bytes32 key => uint64) lastBreachAt;
        mapping(address account => bool) frozen;
        mapping(address caller => mapping(uint64 hour => uint16)) freezeBuckets;
        // Fields below are appended; earlier fields keep their slots.
        mapping(bytes32 codeHash => bool) approvedSpokeCodeHash;
        mapping(address spoke => bytes32) spokeCodeHash;
        mapping(uint32 integrationId => address[]) integrationContracts;
        mapping(address account => bool) knownIntegrationContract;
        mapping(uint256 marketId => uint32) routeEpoch;
        mapping(uint32 integrationId => IntegrationRecord) integrationRecords;
        mapping(uint256 marketId => RouteSlotRef[]) routeSlots;
        mapping(bytes32 slotId => bool) routeSlotListed;
        // The CDP Spokes with an enabled debt reserve of `asset` on `hub`, whose Aave draw caps the First-Loss Reserve
        // must cover; `coverageRefs` counts each Spoke's enabled reserves of the pair.
        mapping(address hub => mapping(address asset => address[])) coverageSpokes;
        mapping(address hub => mapping(address asset => mapping(address spoke => uint256))) coverageRefs;
        mapping(address hub => mapping(address asset => uint256)) coverageAssetId;
    }

    /// @dev `keccak256(abi.encode(uint256(keccak256("avana.storage.MarketRegistry")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _STORAGE_SLOT = 0x598189494afc908fd08b2b882e497a0aa6147de6d30a80184ae623e37f6d8000;

    /// @dev Most address freezes one caller can make in the 24 one-hour buckets ending with the current hour.
    uint256 internal constant _MAX_FREEZES_PER_DAY = 20;
    uint8 internal constant _ORACLE_DECIMALS = 8;
    uint256 internal constant _BPS = 10_000;
    /// @dev Stand-in for an unbounded draw cap: above any line, yet a sum of them cannot overflow.
    uint256 internal constant _UNBOUNDED_DRAW_CAP = 2 ** 128;
    /// @dev EIP-1967 implementation slot read through the Spoke's `extSload`.
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 internal constant _EMPTY_CODE_HASH = keccak256("");
    /// @dev Offboarding notice before the liquidation-threshold drop and `closeMarket`.
    uint64 internal constant OFFBOARD_NOTICE_SECONDS = 5 days;
    /// @dev Target liquidation threshold after offboarding, as a share of the starting threshold, bps.
    uint16 internal constant OFFBOARD_TARGET_SHARE_BPS = 5000;
    uint8 internal constant _PRIMARY = 0;
    uint8 internal constant _BACKUP = 1;

    address internal immutable _TIMELOCK;
    address internal immutable _AAVE_GOVERNANCE_EXECUTOR;
    address internal immutable _VAULT_TOKEN_FACTORY;
    address internal immutable _AAVE_ADAPTER;
    address internal immutable _COLLATERALIZATION;
    address internal immutable _LOCK;
    address internal immutable _PROXY_MANAGER;
    address internal immutable _PARAMETER_STORE;
    address internal immutable _RISK_MODULE;
    address internal immutable _LP_VAULT_SWAP;
    address internal immutable _PAYOUT_ESCROW;
    address internal immutable _FLASH_LIQUIDATOR;
    address internal immutable _STANDARD_SPOKE_IMPLEMENTATION;
    /// @dev The most markets the registry ever lists, closed and cancelled ones included.
    uint256 internal immutable _MAX_MARKET_COUNT;
    /// @dev `keccak256(abi.encode(immutables))`, compared between the registry and each logic contract.
    bytes32 internal immutable _IMMUTABLES_HASH;
    /// @dev This contract's own address: a logic contract refuses every body unless delegatecalled.
    address internal immutable _SELF;

    constructor(
        MarketRegistryImmutables memory im
    ) {
        if (
            im.timelock == address(0) || im.aaveGovernanceExecutor == address(0) || im.vaultTokenFactory == address(0)
                || im.aaveAdapter == address(0) || im.collateralization == address(0) || im.lock == address(0)
                || im.proxyManager == address(0) || im.parameterStore == address(0) || im.riskModule == address(0)
                || im.lpVaultSwap == address(0) || im.payoutEscrow == address(0) || im.flashLiquidator == address(0)
                || im.standardSpokeImplementation == address(0) || im.maxMarketCount == 0
        ) revert ListingCheckFailed("immutables");
        _TIMELOCK = im.timelock;
        _AAVE_GOVERNANCE_EXECUTOR = im.aaveGovernanceExecutor;
        _VAULT_TOKEN_FACTORY = im.vaultTokenFactory;
        _AAVE_ADAPTER = im.aaveAdapter;
        _COLLATERALIZATION = im.collateralization;
        _LOCK = im.lock;
        _PROXY_MANAGER = im.proxyManager;
        _PARAMETER_STORE = im.parameterStore;
        _RISK_MODULE = im.riskModule;
        _LP_VAULT_SWAP = im.lpVaultSwap;
        _PAYOUT_ESCROW = im.payoutEscrow;
        _FLASH_LIQUIDATOR = im.flashLiquidator;
        _STANDARD_SPOKE_IMPLEMENTATION = im.standardSpokeImplementation;
        _MAX_MARKET_COUNT = im.maxMarketCount;
        _IMMUTABLES_HASH = keccak256(abi.encode(im));
        _SELF = address(this);
    }

    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = _STORAGE_SLOT;
        // Reason: binding a storage pointer to the fixed ERC-7201 slot needs one assignment of `.slot`.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    function _onlyDelegated() internal view {
        if (address(this) == _SELF) revert Unauthorized(msg.sender);
    }

    function _keyFree(
        uint256 marketId
    ) internal view returns (bool) {
        if (marketId == 0) return true;
        MarketStatus st = _s().markets[marketId].status;
        return st == MarketStatus.Cancelled || st == MarketStatus.Closed;
    }

    function _liquidatable(
        MarketStatus st
    ) internal pure returns (bool) {
        return st == MarketStatus.Active || st == MarketStatus.Offboarding;
    }

    /// @dev A relisting bumps `routeEpoch`, so the relisted market gets fresh slots.
    function _slotKey(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) internal view returns (bytes32) {
        uint32 epoch = _s().routeEpoch[marketId];
        if (epoch == 0) return keccak256(abi.encode(marketId, token, debtAsset, kind));
        return keccak256(abi.encode(marketId, token, debtAsset, kind, epoch));
    }

    function _clearBreachTimes(
        Layout storage l,
        bytes32 key
    ) internal {
        delete l.lastBreachAt[key];
        delete l.lastBreachAt[BreakerReasons.breachKey(key, BreakerReasons.ORACLE)];
        delete l.lastBreachAt[BreakerReasons.breachKey(key, BreakerReasons.POOL_DEPTH)];
    }

    function _debtKey(
        address spoke,
        uint256 reserveId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(spoke, reserveId));
    }

    function _routeUsable(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) internal view returns (bool) {
        RouteRecord storage r = _s().routes[_slotKey(marketId, token, debtAsset, kind)];
        return r.route != address(0) && r.active;
    }

    function _routesCover(
        uint256 marketId,
        address debtAsset
    ) internal view returns (bool) {
        address[] storage tokens = _s().markets[marketId].tokens;
        for (uint256 i = 0; i < tokens.length; ++i) {
            address t = tokens[i];
            if (t == debtAsset) continue;
            if (!_routeUsable(marketId, t, debtAsset, _PRIMARY) || !_routeUsable(marketId, t, debtAsset, _BACKUP)) {
                return false;
            }
        }
        return true;
    }

    function _isDebtAssetOf(
        address spoke,
        address asset
    ) internal view returns (bool) {
        uint256[] storage ids = _s().debtReserveIds[spoke];
        for (uint256 i = 0; i < ids.length; ++i) {
            if (_s().debtReserves[spoke][ids[i]].asset == asset) return true;
        }
        return false;
    }

    /// @dev Returns 0 when the route passes, else the failed check's name.
    function _routeLegsCheck(
        address[] memory route
    ) internal view returns (bytes32) {
        if (route.length == 0 || route.length > 2) return "routeLength";
        for (uint256 i = 0; i < route.length; ++i) {
            if (route[i] == address(0)) return "feed";
            FeedDef memory f = IParameterStore(_PARAMETER_STORE).getFeed(route[i]);
            if (f.decimals == 0) return "feed";
            if (f.feedHeartbeat == 0) return "heartbeat";
        }
        if (route.length == 2 && route[0] == route[1]) return "sharedFeed";
        return bytes32(0);
    }

    function _shareFeed(
        address[] memory a,
        address[] memory b
    ) internal pure returns (bool) {
        for (uint256 i = 0; i < a.length; ++i) {
            for (uint256 j = 0; j < b.length; ++j) {
                if (a[i] == b[j]) return true;
            }
        }
        return false;
    }

    /// @dev Listing margin for one route: `10^4 - cfLp` exceeds the summed feed deviation and heartbeat drift.
    function _marginHolds(
        uint256 cfLp,
        address[] memory route
    ) internal view returns (bool) {
        if (cfLp >= _BPS) return false;
        uint256 err = 0;
        for (uint256 i = 0; i < route.length; ++i) {
            FeedDef memory f = IParameterStore(_PARAMETER_STORE).getFeed(route[i]);
            err += uint256(f.feedDeviationThresholdBps) + uint256(f.heartbeatDriftBps);
        }
        return _BPS - cfLp > err;
    }

    function _listingMarginHolds(
        uint256 cfLp,
        address[] memory tokens
    ) internal view returns (bool) {
        for (uint256 i = 0; i < tokens.length; ++i) {
            TokenDef memory t = _s().tokens[tokens[i]];
            if (!_marginHolds(cfLp, t.primaryRoute) || !_marginHolds(cfLp, t.alternateRoute)) return false;
        }
        return true;
    }

    /// @dev Common-mode guard: no two pool tokens share a feed in their alternate routes.
    function _commonModeHolds(
        address[] memory tokens
    ) internal view returns (bool) {
        for (uint256 i = 0; i < tokens.length; ++i) {
            TokenDef memory a = _s().tokens[tokens[i]];
            for (uint256 j = i + 1; j < tokens.length; ++j) {
                TokenDef memory b = _s().tokens[tokens[j]];
                if (_shareFeed(a.alternateRoute, b.alternateRoute)) return false;
            }
        }
        return true;
    }

    /// @dev The Spoke's live draw cap in whole tokens; `MAX_ALLOWED_SPOKE_CAP` maps to `_UNBOUNDED_DRAW_CAP`.
    function _drawCapOf(
        address fundingHub,
        uint256 hubAssetId,
        address spoke
    ) internal view returns (uint256 cap) {
        IAaveV4Hub hub = IAaveV4Hub(fundingHub);
        uint40 raw = hub.getSpokeConfig(hubAssetId, spoke).drawCap;
        cap = raw == hub.MAX_ALLOWED_SPOKE_CAP() ? _UNBOUNDED_DRAW_CAP : uint256(raw);
    }

    /// @dev Sum of the live Aave draw caps of every CDP Spoke with an enabled debt reserve of `asset` on `hub`, whole
    /// tokens; an unbounded cap counts `_UNBOUNDED_DRAW_CAP`, which no First-Loss Reserve covers.
    function _drawCapSum(
        address hub,
        address asset
    ) internal view returns (uint256 sum) {
        Layout storage l = _s();
        address[] storage spokes = l.coverageSpokes[hub][asset];
        uint256 assetId = l.coverageAssetId[hub][asset];
        for (uint256 i = 0; i < spokes.length; ++i) {
            sum += _drawCapOf(hub, assetId, spokes[i]);
        }
    }

    /// @dev Coverage of the summed draw caps: `required` rounds up; on overflow it is `type(uint256).max`, so the
    /// check fails closed.
    function _coverage(
        address hub,
        address asset
    ) internal view returns (uint256 drawCapSum, uint256 required, uint256 funded) {
        drawCapSum = _drawCapSum(hub, asset);
        if (drawCapSum == 0) return (0, 0, 0);
        address cs = _s().firstLossReserveOf[hub][asset];
        funded = cs == address(0) ? 0 : IAvanaFirstLossReserve(cs).fundedBalance();
        uint256 k =
            10 ** uint256(IERC20Metadata(asset).decimals()) * IParameterStore(_PARAMETER_STORE).coverageRatioBps();
        if (k != 0 && drawCapSum > (type(uint256).max - _BPS) / k) return (drawCapSum, type(uint256).max, funded);
        required = (drawCapSum * k + _BPS - 1) / _BPS;
    }

    function _requireCovered(
        address hub,
        address asset
    ) internal view {
        (, uint256 required, uint256 funded) = _coverage(hub, asset);
        if (required > funded) revert IMarketRegistry.CoverageBelowRatio(hub, asset, required, funded);
    }

    function _spokeHashApproved(
        bytes32 codeHash
    ) internal view returns (bool) {
        if (codeHash == bytes32(0) || codeHash == _EMPTY_CODE_HASH) return false;
        return codeHash == _STANDARD_SPOKE_IMPLEMENTATION.codehash || _s().approvedSpokeCodeHash[codeHash];
    }

    /// @dev The implementation behind a recorded Spoke proxy; zeros if unrecorded or unreadable.
    function _spokeImplementation(
        address spoke
    ) internal view returns (address implementation, bytes32 codeHash, bool current) {
        SpokeDef storage sp = _s().spokes[spoke];
        if (!sp.approved) return (address(0), bytes32(0), false);
        try IAaveV4ExtSload(spoke).extSload(_IMPLEMENTATION_SLOT) returns (bytes32 v) {
            implementation = address(uint160(uint256(v)));
        } catch {
            return (address(0), bytes32(0), false);
        }
        codeHash = implementation.codehash;
        current = implementation == sp.implementation && codeHash == _s().spokeCodeHash[spoke];
    }

    function _freezesInWindow(
        address caller,
        uint64 hour
    ) internal view returns (uint256 count) {
        uint64 first = hour >= 23 ? hour - 23 : 0;
        for (uint64 h = first; h <= hour; ++h) {
            count += _s().freezeBuckets[caller][h];
        }
    }

    /// @dev True when the LPOracle is deployed; the stateless oracle has no configuration to check.
    function _oracleConfigPasses(
        address lpOracle
    ) internal view returns (bool) {
        return lpOracle.code.length != 0;
    }

    /// @dev True when the LPOracle answers and its inputs are fresh enough to liquidate.
    function _oracleLive(
        address lpOracle
    ) internal view returns (bool) {
        (bool ok, bytes memory ret) = lpOracle.staticcall(abi.encodeCall(ILPOracle.getPriceStatus, ()));
        if (!ok || ret.length != 128) return false;
        return abi.decode(ret, (ILPOracle.PriceStatus)).liquidationFresh;
    }
}
