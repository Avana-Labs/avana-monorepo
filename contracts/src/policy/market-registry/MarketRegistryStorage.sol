// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICoverageSpoke} from "../../coverage/coverage-spoke/ICoverageSpoke.sol";
import {IAaveV4ExtSload} from "../../interfaces/external/aave/IAaveV4ExtSload.sol";
import {IAaveV4Hub} from "../../interfaces/external/aave/IAaveV4Hub.sol";
import {Market} from "../../types/Market.sol";
import {PauseReason} from "../../types/PauseReason.sol";
import {PauseState} from "../../types/PauseState.sol";
import {IParameterStoreCoverage} from "../parameter-store/IParameterStoreCoverage.sol";
import {IParameterStoreViews} from "../parameter-store/IParameterStoreViews.sol";
import {FeedDef} from "../parameter-store/types/FeedDef.sol";
import {IMarketRegistryCreditLines} from "./IMarketRegistryCreditLines.sol";
import {IMarketRegistryErrors} from "./IMarketRegistryErrors.sol";
import {IMarketRegistryEvents} from "./IMarketRegistryEvents.sol";
import {IMarketRegistrySafetyEvents} from "./IMarketRegistrySafetyEvents.sol";
import {DebtReserveDef} from "./types/DebtReserveDef.sol";
import {MarketRegistryImmutables} from "./types/MarketRegistryImmutables.sol";
import {MarketStatus} from "./types/MarketStatus.sol";
import {RiskTier} from "./types/RiskTier.sol";
import {SpokeDef} from "./types/SpokeDef.sol";
import {TokenDef} from "./types/TokenDef.sol";
import {WindDownState} from "./types/WindDownState.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title MarketRegistryStorage
/// @notice Storage layout, implementation immutables, constants and shared checks of the MarketRegistry and of its
/// six logic contracts.
/// @dev All mutable state sits in one ERC-7201 namespace, `avana.storage.MarketRegistry`, owned by the registry proxy;
/// a logic contract reads and writes it only while the registry delegatecalls it. The immutables are the per-chain
/// Avana addresses of `MarketRegistryImmutables`; Hubs, integrations, Spokes, debt assets, Coverage Spokes and the
/// flash source are records, so a new one needs no upgrade (REQ-CONFIG-005).
/// @custom:spec REQ-CONFIG-001, REQ-CONFIG-002, REQ-CONFIG-005, REQ-CONFIG-014, Q-226, Q-313
// ParameterStore feed-definition reads in loops over a route's one or two feeds and a market's tokens; views only.
// forge-lint: disable-start(calls-loop)
abstract contract MarketRegistryStorage is IMarketRegistryEvents, IMarketRegistrySafetyEvents, IMarketRegistryErrors {
    /// @dev A swap-route slot.
    struct RouteRecord {
        address route;
        bool active;
    }

    /// @dev One swap-route slot a market has had set, kept so a later integration-contract record can re-check it
    /// (REQ-MREG-035).
    struct RouteSlotRef {
        address token;
        address debtAsset;
        uint8 kind;
    }

    /// @dev The key of an integration's record of AMM protocol contracts and whether governance finalized it
    /// (REQ-MREG-035).
    struct IntegrationRecord {
        bytes32 key;
        bool finalized;
    }

    /// @dev A credit line of (funding Hub, asset): `line` in whole tokens, `drawCapSum` in whole tokens.
    struct CreditLine {
        uint256 line;
        uint256 drawCapSum;
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
        mapping(bytes32 tripleKey => address) spokeOfTriple;
        address flashSource;
        mapping(address spoke => mapping(uint256 reserveId => DebtReserveDef)) debtReserves;
        mapping(address spoke => uint256[]) debtReserveIds;
        mapping(address coverageSpoke => bool) knownCoverageSpoke;
        mapping(address priceSource => bool) knownPriceSource;
        mapping(address asset => bool) isDebtAsset;
        mapping(address hub => mapping(address asset => address)) coverageSpokeOf;
        mapping(address hub => mapping(address asset => CreditLine)) creditLines;
        mapping(address spoke => mapping(uint256 reserveId => uint256)) recordedDrawCap;
        mapping(address hub => mapping(address asset => mapping(address spoke => uint256))) crossHubLineCap;
        mapping(address hub => mapping(address asset => uint256)) crossHubLineTotal;
        bool crossHubLinesEnabled;
        mapping(address token => TokenDef) tokens;
        mapping(address token => uint64) priceRouteVersion;
        mapping(bytes32 slotKey => RouteRecord) routes;
        mapping(bytes32 slotKey => mapping(address route => bool)) approvedBefore;
        mapping(address route => bool) knownRoute;
        mapping(address hub => PauseState) pauseState;
        mapping(address hub => PauseReason) pauseReason;
        mapping(bytes32 key => uint32) latched;
        mapping(bytes32 key => uint64) lastBreachAt;
        mapping(address account => bool) frozen;
        mapping(address caller => mapping(uint64 hour => uint16)) freezeBuckets;
        // Appended 2026-11-11 (MarketRegistry review fixes); earlier fields keep their slots.
        mapping(bytes32 codeHash => bool) approvedSpokeCodeHash;
        mapping(address spoke => bytes32) spokeCodeHash;
        mapping(uint32 integrationId => address[]) integrationContracts;
        mapping(address account => bool) knownIntegrationContract;
        mapping(address token => uint64) standbyCancelledAt;
        mapping(uint256 marketId => uint32) routeEpoch;
        // Appended fields (integration-contract record, REQ-MREG-035); earlier fields keep their slots.
        mapping(uint32 integrationId => IntegrationRecord) integrationRecords;
        mapping(uint256 marketId => RouteSlotRef[]) routeSlots;
        mapping(bytes32 slotId => bool) routeSlotListed;
    }

    /// @dev `keccak256(abi.encode(uint256(keccak256("avana.storage.MarketRegistry")) - 1)) & ~bytes32(uint256(0xff))`.
    bytes32 private constant _STORAGE_SLOT = 0x598189494afc908fd08b2b882e497a0aa6147de6d30a80184ae623e37f6d8000;

    /// @dev Most address freezes one caller can make in the 24 one-hour buckets ending with the current hour
    /// (REQ-MREG-019).
    uint256 internal constant _MAX_FREEZES_PER_DAY = 20;
    /// @dev Decimals of every CDP Spoke's AaveOracle and of every LPOracle and DebtOracle.
    uint8 internal constant _ORACLE_DECIMALS = 8;
    uint256 internal constant _BPS = 10_000;
    /// @dev Draw cap that stands for `MAX_ALLOWED_SPOKE_CAP` (unbounded) in the credit-line sum: above any line, small
    /// enough that a sum over every drawing Spoke cannot overflow (SPEC-CAP-010).
    uint256 internal constant _UNBOUNDED_DRAW_CAP = 2 ** 128;
    /// @dev EIP-1967 implementation slot read through the Spoke's `extSload` (REQ-CONFIG-074).
    bytes32 internal constant _IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev Code hash of an account with no code: never an approved Spoke implementation (REQ-CONFIG-074).
    bytes32 internal constant _EMPTY_CODE_HASH = keccak256("");
    /// @dev How long the Aave DAO's `cancelStandbySwitch` keeps the guardians from switching the same token again: the
    /// normal delay, so a guardian cannot re-apply what the DAO undid before a timelocked review could (REQ-MREG-028).
    uint64 internal constant _STANDBY_RESWITCH_COOLDOWN = 5 days;
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
    /// @dev The most markets the registry ever lists, closed and cancelled ones included (REQ-MREG-034).
    uint256 internal immutable _MAX_MARKET_COUNT;
    /// @dev `keccak256(abi.encode(immutables))`, compared between the registry and each logic contract.
    bytes32 internal immutable _IMMUTABLES_HASH;
    /// @dev This contract's own address: a logic contract refuses every body unless delegatecalled.
    address internal immutable _SELF;

    /// @notice Fixes the implementation immutables; every address and the market-count limit must be non-zero.
    /// @param im The per-chain Avana addresses and the market-count limit.
    /// @custom:spec REQ-CONFIG-005, REQ-MREG-034
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

    /// @dev The registry's ERC-7201 storage.
    function _s() internal pure returns (Layout storage l) {
        bytes32 slot = _STORAGE_SLOT;
        // Reason: binding a storage pointer to the fixed ERC-7201 slot needs one assignment of `.slot`.
        // solhint-disable-next-line no-inline-assembly
        assembly ("memory-safe") {
            l.slot := slot
        }
    }

    /// @dev Reverts when a logic contract is called directly instead of by the registry's delegatecall.
    function _onlyDelegated() internal view {
        if (address(this) == _SELF) revert Unauthorized(msg.sender);
    }

    /// @dev True when a key mapped to `marketId` is free: unmapped, or held by a Cancelled or Closed market
    /// (REQ-CONFIG-007).
    function _keyFree(
        uint256 marketId
    ) internal view returns (bool) {
        if (marketId == 0) return true;
        MarketStatus st = _s().markets[marketId].status;
        return st == MarketStatus.Cancelled || st == MarketStatus.Closed;
    }

    /// @dev True for a market that can still be liquidated (Active or Offboarding).
    function _liquidatable(
        MarketStatus st
    ) internal pure returns (bool) {
        return st == MarketStatus.Active || st == MarketStatus.Offboarding;
    }

    /// @dev Key of one swap-route slot of the market's current registration: a relisting raises `routeEpoch`, so the
    /// routes, previously approved routes and statuses of a cancelled registration are never read again
    /// (REQ-MREG-030). The first registration keeps the epoch-free key.
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

    /// @dev Breaker key of a debt reserve (REQ-MREG-025).
    function _debtKey(
        address spoke,
        uint256 reserveId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(spoke, reserveId));
    }

    /// @dev True when the slot holds a route with status Active.
    function _routeUsable(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) internal view returns (bool) {
        RouteRecord storage r = _s().routes[_slotKey(marketId, token, debtAsset, kind)];
        return r.route != address(0) && r.active;
    }

    /// @dev True when every pool token of the market other than `debtAsset` has a usable primary and backup route
    /// into `debtAsset` (REQ-CONFIG-039).
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

    /// @dev True when `asset` is the asset of an enabled debt reserve of `spoke`.
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

    /// @dev Route-leg checks of REQ-CONFIG-021 on one route: one or two non-zero feeds, each with a ParameterStore
    /// feed definition and a heartbeat. Returns 0 when it passes, else the failed check's name.
    function _routeLegsCheck(
        address[] memory route
    ) internal view returns (bytes32) {
        if (route.length == 0 || route.length > 2) return "routeLength";
        for (uint256 i = 0; i < route.length; ++i) {
            if (route[i] == address(0)) return "feed";
            FeedDef memory f = IParameterStoreViews(_PARAMETER_STORE).getFeed(route[i]);
            if (f.decimals == 0) return "feed";
            if (f.feedHeartbeat == 0) return "heartbeat";
        }
        if (route.length == 2 && route[0] == route[1]) return "sharedFeed";
        return bytes32(0);
    }

    /// @dev True when two feed lists share an address.
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

    /// @dev SPEC-CF-004 for one route: `10^4 - cfLp > Σ (feedDeviationThresholdBps + heartbeatDriftBps)`.
    function _marginHolds(
        uint256 cfLp,
        address[] memory route
    ) internal view returns (bool) {
        if (cfLp >= _BPS) return false;
        uint256 err = 0;
        for (uint256 i = 0; i < route.length; ++i) {
            FeedDef memory f = IParameterStoreViews(_PARAMETER_STORE).getFeed(route[i]);
            err += uint256(f.feedDeviationThresholdBps) + uint256(f.heartbeatDriftBps);
        }
        return _BPS - cfLp > err;
    }

    /// @dev SPEC-CF-004 for every route of every pool token of a market (the standby included, since a guardian can
    /// put it in place of either slot at once).
    function _listingMarginHolds(
        uint256 cfLp,
        address[] memory tokens
    ) internal view returns (bool) {
        for (uint256 i = 0; i < tokens.length; ++i) {
            TokenDef memory t = _s().tokens[tokens[i]];
            if (!_marginHolds(cfLp, t.primaryRoute) || !_marginHolds(cfLp, t.alternateRoute)) return false;
            if (!_marginHolds(cfLp, t.standbyRoute)) return false;
        }
        return true;
    }

    /// @dev REQ-CONFIG-034 with the standby counted as a possible alternate: for every pair of distinct pool tokens,
    /// no feed of one token's alternate or standby route is a feed of the other's.
    function _commonModeHolds(
        address[] memory tokens
    ) internal view returns (bool) {
        for (uint256 i = 0; i < tokens.length; ++i) {
            TokenDef memory a = _s().tokens[tokens[i]];
            for (uint256 j = i + 1; j < tokens.length; ++j) {
                TokenDef memory b = _s().tokens[tokens[j]];
                if (_shareFeed(a.alternateRoute, b.alternateRoute) || _shareFeed(a.alternateRoute, b.standbyRoute)) {
                    return false;
                }
                if (_shareFeed(a.standbyRoute, b.alternateRoute) || _shareFeed(a.standbyRoute, b.standbyRoute)) {
                    return false;
                }
            }
        }
        return true;
    }

    /// @dev The Spoke's live `drawCap` on (fundingHub, hubAssetId) in whole tokens, with `MAX_ALLOWED_SPOKE_CAP`
    /// counted as unbounded (SPEC-CAP-010).
    function _drawCapOf(
        address fundingHub,
        uint256 hubAssetId,
        address spoke
    ) internal view returns (uint256 cap) {
        IAaveV4Hub hub = IAaveV4Hub(fundingHub);
        uint40 raw = hub.getSpokeConfig(hubAssetId, spoke).drawCap;
        cap = raw == hub.MAX_ALLOWED_SPOKE_CAP() ? _UNBOUNDED_DRAW_CAP : uint256(raw);
    }

    /// @dev REQ-CONFIG-081 coverage of a line: `required = ⌈line × 10^dec × coverageRatioBps / 10^4⌉` base units (the
    /// smallest balance that passes `line × 10^dec × coverageRatioBps ≤ fundedBalance × 10^4`) and `funded`, the asset
    /// balance of `coverageSpokeOf(hub, asset)` (0 when the pair has none). A line of 0 needs nothing. A line so large
    /// that `line × 10^dec × coverageRatioBps` would not fit 256 bits requires `type(uint256).max`, which no balance
    /// meets, so the test fails closed instead of overflowing.
    function _coverage(
        address hub,
        address asset,
        uint256 line
    ) internal view returns (uint256 required, uint256 funded) {
        if (line == 0) return (0, 0);
        address cs = _s().coverageSpokeOf[hub][asset];
        funded = cs == address(0) ? 0 : ICoverageSpoke(cs).fundedBalance();
        uint256 k = 10 ** uint256(IERC20Metadata(asset).decimals())
            * IParameterStoreCoverage(_PARAMETER_STORE).coverageRatioBps();
        if (k != 0 && line > (type(uint256).max - _BPS) / k) return (type(uint256).max, funded);
        required = (line * k + _BPS - 1) / _BPS;
    }

    /// @dev Reverts `CoverageBelowRatio` unless the Coverage Spoke of `(hub, asset)` covers `line` (REQ-CONFIG-081).
    function _requireCovered(
        address hub,
        address asset,
        uint256 line
    ) internal view {
        (uint256 required, uint256 funded) = _coverage(hub, asset, line);
        if (required > funded) revert IMarketRegistryCreditLines.CoverageBelowRatio(hub, asset, required, funded);
    }

    /// @dev True for a code hash governance approved for a CDP Spoke implementation: the hash of
    /// `STANDARD_SPOKE_IMPLEMENTATION` or one added by `approveSpokeCodeHash`; never 0 or the empty-code hash
    /// (REQ-CONFIG-074).
    function _spokeHashApproved(
        bytes32 codeHash
    ) internal view returns (bool) {
        if (codeHash == bytes32(0) || codeHash == _EMPTY_CODE_HASH) return false;
        return codeHash == _STANDARD_SPOKE_IMPLEMENTATION.codehash || _s().approvedSpokeCodeHash[codeHash];
    }

    /// @dev The implementation behind a Spoke proxy: the address in the proxy's ERC-1967 implementation slot, read
    /// through the Spoke's `extSload` (which runs in the proxy's storage), and its code hash; all zero for a Spoke that
    /// is not recorded (so no call is made to an address that may hold no code) or when the read fails. `current` is true only for an approved Spoke whose slot still holds the recorded implementation with the
    /// code hash recorded when `deployCdpSpoke` approved it (REQ-CONFIG-074, REQ-CONFIG-016); a recorded hash was
    /// approved at that time, and approvals are never withdrawn.
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

    /// @dev REQ-MREG-019: the caller's freezes in the 24 one-hour buckets ending with `hour` (hours `⌊t / 3,600⌋`), so
    /// the window spans between 23 and 24 hours of wall-clock time.
    function _freezesInWindow(
        address caller,
        uint64 hour
    ) internal view returns (uint256 count) {
        uint64 first = hour >= 23 ? hour - 23 : 0;
        for (uint64 h = first; h <= hour; ++h) {
            count += _s().freezeBuckets[caller][h];
        }
    }
}
// forge-lint: disable-end(calls-loop)
