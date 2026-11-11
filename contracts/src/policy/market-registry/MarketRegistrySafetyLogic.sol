// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashSource} from "../../flash/IFlashSource.sol";
import {PauseReason} from "../../types/PauseReason.sol";
import {PauseState} from "../../types/PauseState.sol";
import {IAaveAdapterViews} from "../aave-adapter/IAaveAdapterViews.sol";
import {IRiskModuleViews} from "../risk-module/IRiskModuleViews.sol";
import {IMarketRegistryHubs} from "./IMarketRegistryHubs.sol";
import {IMarketRegistryLogic} from "./IMarketRegistryLogic.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {BreakerReasons, BreakerScope} from "./types/Breaker.sol";
import {MarketRegistryImmutables} from "./types/MarketRegistryImmutables.sol";
import {MarketStatus} from "./types/MarketStatus.sol";
import {RiskTier} from "./types/RiskTier.sol";

/// @title MarketRegistrySafetyLogic
/// @notice Bodies of the per-Hub pause state and reason, the address freeze and the breaker writes.
/// @dev Reached only by delegatecall from the MarketRegistry, which checks the caller's role first (guardians
/// immediate, `APPLICATION_ADMIN` through the timelock, `recordBreach` the RiskModule); see `IMarketRegistryLogic`.
/// None of this state is read by repay, debt-free exits, fee collection, zero-credit release, pending settlement or
/// liquidation (INV-081). Every external call is a view.
/// @custom:spec REQ-MREG-001, REQ-MREG-003, REQ-MREG-004, REQ-MREG-017, REQ-MREG-019, REQ-MREG-020, REQ-MREG-021, REQ-MREG-022, REQ-MREG-024, REQ-MREG-025, REQ-MREG-026, REQ-CONFIG-082, INV-049, INV-081, INV-085, Q-227, Q-241, Q-242, Q-252, Q-399, Q-400
// Each function carries the body of a selector declared in an IMarketRegistry piece that the MarketRegistry itself
// implements; this contract inherits no piece, since each piece also declares functions another contract serves.
// solhint-disable comprehensive-interface
// Every external call made here is a view (STATICCALL), so none can re-enter the registry or reorder its events.
// forge-lint: disable-start(reentrancy-events)
contract MarketRegistrySafetyLogic is MarketRegistryStorage, IMarketRegistryLogic {
    /// @notice Fixes the implementation immutables; they must equal the MarketRegistry's.
    /// @param im The per-chain Avana addresses.
    /// @custom:spec REQ-CONFIG-005
    constructor(
        MarketRegistryImmutables memory im
    ) MarketRegistryStorage(im) {}

    /// @inheritdoc IMarketRegistryLogic
    /// @custom:spec REQ-CONFIG-005
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("MarketRegistrySafetyLogic"), _IMMUTABLES_HASH);
    }

    /// @notice Body of `freeze`: None → Frozen.
    /// @custom:spec REQ-MREG-001, REQ-MREG-017
    function freeze(
        address hub
    ) external {
        _onlyDelegated();
        PauseState st = _stateOf(hub);
        if (st == PauseState.Frozen) revert AlreadyFrozen();
        if (st == PauseState.Paused) revert AlreadyPaused();
        _setState(hub, st, PauseState.Frozen);
    }

    /// @notice Body of `freezeAll`: None → Frozen on every recorded Hub; `AlreadyFrozen` when none changes.
    /// @custom:spec REQ-MREG-001, REQ-CONFIG-082
    function freezeAll() external {
        _onlyDelegated();
        address[] storage hubs = _s().hubList;
        bool changed = false;
        for (uint256 i = 0; i < hubs.length; ++i) {
            PauseState st = _s().pauseState[hubs[i]];
            if (st != PauseState.None) continue;
            _setState(hubs[i], st, PauseState.Frozen);
            changed = true;
        }
        if (!changed) revert AlreadyFrozen();
    }

    /// @notice Body of `pause`: None or Frozen → Paused(reason), or Paused(r) → Paused(reason ≠ r).
    /// @custom:spec REQ-MREG-001, REQ-MREG-017, REQ-MREG-024
    function pause(
        address hub,
        PauseReason reason
    ) external {
        _onlyDelegated();
        if (reason == PauseReason.None) revert InvalidPauseReason();
        PauseState st = _stateOf(hub);
        if (st == PauseState.Paused && _s().pauseReason[hub] == reason) revert InvalidPauseReason();
        _pauseOne(hub, st, reason);
    }

    /// @notice Body of `pauseAll`; `AlreadyPaused` when no Hub changes.
    /// @custom:spec REQ-MREG-001, REQ-MREG-024, REQ-CONFIG-082
    function pauseAll(
        PauseReason reason
    ) external {
        _onlyDelegated();
        if (reason == PauseReason.None) revert InvalidPauseReason();
        address[] storage hubs = _s().hubList;
        bool changed = false;
        for (uint256 i = 0; i < hubs.length; ++i) {
            address hub = hubs[i];
            PauseState st = _s().pauseState[hub];
            if (st == PauseState.Paused && _s().pauseReason[hub] == reason) continue;
            _pauseOne(hub, st, reason);
            changed = true;
        }
        if (!changed) revert AlreadyPaused();
    }

    /// @notice Body of `unfreeze`: Frozen → None.
    /// @custom:spec REQ-MREG-001, REQ-MREG-017
    function unfreeze(
        address hub
    ) external {
        _onlyDelegated();
        PauseState st = _stateOf(hub);
        if (st == PauseState.None) revert NotFrozen();
        if (st == PauseState.Paused) revert CannotUnfreezeWhilePaused();
        _setState(hub, st, PauseState.None);
    }

    /// @notice Body of `unpause`: Paused → None, reason cleared.
    /// @custom:spec REQ-MREG-001, REQ-MREG-017, REQ-MREG-024
    function unpause(
        address hub
    ) external {
        _onlyDelegated();
        PauseState st = _stateOf(hub);
        if (st != PauseState.Paused) revert NotPaused();
        PauseReason prev = _s().pauseReason[hub];
        _s().pauseReason[hub] = PauseReason.None;
        _setState(hub, st, PauseState.None);
        emit PauseReasonChanged(hub, prev, PauseReason.None, msg.sender);
    }

    /// @notice Body of `freezeAddress`.
    /// @custom:spec REQ-MREG-019, REQ-MREG-020, REQ-MREG-021, INV-085, Q-242, Q-400, Q-404
    function freezeAddress(
        address account
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        if (l.frozen[account]) revert AddressAlreadyFrozen(account);
        if (_isProtected(account)) revert ProtectedAddress(account);
        // Block timestamps and chain identifiers fit 64 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 hour = uint64(block.timestamp / 3600);
        if (_freezesInWindow(msg.sender, hour) >= _MAX_FREEZES_PER_DAY) revert FreezeLimitReached(msg.sender);
        ++l.freezeBuckets[msg.sender][hour];
        l.frozen[account] = true;
        emit AddressFrozen(account, msg.sender);
    }

    /// @notice Body of `unfreezeAddress`.
    /// @custom:spec REQ-MREG-022, Q-263
    function unfreezeAddress(
        address account
    ) external {
        _onlyDelegated();
        if (!_s().frozen[account]) revert AddressNotFrozen(account);
        _s().frozen[account] = false;
        emit AddressUnfrozen(account);
    }

    /// @notice Body of `recordBreach`.
    /// @custom:spec REQ-MREG-026, REQ-MREG-025, SPEC-BRK-007, SPEC-BRK-008, Q-399
    function recordBreach(
        bytes32 key,
        uint32 reasons
    ) external {
        _onlyDelegated();
        Layout storage l = _s();
        uint32 old = l.latched[key];
        uint32 next = old | (reasons & BreakerReasons.SECURITY);
        if (next != old) {
            l.latched[key] = next;
            emit BreakerLatched(_scopeOf(key), key, next);
        }
        uint32 temp = reasons & BreakerReasons.TEMPORARY;
        if (temp != 0) {
            // Block timestamps and chain identifiers fit 64 bits.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64 at = uint64(block.timestamp);
            l.lastBreachAt[key] = at;
            emit GateBreached(key, temp, at);
        }
    }

    /// @notice Body of `tripMarketBreaker`.
    /// @custom:spec REQ-MREG-025, Q-241
    function tripMarketBreaker(
        uint256 marketId
    ) external {
        _onlyDelegated();
        if (_s().markets[marketId].status == MarketStatus.None) revert UnknownMarket(marketId);
        _trip(BreakerScope.Market, bytes32(marketId));
    }

    /// @notice Body of `tripDebtBreaker`.
    /// @custom:spec REQ-MREG-025, Q-241
    function tripDebtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external {
        _onlyDelegated();
        if (!_s().debtReserves[spoke][debtReserveId].approved) revert UnknownDebtReserve(spoke, debtReserveId);
        _trip(BreakerScope.DebtReserve, _debtKey(spoke, debtReserveId));
    }

    /// @notice Body of `resetMarketBreaker`.
    /// @custom:spec REQ-MREG-025, Q-241
    function resetMarketBreaker(
        uint256 marketId
    ) external {
        _onlyDelegated();
        bytes32 key = bytes32(marketId);
        uint32 latched = _s().latched[key];
        if (latched == 0) revert NothingToReset();
        uint32 still = IRiskModuleViews(_RISK_MODULE).liveBreakerReasons(marketId) & latched & BreakerReasons.SECURITY;
        _reset(BreakerScope.Market, key, still);
    }

    /// @notice Body of `resetDebtBreaker`.
    /// @custom:spec REQ-MREG-025, Q-241
    function resetDebtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external {
        _onlyDelegated();
        bytes32 key = _debtKey(spoke, debtReserveId);
        uint32 latched = _s().latched[key];
        if (latched == 0) revert NothingToReset();
        uint32 still = IRiskModuleViews(_RISK_MODULE).liveDebtBreakerReasons(spoke, debtReserveId) & latched
            & BreakerReasons.SECURITY;
        _reset(BreakerScope.DebtReserve, key, still);
    }

    /// @dev The Hub's state; `InvalidHub` for a Hub not recorded.
    function _stateOf(
        address hub
    ) private view returns (PauseState) {
        if (_s().hubTier[hub] == RiskTier.None) revert IMarketRegistryHubs.InvalidHub(hub);
        return _s().pauseState[hub];
    }

    /// @dev Writes a state change and emits `PauseStateChanged`.
    function _setState(
        address hub,
        PauseState previous,
        PauseState current
    ) private {
        _s().pauseState[hub] = current;
        emit PauseStateChanged(hub, previous, current, msg.sender);
    }

    /// @dev Moves one Hub to Paused(reason), emitting the state change only when the state changes.
    function _pauseOne(
        address hub,
        PauseState st,
        PauseReason reason
    ) private {
        if (st != PauseState.Paused) _setState(hub, st, PauseState.Paused);
        PauseReason prev = _s().pauseReason[hub];
        _s().pauseReason[hub] = reason;
        emit PauseReasonChanged(hub, prev, reason, msg.sender);
    }

    /// @dev Adds `MANUAL` and emits `BreakerLatched` with the bits after the call.
    function _trip(
        BreakerScope scope,
        bytes32 key
    ) private {
        uint32 next = _s().latched[key] | BreakerReasons.MANUAL;
        _s().latched[key] = next;
        emit BreakerLatched(scope, key, next);
    }

    /// @dev Clears the latch unless a latched security condition still holds.
    function _reset(
        BreakerScope scope,
        bytes32 key,
        uint32 still
    ) private {
        if (still != 0) revert ConditionStillHolds(key, still);
        delete _s().latched[key];
        emit BreakerReset(scope, key, msg.sender);
    }

    /// @dev A market key is `bytes32(marketId)` with `marketId < 2^32` (REQ-CONFIG-006); a debt key is a hash.
    function _scopeOf(
        bytes32 key
    ) private pure returns (BreakerScope) {
        return uint256(key) <= type(uint32).max ? BreakerScope.Market : BreakerScope.DebtReserve;
    }

    /// @dev The lender behind a flash source (`IFlashSource.LENDER()`), or address(0) for no source or a failed read.
    function _lenderOf(
        address fs
    ) private view returns (address lender) {
        if (fs == address(0)) return address(0);
        try IFlashSource(fs).LENDER() returns (address x) {
            lender = x;
        } catch {
            lender = address(0);
        }
    }

    /// @dev REQ-MREG-020: the protected set. The flash source's lender (the Aave V3 Pool behind it) is read live, so
    /// a new source moves the protection with it; a source whose `LENDER()` cannot be read protects only itself.
    function _isProtected(
        address a
    ) private view returns (bool) {
        Layout storage l = _s();
        address fs = l.flashSource;
        if (
            a == _TIMELOCK || a == _AAVE_GOVERNANCE_EXECUTOR || a == _AAVE_ADAPTER || a == _COLLATERALIZATION
                || a == _LP_VAULT_SWAP || a == _PROXY_MANAGER || a == address(this) || a == _PARAMETER_STORE
                || a == _RISK_MODULE || a == _PAYOUT_ESCROW || a == _LOCK || a == _VAULT_TOKEN_FACTORY
                || a == _FLASH_LIQUIDATOR || a == fs || a == address(0) || l.knownIntegrationContract[a]
                || a == _lenderOf(fs)
        ) return true;
        uint256 mv = l.marketOfVaultToken[a];
        uint256 mo = l.marketOfLpOracle[a];
        if (
            (mv != 0 && l.markets[mv].status != MarketStatus.Cancelled)
                || (mo != 0 && l.markets[mo].status != MarketStatus.Cancelled)
        ) return true;
        if (
            l.hubTier[a] != RiskTier.None || l.spokes[a].approved || l.knownCoverageSpoke[a] || l.knownPriceSource[a]
                || l.isDebtAsset[a] || l.integrationIdOf[a] != 0 || l.isPricing[a] || l.knownRoute[a]
        ) return true;
        return IAaveAdapterViews(_AAVE_ADAPTER).walletOf(a) != address(0);
    }
}
