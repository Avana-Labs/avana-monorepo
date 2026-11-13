// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ISequencerUptimeFeed} from "../../src/interfaces/external/chainlink/ISequencerUptimeFeed.sol";
import {LPPriceMath} from "../../src/oracle/lp-oracle/LPPriceMath.sol";
import {AvanaTest} from "../utils/AvanaTest.sol";
import {ForkConstants} from "../utils/fixtures/ForkConstants.sol";

/// @notice The proxy and the L2 uptime aggregator behind it (Chainlink `OptimismSequencerUptimeFeed`, used on Base).
interface IForkUptimeProxy {
    function aggregator() external view returns (address);
}

interface IForkUptimeAggregator {
    function l1Sender() external view returns (address);
    function updateStatus(
        bool status,
        uint64 timestamp
    ) external;
}

/// @notice The OP-stack L2 cross-domain messenger read by the uptime aggregator's sender check.
interface IForkL2Messenger {
    function xDomainMessageSender() external view returns (address);
}

/// @title SequencerUptimeFeedForkTest
/// @notice `TEST-275` against the real Chainlink L2 sequencer-uptime feed on the Base fork
/// (`0xBCF85224fc0756B9Fa45aA7892530B47e10b6433`), the external the unit tests replace with `AdapterSequencerFeed` and
/// `RiskSequencerFeed`. Read the way the RiskModule, LPOracle and DebtOracle read it (a `staticcall` with
/// `SEQUENCER_CALL_GAS`, the answer exactly 160 bytes), the live feed answers 0 or 1 with a `startedAt` in the past, and
/// `LPPriceMath.sequencerStatus` (SPEC-ORC-021) on its words gives: in grace until `startedAt + 3,600`, ready from
/// then. A status report delivered through the real aggregator's L1-sender path (the L2 messenger's
/// `xDomainMessageSender` answered as the aggregator's own `l1Sender`) turns the feed down, which the gate reads as down,
/// and back up with a new `startedAt`, which opens a new 3,600 s grace period. Forks at the pinned Base block when one is
/// set, else at the latest block; skipped without `RPC_BASE`.
/// @dev Run with `FOUNDRY_PROFILE=fork forge test --match-contract SequencerUptimeFeedForkTest`.
contract SequencerUptimeFeedForkTest is AvanaTest {
    address internal constant FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    address internal constant L2_MESSENGER = 0x4200000000000000000000000000000000000007;
    /// @dev `RiskModuleBase.SEQUENCER_CALL_GAS` and `ROUND_LENGTH`: the gas and the exact answer length of the read.
    uint256 internal constant SEQUENCER_CALL_GAS = 50_000;
    uint256 internal constant ROUND_LENGTH = 160;
    /// @dev Base `sequencerGraceSeconds` (3.8).
    uint256 internal constant GRACE = 3600;

    function setUp() public {
        string memory rpc = vm.envOr("RPC_BASE", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 pin = ForkConstants.baseForkBlock();
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
    }

    // TEST-275 verifies: REQ-ORACLE-099, SPEC-ORC-021
    function test_TEST_275_liveFeedAnswersOneRoundAndTheGateReadsIt() public {
        (bool ok, int256 answer, uint256 startedAt) = _read();
        assertTrue(ok, "a 160-byte answer within SEQUENCER_CALL_GAS");
        assertTrue(answer == 0 || answer == 1, "answer is 0 (up) or 1 (down)");
        assertGt(startedAt, 0, "an initialised round");
        assertLe(startedAt, block.timestamp);
        if (answer == 1) {
            (, bool down,,,) = LPPriceMath.sequencerStatus(true, ok, answer, startedAt, block.timestamp, GRACE);
            assertTrue(down);
            return;
        }
        uint256 snap = vm.snapshotState();
        vm.warp(startedAt + GRACE - 1);
        (bool up,,, bool inGrace, bool ready) =
            LPPriceMath.sequencerStatus(true, ok, answer, startedAt, block.timestamp, GRACE);
        assertTrue(up && inGrace && !ready, "in grace one second before startedAt + grace");
        vm.warp(startedAt + GRACE);
        (,,, inGrace, ready) = LPPriceMath.sequencerStatus(true, ok, answer, startedAt, block.timestamp, GRACE);
        assertTrue(ready && !inGrace, "ready from startedAt + grace");
        vm.revertToState(snap);
    }

    // TEST-275 verifies: REQ-ORACLE-099, SPEC-ORC-021
    function test_TEST_275_downThenRestartOpensANewGracePeriod() public {
        address agg = IForkUptimeProxy(FEED).aggregator();
        address l1 = IForkUptimeAggregator(agg).l1Sender();
        vm.mockCall(L2_MESSENGER, abi.encodeCall(IForkL2Messenger.xDomainMessageSender, ()), abi.encode(l1));

        vm.warp(block.timestamp + 60);
        uint64 downAt = uint64(block.timestamp);
        vm.prank(L2_MESSENGER);
        IForkUptimeAggregator(agg).updateStatus(true, downAt);
        (bool ok, int256 answer, uint256 startedAt) = _read();
        assertTrue(ok);
        assertEq(answer, 1, "the feed reports down");
        assertEq(startedAt, downAt);
        (bool up, bool down, bool unknown,, bool ready) =
            LPPriceMath.sequencerStatus(true, ok, answer, startedAt, block.timestamp, GRACE);
        assertTrue(down && !up && !unknown && !ready, "down blocks borrowing");

        vm.warp(block.timestamp + 600);
        uint64 upAt = uint64(block.timestamp);
        vm.prank(L2_MESSENGER);
        IForkUptimeAggregator(agg).updateStatus(false, upAt);
        (ok, answer, startedAt) = _read();
        assertEq(answer, 0, "the feed reports up");
        assertEq(startedAt, upAt, "startedAt is the restart");
        bool inGrace;
        (up,,, inGrace, ready) = LPPriceMath.sequencerStatus(true, ok, answer, startedAt, block.timestamp, GRACE);
        assertTrue(up && inGrace && !ready, "in grace right after the restart");
        vm.warp(upAt + GRACE - 1);
        (,,, inGrace, ready) = LPPriceMath.sequencerStatus(true, ok, answer, startedAt, block.timestamp, GRACE);
        assertTrue(inGrace && !ready);
        vm.warp(upAt + GRACE);
        (,,, inGrace, ready) = LPPriceMath.sequencerStatus(true, ok, answer, startedAt, block.timestamp, GRACE);
        assertTrue(ready && !inGrace, "ready once the grace period has passed");
    }

    /// @dev The read of `RiskModuleBase._sequencerState`: bounded gas, the answer exactly `ROUND_LENGTH` bytes.
    function _read() internal view returns (bool ok, int256 answer, uint256 startedAt) {
        bytes memory ret;
        (ok, ret) = FEED.staticcall{gas: SEQUENCER_CALL_GAS}(abi.encodeCall(ISequencerUptimeFeed.latestRoundData, ()));
        ok = ok && ret.length == ROUND_LENGTH;
        if (ok) (, answer, startedAt,,) = abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
    }
}
