// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title IParameterStoreLogic
/// @notice Identity of one of the five logic contracts the ParameterStore delegatecalls for its setters.
/// @dev The ParameterStore implementation exceeds the 24,576-byte code limit as one contract, so its setter bodies
/// live in five immutable logic contracts that share the ERC-7201 layout `avana.storage.ParameterStore`: tighten,
/// loosen, listing (with the chain and Spoke setters), oracle structural and risk structural. The ParameterStore
/// checks the caller's role in each setter and then delegatecalls the logic contract with the same calldata, so a
/// setter's state, events and `msg.sender` are the proxy's. Its constructor refuses a logic contract whose
/// `logicConfig()` names another kind, timelock, MarketRegistry, block time or sequencer flag. A logic contract holds
/// no state any contract reads, and every setter body refuses a direct call (`NotDelegated`), so it runs only in the
/// ParameterStore proxy's storage.
/// @custom:spec REQ-PSTORE-001, REQ-PSTORE-002
interface IParameterStoreLogic {
    /// @notice The logic contract's kind and implementation immutables.
    /// @return kind `keccak256` of the logic contract's name, for example `keccak256("ParameterStoreTightenLogic")`.
    /// @return timelock The AvanaTimelock the logic contract was built for.
    /// @return marketRegistry The MarketRegistry proxy it reads.
    /// @return chainBlockTime Seconds per block.
    /// @return hasSequencer Whether the chain runs an L2 sequencer.
    /// @custom:spec REQ-PSTORE-001
    function logicConfig()
        external
        view
        returns (bytes32 kind, address timelock, address marketRegistry, uint32 chainBlockTime, bool hasSequencer);
}
