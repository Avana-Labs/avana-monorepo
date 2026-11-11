// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IDebtOracle} from "../../../src/oracle/debt-oracle/IDebtOracle.sol";
import {PriceState} from "../../../src/types/PriceState.sol";
import {RouteSlot} from "../../../src/types/RouteSlot.sol";
import {DebtRegistryMock} from "../../utils/mocks/DebtOracleConfigMocks.sol";
import {MockAggregator} from "../../utils/mocks/MockAggregator.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @title DebtOracleHandler
/// @notice Drives one DebtOracle through feed moves, outages, hostile reads, time, standby switches and pokes, and
/// records what a correct oracle may never do: a reverting poke, an accepted timestamp that no feed published, or an
/// accepted timestamp that moves backwards.
contract DebtOracleHandler is CommonBase, StdUtils {
    IDebtOracle public immutable ORACLE;
    DebtRegistryMock public immutable REGISTRY;
    address public immutable ASSET;
    MockAggregator[4] internal feeds;
    int256[4] internal honest;

    /// @notice Largest `updatedAt` any feed has published.
    uint256 public maxPublished;
    /// @notice `lastAcceptedPrice().updatedAt` after the previous handler call.
    uint64 public lastAcceptedAt;
    uint256 public acceptedWentBack;
    uint256 public pokeReverts;
    uint256 public pokes;
    uint256 public switches;

    constructor(
        IDebtOracle oracle,
        DebtRegistryMock registry,
        address asset,
        MockAggregator[4] memory feeds_,
        int256[4] memory honest_
    ) {
        ORACLE = oracle;
        REGISTRY = registry;
        ASSET = asset;
        feeds = feeds_;
        honest = honest_;
        maxPublished = block.timestamp;
        (, lastAcceptedAt) = oracle.lastAcceptedPrice();
    }

    function _track() internal {
        (, uint64 at) = ORACLE.lastAcceptedPrice();
        if (at < lastAcceptedAt) ++acceptedWentBack;
        lastAcceptedAt = at;
    }

    function _publish(
        MockAggregator f,
        int256 answer,
        uint256 updatedAt
    ) internal {
        f.push(answer, updatedAt);
        if (updatedAt > maxPublished) maxPublished = updatedAt;
    }

    /// @notice A new round on one feed: honest, moved by up to ±50 %, or at a bound.
    function move(
        uint256 feedSeed,
        uint256 kind,
        uint256 moveBps
    ) external {
        uint256 i = feedSeed % 4;
        int256 v = honest[i];
        int256 a = v;
        kind %= 5;
        if (kind == 1) a = v + (v * int256(bound(moveBps, 0, 5000))) / 10_000;
        else if (kind == 2) a = v - (v * int256(bound(moveBps, 0, 5000))) / 10_000;
        else if (kind == 3) a = 0;
        else if (kind == 4) a = -v;
        _publish(feeds[i], a, block.timestamp);
        _track();
    }

    /// @notice A round with an old, zero or future timestamp.
    function oddTimestamp(
        uint256 feedSeed,
        uint256 kind
    ) external {
        uint256 i = feedSeed % 4;
        kind %= 3;
        uint256 t = kind == 0 ? 0 : kind == 1 ? block.timestamp + 1 : block.timestamp - 100_000;
        _publish(feeds[i], honest[i], t);
        _track();
    }

    function warp(
        uint256 seconds_
    ) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 100_000));
        _track();
    }

    function breakFeed(
        uint256 feedSeed,
        uint256 mode
    ) external {
        MockAggregator f = feeds[feedSeed % 4];
        f.setMode(f.latestRoundData.selector, MockAggregator.Mode(mode % 6));
        _track();
    }

    function switchStandby(
        bool alternate
    ) external {
        if (REGISTRY.replaced(ASSET) == RouteSlot.None) {
            REGISTRY.useStandby(ASSET, alternate ? RouteSlot.Alternate : RouteSlot.Primary);
        } else {
            REGISTRY.restore(ASSET);
        }
        ++switches;
        _track();
    }

    function poke() external {
        ++pokes;
        try ORACLE.poke{gas: 5_000_000}() returns (PriceState) {}
        catch {
            ++pokeReverts;
        }
        _track();
    }
}
