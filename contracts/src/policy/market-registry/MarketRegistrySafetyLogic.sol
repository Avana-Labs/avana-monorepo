// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IFlashSource} from "../../flash/IFlashSource.sol";
import {PauseReason} from "../../types/PauseReason.sol";
import {PauseState} from "../../types/PauseState.sol";
import {IAaveAdapter} from "../aave-adapter/IAaveAdapter.sol";
import {IRiskModule} from "../risk-module/IRiskModule.sol";
import {IMarketRegistry} from "./IMarketRegistry.sol";
import {IMarketRegistryLogic} from "./IMarketRegistryLogic.sol";
import {MarketRegistryStorage} from "./MarketRegistryStorage.sol";
import {BreakerReasons, BreakerScope} from "./types/Breaker.sol";
import {MarketRegistryImmutables, MarketStatus, RiskTier} from "./types/MarketRegistryTypes.sol";

/// @title MarketRegistrySafetyLogic
/// @notice Bodies of the per-Hub pause state and reason, the address freeze and the breaker writes.
/// @dev Runs only by delegatecall from the MarketRegistry, which checks the caller's role first.
// Bodies of IMarketRegistry selectors; this contract inherits no interface piece.
// solhint-disable comprehensive-interface
// Every external call here is a view, so none can re-enter the registry.
// forge-lint: disable-start(reentrancy-events)
contract MarketRegistrySafetyLogic is MarketRegistryStorage, IMarketRegistryLogic {
    constructor(
        MarketRegistryImmutables memory im
    ) MarketRegistryStorage(im) {}

    /// @inheritdoc IMarketRegistryLogic
    function logicConfig() external view override returns (bytes32 kind, bytes32 immutablesHash) {
        return (keccak256("MarketRegistrySafetyLogic"), _IMMUTABLES_HASH);
    }

    function freeze(
        address hub
    ) external {
        _onlyDelegated();
        PauseState st = _stateOf(hub);
        if (st == PauseState.Frozen) revert AlreadyFrozen();
        if (st == PauseState.Paused) revert AlreadyPaused();
        _setState(hub, st, PauseState.Frozen);
    }

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

    function unfreeze(
        address hub
    ) external {
        _onlyDelegated();
        PauseState st = _stateOf(hub);
        if (st == PauseState.None) revert NotFrozen();
        if (st == PauseState.Paused) revert CannotUnfreezeWhilePaused();
        _setState(hub, st, PauseState.None);
    }

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

    function unfreezeAddress(
        address account
    ) external {
        _onlyDelegated();
        if (!_s().frozen[account]) revert AddressNotFrozen(account);
        _s().frozen[account] = false;
        emit AddressUnfrozen(account);
    }

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
            // Each temporary reason keeps its own breach time, so a recovery reopens only what was recorded.
            if (temp & BreakerReasons.ORACLE != 0) {
                l.lastBreachAt[BreakerReasons.breachKey(key, BreakerReasons.ORACLE)] = at;
            }
            if (temp & BreakerReasons.POOL_SHARE != 0) {
                l.lastBreachAt[BreakerReasons.breachKey(key, BreakerReasons.POOL_SHARE)] = at;
            }
            if (temp & BreakerReasons.POOL_DEPTH != 0) {
                l.lastBreachAt[BreakerReasons.breachKey(key, BreakerReasons.POOL_DEPTH)] = at;
            }
            emit GateBreached(key, temp, at);
        }
    }

    function tripMarketBreaker(
        uint256 marketId
    ) external {
        _onlyDelegated();
        if (_s().markets[marketId].status == MarketStatus.None) revert UnknownMarket(marketId);
        _trip(BreakerScope.Market, bytes32(marketId));
    }

    function tripDebtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external {
        _onlyDelegated();
        if (!_s().debtReserves[spoke][debtReserveId].approved) revert UnknownDebtReserve(spoke, debtReserveId);
        _trip(BreakerScope.DebtReserve, _debtKey(spoke, debtReserveId));
    }

    function resetMarketBreaker(
        uint256 marketId
    ) external {
        _onlyDelegated();
        bytes32 key = bytes32(marketId);
        uint32 latched = _s().latched[key];
        if (latched == 0) revert NothingToReset();
        uint32 still = IRiskModule(_RISK_MODULE).liveBreakerReasons(marketId) & latched & BreakerReasons.SECURITY;
        _reset(BreakerScope.Market, key, still);
    }

    function resetDebtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external {
        _onlyDelegated();
        bytes32 key = _debtKey(spoke, debtReserveId);
        uint32 latched = _s().latched[key];
        if (latched == 0) revert NothingToReset();
        uint32 still =
            IRiskModule(_RISK_MODULE).liveDebtBreakerReasons(spoke, debtReserveId) & latched & BreakerReasons.SECURITY;
        _reset(BreakerScope.DebtReserve, key, still);
    }

    function _stateOf(
        address hub
    ) private view returns (PauseState) {
        if (_s().hubTier[hub] == RiskTier.None) revert IMarketRegistry.InvalidHub(hub);
        return _s().pauseState[hub];
    }

    function _setState(
        address hub,
        PauseState previous,
        PauseState current
    ) private {
        _s().pauseState[hub] = current;
        emit PauseStateChanged(hub, previous, current, msg.sender);
    }

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

    function _trip(
        BreakerScope scope,
        bytes32 key
    ) private {
        uint32 next = _s().latched[key] | BreakerReasons.MANUAL;
        _s().latched[key] = next;
        emit BreakerLatched(scope, key, next);
    }

    function _reset(
        BreakerScope scope,
        bytes32 key,
        uint32 still
    ) private {
        if (still != 0) revert ConditionStillHolds(key, still);
        delete _s().latched[key];
        emit BreakerReset(scope, key, msg.sender);
    }

    /// @dev A market key is `bytes32(marketId)` with `marketId < 2^32`; a debt key is a hash.
    function _scopeOf(
        bytes32 key
    ) private pure returns (BreakerScope) {
        return uint256(key) <= type(uint32).max ? BreakerScope.Market : BreakerScope.DebtReserve;
    }

    /// @dev address(0) for no source or a failed read.
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

    /// @dev The flash source's lender is read live, so protection follows a new source.
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
            l.hubTier[a] != RiskTier.None || l.spokes[a].approved || l.knownAvanaFirstLossReserve[a]
                || l.knownPriceSource[a] || l.isDebtAsset[a] || l.integrationIdOf[a] != 0 || l.isPricing[a]
                || l.knownRoute[a]
        ) return true;
        return IAaveAdapter(_AAVE_ADAPTER).walletOf(a) != address(0);
    }
}
