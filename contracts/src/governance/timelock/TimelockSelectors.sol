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
import {IParameterStoreSpeed} from "../../policy/parameter-store/IParameterStoreSpeed.sol";
import {IParameterStoreTighten} from "../../policy/parameter-store/IParameterStoreTighten.sol";
import {IRiskModuleAdmin} from "../../policy/risk-module/IRiskModuleAdmin.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title TimelockSelectors
/// @notice Selectors the AvanaTimelock classifies: role changes, never-short selectors, the short-delay list and
/// the DAO-only cancel set.
/// @dev Selectors come from their declaring interfaces, so a signature change fails to compile here.
library TimelockSelectors {
    /// @notice Whether `selector` is `grantRole`, `revokeRole` or `renounceRole`.
    function isRoleSelector(
        bytes4 selector
    ) internal pure returns (bool) {
        return selector == IAccessControl.grantRole.selector || selector == IAccessControl.revokeRole.selector
            || selector == IAccessControl.renounceRole.selector;
    }

    /// @notice Whether `selector` may never be on the short-delay list or in the DAO-only cancel set.
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

    /// @notice Whether `selector` is on the fixed short-delay list.
    function isShortDelayListSelector(
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

    /// @notice Whether `selector` is in the DAO-only cancel set.
    function isDaoCancelSelector(
        bytes4 selector
    ) internal pure returns (bool) {
        return selector == IMarketRegistryRoutes.restoreRoute.selector
            || selector == IMarketRegistryStandby.useStandbyRoute.selector
            || selector == IMarketRegistryFreeze.unfreezeAddress.selector
            || selector == ILPVaultSwapAdmin.addKeeper.selector;
    }

    /// @notice Owner of a short-eligible or DAO-only selector: 1 ParameterStore, 2 MarketRegistry, 3 LPVaultSwap,
    /// 0 none.
    function ownerKind(
        bytes4 selector
    ) internal pure returns (uint8) {
        if (_isTightenSelector(selector)) return 1;
        if (selector == ILPVaultSwapAdmin.removeKeeper.selector || selector == ILPVaultSwapAdmin.addKeeper.selector) {
            return 3;
        }
        if (isShortDelayListSelector(selector) || isDaoCancelSelector(selector)) return 2;
        return 0;
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
            || s == IParameterStoreTighten.tightenPoolShareMaxBps.selector
            || s == IParameterStoreTighten.tightenPoolShareMaxBpsOf.selector
            || s == IParameterStoreTighten.tightenMinPledgeUsd.selector
            || s == IParameterStoreBreakers.tightenBreakerDeficitMax.selector
            || s == IParameterStoreBreakers.tightenGateRecoverySeconds.selector
            || s == IParameterStoreLiquidation.tightenMaxShortfallBps.selector
            || s == IParameterStoreLiquidation.tightenDebtStressRiseBps.selector
            || s == IParameterStoreAdmin.tightenMaxFlashFeeBps.selector
            || s == IParameterStoreSpeed.tightenMarketSpeedLimits.selector
            || s == IParameterStoreSpeed.tightenDebtSpeedLimit.selector;
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
