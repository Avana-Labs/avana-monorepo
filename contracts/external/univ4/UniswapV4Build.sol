// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

// Copyright (c) 2026 Avana Labs

// Build entry of the pinned Uniswap v4 core (v4.0.0, e50237c) and periphery (1.0.1, ea2bf2e) for local and
// test-network deployments: the univ4 profile compiles the PoolManager, the PositionManager and the StateView lens with
// Solidity 0.8.26 and Uniswap's settings. Permit2 is built alone by the permit2 profile. Nothing in Avana's src/
// imports them; tests and scripts deploy them from out-univ4/.
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {StateView} from "@uniswap/v4-periphery/src/lens/StateView.sol";
