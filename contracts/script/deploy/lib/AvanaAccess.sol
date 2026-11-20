// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaRoles} from "../../../src/access/AvanaRoles.sol";
import {IFirstLossReserve} from "../../../src/reserve/interfaces/IFirstLossReserve.sol";
import {IRiskModule} from "../../../src/risk/interfaces/IRiskModule.sol";
import {IVaultToken} from "../../../src/token/interfaces/IVaultToken.sol";
import {ILPVault} from "../../../src/vault/interfaces/ILPVault.sol";

/// @title AvanaAccess
/// @notice Avana's AccessManager roles, their labels, the execution delay of each role and the map of every restricted
/// core function to its role.
/// @dev Shared by the deploy scripts and the tests. The tighten role carries 12 hours, the governance role 4 to 5 days
/// and First-Loss Reserve `withdraw` 14 days (on the Aave AccessManager, `08_AaveLossLayersPayload`). The governance
/// Safe, the manager's admin, is the guardian of every role and can cancel any scheduled operation.
/// Contract-to-contract calls take core roles of their own, one set per integration (`coreRole`), so the adapter of
/// one LPVault cannot call another LPVault: `100 · integrationId + kind`, each held by one contract with no delay.
library AvanaAccess {
    /// @notice Core role kinds (`coreRole`): the RiskModule on `LPVault.listMarket`.
    uint64 internal constant CORE_RISK_MODULE = 1;
    /// @notice The AaveAdapter on the LPVault's user flows and on each vault token's `mint` and `addValidProxy`.
    uint64 internal constant CORE_ADAPTER = 2;
    /// @notice The LiquidationModule on `LPVault.unwind`.
    uint64 internal constant CORE_LIQUIDATION = 3;
    /// @notice `VaultToken.burn`, held by both the AaveAdapter (withdrawals) and the LiquidationModule (seized units).
    uint64 internal constant CORE_BURN = 4;

    /// @notice Highest integration id a core role can carry.
    uint32 internal constant MAX_INTEGRATION_ID = 99;

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

    /// @notice The core role of `kind` for integration `integrationId`: `100 · integrationId + kind`.
    function coreRole(
        uint32 integrationId,
        uint64 kind
    ) internal pure returns (uint64) {
        require(integrationId != 0 && integrationId <= MAX_INTEGRATION_ID, "AvanaAccess: integration id 1-99");
        require(kind >= CORE_RISK_MODULE && kind <= CORE_BURN, "AvanaAccess: unknown core role");
        return 100 * uint64(integrationId) + kind;
    }

    /// @notice The label of a core role, for example `AVANA_I1_ADAPTER_ROLE`.
    function coreRoleLabel(
        uint32 integrationId,
        uint64 kind
    ) internal pure returns (string memory) {
        string memory k = kind == CORE_RISK_MODULE
            ? "RISK_MODULE"
            : kind == CORE_ADAPTER ? "ADAPTER" : kind == CORE_LIQUIDATION ? "LIQUIDATION" : "BURN";
        return string.concat("AVANA_I", _uintToString(integrationId), "_", k, "_ROLE");
    }

    /// @notice `LPVault.listMarket`: the RiskModule.
    function lpVaultRiskSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = ILPVault.listMarket.selector;
    }

    /// @notice The LPVault's user flows: the AaveAdapter.
    function lpVaultAdapterSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](5);
        s[0] = ILPVault.pledge.selector;
        s[1] = ILPVault.addLiquidity.selector;
        s[2] = ILPVault.removeLiquidity.selector;
        s[3] = ILPVault.release.selector;
        s[4] = ILPVault.collectFees.selector;
    }

    /// @notice `LPVault.unwind`: the LiquidationModule.
    function lpVaultLiquidationSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = ILPVault.unwind.selector;
    }

    /// @notice A vault token's `mint` and `addValidProxy`: the AaveAdapter.
    function vaultTokenAdapterSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = IVaultToken.mint.selector;
        s[1] = IVaultToken.addValidProxy.selector;
    }

    /// @notice A vault token's `burn`: the burn role.
    function vaultTokenBurnSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IVaultToken.burn.selector;
    }

    /// @notice RiskModule setters that only make the protocol safer: removals. The tighten role (12 hours).
    function riskModuleTightenSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = IRiskModule.removeDebtReserve.selector;
        s[1] = IRiskModule.removeKeeper.selector;
    }

    /// @notice Every other RiskModule setter, listing and registration. The governance role (4 to 5 days).
    function riskModuleGovernanceSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](8);
        s[0] = IRiskModule.registerSpoke.selector;
        s[1] = IRiskModule.setSpokeWidth.selector;
        s[2] = IRiskModule.listPool.selector;
        s[3] = IRiskModule.activateMarket.selector;
        s[4] = IRiskModule.setDebtReserve.selector;
        s[5] = IRiskModule.setCoverageRatio.selector;
        s[6] = IRiskModule.setFee.selector;
        s[7] = IRiskModule.addKeeper.selector;
    }

    /// @notice First-Loss Reserve `coverDeficit`: the coverage caller (Aave AccessManager).
    function reserveCoverageSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IFirstLossReserve.coverDeficit.selector;
    }

    /// @notice First-Loss Reserve `setAllowedSpoke` and `setMinimum`: the reserve admin (Aave AccessManager).
    function reserveAdminSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = IFirstLossReserve.setAllowedSpoke.selector;
        s[1] = IFirstLossReserve.setMinimum.selector;
    }

    /// @notice First-Loss Reserve `withdraw`: the withdraw role, held with the 14-day delay (Aave AccessManager).
    function reserveWithdrawSelectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = IFirstLossReserve.withdraw.selector;
    }

    function _uintToString(
        uint256 v
    ) private pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len;
        for (uint256 x = v; x != 0; x /= 10) {
            ++len;
        }
        bytes memory b = new bytes(len);
        for (; v != 0; v /= 10) {
            // A decimal digit.
            // forge-lint: disable-next-line(unsafe-typecast)
            b[--len] = bytes1(uint8(48 + v % 10));
        }
        return string(b);
    }

    /// @notice The roles Avana adds to the manager, in id order.
    function roles() internal pure returns (uint64[] memory ids) {
        ids = new uint64[](3);
        ids[0] = AvanaRoles.TIGHTEN_ROLE;
        ids[1] = AvanaRoles.GOVERNANCE_ROLE;
        ids[2] = AvanaRoles.RESERVE_WITHDRAW_ROLE;
    }
}
