// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {PledgePreview} from "../../../types/PledgePreview.sol";

/// @notice `RiskModule.previewPledge` with the block it was read at (REQ-LENS-048).
/// @custom:spec REQ-LENS-048, REQ-LENS-005
struct PledgePreviewView {
    uint256 blockNumber;
    uint256 timestamp;
    PledgePreview preview;
}
