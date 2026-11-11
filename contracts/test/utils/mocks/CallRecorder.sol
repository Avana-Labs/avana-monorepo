// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title CallRecorder
/// @notice Stand-in target for timelock operations: accepts any call, records its caller and calldata, and can be
/// told to revert, so tests see exactly what an executed operation delivered and when.
contract CallRecorder {
    error Refused();

    struct Call {
        address caller;
        uint256 value;
        bytes data;
    }

    Call[] internal _calls;
    bool public refuse;

    function setRefuse(
        bool refuse_
    ) external {
        refuse = refuse_;
    }

    function callCount() external view returns (uint256) {
        return _calls.length;
    }

    function callAt(
        uint256 i
    ) external view returns (Call memory) {
        return _calls[i];
    }

    fallback() external payable {
        if (refuse) revert Refused();
        _calls.push(Call({caller: msg.sender, value: msg.value, data: msg.data}));
    }

    receive() external payable {
        _calls.push(Call({caller: msg.sender, value: msg.value, data: ""}));
    }
}
