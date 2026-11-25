// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.17;

// Copyright (c) 2026 Avana Labs

// Build entry of the pinned Permit2 (cc56ad0) for local and test-network deployments: the permit2 profile compiles it
// with Solidity 0.8.17 and Uniswap's settings. The Uniswap v4 PositionManager takes its address at construction.
import {Permit2} from "permit2/src/Permit2.sol";
