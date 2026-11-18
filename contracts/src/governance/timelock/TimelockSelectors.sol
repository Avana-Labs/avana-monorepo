// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapAdmin} from "../../liquidation/lp-vault-swap/ILPVaultSwapAdmin.sol";
import {IDebtOracle} from "../../oracle/debt-oracle/IDebtOracle.sol";
import {ILPOracle} from "../../oracle/lp-oracle/ILPOracle.sol";
import {IAaveAdapterAdmin} from "../../policy/aave-adapter/IAaveAdapterAdmin.sol";
import {IMarketRegistry} from "../../policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryRoutes} from "../../policy/market-registry/IMarketRegistryRoutes.sol";
import {IParameterStore} from "../../policy/parameter-store/IParameterStore.sol";
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
            || selector == IMarketRegistry.setFlashSource.selector
            || selector == IMarketRegistry.deployCdpSpoke.selector
            || selector == IMarketRegistry.listCollateralMarket.selector
            || selector == IMarketRegistry.enableDebtReserve.selector
            || selector == IMarketRegistry.setCrossHubLinesEnabled.selector
            || selector == IMarketRegistry.setCrossHubLine.selector || _isInitializer(selector);
    }

    /// @notice Whether `selector` is on the fixed short-delay list.
    function isShortDelayListSelector(
        bytes4 selector
    ) internal pure returns (bool) {
        return _isTightenSelector(selector) || selector == IMarketRegistryRoutes.disableRoute.selector
            || selector == IMarketRegistryRoutes.restoreRoute.selector
            || selector == IMarketRegistry.setMarketOffboarding.selector
            || selector == IMarketRegistry.activateMarket.selector
            || selector == IMarketRegistry.cancelRegistration.selector || selector == IMarketRegistry.freeze.selector
            || selector == IMarketRegistry.pause.selector || selector == IMarketRegistry.freezeAddress.selector
            || selector == IMarketRegistry.tripMarketBreaker.selector
            || selector == IMarketRegistry.tripDebtBreaker.selector
            || selector == IMarketRegistry.useStandbyRoute.selector
            || selector == ILPVaultSwapAdmin.removeKeeper.selector;
    }

    /// @notice Whether `selector` is in the DAO-only cancel set.
    function isDaoCancelSelector(
        bytes4 selector
    ) internal pure returns (bool) {
        return selector == IMarketRegistryRoutes.restoreRoute.selector
            || selector == IMarketRegistry.useStandbyRoute.selector
            || selector == IMarketRegistry.unfreezeAddress.selector || selector == ILPVaultSwapAdmin.addKeeper.selector;
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
            || s == IParameterStore.tightenBreakerDeficitMax.selector
            || s == IParameterStore.tightenGateRecoverySeconds.selector
            || s == IParameterStore.tightenMaxShortfallBps.selector
            || s == IParameterStore.tightenDebtStressRiseBps.selector
            || s == IParameterStore.tightenMaxFlashFeeBps.selector
            || s == IParameterStore.tightenMarketSpeedLimits.selector
            || s == IParameterStore.tightenDebtSpeedLimit.selector;
    }

    function _isInitializer(
        bytes4 selector
    ) private pure returns (bool) {
        return selector == IAaveAdapterAdmin.initialize.selector || selector == IRiskModuleAdmin.initialize.selector
            || selector == IMarketRegistry.initialize.selector || selector == IParameterStore.initialize.selector
            || selector == ILPOracle.initialize.selector || selector == IDebtOracle.initialize.selector
            || selector == ILPVaultSwapAdmin.initialize.selector;
    }
}
