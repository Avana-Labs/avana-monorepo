// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketRegistry} from "../../../src/policy/market-registry/MarketRegistry.sol";
import {BreakerReasons} from "../../../src/policy/market-registry/types/Breaker.sol";
import {MarketRegistryFixture} from "../../utils/fixtures/MarketRegistryFixture.sol";

/// @title MarketRegistryStopsHandler
/// @notice Stops handler of the market-registry suite: address freezes and unfreezes by both guardians, the timelock
/// and a stranger over twelve wallets and the protected Avana addresses; RiskModule breach reports with any reasons;
/// manual trips and resets of the market and debt breakers while the RiskModule's live conditions change; time warps.
/// A model of REQ-MREG-019, REQ-MREG-020, REQ-MREG-022, REQ-MREG-025 and REQ-MREG-026 predicts each outcome; ghosts
/// count every departure, and the suite also checks the 24-bucket freeze bound per caller directly.
contract MarketRegistryStopsHandler is MarketRegistryFixture {
    uint256 public constant WALLETS = 12;
    uint256 public constant ACTORS = 4;

    uint256 public marketId;
    bytes32 public mKey;
    bytes32 public dKey;
    address[] internal _protected;
    /// @dev 0 Emergency Guardian, 1 Aave Protocol Guardian, 2 timelock, 3 stranger.
    address[ACTORS] internal _actors;

    mapping(address => bool) public modelFrozen;
    /// @dev Successful freezes per caller per hour bucket.
    mapping(address => mapping(uint256 => uint256)) public modelBuckets;
    mapping(bytes32 => uint32) public modelLatched;
    mapping(bytes32 => uint64) public modelBreachAt;

    uint256 public calls;
    uint256 public outcomeMismatch;
    uint256 public frozenMismatch;
    uint256 public latchMismatch;
    uint256 public protectedFrozen;

    function init() external {
        _setUpWorld();
        (marketId,,) = _activeMarket();
        mKey = bytes32(marketId);
        dKey = keccak256(abi.encode(address(spoke), GHO_RESERVE));
        _actors = [emergencyGuardian, aaveGuardian, address(timelock), attacker];
        _protected.push(address(timelock));
        _protected.push(aaveGovernanceExecutor);
        _protected.push(address(registry));
        _protected.push(address(hub));
        _protected.push(address(spoke));
        _protected.push(address(gho));
        _protected.push(address(flash));
        _protected.push(aaveV3Pool);
        _protected.push(registry.getMarket(marketId).vaultToken);
        _protected.push(registry.getMarket(marketId).lpOracle);
    }

    function reg() external view returns (MarketRegistry) {
        return registry;
    }

    function spokeOf() external view returns (address) {
        return address(spoke);
    }

    function actor(
        uint256 i
    ) external view returns (address) {
        return _actors[i];
    }

    function protectedCount() external view returns (uint256) {
        return _protected.length;
    }

    function protectedAt(
        uint256 i
    ) external view returns (address) {
        return _protected[i];
    }

    function wallet(
        uint256 i
    ) public pure returns (address) {
        return address(uint160(0xF00D0000 + i));
    }

    function windowCount(
        address caller
    ) public view returns (uint256 n) {
        uint256 h = block.timestamp / 3600;
        uint256 first = h >= 23 ? h - 23 : 0;
        for (uint256 x = first; x <= h; ++x) {
            n += modelBuckets[caller][x];
        }
    }

    // ─── Address freeze ───

    function freezeAddress(
        uint256 actorSeed,
        uint256 targetSeed,
        bool protectedTarget
    ) external {
        address caller = _actors[actorSeed % ACTORS];
        address target = protectedTarget ? _protected[targetSeed % _protected.length] : wallet(targetSeed % WALLETS);
        bool authorized = actorSeed % ACTORS != 3;
        bool expected = authorized && !modelFrozen[target] && !protectedTarget && windowCount(caller) < 20;
        ++calls;
        vm.prank(caller);
        try registry.freezeAddress(target) {
            modelFrozen[target] = true;
            ++modelBuckets[caller][block.timestamp / 3600];
            if (!expected) ++outcomeMismatch;
        } catch {
            if (expected) ++outcomeMismatch;
        }
        if (registry.isFrozenAddress(target) != modelFrozen[target]) ++frozenMismatch;
        if (protectedTarget && registry.isFrozenAddress(target)) ++protectedFrozen;
    }

    function unfreezeAddress(
        uint256 actorSeed,
        uint256 targetSeed
    ) external {
        address caller = _actors[actorSeed % ACTORS];
        address target = wallet(targetSeed % WALLETS);
        bool expected = caller == address(timelock) && modelFrozen[target];
        ++calls;
        vm.prank(caller);
        try registry.unfreezeAddress(target) {
            modelFrozen[target] = false;
            if (!expected) ++outcomeMismatch;
        } catch {
            if (expected) ++outcomeMismatch;
        }
        if (registry.isFrozenAddress(target) != modelFrozen[target]) ++frozenMismatch;
    }

    // ─── Breakers ───

    function _key(
        bool debt
    ) internal view returns (bytes32) {
        return debt ? dKey : mKey;
    }

    function recordBreach(
        bool debt,
        uint32 reasons
    ) external {
        bytes32 k = _key(debt);
        ++calls;
        vm.prank(address(rm));
        registry.recordBreach(k, reasons);
        modelLatched[k] |= reasons & BreakerReasons.SECURITY;
        if (reasons & BreakerReasons.TEMPORARY != 0) modelBreachAt[k] = uint64(block.timestamp);
        _compare(debt);
    }

    function trip(
        uint256 actorSeed,
        bool debt
    ) external {
        address caller = _actors[actorSeed % ACTORS];
        bool expected = actorSeed % ACTORS != 3;
        bytes32 k = _key(debt);
        ++calls;
        vm.prank(caller);
        bool ok;
        if (debt) {
            try registry.tripDebtBreaker(address(spoke), GHO_RESERVE) {
                ok = true;
            } catch {}
        } else {
            try registry.tripMarketBreaker(marketId) {
                ok = true;
            } catch {}
        }
        if (ok) modelLatched[k] |= BreakerReasons.MANUAL;
        if (ok != expected) ++outcomeMismatch;
        _compare(debt);
    }

    function setLive(
        bool debt,
        uint32 reasons
    ) external {
        if (debt) rm.setLiveDebt(address(spoke), GHO_RESERVE, reasons);
        else rm.setLive(marketId, reasons);
    }

    function reset(
        uint256 actorSeed,
        bool debt
    ) external {
        address caller = _actors[actorSeed % ACTORS];
        bytes32 k = _key(debt);
        uint32 live = debt ? rm.liveDebtBreakerReasons(address(spoke), GHO_RESERVE) : rm.liveBreakerReasons(marketId);
        bool authorized = actorSeed % ACTORS != 3;
        bool expected = authorized && modelLatched[k] != 0 && (live & modelLatched[k] & BreakerReasons.SECURITY) == 0;
        ++calls;
        vm.prank(caller);
        bool ok;
        if (debt) {
            try registry.resetDebtBreaker(address(spoke), GHO_RESERVE) {
                ok = true;
            } catch {}
        } else {
            try registry.resetMarketBreaker(marketId) {
                ok = true;
            } catch {}
        }
        if (ok) modelLatched[k] = 0;
        if (ok != expected) ++outcomeMismatch;
        _compare(debt);
    }

    function warp(
        uint256 secondsSeed
    ) external {
        vm.warp(block.timestamp + bound(secondsSeed, 1 minutes, 30 hours));
    }

    function _compare(
        bool debt
    ) internal {
        bytes32 k = _key(debt);
        (uint32 latched, uint64 at) =
            debt ? registry.debtBreaker(address(spoke), GHO_RESERVE) : registry.marketBreaker(marketId);
        if (latched != modelLatched[k] || at != modelBreachAt[k]) ++latchMismatch;
    }
}
