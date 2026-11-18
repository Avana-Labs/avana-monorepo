// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwap} from "../../liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {IAaveAdapter} from "../../policy/aave-adapter/IAaveAdapter.sol";
import {IMarketRegistry} from "../../policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryRoutes} from "../../policy/market-registry/IMarketRegistryRoutes.sol";
import {IParameterStore} from "../../policy/parameter-store/IParameterStore.sol";
import {IParameterStoreTighten} from "../../policy/parameter-store/IParameterStoreTighten.sol";
import {IRiskModule} from "../../policy/risk-module/IRiskModule.sol";
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
            || selector == IMarketRegistry.enableDebtReserve.selector || _isInitializer(selector);
    }

    /// @notice Whether `selector` is on the fixed short-delay list.
    function isShortDelayListSelector(
        bytes4 selector
    ) internal pure returns (bool) {
        return _isTightenSelector(selector) || selector == IMarketRegistryRoutes.disableRoute.selector
            || selector == IMarketRegistryRoutes.restoreRoute.selector
            || selector == IMarketRegistry.setMarketOffboarding.selector
            || selector == IMarketRegistry.activateMarket.selector
            || selector == IMarketRegistry.cancelRegistration.selector || selector == ILPVaultSwap.removeKeeper.selector;
    }

    /// @notice Whether `selector` is in the DAO-only cancel set.
    function isDaoCancelSelector(
        bytes4 selector
    ) internal pure returns (bool) {
        return selector == IMarketRegistryRoutes.restoreRoute.selector || selector == ILPVaultSwap.addKeeper.selector;
    }

    /// @notice Owner of a short-eligible or DAO-only selector: 1 ParameterStore, 2 MarketRegistry, 3 LPVaultSwap,
    /// 0 none.
    function ownerKind(
        bytes4 selector
    ) internal pure returns (uint8) {
        if (_isTightenSelector(selector)) return 1;
        if (selector == ILPVaultSwap.removeKeeper.selector || selector == ILPVaultSwap.addKeeper.selector) {
            return 3;
        }
        if (isShortDelayListSelector(selector) || isDaoCancelSelector(selector)) return 2;
        return 0;
    }

    function _isTightenSelector(
        bytes4 s
    ) private pure returns (bool) {
        return s == IParameterStoreTighten.tightenSlippageAllowanceBps.selector
            || s == IParameterStoreTighten.tightenFloorRoundingAllowance.selector
            || s == IParameterStoreTighten.tightenBorrowPriceMaxAge.selector
            || s == IParameterStoreTighten.tightenPoolRiskFactor.selector
            || s == IParameterStoreTighten.tightenRouteDepthThreshold.selector
            || s == IParameterStoreTighten.tightenMarketUsdCap.selector
            || s == IParameterStoreTighten.tightenTopUpSliceUsd.selector
            || s == IParameterStoreTighten.tightenTokenUsdCap.selector
            || s == IParameterStoreTighten.tightenMinPledgeUsd.selector
            || s == IParameterStore.tightenDeficitMax.selector || s == IParameterStore.tightenMaxShortfallBps.selector
            || s == IParameterStore.tightenDebtStressRiseBps.selector
            || s == IParameterStore.tightenMaxFlashFeeBps.selector
            || s == IParameterStore.tightenMarketDynamicCap.selector;
    }

    function _isInitializer(
        bytes4 selector
    ) private pure returns (bool) {
        return selector == IAaveAdapter.initialize.selector || selector == IRiskModule.initialize.selector
            || selector == IMarketRegistry.initialize.selector || selector == IParameterStore.initialize.selector
            || selector == ILPVaultSwap.initialize.selector;
    }
}
