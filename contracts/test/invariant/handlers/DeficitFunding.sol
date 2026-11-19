// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapBase} from "../../../src/legacy/lp-vault-swap/ILPVaultSwapBase.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title DeficitFunding
/// @notice The part of a liquidation's borrower surplus `B` that LPVaultSwap paid into the First-Loss Reserve
/// (`DeficitSurplusFunded`, REQ-SWAP-027, SPEC-LIQ-022). The reserve's `fund` sends it on to the Hub, so the balance
/// checks of TEST-093 and TEST-104 count it in the Hub's rise and take it off the borrower's.
library DeficitFunding {
    function funded(
        Vm.Log[] memory logs,
        address lvs
    ) internal pure returns (uint256 amount) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == lvs && logs[i].topics.length != 0
                    && logs[i].topics[0] == ILPVaultSwapBase.DeficitSurplusFunded.selector
            ) {
                (uint256 taken,) = abi.decode(logs[i].data, (uint256, uint256));
                amount += taken;
            }
        }
    }
}
