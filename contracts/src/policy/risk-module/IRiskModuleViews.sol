// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AccountGateStatus} from "../../types/AccountGateStatus.sol";
import {PledgePreview} from "../../types/PledgePreview.sol";
import {SpeedView} from "./types/SpeedView.sol";

/// @title IRiskModuleViews
/// @notice Non-reverting previews, formula views, the health floor and the implementation immutables of the RiskModule.
interface IRiskModuleViews {
    /// @notice Runs the checks of `checkPledge` and returns the outcome without reverting.
    /// @dev For the app and the Lens. The proxy is `ADAPTER.predictProxy(depositor, marketId)` (the deployed proxy has
    /// the same address); the counters come from `COLLATERALIZATION.getCounters(vaultToken, depositor)` (never inside a pledge, where the
    /// lock is held).
    /// @param depositor Current owner of the position.
    /// @param marketId MarketRegistry market identifier.
    /// @param positionKey The position, in the market's AMM integration key format.
    /// @return preview Eligibility, first failing reason, account class, charge, slice and remaining room of every cap.
    /// @custom:spec REQ-RISK-031, REQ-RISK-057
    function previewPledge(
        address depositor,
        uint256 marketId,
        bytes32 positionKey
    ) external view returns (PledgePreview memory preview);

    /// @notice Every borrow-side gate outcome for an account, without poking and without reverting.
    /// @param proxy The account; its Spoke and market are the proxy's immutables.
    /// @return status The scope and every gate outcome.
    /// @custom:spec REQ-ADAPTER-038, REQ-RISK-060
    function getAccountGateStatus(
        address proxy
    ) external view returns (AccountGateStatus memory status);

    /// @notice USD of collateral at the oracle price that restores the account to `rescueHealthFactor` (1.10).
    /// @dev SPEC-CAP-003, rounded up; 0 when the account has no debt, is at or above the gate, or `CF_m = 0`.
    /// @param proxy The account; collateral is valued in the proxy's market.
    /// @return usd 8-decimal USD.
    /// @custom:spec SPEC-CAP-003
    function usdToRestore(
        address proxy
    ) external view returns (uint256 usd);

    /// @notice LP collateral factor the Spoke reserve may carry at most.
    /// @dev `floor(min_i CF_i * poolRiskFactor / 1e4)` in bps over every pool token `i` of the market (n tokens), from
    /// the ParameterStore; rounds down. Example: a 3-token Curve market with token factors 9000, 9000 and 8500 bps
    /// and `poolRiskFactor = 9500` gives `floor(8500 * 9500 / 1e4) = 8075` bps; the weakest token sets the bound
    /// because an unwind can return the whole position in that token.
    /// @param marketId MarketRegistry market identifier.
    /// @return cfBps The collateral factor, bps.
    /// @custom:spec SPEC-CF-001
    function expectedCollateralFactorBps(
        uint256 marketId
    ) external view returns (uint256 cfBps);

    /// @notice Health factor below which an indebted account may make a rescue top-up, and the value the top-up
    /// restores (Q-398). Not a borrow gate: a borrow needs only Aave's HF 1.00, the caller's minimum and the market's
    /// optional `hardHealthFloor` (0 = off).
    /// @return value 1.10e18 (WAD); changes only with a RiskModule upgrade.
    /// @custom:spec REQ-RISK-059, SPEC-PROXY-001, SPEC-CAP-003, Q-398
    function rescueHealthFactor() external pure returns (uint256 value);

    /// @notice MarketRegistry (implementation immutable).
    /// @return marketRegistry The MarketRegistry.
    /// @custom:spec REQ-RISK-029, REQ-RISK-055
    function MARKET_REGISTRY() external view returns (address marketRegistry);

    /// @notice ParameterStore (implementation immutable).
    /// @return parameterStore The ParameterStore.
    /// @custom:spec REQ-RISK-055
    function PARAMETER_STORE() external view returns (address parameterStore);

    /// @notice Collateralization, the caller of `checkPledge` (implementation immutable).
    /// @return collateralization Collateralization.
    /// @custom:spec REQ-RISK-004, REQ-RISK-058
    function COLLATERALIZATION() external view returns (address collateralization);

    /// @notice AaveAdapter, the caller of the borrow-side checks (implementation immutable).
    /// @return adapter The AaveAdapter.
    /// @custom:spec REQ-ADAPTER-009, REQ-RISK-031
    function ADAPTER() external view returns (address adapter);

    /// @notice Live, recovering and latched reasons of a market's circuit breaker.
    /// @dev Never reverts. Live condition bits (`ORACLE`, `POOL_SHARE`, `POOL_DEPTH`, `ISSUER`, the Spoke's
    /// `CONFIG_DRIFT`), temporary bits still inside `gateRecoverySeconds` of `lastBreachAt`, and latched bits from
    /// `MarketRegistry.marketBreaker`.
    /// @param marketId Market identifier.
    /// @return reasons Bitmap of `BreakerReasons`.
    /// @return reopensAt When the last temporary gate reopens, `lastBreachAt + gateRecoverySeconds`; 0 when none.
    /// @custom:spec REQ-RISK-065, REQ-RISK-078, SPEC-BRK-001, SPEC-BRK-002, SPEC-BRK-003, SPEC-BRK-007, Q-241, Q-399
    function getBreakerStatus(
        uint256 marketId
    ) external view returns (uint32 reasons, uint64 reopensAt);

