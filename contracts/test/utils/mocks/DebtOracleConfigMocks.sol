// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {TokenDef} from "../../../src/policy/market-registry/types/TokenDef.sol";
import {FeedDef} from "../../../src/policy/parameter-store/types/FeedDef.sol";
import {RouteSlot} from "../../../src/types/RouteSlot.sol";
import {SecondSource} from "../../../src/types/SecondSource.sol";

/// @title HostileConfig
/// @notice Per-selector hostile behaviour shared by the DebtOracle's registry and store mocks: revert, a short (empty)
/// return, a call that burns all its gas, and a return word that does not fit the ABI type.
abstract contract HostileConfig {
    enum Mode {
        Normal,
        Revert,
        Short,
        Burn,
        Oversized
    }

    mapping(bytes4 => Mode) public modeOf;

    function setMode(
        bytes4 selector,
        Mode m
    ) external {
        modeOf[selector] = m;
    }

    function _hostile(
        bytes4 selector
    ) internal view {
        Mode m = modeOf[selector];
        if (m == Mode.Normal) return;
        if (m == Mode.Revert) revert("config down");
        if (m == Mode.Short) {
            assembly {
                return(0, 0)
            }
        }
        if (m == Mode.Burn) {
            uint256 x;
            while (true) {
                x += 1;
            }
        }
        if (m == Mode.Oversized) {
            assembly {
                mstore(0, not(0))
                mstore(32, not(0))
                mstore(64, not(0))
                mstore(96, not(0))
                mstore(128, not(0))
                mstore(160, not(0))
                mstore(192, not(0))
                mstore(224, not(0))
                mstore(256, not(0))
                mstore(288, not(0))
                return(0, 320)
            }
        }
    }
}

/// @title DebtRegistryMock
/// @notice The MarketRegistry views a DebtOracle reads: `getToken`, `activePriceRoutes` and `priceRouteVersion`, with a
/// standby switch that replaces a slot and increments the version, as `useStandbyRoute` does.
contract DebtRegistryMock is HostileConfig {
    mapping(address => bool) public listed;
    mapping(address => address[]) internal _primary;
    mapping(address => address[]) internal _alternate;
    mapping(address => address[]) internal _standby;
    mapping(address => RouteSlot) public replaced;
    mapping(address => uint64) public versionOf;

    function list(
        address token,
        address[] memory primary,
        address[] memory alternate,
        address[] memory standby
    ) external {
        listed[token] = true;
        _primary[token] = primary;
        _alternate[token] = alternate;
        _standby[token] = standby;
        versionOf[token] += 1;
    }

    function setListed(
        address token,
        bool v
    ) external {
        listed[token] = v;
    }

    function setRoutes(
        address token,
        address[] memory primary,
        address[] memory alternate
    ) external {
        _primary[token] = primary;
        _alternate[token] = alternate;
        versionOf[token] += 1;
    }

    function useStandby(
        address token,
        RouteSlot slot
    ) external {
        replaced[token] = slot;
        versionOf[token] += 1;
    }

    function restore(
        address token
    ) external {
        replaced[token] = RouteSlot.None;
        versionOf[token] += 1;
    }

    function getToken(
        address token
    ) external view returns (TokenDef memory def) {
        _hostile(this.getToken.selector);
        def.listed = listed[token];
        def.decimals = 6;
        def.primaryRoute = _primary[token];
        def.alternateRoute = _alternate[token];
        def.standbyRoute = _standby[token];
        def.replacedSlot = replaced[token];
    }

    function activePriceRoutes(
        address token
    ) external view returns (address[] memory primary, address[] memory alternate, RouteSlot slot) {
        _hostile(this.activePriceRoutes.selector);
        if (!listed[token]) return (primary, alternate, RouteSlot.None);
        slot = replaced[token];
        primary = slot == RouteSlot.Primary ? _standby[token] : _primary[token];
        alternate = slot == RouteSlot.Alternate ? _standby[token] : _alternate[token];
    }

    function priceRouteVersion(
        address token
    ) external view returns (uint64) {
        _hostile(this.priceRouteVersion.selector);
        return versionOf[token];
    }
}

/// @title DebtStoreMock
/// @notice The ParameterStore views a DebtOracle reads: feed records, tolerance, second source, sequencer, timers and
/// the stress rise.
contract DebtStoreMock is HostileConfig {
    mapping(address => FeedDef) internal _feeds;
    mapping(address => uint16) public tolerance;
    mapping(address => uint16) public stressRise;
    mapping(address => SecondSource) internal _second;
    address public sequencerFeed;
    uint32 public sequencerGracePeriod;
    uint32 public cachedWindowValue = 3600;
    uint32 public pauseMaxValue = 3600;
    uint32 public graceValue = 1800;

    function setFeed(
        address feed,
        uint8 decimals,
        int256 minAnswer,
        int256 maxAnswer,
        uint32 heartbeat,
        uint32 margin
    ) external {
        FeedDef storage f = _feeds[feed];
        f.decimals = decimals;
        f.minAnswer = minAnswer;
        f.maxAnswer = maxAnswer;
        f.feedHeartbeat = heartbeat;
        f.heartbeatMargin = margin;
        f.feedMaxAge = heartbeat + margin;
        f.feedDeviationThresholdBps = 25;
        f.borrowPriceMaxAge = heartbeat + margin;
        f.liquidationPriceMaxAge = heartbeat + margin;
    }

    function setBorrowAge(
        address feed,
        uint32 age
    ) external {
        _feeds[feed].borrowPriceMaxAge = age;
    }

    function clearFeed(
        address feed
    ) external {
        delete _feeds[feed];
    }

    function setTolerance(
        address token,
        uint16 bps
    ) external {
        tolerance[token] = bps;
    }

    function setStressRise(
        address token,
        uint16 bps
    ) external {
        stressRise[token] = bps;
    }

    function setSecondSource(
        address token,
        SecondSource memory s
    ) external {
        _second[token] = s;
    }

    function setSequencer(
        address feed,
        uint32 gracePeriod
    ) external {
        sequencerFeed = feed;
        sequencerGracePeriod = gracePeriod;
    }

    function setTimers(
        uint32 cached,
        uint32 pauseMax,
        uint32 grace
    ) external {
        cachedWindowValue = cached;
        pauseMaxValue = pauseMax;
        graceValue = grace;
    }

    function getFeed(
        address feed
    ) external view returns (FeedDef memory) {
        _hostile(this.getFeed.selector);
        return _feeds[feed];
    }

    function feedAgreementToleranceBps(
        address token
    ) external view returns (uint16) {
        _hostile(this.feedAgreementToleranceBps.selector);
        return tolerance[token];
    }

    function debtStressRiseBps(
        address token
    ) external view returns (uint16) {
        _hostile(this.debtStressRiseBps.selector);
        return stressRise[token];
    }

    function secondSource(
        address token
    ) external view returns (SecondSource memory) {
        _hostile(this.secondSource.selector);
        return _second[token];
    }

    function sequencer() external view returns (address feed, uint32 gracePeriod) {
        _hostile(this.sequencer.selector);
        return (sequencerFeed, sequencerGracePeriod);
    }

    function cachedWindow() external view returns (uint32) {
        _hostile(this.cachedWindow.selector);
        return cachedWindowValue;
    }

    function disagreementPauseMax() external view returns (uint32) {
        _hostile(this.disagreementPauseMax.selector);
        return pauseMaxValue;
    }

    function graceDuration() external view returns (uint32) {
        _hostile(this.graceDuration.selector);
        return graceValue;
    }
}
