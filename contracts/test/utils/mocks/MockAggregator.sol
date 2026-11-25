// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title MockAggregator
/// @notice A Chainlink aggregator proxy for the oracle tests: round IDs `phaseId << 64 | aggregatorRoundId`, a round
/// history for `getRoundData`, `phaseAggregators` per phase, settable `startedAt` (the sequencer-uptime feed reads
/// it), and hostile behaviours per read: revert, a short return, a 100 KB return, a call that burns all its gas and a
/// round identifier that does not fit `uint80`.
contract MockAggregator {
    enum Mode {
        Normal,
        Revert,
        Short,
        Bomb,
        Burn,
        Dirty
    }

    struct Round {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
    }

    uint8 internal _decimals;
    uint16 public phase = 1;
    uint64 public aggregatorRound;
    int256 internal _answer;
    uint256 internal _startedAt;
    uint256 internal _updatedAt;
    mapping(uint80 => Round) internal _rounds;
    mapping(uint16 => address) public phaseAggregators;
    mapping(bytes4 => Mode) public modeOf;
    uint256 public decimalsWord;
    bool public decimalsWordSet;

    constructor(
        uint8 decimals_,
        int256 answer,
        uint256 updatedAt
    ) {
        _decimals = decimals_;
        push(answer, updatedAt);
    }

    // ─── Test controls ───

    /// @notice A new round in the current phase.
    function push(
        int256 answer,
        uint256 updatedAt
    ) public {
        aggregatorRound += 1;
        _store(answer, updatedAt);
    }

    /// @notice A new round with the current answer, whatever the read mode.
    function republish(
        uint256 updatedAt
    ) external {
        push(_answer, updatedAt);
    }

    /// @notice The first round of a new phase (`uint64(roundId) == 1`), naming `previous` as the old phase aggregator.
    function pushNewPhase(
        int256 answer,
        uint256 updatedAt,
        address previous
    ) external {
        phaseAggregators[phase] = previous;
        phase += 1;
        aggregatorRound = 1;
        _store(answer, updatedAt);
    }

    /// @notice Overwrites the current round's answer and timestamp without a new round identifier.
    function setCurrent(
        int256 answer,
        uint256 updatedAt
    ) external {
        _answer = answer;
        _updatedAt = updatedAt;
        _rounds[roundId()] = Round(answer, _startedAt, updatedAt);
    }

    function setStartedAt(
        uint256 startedAt
    ) external {
        _startedAt = startedAt;
        _rounds[roundId()].startedAt = startedAt;
    }

    function setDecimals(
        uint8 d
    ) external {
        _decimals = d;
    }

    /// @notice Makes `decimals()` return a raw word (for decode checks).
    function setDecimalsWord(
        uint256 w
    ) external {
        decimalsWord = w;
        decimalsWordSet = true;
    }

    function setPhaseAggregator(
        uint16 p,
        address a
    ) external {
        phaseAggregators[p] = a;
    }

    function setMode(
        bytes4 selector,
        Mode m
    ) external {
        modeOf[selector] = m;
    }

    function setAll(
        Mode m
    ) external {
        modeOf[this.latestRoundData.selector] = m;
        modeOf[this.decimals.selector] = m;
        modeOf[this.getRoundData.selector] = m;
    }

    function forgetRound(
        uint80 id
    ) external {
        delete _rounds[id];
    }

    // ─── Chainlink interface ───

    function roundId() public view returns (uint80) {
        return (uint80(phase) << 64) | aggregatorRound;
    }

    function decimals() external view returns (uint8) {
        _hostile(this.decimals.selector);
        if (decimalsWordSet) {
            uint256 w = decimalsWord;
            assembly {
                mstore(0, w)
                return(0, 32)
            }
        }
        return _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        _hostile(this.latestRoundData.selector);
        uint80 id = roundId();
        return (id, _answer, _startedAt, _updatedAt, id);
    }

    function getRoundData(
        uint80 id
    ) external view returns (uint80, int256, uint256, uint256, uint80) {
        _hostile(this.getRoundData.selector);
        Round memory r = _rounds[id];
        require(r.updatedAt != 0, "No data present");
        return (id, r.answer, r.startedAt, r.updatedAt, id);
    }

    function _store(
        int256 answer,
        uint256 updatedAt
    ) internal {
        _answer = answer;
        _updatedAt = updatedAt;
        _startedAt = updatedAt;
        _rounds[roundId()] = Round(answer, updatedAt, updatedAt);
    }

    function _hostile(
        bytes4 selector
    ) internal view {
        Mode m = modeOf[selector];
        if (m == Mode.Normal) return;
        if (m == Mode.Revert) revert("feed down");
        if (m == Mode.Short) {
            assembly {
                mstore(0, 1)
                return(0, 31)
            }
        }
        if (m == Mode.Bomb) {
            assembly {
                return(0, 100000)
            }
        }
        if (m == Mode.Burn) {
            uint256 x;
            while (true) {
                x += 1;
            }
        }
        if (m == Mode.Dirty) {
            assembly {
                mstore(0, shl(100, 1))
                mstore(32, 1)
                mstore(64, 1)
                mstore(96, timestamp())
                mstore(128, 1)
                return(0, 160)
            }
        }
    }
}
