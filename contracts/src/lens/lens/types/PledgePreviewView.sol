// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PledgePreview} from "../../../types/PositionTypes.sol";

/// @notice `RiskModule.previewPledge` with the block it was read at.
struct PledgePreviewView {
    uint256 blockNumber;
    uint256 timestamp;
    PledgePreview preview;
}
