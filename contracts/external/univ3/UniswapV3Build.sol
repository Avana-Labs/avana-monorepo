// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

// Copyright (c) 2026 Avana Labs

// Build entry of the pinned Uniswap v3 periphery (24ccf01) for local and test-network deployments: the univ3-periphery
// profile compiles the position manager and the swap router with Solidity 0.7.6 and Uniswap's settings. The core
// (factory and pool) is built alone by the univ3 profile. Nothing in Avana's src/ or test/ imports them.
import {NonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/NonfungiblePositionManager.sol";
import {SwapRouter} from "@uniswap/v3-periphery/contracts/SwapRouter.sol";
