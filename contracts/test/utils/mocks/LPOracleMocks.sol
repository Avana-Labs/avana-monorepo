// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice Behaviour of a mocked read: normal, revert, short (malformed) return, gas burn, oversized return.
enum ReadMode {
    Normal,
    Revert,
    Short,
    BurnGas,
    Huge
}

/// @notice Shared misbehaviour switches for the LPOracle mocks.
abstract contract MisbehavingRead {
    mapping(bytes4 selector => ReadMode) public modeOf;

    function setMode(
        bytes4 selector,
        ReadMode mode
    ) external {
        modeOf[selector] = mode;
    }

    /// @dev Applies the misbehaviour of `selector`, if any; returns normally for `Normal`.
    function _misbehave(
        bytes4 selector
    ) internal view {
        ReadMode m = modeOf[selector];
        if (m == ReadMode.Normal) return;
        if (m == ReadMode.Revert) revert("mock revert");
        if (m == ReadMode.BurnGas) {
            uint256 x = 0;
            while (gasleft() > 1000) {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
        assembly {
            switch m
            case 2 { return(0, 16) }
            case 4 { return(0, 100000) }
            default { return(0, 0) }
        }
    }
}

/// @notice Chainlink aggregator proxy and aggregator in one: rounds, history, phases and bounds.
contract OracleFeedMock is MisbehavingRead {
    uint8 internal dec;
    uint80 public roundId;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    int192 public minAnswer;
    int192 public maxAnswer;
    mapping(uint80 id => uint256 at) public history;
    mapping(uint16 phase => address aggregator) public phaseAggregators;

    constructor(
        uint8 decimals_,
        int192 minAnswer_,
        int192 maxAnswer_
    ) {
        (dec, minAnswer, maxAnswer) = (decimals_, minAnswer_, maxAnswer_);
        roundId = 1;
    }

    function setDecimals(
        uint8 d
    ) external {
        dec = d;
    }

    function setBounds(
        int192 lo,
        int192 hi
    ) external {
        (minAnswer, maxAnswer) = (lo, hi);
    }

    /// @notice Publishes a new round: the previous round's timestamp stays readable through `getRoundData`.
    function push(
        int256 a,
        uint256 at
    ) external {
        history[roundId] = updatedAt;
        roundId += 1;
        (answer, updatedAt, startedAt) = (a, at, at);
        history[roundId] = at;
    }

    /// @notice Sets the current round exactly.
    function setRound(
        uint80 id,
        int256 a,
        uint256 started,
        uint256 at
    ) external {
        (roundId, answer, startedAt, updatedAt) = (id, a, started, at);
        history[id] = at;
    }

    function setHistory(
        uint80 id,
        uint256 at
    ) external {
        history[id] = at;
    }

    function setPhaseAggregator(
        uint16 phase,
        address aggregator_
    ) external {
        phaseAggregators[phase] = aggregator_;
    }

    function decimals() external view returns (uint8) {
        _misbehave(this.decimals.selector);
        return dec;
    }

    function aggregator() external view returns (address) {
        return address(this);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        _misbehave(this.latestRoundData.selector);
        return (roundId, answer, startedAt, updatedAt, roundId);
    }

    /// @notice The answer of the latest round, as Aave's oracle reads a reserve's Chainlink source.
    function latestAnswer() external view returns (int256) {
        _misbehave(this.latestAnswer.selector);
        return answer;
    }

    function getRoundData(
        uint80 id
    ) external view returns (uint80, int256, uint256, uint256, uint80) {
        _misbehave(this.getRoundData.selector);
        if (history[id] == 0) revert("no round");
        return (id, answer, history[id], history[id], id);
    }
}

/// @notice ERC-20 decimals only.
contract OracleTokenMock is MisbehavingRead {
    uint8 internal dec;

    constructor(
        uint8 d
    ) {
        dec = d;
    }

    function setDecimals(
        uint8 d
    ) external {
        dec = d;
    }

    function decimals() external view returns (uint8) {
        _misbehave(this.decimals.selector);
        return dec;
    }
}
