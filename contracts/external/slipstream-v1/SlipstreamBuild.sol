// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

// Copyright (c) 2026 Avana Labs

// Build entry of the vendored Aerodrome Slipstream (slipstream-1.0.0) for local and test-network deployments only: the
// slipstream-v1 profile compiles the pool factory, pool, position manager, swap router and gauge factory below with
// Slipstream's own settings (Solidity 0.7.6, 200 runs, no metadata hash). Nothing in Avana's src/ or test/ imports them.
import {CLFactory} from "dependencies/slipstream-1.0.0/contracts/core/CLFactory.sol";
import {CLPool} from "dependencies/slipstream-1.0.0/contracts/core/CLPool.sol";
import {CLGauge} from "dependencies/slipstream-1.0.0/contracts/gauge/CLGauge.sol";
import {CLGaugeFactory} from "dependencies/slipstream-1.0.0/contracts/gauge/CLGaugeFactory.sol";
import {
    NonfungiblePositionManager
} from "dependencies/slipstream-1.0.0/contracts/periphery/NonfungiblePositionManager.sol";
import {SwapRouter} from "dependencies/slipstream-1.0.0/contracts/periphery/SwapRouter.sol";
