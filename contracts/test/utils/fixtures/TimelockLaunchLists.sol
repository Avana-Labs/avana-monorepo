// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {SelectorPair} from "../../../src/governance/timelock/types/SelectorPair.sol";
import {ILPVaultSwapAdmin} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwapAdmin.sol";
import {IMarketRegistryBreakers} from "../../../src/policy/market-registry/IMarketRegistryBreakers.sol";
import {IMarketRegistryFreeze} from "../../../src/policy/market-registry/IMarketRegistryFreeze.sol";
import {IMarketRegistryListing} from "../../../src/policy/market-registry/IMarketRegistryListing.sol";
import {IMarketRegistryPause} from "../../../src/policy/market-registry/IMarketRegistryPause.sol";
import {IMarketRegistryRoutes} from "../../../src/policy/market-registry/IMarketRegistryRoutes.sol";
import {IMarketRegistryStandby} from "../../../src/policy/market-registry/IMarketRegistryStandby.sol";
import {IParameterStoreAdmin} from "../../../src/policy/parameter-store/IParameterStoreAdmin.sol";
import {IParameterStoreBreakers} from "../../../src/policy/parameter-store/IParameterStoreBreakers.sol";
import {IParameterStoreLiquidation} from "../../../src/policy/parameter-store/IParameterStoreLiquidation.sol";
import {IParameterStoreSpeed} from "../../../src/policy/parameter-store/IParameterStoreSpeed.sol";
import {IParameterStoreTighten} from "../../../src/policy/parameter-store/IParameterStoreTighten.sol";

/// @title TimelockLaunchLists
/// @notice The AvanaTimelock's launch short-delay list (= `SHORT_ELIGIBLE`) and DAO-only cancel set of 2.15
/// ("Delay classes and timing", `REQ-ACCESS-155`, `REQ-ACCESS-156`), built from the interfaces for given target
/// addresses: 22 ParameterStore tighten setters, 11 MarketRegistry selectors and LPVaultSwap `removeKeeper`; and
/// MarketRegistry `restoreRoute`, `useStandbyRoute`, `unfreezeAddress` with LPVaultSwap `addKeeper`.
library TimelockLaunchLists {
    uint256 internal constant SHORT_COUNT = 34;
    uint256 internal constant DAO_COUNT = 4;

    function shortEligible(
        address parameterStore,
        address marketRegistry,
        address lpVaultSwap
    ) internal pure returns (SelectorPair[] memory pairs) {
        bytes4[22] memory ps = [
            IParameterStoreTighten.tightenHardHealthFloor.selector,
            IParameterStoreTighten.tightenSlippageAllowanceBps.selector,
            IParameterStoreTighten.tightenFloorRoundingAllowance.selector,
            IParameterStoreTighten.tightenBorrowPriceMaxAge.selector,
            IParameterStoreTighten.tightenConsistencyToleranceBps.selector,
            IParameterStoreTighten.tightenFeedAgreementToleranceBps.selector,
            IParameterStoreTighten.tightenPoolRiskFactor.selector,
            IParameterStoreTighten.tightenRouteDepthThreshold.selector,
            IParameterStoreTighten.tightenMarketUsdCap.selector,
            IParameterStoreTighten.tightenTopUpSliceUsd.selector,
            IParameterStoreTighten.tightenTokenUsdCap.selector,
            IParameterStoreTighten.tightenDepositorUsdCap.selector,
            IParameterStoreTighten.tightenPoolShareMaxBps.selector,
            IParameterStoreTighten.tightenPoolShareMaxBpsOf.selector,
            IParameterStoreTighten.tightenMinPledgeUsd.selector,
            IParameterStoreBreakers.tightenBreakerDeficitMax.selector,
            IParameterStoreBreakers.tightenGateRecoverySeconds.selector,
            IParameterStoreLiquidation.tightenMaxShortfallBps.selector,
            IParameterStoreLiquidation.tightenDebtStressRiseBps.selector,
            IParameterStoreAdmin.tightenMaxFlashFeeBps.selector,
            IParameterStoreSpeed.tightenMarketSpeedLimits.selector,
            IParameterStoreSpeed.tightenDebtSpeedLimit.selector
        ];
        bytes4[11] memory mr = [
            IMarketRegistryRoutes.disableRoute.selector,
            IMarketRegistryRoutes.restoreRoute.selector,
            IMarketRegistryListing.setMarketOffboarding.selector,
            IMarketRegistryListing.activateMarket.selector,
            IMarketRegistryListing.cancelRegistration.selector,
            IMarketRegistryPause.freeze.selector,
            IMarketRegistryPause.pause.selector,
            IMarketRegistryFreeze.freezeAddress.selector,
            IMarketRegistryBreakers.tripMarketBreaker.selector,
            IMarketRegistryBreakers.tripDebtBreaker.selector,
            IMarketRegistryStandby.useStandbyRoute.selector
        ];
        pairs = new SelectorPair[](SHORT_COUNT);
        for (uint256 i; i < ps.length; ++i) {
            pairs[i] = SelectorPair(parameterStore, ps[i]);
        }
        for (uint256 i; i < mr.length; ++i) {
            pairs[ps.length + i] = SelectorPair(marketRegistry, mr[i]);
        }
        pairs[SHORT_COUNT - 1] = SelectorPair(lpVaultSwap, ILPVaultSwapAdmin.removeKeeper.selector);
    }

    function daoOnlyCancel(
        address marketRegistry,
        address lpVaultSwap
    ) internal pure returns (SelectorPair[] memory pairs) {
        pairs = new SelectorPair[](DAO_COUNT);
        pairs[0] = SelectorPair(marketRegistry, IMarketRegistryRoutes.restoreRoute.selector);
        pairs[1] = SelectorPair(marketRegistry, IMarketRegistryStandby.useStandbyRoute.selector);
        pairs[2] = SelectorPair(marketRegistry, IMarketRegistryFreeze.unfreezeAddress.selector);
        pairs[3] = SelectorPair(lpVaultSwap, ILPVaultSwapAdmin.addKeeper.selector);
    }
}
