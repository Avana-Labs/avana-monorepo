// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapAdmin} from "../../liquidation/lp-vault-swap/ILPVaultSwapAdmin.sol";
import {IDebtOracle} from "../../oracle/debt-oracle/IDebtOracle.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {IAaveAdapterAdmin} from "../../policy/aave-adapter/IAaveAdapterAdmin.sol";
import {IMarketRegistryBreakers} from "../../policy/market-registry/IMarketRegistryBreakers.sol";
import {IMarketRegistryFreeze} from "../../policy/market-registry/IMarketRegistryFreeze.sol";
import {IMarketRegistryHubs} from "../../policy/market-registry/IMarketRegistryHubs.sol";
import {IMarketRegistryListing} from "../../policy/market-registry/IMarketRegistryListing.sol";
import {IMarketRegistryPause} from "../../policy/market-registry/IMarketRegistryPause.sol";
import {IMarketRegistryRoutes} from "../../policy/market-registry/IMarketRegistryRoutes.sol";
import {IMarketRegistryStandby} from "../../policy/market-registry/IMarketRegistryStandby.sol";
import {IParameterStoreAdmin} from "../../policy/parameter-store/IParameterStoreAdmin.sol";
import {IParameterStoreBreakers} from "../../policy/parameter-store/IParameterStoreBreakers.sol";
import {IParameterStoreLiquidation} from "../../policy/parameter-store/IParameterStoreLiquidation.sol";
import {IParameterStoreTighten} from "../../policy/parameter-store/IParameterStoreTighten.sol";
import {IRiskModuleAdmin} from "../../policy/risk-module/IRiskModuleAdmin.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title TimelockSelectors
/// @notice The selectors the AvanaTimelock classifies by name: the role selectors that make an operation a role
/// change, and the selectors that may never take the short delay or sit in the DAO-only cancel set.
/// @dev Every selector is taken from the interface that declares it, so a signature change fails to compile here
/// rather than silently changing the class of a call.
/// @custom:spec REQ-ACCESS-142, REQ-ACCESS-143, REQ-ACCESS-155, REQ-ACCESS-156, REQ-ACCESS-181, SPEC-GOV-005
library TimelockSelectors {
    /// @notice Whether `selector` is `grantRole`, `revokeRole` or `renounceRole`.
    /// @custom:spec REQ-ACCESS-019, REQ-ACCESS-143, SPEC-GOV-005
    function isRoleSelector(
        bytes4 selector
    ) internal pure returns (bool) {
        return selector == IAccessControl.grantRole.selector || selector == IAccessControl.revokeRole.selector
            || selector == IAccessControl.renounceRole.selector;
    }

    /// @notice Whether `selector` may never be on the short-delay list or in the DAO-only cancel set: role changes,
    /// upgrades, the flash-source replacement, the three deployment operations, cross-Hub enablement and every
    /// Avana `initialize`.
    /// @custom:spec REQ-ACCESS-142, REQ-ACCESS-181
    function isNeverShort(
        bytes4 selector
    ) internal pure returns (bool) {
        return isRoleSelector(selector) || selector == UUPSUpgradeable.upgradeToAndCall.selector
            || selector == IMarketRegistryHubs.setFlashSource.selector
            || selector == IMarketRegistryListing.deployCdpSpoke.selector
            || selector == IMarketRegistryListing.listCollateralMarket.selector
            || selector == IMarketRegistryListing.enableDebtReserve.selector
            || selector == IMarketRegistryHubs.setCrossHubLinesEnabled.selector
            || selector == IMarketRegistryHubs.setCrossHubLine.selector || _isInitializer(selector);
    }

    /// @notice Whether `selector` is one of the 32 selectors of the launch short-delay list (`REQ-ACCESS-155`): the
    /// 20 ParameterStore tighten setters, the 11 MarketRegistry stops and repairs, and LPVaultSwap `removeKeeper`.
    /// @custom:spec REQ-ACCESS-142, REQ-ACCESS-155
    function isLaunchShortSelector(
        bytes4 selector
    ) internal pure returns (bool) {
        return _isTightenSelector(selector) || selector == IMarketRegistryRoutes.disableRoute.selector
            || selector == IMarketRegistryRoutes.restoreRoute.selector
            || selector == IMarketRegistryListing.setMarketOffboarding.selector
            || selector == IMarketRegistryListing.activateMarket.selector
            || selector == IMarketRegistryListing.cancelRegistration.selector
            || selector == IMarketRegistryPause.freeze.selector || selector == IMarketRegistryPause.pause.selector
            || selector == IMarketRegistryFreeze.freezeAddress.selector
            || selector == IMarketRegistryBreakers.tripMarketBreaker.selector
            || selector == IMarketRegistryBreakers.tripDebtBreaker.selector
            || selector == IMarketRegistryStandby.useStandbyRoute.selector
            || selector == ILPVaultSwapAdmin.removeKeeper.selector;
    }

    /// @notice Whether `selector` is one of the four of the DAO-only cancel set (`REQ-ACCESS-156`).
    /// @custom:spec REQ-ACCESS-156, REQ-ACCESS-181
    function isDaoCancelSelector(
        bytes4 selector
    ) internal pure returns (bool) {
        return selector == IMarketRegistryRoutes.restoreRoute.selector
            || selector == IMarketRegistryStandby.useStandbyRoute.selector
            || selector == IMarketRegistryFreeze.unfreezeAddress.selector
            || selector == ILPVaultSwapAdmin.addKeeper.selector;
    }

    function _isTightenSelector(
        bytes4 s
    ) private pure returns (bool) {
        return s == IParameterStoreTighten.tightenHardHealthFloor.selector
            || s == IParameterStoreTighten.tightenSlippageAllowanceBps.selector
            || s == IParameterStoreTighten.tightenFloorRoundingAllowance.selector
            || s == IParameterStoreTighten.tightenBorrowPriceMaxAge.selector
            || s == IParameterStoreTighten.tightenConsistencyToleranceBps.selector
            || s == IParameterStoreTighten.tightenFeedAgreementToleranceBps.selector
            || s == IParameterStoreTighten.tightenPoolRiskFactor.selector
            || s == IParameterStoreTighten.tightenRouteDepthThreshold.selector
            || s == IParameterStoreTighten.tightenMarketUsdCap.selector
            || s == IParameterStoreTighten.tightenTopUpSliceUsd.selector
            || s == IParameterStoreTighten.tightenTokenUsdCap.selector
            || s == IParameterStoreTighten.tightenDepositorUsdCap.selector
            || s == IParameterStoreTighten.tightenPoolShareMaxBps.selector
            || s == IParameterStoreTighten.tightenPoolShareMaxBpsOf.selector
            || s == IParameterStoreTighten.tightenMinPledgeUsd.selector
            || s == IParameterStoreBreakers.tightenBreakerDeficitMax.selector
            || s == IParameterStoreBreakers.tightenGateRecoverySeconds.selector
            || s == IParameterStoreLiquidation.tightenMaxShortfallBps.selector
            || s == IParameterStoreLiquidation.tightenDebtStressRiseBps.selector
            || s == IParameterStoreAdmin.tightenMaxFlashFeeBps.selector;
    }

    function _isInitializer(
        bytes4 selector
    ) private pure returns (bool) {
        return selector == IAaveAdapterAdmin.initialize.selector || selector == IRiskModuleAdmin.initialize.selector
            || selector == IMarketRegistryListing.initialize.selector
            || selector == IParameterStoreAdmin.initialize.selector || selector == ILPOracle.initialize.selector
            || selector == IDebtOracle.initialize.selector || selector == ILPVaultSwapAdmin.initialize.selector;
    }
}
