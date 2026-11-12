// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title AaveV4Bootstrap
/// @notice Temporary AccessManager admin of a test-network Aave V4 deployment: it runs Aave's own role procedures
/// (`aave-deploy/AvanaAaveV4Roles.sol`, compiled with Aave's settings) by `delegatecall`, exactly as the deployer does in
/// Aave's deploy orchestration, and then hands the admin role to the Aave DAO account of the network.
/// @dev Used only by `01_DeployAaveV4` on anvil, Tenderly and Sepolia, where Avana deploys its own Aave V4; on Ethereum
/// and Base the Aave DAO's deployment is used. Only the deployer that created it can call it, and after the handover
/// it holds no role.
contract AaveV4Bootstrap {
    address public immutable OWNER;

    error NotOwner();

    constructor() {
        OWNER = msg.sender;
    }

    /// @notice Runs one role procedure of `runner` in this contract's context.
    function run(
        address runner,
        bytes calldata data
    ) external {
        if (msg.sender != OWNER) revert NotOwner();
        (bool ok, bytes memory ret) = runner.delegatecall(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