    /// @notice Live, recovering and latched reasons of a debt reserve's circuit breaker.
    /// @dev Never reverts. Live condition bits (`ORACLE`, `ISSUER`, `DEFICIT`), temporary bits still in recovery and
    /// latched bits from `MarketRegistry.debtBreaker`.
    /// @param spoke The CDP Spoke.
    /// @param debtReserveId The debt reserve.
    /// @return reasons Bitmap of `BreakerReasons`.
    /// @return reopensAt When the last temporary gate reopens; 0 when none.
    /// @custom:spec REQ-RISK-065, SPEC-BRK-003, SPEC-BRK-004, SPEC-BRK-007, Q-241, Q-399
    function getDebtBreakerStatus(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32 reasons, uint64 reopensAt);

    /// @notice Security-freeze conditions of a market that hold now, from live state only.
    /// @dev Never reverts. The `ISSUER` and `CONFIG_DRIFT` bits the market's live evaluation finds, without latched
    /// bits and without temporary gates; the MarketRegistry's `resetMarketBreaker` refuses a reset while any latched
    /// reason other than `MANUAL` is among them (REQ-MREG-025).
    /// @param marketId Market identifier.
    /// @return reasons Bitmap of `BreakerReasons`, within `BreakerReasons.SECURITY`.
    /// @custom:spec REQ-MREG-025, SPEC-BRK-008, Q-399
    function liveBreakerReasons(
        uint256 marketId
    ) external view returns (uint32 reasons);

    /// @notice Security-freeze conditions of a debt reserve that hold now, from live state only.
    /// @dev Never reverts. The `ISSUER` and `DEFICIT` bits of the reserve's live evaluation, without latched bits and
    /// without temporary gates; read by `resetDebtBreaker` (REQ-MREG-025).
    /// @param spoke The CDP Spoke.
    /// @param debtReserveId The debt reserve.
    /// @return reasons Bitmap of `BreakerReasons`, within `BreakerReasons.SECURITY`.
    /// @custom:spec REQ-MREG-025, SPEC-BRK-008, Q-399
    function liveDebtBreakerReasons(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32 reasons);

    /// @notice Most a rescue top-up's minimum value can be.
    /// @return usd `10e8` ($10.00), 8-decimal USD; changes only with an upgrade.
    /// @custom:spec REQ-RISK-067, Q-252
    function RESCUE_MIN_PLEDGE_USD() external pure returns (uint256 usd);

    /// @notice LPVaultSwap, read for `activeKeeperCount`; new borrowing halts only when it is 0 (Q-400).
    /// @return lpVaultSwap LPVaultSwap.
    /// @custom:spec REQ-RISK-071
    function LP_VAULT_SWAP() external view returns (address lpVaultSwap);

    /// @notice The only address that may hold `DEFAULT_ADMIN_ROLE` or `APPLICATION_ADMIN` (implementation immutable).
    /// @return timelock The AvanaTimelock.
    /// @custom:spec REQ-RISK-072, Q-259
    function TIMELOCK() external view returns (address timelock);

    /// @notice Debt of an account valued at its debt oracles, 8-decimal USD.
    /// @param proxy The account.
    /// @return usd Debt value.
    /// @custom:spec SPEC-CAP-009, REQ-RISK-077
    function debtValueUsd(
        address proxy
    ) external view returns (uint256 usd);

    /// @notice The market's borrow-speed window and the borrow-speed window of reserve `debtReserveId`'s (funding Hub,
    /// asset), as the next borrow of that reserve would see them now (REQ-RISK-097).
    /// @dev Never reverts and writes nothing: a failed read returns both views with `unavailable = true` and every other
    /// field 0. Example (SPEC-CAP-012): Spoke debt $4,000,000 with $600,000 charged gives the market view `{85,000,000,
    /// 000,000, 60,000,000,000,000, 25,000,000,000,000, start + τ, …}`.
    /// @param marketId The market.
    /// @param debtReserveId The reserve.
    /// @return market The market window, 8-decimal USD.
    /// @return debt The (funding Hub, asset) window, asset base units.
    /// @custom:spec REQ-RISK-097, SPEC-CAP-011, Q-411
    function getBorrowSpeed(
        uint256 marketId,
        uint256 debtReserveId
    ) external view returns (SpeedView memory market, SpeedView memory debt);

    /// @notice The market's pledge-speed window as the next non-rescue pledge would see it now (REQ-RISK-097).
    /// @dev Never reverts and writes nothing; reads Collateralization's counters, so it reports `unavailable` while the
    /// Lock is held. `previewPledge` does not read the window; the app reads this view beside it.
    /// @param marketId The market.
    /// @return pledge The pledge window, 8-decimal USD.
    /// @custom:spec REQ-RISK-097, SPEC-CAP-011, Q-411
    function getPledgeSpeed(
        uint256 marketId
    ) external view returns (SpeedView memory pledge);
}
