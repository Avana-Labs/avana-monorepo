// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title AaveGovernanceExecutorStandIn
/// @notice Test-network stand-in for Aave governance v3's `Executor` (the account that holds the Aave V4 admin roles and
/// runs every payload): the same `executeTransaction` entry point, callable only by its owner, which in production is
/// the PayloadsController. A payload runs by `delegatecall` of its `execute()`, so every configurator and AccessManager
/// call of the payload originates from this account, exactly as on Ethereum. Listed as a stand-in in
/// `deployments/README.md`.
/// @dev The local rehearsal places this runtime code at the network's Aave DAO account (`aaveLocal.aaveDao`) with
/// `anvil_setCode` and writes the owner (`aaveLocal.payloadsController`) into slot 0, so the account that Aave V4's
/// deployment made admin keeps its address. Nothing runs a constructor.
contract AaveGovernanceExecutorStandIn {
    /// @dev Slot 0, the owner: the PayloadsController stand-in.
    address public owner;

    error OnlyOwner();
    error ExecutionFailed(bytes reason);

    event ExecutedAction(
        address indexed target, uint256 value, string signature, bytes data, uint256 executionTime, bool withDelegatecall
    );

    /// @notice Runs `signature(data)` on `target`, by `delegatecall` when `withDelegatecall` (a payload's `execute()`).
    function executeTransaction(
        address target,
        uint256 value,
        string calldata signature,
        bytes calldata data,
        bool withDelegatecall
    ) external payable returns (bytes memory result) {
        if (msg.sender != owner) revert OnlyOwner();
        bytes memory callData =
            bytes(signature).length == 0 ? data : abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        bool ok;
        if (withDelegatecall) {
            // forge-lint: disable-next-line(unchecked-call)
            (ok, result) = target.delegatecall(callData);
        } else {
            (ok, result) = target.call{value: value}(callData);
        }
        if (!ok) revert ExecutionFailed(result);
        emit ExecutedAction(target, value, signature, data, block.timestamp, withDelegatecall);
    }

    receive() external payable {}
}
