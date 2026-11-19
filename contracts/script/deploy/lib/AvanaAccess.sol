// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAvanaFirstLossReserve} from "../../../src/coverage/first-loss-reserve/IAvanaFirstLossReserve.sol";
import {AvanaRoles} from "../../../src/governance/roles/AvanaRoles.sol";
import {ILegacyLPVault} from "../../../src/legacy/ILegacyLPVault.sol";
import {ILegacyVaultTokenFactory} from "../../../src/legacy/ILegacyVaultTokenFactory.sol";
import {ILPVaultSwap} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwap.sol";
import {IMarketRegistry} from "../../../src/policy/market-registry/IMarketRegistry.sol";
import {IMarketRegistryRoutes} from "../../../src/policy/market-registry/IMarketRegistryRoutes.sol";
import {IParameterStore} from "../../../src/policy/parameter-store/IParameterStore.sol";
import {IParameterStoreListing} from "../../../src/policy/parameter-store/IParameterStoreListing.sol";
import {IParameterStoreLoosen} from "../../../src/policy/parameter-store/IParameterStoreLoosen.sol";
import {IParameterStoreTighten} from "../../../src/policy/parameter-store/IParameterStoreTighten.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// @title AvanaAccess
/// @notice The one map of Avana's governed functions to AccessManager roles, and the execution delay of each role.
/// @dev Shared by the deploy scripts (`04_ConfigureAccess`) and the tests, so both set the same
/// `setTargetFunctionRole` calls. The tighten role holds the selectors that make a value safer (12 hours); every other
/// governed function takes the governance role (4 to 5 days); First-Loss Reserve `withdraw` takes the withdraw role
/// (14 days). The DAO, the manager's admin, is the guardian of every role and can cancel any scheduled operation.
library AvanaAccess {
    /// @notice The contract a governed function belongs to.
    enum Kind {
        ParameterStore,
        MarketRegistry,
        LPVaultSwap,
        VaultTokenFactory,
        LegacyRiskModule,
        AaveAdapter,
        LpVault,
        FirstLossReserve
    }

    /// @notice One governed function of a kind of contract and the role that may call it.
    struct Binding {
        Kind kind;
        bytes4 selector;
        uint64 role;
    }

    /// @notice Execution delay of the tighten role for the governance Safe: 12 hours.
    uint32 internal constant TIGHTEN_DELAY = 12 hours;

    /// @notice Lowest governance delay: 4 days.
    uint32 internal constant GOVERNANCE_DELAY_MIN = 4 days;

    /// @notice Highest governance delay: 5 days.
    uint32 internal constant GOVERNANCE_DELAY_MAX = 5 days;

    /// @notice Execution delay of the First-Loss Reserve withdraw role: 14 days.
    uint32 internal constant RESERVE_WITHDRAW_DELAY = 14 days;

    /// @notice The governance delay: `normalDelay` (the config's `timelockNormalDelay`) when it lies between 4 and 5
    /// days, else 4 days.
    function governanceDelay(
        uint256 normalDelay
    ) internal pure returns (uint32) {
        if (normalDelay < GOVERNANCE_DELAY_MIN || normalDelay > GOVERNANCE_DELAY_MAX) return GOVERNANCE_DELAY_MIN;
        // Bounded by `GOVERNANCE_DELAY_MAX`.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(normalDelay);
    }

    /// @notice The execution delay a role carries for the governance Safe.
    function roleDelay(
        uint64 role,
        uint256 normalDelay
    ) internal pure returns (uint32) {
        if (role == AvanaRoles.TIGHTEN_ROLE) return TIGHTEN_DELAY;
        if (role == AvanaRoles.GOVERNANCE_ROLE) return governanceDelay(normalDelay);
        if (role == AvanaRoles.RESERVE_WITHDRAW_ROLE) return RESERVE_WITHDRAW_DELAY;
        revert("AvanaAccess: unknown role");
    }

    /// @notice The label of a role.
    function roleLabel(
        uint64 role
    ) internal pure returns (string memory) {
        if (role == AvanaRoles.TIGHTEN_ROLE) return AvanaRoles.TIGHTEN_LABEL;
        if (role == AvanaRoles.GOVERNANCE_ROLE) return AvanaRoles.GOVERNANCE_LABEL;
        if (role == AvanaRoles.RESERVE_WITHDRAW_ROLE) return AvanaRoles.RESERVE_WITHDRAW_LABEL;
        revert("AvanaAccess: unknown role");
    }

    /// @notice The roles Avana adds to the manager, in id order.
    function roles() internal pure returns (uint64[] memory ids) {
        ids = new uint64[](3);
        ids[0] = AvanaRoles.TIGHTEN_ROLE;
        ids[1] = AvanaRoles.GOVERNANCE_ROLE;
        ids[2] = AvanaRoles.RESERVE_WITHDRAW_ROLE;
    }

    /// @notice The selectors of `kind` that `role` may call.
    function selectorsOf(
        Kind kind,
        uint64 role
    ) internal pure returns (bytes4[] memory out) {
        Binding[] memory all = bindings();
        uint256 n;
        for (uint256 i = 0; i < all.length; ++i) {
            if (all[i].kind == kind && all[i].role == role) ++n;
        }
        out = new bytes4[](n);
        n = 0;
        for (uint256 i = 0; i < all.length; ++i) {
            if (all[i].kind == kind && all[i].role == role) out[n++] = all[i].selector;
        }
    }

    /// @notice The role of one governed function of `kind`; reverts when it is not governed.
    function roleOf(
        Kind kind,
        bytes4 selector
    ) internal pure returns (uint64) {
        Binding[] memory all = bindings();
        for (uint256 i = 0; i < all.length; ++i) {
            if (all[i].kind == kind && all[i].selector == selector) return all[i].role;
        }
        revert("AvanaAccess: selector not governed");
    }

    /// @notice Every governed function of Avana with its role.
    function bindings() internal pure returns (Binding[] memory b) {
        b = new Binding[](89);
        uint256 n;
        n = _parameterStore(b, n);
        n = _marketRegistry(b, n);
        n = _others(b, n);
        // Shrinks the array to its filled length.
        assembly ("memory-safe") {
            mstore(b, n)
        }
    }

    function _parameterStore(
        Binding[] memory b,
        uint256 n
    ) private pure returns (uint256) {
        Kind k = Kind.ParameterStore;
        uint64 t = AvanaRoles.TIGHTEN_ROLE;
        uint64 g = AvanaRoles.GOVERNANCE_ROLE;
        // Tighten (the risk steward calls these at once): the setters that only make a value safer, and the fee share.
        b[n++] = Binding(k, IParameterStoreTighten.tightenSlippageAllowanceBps.selector, t);
        b[n++] = Binding(k, IParameterStoreTighten.tightenFloorRoundingAllowance.selector, t);
        b[n++] = Binding(k, IParameterStoreTighten.tightenBorrowPriceMaxAge.selector, t);
        b[n++] = Binding(k, IParameterStoreTighten.tightenPoolRiskFactor.selector, t);
        b[n++] = Binding(k, IParameterStoreTighten.tightenRouteDepthThreshold.selector, t);
        b[n++] = Binding(k, IParameterStoreTighten.tightenMarketUsdCap.selector, t);
        b[n++] = Binding(k, IParameterStoreTighten.tightenTopUpSliceUsd.selector, t);
        b[n++] = Binding(k, IParameterStoreTighten.tightenTokenUsdCap.selector, t);
        b[n++] = Binding(k, IParameterStoreTighten.tightenMinPledgeUsd.selector, t);
        b[n++] = Binding(k, IParameterStore.tightenDeficitMax.selector, t);
        b[n++] = Binding(k, IParameterStore.tightenMaxShortfallBps.selector, t);
        b[n++] = Binding(k, IParameterStore.tightenDebtStressRiseBps.selector, t);
        b[n++] = Binding(k, IParameterStore.tightenMaxFlashFeeBps.selector, t);
        b[n++] = Binding(k, IParameterStore.tightenMarketDynamicCap.selector, t);
        b[n++] = Binding(k, IParameterStore.setAvanaFeeShareBps.selector, t);
        // Governance.
        b[n++] = Binding(k, IParameterStoreLoosen.loosenSlippageAllowanceBps.selector, g);
        b[n++] = Binding(k, IParameterStoreLoosen.loosenFloorRoundingAllowance.selector, g);
        b[n++] = Binding(k, IParameterStoreLoosen.loosenRouteDepthThreshold.selector, g);
        b[n++] = Binding(k, IParameterStoreLoosen.loosenMarketUsdCap.selector, g);
        b[n++] = Binding(k, IParameterStoreLoosen.loosenTopUpSliceUsd.selector, g);
        b[n++] = Binding(k, IParameterStoreLoosen.loosenTokenUsdCap.selector, g);
        b[n++] = Binding(k, IParameterStoreLoosen.loosenMinPledgeUsd.selector, g);
        b[n++] = Binding(k, IParameterStore.loosenDeficitMax.selector, g);
        b[n++] = Binding(k, IParameterStore.loosenMaxShortfallBps.selector, g);
        b[n++] = Binding(k, IParameterStore.loosenDebtStressRiseBps.selector, g);
        b[n++] = Binding(k, IParameterStore.loosenMarketDynamicCap.selector, g);
        b[n++] = Binding(k, IParameterStore.setCoverageRatioBps.selector, g);
        b[n++] = Binding(k, IParameterStore.setBorrowPriceMaxAge.selector, g);
        b[n++] = Binding(k, IParameterStore.setPoolRiskFactor.selector, g);
        b[n++] = Binding(k, IParameterStore.setFeeRecipient.selector, g);
        b[n++] = Binding(k, IParameterStore.setMaxFlashFeeBps.selector, g);
        b[n++] = Binding(k, IParameterStore.setLiquidationPriceMaxAge.selector, g);
        b[n++] = Binding(k, IParameterStore.setFeedMaxAge.selector, g);
        b[n++] = Binding(k, IParameterStore.setSlippageAllowanceMinBps.selector, g);
        b[n++] = Binding(k, IParameterStore.setTokenCollateralFactorBps.selector, g);
        b[n++] = Binding(k, IParameterStore.setStressFloorUsd.selector, g);
        b[n++] = Binding(k, IParameterStoreListing.setInitialMarketParams.selector, g);
        b[n++] = Binding(k, IParameterStoreListing.setInitialMarketCaps.selector, g);
        b[n++] = Binding(k, IParameterStoreListing.setInitialTokenCap.selector, g);
        b[n++] = Binding(k, IParameterStoreListing.setFeed.selector, g);
        b[n++] = Binding(k, IParameterStoreListing.setDebtAssetParams.selector, g);
        b[n++] = Binding(k, UUPSUpgradeable.upgradeToAndCall.selector, g);
        return n;
    }

    function _marketRegistry(
        Binding[] memory b,
        uint256 n
    ) private pure returns (uint256) {
        Kind k = Kind.MarketRegistry;
        uint64 t = AvanaRoles.TIGHTEN_ROLE;
        uint64 g = AvanaRoles.GOVERNANCE_ROLE;
        b[n++] = Binding(k, IMarketRegistryRoutes.disableRoute.selector, t);
        b[n++] = Binding(k, IMarketRegistryRoutes.restoreRoute.selector, t);
        b[n++] = Binding(k, IMarketRegistry.setMarketOffboarding.selector, t);
        b[n++] = Binding(k, IMarketRegistry.activateMarket.selector, t);
        b[n++] = Binding(k, IMarketRegistry.cancelRegistration.selector, t);
        b[n++] = Binding(k, IMarketRegistry.recordHub.selector, g);
        b[n++] = Binding(k, IMarketRegistry.setAvanaFirstLossReserve.selector, g);
        b[n++] = Binding(k, IMarketRegistry.setFlashSource.selector, g);
        b[n++] = Binding(k, IMarketRegistry.approveSpokeCodeHash.selector, g);
        b[n++] = Binding(k, IMarketRegistry.recordIntegrationContracts.selector, g);
        b[n++] = Binding(k, IMarketRegistry.finalizeIntegrationContracts.selector, g);
        b[n++] = Binding(k, IMarketRegistry.deployCdpSpoke.selector, g);
        b[n++] = Binding(k, IMarketRegistry.enableDebtReserve.selector, g);
        b[n++] = Binding(k, IMarketRegistry.removeDebtReserve.selector, g);
        b[n++] = Binding(k, IMarketRegistry.listToken.selector, g);
        b[n++] = Binding(k, IMarketRegistry.setPriceSource.selector, g);
        b[n++] = Binding(k, IMarketRegistry.listCollateralMarket.selector, g);
        b[n++] = Binding(k, IMarketRegistryRoutes.setRoute.selector, g);
        b[n++] = Binding(k, IMarketRegistry.setSettlementReserve.selector, g);
        b[n++] = Binding(k, UUPSUpgradeable.upgradeToAndCall.selector, g);
        return n;
    }

    function _others(
        Binding[] memory b,
        uint256 n
    ) private pure returns (uint256) {
        uint64 t = AvanaRoles.TIGHTEN_ROLE;
        uint64 g = AvanaRoles.GOVERNANCE_ROLE;
        b[n++] = Binding(Kind.LPVaultSwap, ILPVaultSwap.removeKeeper.selector, t);
        b[n++] = Binding(Kind.LPVaultSwap, ILPVaultSwap.addKeeper.selector, g);
        b[n++] = Binding(Kind.LPVaultSwap, UUPSUpgradeable.upgradeToAndCall.selector, g);
        b[n++] = Binding(Kind.VaultTokenFactory, ILegacyVaultTokenFactory.registerIntegration.selector, g);
        b[n++] = Binding(Kind.VaultTokenFactory, ILegacyVaultTokenFactory.deployVaultToken.selector, g);
        b[n++] = Binding(Kind.LegacyRiskModule, UUPSUpgradeable.upgradeToAndCall.selector, g);
        b[n++] = Binding(Kind.AaveAdapter, UUPSUpgradeable.upgradeToAndCall.selector, g);
        b[n++] = Binding(Kind.LpVault, ILegacyLPVault.returnStray.selector, g);
        b[n++] =
            Binding(Kind.FirstLossReserve, IAvanaFirstLossReserve.withdraw.selector, AvanaRoles.RESERVE_WITHDRAW_ROLE);
        return n;
    }
}
