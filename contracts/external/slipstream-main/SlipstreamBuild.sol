// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.7.6;
pragma abicoder v2;

// Copyright (c) 2026 Avana Labs

// Build entry of the vendored Aerodrome Slipstream (slipstream-main-f8717fa) for local and test-network deployments only: the
// slipstream-main profile compiles the pool factory, pool, position manager, swap router and gauge factory below with
// Slipstream's own settings (Solidity 0.7.6, 200 runs, no metadata hash). Nothing in Avana's src/ or test/ imports them.
import {CLFactory} from "dependencies/slipstream-main-f8717fa/contracts/core/CLFactory.sol";
import {CLPool} from "dependencies/slipstream-main-f8717fa/contracts/core/CLPool.sol";
import {CLGauge} from "dependencies/slipstream-main-f8717fa/contracts/gauge/CLGauge.sol";
import {CLGaugeFactory} from "dependencies/slipstream-main-f8717fa/contracts/gauge/CLGaugeFactory.sol";
import {
    NonfungiblePositionManager
} from "dependencies/slipstream-main-f8717fa/contracts/periphery/NonfungiblePositionManager.sol";
import {SwapRouter} from "dependencies/slipstream-main-f8717fa/contracts/periphery/SwapRouter.sol";
