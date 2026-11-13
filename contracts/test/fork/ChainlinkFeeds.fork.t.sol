// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaTest} from "../utils/AvanaTest.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";

/// @notice The EACAggregatorProxy reads the fork test makes.
interface IForkFeedProxy {
    function decimals() external view returns (uint8);
    function aggregator() external view returns (address);
    function phaseId() external view returns (uint16);
    function phaseAggregators(
        uint16 phase
    ) external view returns (address);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function getRoundData(
        uint80 roundId
    )
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice The OCR2 aggregator behind a proxy: its own round numbering and its answer bounds.
interface IForkOcrAggregator {
    function minAnswer() external view returns (int192);
    function maxAnswer() external view returns (int192);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkFeedsForkTest
/// @notice `TEST-117` against the real Chainlink feeds of the launch tokens and debt assets on the Ethereum and Base
/// forks, the externals the unit tests replace with `MockAggregator`, `EacProxyMock` and `OcrAggregatorMock`. For each
/// feed: 8 decimals; a positive answer inside the aggregator's own `minAnswer`/`maxAnswer` and, for a stablecoin,
/// within 5 % of $1; an age within the feed's heartbeat plus the
/// 1,800 s buffer of `feedMaxAge` (82,800–86,400 s for the stablecoin legs); the round ID decodes as
/// `(phaseId << 64) | aggregatorRoundId` with `phaseAggregators(phaseId) == aggregator()` (EXT-025); re-reading the
/// same round, latest or by ID, returns the same `updatedAt`; and with no new round the feed's age keeps growing past
/// the heartbeat (a silent stall is visible to a per-feed age check, nothing refreshes it).
/// Forks at `ForkConstants`' pinned block of the chain when one is set, else at the latest block; skipped without
/// `RPC_MAINNET` or `RPC_BASE`.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract ChainlinkFeedsForkTest`.
contract ChainlinkFeedsForkTest is AvanaTest {
    /// @dev The buffer of `feedMaxAge = heartbeat + buffer` (2.10 SPEC-ORC-013 example: 82,800 + 1,800 = 84,600).
    uint256 internal constant AGE_BUFFER = 1800;

    struct Feed {
        string name;
        address proxy;
        uint256 heartbeat;
        bool stable;
    }

    // TEST-117 verifies: Q-238, Q-364
    function test_TEST_117_ethereumLaunchFeeds() public {
        if (!_fork(vm.envOr("RPC_MAINNET", string("")), ForkConstants.mainnetForkBlock())) return;
        Feed[5] memory feeds = [
            Feed("USDC/USD", 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6, 86_400, true),
            Feed("USDT/USD", 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D, 86_400, true),
            Feed("DAI/USD", 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9, 3600, true),
            Feed("GHO/USD", 0x3f12643D3f6f874d39C2a4c9f2Cd6f2DbAC877FC, 86_400, true),
            Feed("ETH/USD", 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419, 3600, false)
        ];
        for (uint256 i = 0; i < feeds.length; ++i) {
            _checkFeed(feeds[i]);
        }
    }

    // TEST-117 verifies: Q-238, Q-364
    function test_TEST_117_baseLaunchFeeds() public {
        if (!_fork(vm.envOr("RPC_BASE", string("")), ForkConstants.baseForkBlock())) return;
        Feed[2] memory feeds = [
            Feed("USDC/USD", 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B, 86_400, true),
            Feed("ETH/USD", 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70, 1200, false)
        ];
        for (uint256 i = 0; i < feeds.length; ++i) {
            _checkFeed(feeds[i]);
        }
    }

    function _fork(
        string memory rpc,
        uint256 pin
    ) internal returns (bool) {
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        return true;
    }

    function _checkFeed(
        Feed memory f
    ) internal {
        IForkFeedProxy proxy = IForkFeedProxy(f.proxy);
        assertEq(proxy.decimals(), 8, string.concat(f.name, ": decimals"));
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = proxy.latestRoundData();
        assertGt(answer, 0, string.concat(f.name, ": positive answer"));
        assertGe(answeredInRound, roundId, string.concat(f.name, ": answered in its round"));
        assertLe(updatedAt, block.timestamp, string.concat(f.name, ": not from the future"));
        assertLe(block.timestamp - updatedAt, f.heartbeat + AGE_BUFFER, string.concat(f.name, ": within heartbeat"));
        if (f.stable) {
            assertGe(answer, 0.95e8, string.concat(f.name, ": near $1"));
            assertLe(answer, 1.05e8, string.concat(f.name, ": near $1"));
        }
        _checkPhase(f.name, proxy, roundId, answer, updatedAt);
        _checkNoRefresh(f, proxy, roundId, updatedAt);
    }

    /// @dev Phase encoding (EXT-025): the proxy's round is (phaseId << 64) | the aggregator's own round, and the
    /// aggregator's answer lies inside its own `minAnswer`/`maxAnswer`.
    function _checkPhase(
        string memory name,
        IForkFeedProxy proxy,
        uint80 roundId,
        int256 answer,
        uint256 updatedAt
    ) internal view {
        uint16 phase = proxy.phaseId();
        address agg = proxy.aggregator();
        assertEq(uint256(roundId) >> 64, phase, string.concat(name, ": phase in the round ID"));
        assertEq(proxy.phaseAggregators(phase), agg, string.concat(name, ": current phase aggregator"));
        IForkOcrAggregator ocr = IForkOcrAggregator(agg);
        (uint80 aggRound, int256 aggAnswer,, uint256 aggUpdatedAt,) = ocr.latestRoundData();
        assertEq(aggRound, uint64(roundId), string.concat(name, ": aggregator round"));
        assertEq(aggAnswer, answer);
        assertEq(aggUpdatedAt, updatedAt);
        assertLt(int256(ocr.minAnswer()), answer, string.concat(name, ": above minAnswer"));
        assertGt(int256(ocr.maxAnswer()), answer, string.concat(name, ": below maxAnswer"));
    }

    /// @dev Re-reading the same round never refreshes its age, and with no new round the age passes the heartbeat.
    function _checkNoRefresh(
        Feed memory f,
        IForkFeedProxy proxy,
        uint80 roundId,
        uint256 updatedAt
    ) internal {
        (uint80 again,,, uint256 updatedAgain,) = proxy.getRoundData(roundId);
        assertEq(again, roundId);
        assertEq(updatedAgain, updatedAt, string.concat(f.name, ": same round, same updatedAt"));
        uint256 snap = vm.snapshotState();
        vm.warp(updatedAt + f.heartbeat + AGE_BUFFER + 1);
        (uint80 later,,, uint256 updatedLater,) = proxy.latestRoundData();
        assertEq(later, roundId, string.concat(f.name, ": no round appears by itself"));
        assertEq(updatedLater, updatedAt);
        assertGt(block.timestamp - updatedLater, f.heartbeat + AGE_BUFFER, string.concat(f.name, ": stall is visible"));
        vm.revertToState(snap);
    }
}
