// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveGovernanceExecutorStandIn} from "./AaveGovernanceExecutorStandIn.sol";

/// @title AaveGovernanceExecutorOwnedStandIn
/// @notice The Aave governance executor stand-in for a test network that cannot place code (Sepolia, Base Sepolia):
/// the same `executeTransaction` and slot-0 owner as `AaveGovernanceExecutorStandIn`, the owner (the
/// PayloadsController stand-in) set by the constructor. Deployed through the Safe Singleton Factory with salt 0 before
/// Aave V4 (step 01), so its address follows from the owner alone and the config names it before it exists
/// (`aaveLocal.aaveDao`, `aave.governanceExecutor`, `governance.aaveGovernanceExecutor`). Listed as a stand-in in
/// `deployments/README.md`.
contract AaveGovernanceExecutorOwnedStandIn is AaveGovernanceExecutorStandIn {
    constructor(
        address owner_
    ) {
        owner = owner_;
    }
}
