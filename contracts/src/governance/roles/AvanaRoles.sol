// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

/// @title AvanaRoles
/// @notice Role identifiers Avana adds to OpenZeppelin `AccessControl` and `TimelockController`.
/// @dev Holders and delays (2.15 role table). Each chain has its own AvanaTimelock, governance multisig and guardian
/// set; every holder below is the one of the contract's own chain, and no role reaches across chains.
/// - `DEFAULT_ADMIN_ROLE` (OpenZeppelin, `0x00`): the AvanaTimelock only, on itself and on every upgradeable Avana
///   contract (AaveAdapter, RiskModule, MarketRegistry, ParameterStore, each LPOracle, each DebtOracle, LPVaultSwap);
///   the ProxyManager and every PositionProxy are immutable and hold no role (Q-375). Grants and revokes roles, each
///   a role-change operation at the normal delay that only the Aave governance executor can cancel. A grant to any other account reverts `AdminRoleOnlyTimelock`.
/// - `APPLICATION_ADMIN`: the AvanaTimelock only, on every upgradeable Avana contract (a grant to any other account
///   reverts `AdminRoleOnlyTimelock`); role admin `DEFAULT_ADMIN_ROLE`. Guards UUPS upgrades, the replacement of the
///   IFlashSource implementation, the deployment operations (`deployCdpSpoke`, `listCollateralMarket`,
///   `enableDebtReserve`), fee changes, every parameter setter, listings, price sources, routes, debt reserves, keepers,
///   offboarding, the pause switch, the address freeze, breaker trips
///   and resets, and the standby route switch and its reversal; each call runs at the short delay (12 hours) when
///   every call of its operation is on the short-delay list, otherwise at the normal delay (4 to 5 days).
/// - `APPLICATION_PAUSE_GUARDIAN`: on the MarketRegistry, the 3-of-5 Emergency Guardian, the Aave Protocol Guardian
///   and the 2-of-3 Joint Configuration Safe: `pause(reason)`, `unpause`, `unfreeze`, `resetMarketBreaker`,
///   `resetDebtBreaker` and `useStandbyRoute`, immediately; on the ParameterStore, the Emergency Guardian and the
///   Aave Protocol Guardian only: `useStandbySecondSource`, immediately. Role admin `APPLICATION_ADMIN`.
/// - `APPLICATION_FREEZE_GUARDIAN` (MarketRegistry only): the same three holders as on the MarketRegistry above;
///   `freeze`, `freezeAddress`, `tripMarketBreaker` and `tripDebtBreaker`, immediately; role admin
///   `APPLICATION_ADMIN`. A key holding only this role can never undo a freeze, an address freeze or a breaker trip.
/// - `APPLICATION_RISK_STEWARD` (ParameterStore only): the 2-of-3 Joint Configuration Safe (one Avana Labs, one Aave
///   Labs and one LlamaRisk signer); the 22 ParameterStore tighten setters and `setAvanaFeeShareBps` within its
///   0–5,000 bps bound, immediately, beside the timelock; role admin `APPLICATION_ADMIN`. It cannot loosen, upgrade,
///   change a route, a price source, a keeper or a role, cover a deficit or cancel an operation.
/// - `DAO_CANCELLER_ROLE` (AvanaTimelock only): the Aave governance executor; needed with `CANCELLER_ROLE` to cancel
///   a role-change or restoring operation. The same executor is the MarketRegistry's immutable
///   `AAVE_GOVERNANCE_EXECUTOR`, the only caller of `cancelStandbySwitch`.
/// Every role above except the two admin roles is granted and revoked only by a role-change operation of the timelock
/// at the normal delay, which only the Aave governance executor can cancel.
/// The Emergency Guardian's five seats are three Avana Labs signers, one Aave Labs signer and one LlamaRisk signer, so
/// no seat acts alone and no organisation reaches the threshold alone; no signer key is shared between the Emergency
/// Guardian, the governance multisig and the Aave Protocol Guardian (REQ-ROLE-007). `COVERAGE_ROLE` is not an Avana
/// role: it is the Aave DAO's AccessManager role for `coverDeficit` on each Coverage Spoke, which the DAO grants to the
/// Emergency Guardian and the Aave Protocol Guardian.
/// OpenZeppelin `TimelockController` roles on the AvanaTimelock: `PROPOSER_ROLE` the 4-of-7 governance multisig and
/// the Aave governance executor (never fewer than two holders); `CANCELLER_ROLE` the governance multisig, the
/// Emergency Guardian, the Aave Protocol Guardian and the Aave governance executor; `EXECUTOR_ROLE` the governance
/// multisig (anyone executes while public execution is on).
/// Immutable Avana contracts keep no roles: they check `msg.sender == TIMELOCK`.
/// @custom:spec REQ-ACCESS-001, REQ-ACCESS-002, REQ-ACCESS-003, REQ-ACCESS-004, REQ-ACCESS-005, REQ-ACCESS-006, REQ-ACCESS-007, REQ-ACCESS-008, REQ-ACCESS-009, REQ-ACCESS-010, REQ-ACCESS-014, REQ-ACCESS-149, REQ-ACCESS-153, REQ-ACCESS-157, REQ-ACCESS-158, REQ-ACCESS-159, REQ-ACCESS-160, REQ-ROLE-006, REQ-ROLE-007, REQ-ROLE-117, Q-228, Q-241, Q-242, Q-245, Q-248, Q-259, Q-375, Q-378
library AvanaRoles {
    /// @notice Upgrades, setters, listings, keepers and the pause switch on every upgradeable Avana contract; held only
    /// by the AvanaTimelock.
    /// @custom:spec REQ-ACCESS-003, REQ-ACCESS-014
    bytes32 internal constant APPLICATION_ADMIN = keccak256("APPLICATION_ADMIN");

    /// @notice `MarketRegistry.pause(reason)`, `unpause`, `unfreeze`, breaker resets and `useStandbyRoute`, and
    /// `ParameterStore.useStandbySecondSource`, immediately.
    /// @custom:spec REQ-ACCESS-008, REQ-ACCESS-063, REQ-ACCESS-086, REQ-ACCESS-158, REQ-ACCESS-159, REQ-ACCESS-162, REQ-PSTORE-029
    bytes32 internal constant APPLICATION_PAUSE_GUARDIAN = keccak256("APPLICATION_PAUSE_GUARDIAN");

    /// @notice `MarketRegistry.freeze`, `freezeAddress`, `tripMarketBreaker` and `tripDebtBreaker`, immediately.
    /// @custom:spec REQ-ACCESS-009, REQ-ACCESS-062, REQ-ACCESS-086, REQ-ACCESS-157, REQ-ACCESS-158
    bytes32 internal constant APPLICATION_FREEZE_GUARDIAN = keccak256("APPLICATION_FREEZE_GUARDIAN");

    /// @notice The ParameterStore's tighten setters and `setAvanaFeeShareBps`, immediately; held by the Joint
    /// Configuration Safe.
    /// @custom:spec REQ-PSTORE-002, REQ-PSTORE-010, REQ-ROLE-027, REQ-ROLE-117
    bytes32 internal constant APPLICATION_RISK_STEWARD = keccak256("APPLICATION_RISK_STEWARD");

    /// @notice On the AvanaTimelock, required together with `CANCELLER_ROLE` to cancel a role-change or restoring
    /// operation.
    /// @custom:spec REQ-ACCESS-006, REQ-ACCESS-019, REQ-ACCESS-156, REQ-ACCESS-159, SPEC-GOV-005
    bytes32 internal constant DAO_CANCELLER_ROLE = keccak256("DAO_CANCELLER_ROLE");
}
