// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SelectorPair} from "../../../src/governance/timelock/IAvanaTimelock.sol";
import {ILPVaultSwap} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {IMarketRegistry} from "../../../src/policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryRoutes} from "../../../src/policy/market-registry/IMarketRegistryRoutes.sol";
import {IParameterStore} from "../../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreTighten} from "../../../src/policy/parameter-store/IParameterStoreTighten.sol";

/// @title TimelockShortDelayLists
/// @notice The AvanaTimelock's short-delay list (= `SHORT_ELIGIBLE`) and DAO-only cancel set of 2.15
/// ("Delay classes and timing", `REQ-ACCESS-155`, `REQ-ACCESS-156`), built from the interfaces for given target
/// addresses: 16 ParameterStore tighten setters, 10 MarketRegistry selectors and LPVaultSwap `removeKeeper`; and
/// MarketRegistry `restoreRoute`, `unfreezeAddress` with LPVaultSwap `addKeeper`.
library TimelockShortDelayLists {
    uint256 internal constant SHORT_COUNT = 27;
    uint256 internal constant DAO_COUNT = 3;

    function shortEligible(
        address parameterStore,
        address marketRegistry,
        address lpVaultSwap
    ) internal pure returns (SelectorPair[] memory pairs) {
        bytes4[16] memory ps = [
            IParameterStoreTighten.tightenSlippageAllowanceBps.selector,
            IParameterStoreTighten.tightenFloorRoundingAllowance.selector,
            IParameterStoreTighten.tightenBorrowPriceMaxAge.selector,
            IParameterStoreTighten.tightenPoolRiskFactor.selector,
            IParameterStoreTighten.tightenRouteDepthThreshold.selector,
            IParameterStoreTighten.tightenMarketUsdCap.selector,
            IParameterStoreTighten.tightenTopUpSliceUsd.selector,
            IParameterStoreTighten.tightenTokenUsdCap.selector,
            IParameterStoreTighten.tightenMinPledgeUsd.selector,
            IParameterStore.tightenBreakerDeficitMax.selector,
            IParameterStore.tightenGateRecoverySeconds.selector,
            IParameterStore.tightenMaxShortfallBps.selector,
            IParameterStore.tightenDebtStressRiseBps.selector,
            IParameterStore.tightenMaxFlashFeeBps.selector,
            IParameterStore.tightenMarketSpeedLimits.selector,
            IParameterStore.tightenDebtSpeedLimit.selector
        ];
        bytes4[10] memory mr = [
            IMarketRegistryRoutes.disableRoute.selector,
            IMarketRegistryRoutes.restoreRoute.selector,
            IMarketRegistry.setMarketOffboarding.selector,
            IMarketRegistry.activateMarket.selector,
            IMarketRegistry.cancelRegistration.selector,
            IMarketRegistry.freeze.selector,
            IMarketRegistry.pause.selector,
            IMarketRegistry.freezeAddress.selector,
            IMarketRegistry.tripMarketBreaker.selector,
            IMarketRegistry.tripDebtBreaker.selector
        ];
        pairs = new SelectorPair[](SHORT_COUNT);
        for (uint256 i; i < ps.length; ++i) {
            pairs[i] = SelectorPair(parameterStore, ps[i]);
        }
        for (uint256 i; i < mr.length; ++i) {
            pairs[ps.length + i] = SelectorPair(marketRegistry, mr[i]);
        }
        pairs[SHORT_COUNT - 1] = SelectorPair(lpVaultSwap, ILPVaultSwap.removeKeeper.selector);
    }

    function daoOnlyCancel(
        address marketRegistry,
        address lpVaultSwap
    ) internal pure returns (SelectorPair[] memory pairs) {
        pairs = new SelectorPair[](DAO_COUNT);
        pairs[0] = SelectorPair(marketRegistry, IMarketRegistryRoutes.restoreRoute.selector);
        pairs[1] = SelectorPair(marketRegistry, IMarketRegistry.unfreezeAddress.selector);
        pairs[2] = SelectorPair(lpVaultSwap, ILPVaultSwap.addKeeper.selector);
    }
}
