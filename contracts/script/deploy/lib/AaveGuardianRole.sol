// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title AaveGuardianRole
/// @notice The Aave Protocol Guardian's grant the deployment AIP asks the Aave DAO for (REQ-ACCESS-070): the one-way
/// `freezeReserve` and `pauseReserve` of the chain's SpokeConfigurator, moved from the SpokeConfigurator Domain Admin
/// role (400) to a role of their own, held by the Guardian and by every Domain Admin holder (the Aave governance
/// executor), so the DAO keeps both. AccessManager scopes a role by (target, selector), and one SpokeConfigurator
/// serves every Spoke of the chain, so the grant is chain-wide; using it only on Avana's Spokes, and only
/// `freezeReserve` on a Lend Spoke, is playbook P-18's procedure.
/// @dev The role id is outside every range the pinned Aave V4 source uses (aave-v4 a3ef63e,
/// src/deployments/utils/libraries/Roles.sol: AccessManager 0, Hub 100-199, HubConfigurator 200-299, Spoke 300-399,
/// SpokeConfigurator 400-499), next to the Avana roles already on the Aave AccessManager (500 and 501, the loss-layer
/// roles of 08_AaveLossLayersPayload). It is read from the config (`aavePayload.guardianRole`).
library AaveGuardianRole {
    string internal constant LABEL = "AVANA_RESERVE_GUARDIAN_ROLE";

    /// @notice SpokeConfigurator Domain Admin role (aave-v4 Roles.SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE).
    uint64 internal constant SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE = 400;

    /// @notice `freezeReserve(address,uint256)` and `pauseReserve(address,uint256)` of the SpokeConfigurator: each sets
    /// its flag, never clears it (`updateFrozen` and `updatePaused` do both and stay with the Domain Admin).
    function selectors() internal pure returns (bytes4[] memory s) {
        s = new bytes4[](2);
        s[0] = bytes4(keccak256("freezeReserve(address,uint256)"));
        s[1] = bytes4(keccak256("pauseReserve(address,uint256)"));
    }
}
