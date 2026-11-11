// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @notice OCR2-shaped aggregator with the storage reads of Chainlink's `OCR2Aggregator`: decimals and bounds are
/// immutables, `latestRoundData` reads `hotVars` and one transmission slot (2 SLOADs), `getRoundData` one
/// transmission slot. Used where gas must match a production Chainlink read.
contract OcrAggregatorMock {
    struct Transmission {
        int192 answer;
        uint32 observationsTimestamp;
        uint32 transmissionTimestamp;
    }

    uint8 public immutable decimals;
    int192 public immutable minAnswer;
    int192 public immutable maxAnswer;
    uint32 internal latestRound;
    mapping(uint32 round => Transmission) internal transmissions;

    constructor(
        uint8 d,
        int192 lo,
        int192 hi
    ) {
        (decimals, minAnswer, maxAnswer) = (d, lo, hi);
    }

    function setRound(
        int192 a,
        uint32 ts
    ) external {
        latestRound += 1;
        transmissions[latestRound] = Transmission(a, ts, ts);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        uint32 r = latestRound;
        Transmission memory t = transmissions[r];
        return (r, t.answer, t.observationsTimestamp, t.transmissionTimestamp, r);
    }

    function getRoundData(
        uint80 id
    ) external view returns (uint80, int256, uint256, uint256, uint80) {
        Transmission memory t = transmissions[uint32(id)];
        return (id, t.answer, t.observationsTimestamp, t.transmissionTimestamp, id);
    }

    function latestAnswer() external view returns (int256) {
        return transmissions[latestRound].answer;
    }
}

/// @notice `EACAggregatorProxy`-shaped proxy: `checkAccess` (one SLOAD, controller unset), `currentPhase` (one SLOAD),
/// then the aggregator call; round ids carry the phase in their top 16 bits.
contract EacProxyMock {
    struct Phase {
        uint16 id;
        OcrAggregatorMock aggregator;
    }

    address internal accessController;
    Phase internal currentPhase;
    mapping(uint16 phase => OcrAggregatorMock) internal phases;

    constructor(
        OcrAggregatorMock agg
    ) {
        currentPhase = Phase(1, agg);
        phases[1] = agg;
    }

    function setRound(
        int192 a,
        uint32 ts
    ) external {
        currentPhase.aggregator.setRound(a, ts);
    }

    /// @notice Moves the proxy to a new phase served by `agg`, as a Chainlink aggregator upgrade does.
    function newPhase(
        OcrAggregatorMock agg
    ) external {
        uint16 id = currentPhase.id + 1;
        currentPhase = Phase(id, agg);
        phases[id] = agg;
    }

    function aggregator() external view returns (address) {
        return address(currentPhase.aggregator);
    }

    function phaseId() external view returns (uint16) {
        return currentPhase.id;
    }

    function phaseAggregators(
        uint16 phase
    ) external view returns (address) {
        return address(phases[phase]);
    }

    function decimals() external view returns (uint8) {
        return currentPhase.aggregator.decimals();
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        _check();
        Phase memory p = currentPhase;
        (uint80 r, int256 a, uint256 s, uint256 u, uint80 ar) = p.aggregator.latestRoundData();
        uint80 base = uint80(uint256(p.id) << 64);
        return (base | r, a, s, u, base | ar);
    }

    function getRoundData(
        uint80 id
    ) external view returns (uint80, int256, uint256, uint256, uint80) {
        _check();
        OcrAggregatorMock agg = phases[uint16(id >> 64)];
        (, int256 a, uint256 s, uint256 u,) = agg.getRoundData(uint80(uint64(id)));
        return (id, a, s, u, id);
    }

    function latestAnswer() external view returns (int256) {
        _check();
        return currentPhase.aggregator.latestAnswer();
    }

    function _check() internal view {
        require(accessController == address(0), "access");
    }
}
