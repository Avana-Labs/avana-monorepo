// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {MarketRegistrySafetyLogic} from "../../src/policy/market-registry/MarketRegistrySafetyLogic.sol";
import {MarketRegistryImmutables} from "../../src/policy/market-registry/types/MarketRegistryImmutables.sol";

/// @title MarketRegistrySafetyLogicHarness
/// @notice Verification harness for MarketRegistry.conf: the unchanged MarketRegistrySafetyLogic plus one view that
/// compares its implementation immutables with given addresses. The MarketRegistry constructor accepts a logic
/// contract only when its immutables hash equals the registry's own (REQ-CONFIG-005), so the two sets of immutables are
/// equal on every deployment; the prover does not run that constructor, and MarketRegistry.spec states the equality
/// through this view. The read views below expose the safety logic's own copy of the registry layout, for the rule
/// that checks `freezeAll` on that copy (the prover leaves the router's 4-byte `freezeAll` delegatecall unresolved).
/// The router delegatecalls only the selectors it serves, so these views are never reached through it.
contract MarketRegistrySafetyLogicHarness is MarketRegistrySafetyLogic {
    constructor(
        MarketRegistryImmutables memory im
    ) MarketRegistrySafetyLogic(im) {}

    /// @notice True when the protected-set immutables equal the given addresses, in MarketRegistryImmutables order.
    function immutablesMatch(
        address timelock,
        address aaveGovernanceExecutor,
        address vaultTokenFactory,
        address aaveAdapter,
        address collateralization,
        address lock,
        address proxyManager,
        address parameterStore,
        address riskModule,
        address lpVaultSwap,
        address payoutEscrow,
        address flashLiquidator
    ) external view returns (bool) {
        return _TIMELOCK == timelock && _AAVE_GOVERNANCE_EXECUTOR == aaveGovernanceExecutor
            && _VAULT_TOKEN_FACTORY == vaultTokenFactory && _AAVE_ADAPTER == aaveAdapter
            && _COLLATERALIZATION == collateralization && _LOCK == lock && _PROXY_MANAGER == proxyManager
            && _PARAMETER_STORE == parameterStore && _RISK_MODULE == riskModule && _LP_VAULT_SWAP == lpVaultSwap
            && _PAYOUT_ESCROW == payoutEscrow && _FLASH_LIQUIDATOR == flashLiquidator;
    }

    /// @notice The pause state of `hub` in this contract's copy of the registry layout.
    function pauseStateOf(
        address hub
    ) external view returns (uint8) {
        return uint8(_s().pauseState[hub]);
    }

    /// @notice The pause reason of `hub` in this contract's copy of the registry layout.
    function pauseReasonOf(
        address hub
    ) external view returns (uint8) {
        return uint8(_s().pauseReason[hub]);
    }

    /// @notice The address-freeze flag of `account` in this contract's copy of the registry layout.
    function isFrozenAddressOf(
        address account
    ) external view returns (bool) {
        return _s().frozen[account];
    }
}
