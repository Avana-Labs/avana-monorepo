// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DriftReason} from "../../types/DriftReason.sol";
import {PledgeCounters} from "../../types/PledgeCounters.sol";
import {PledgeCharge} from "./types/PledgeCharge.sol";

/// @title IRiskModuleChecks
/// @notice The pledge check, the borrow-side pre- and post-checks, the Aave configuration drift check and the Hub shares
/// == assets check.
interface IRiskModuleChecks {
    /// @notice `pokeConfig` found the Spoke's Aave settings drifted.
    /// @param spoke The CDP Spoke.
    /// @param reason The first drift found.
    /// @custom:spec REQ-RISK-090
    event ConfigDriftDetected(address indexed spoke, DriftReason reason);

    /// @notice `pokeBreakers` evaluated a market and its Spoke's debt reserves.
    /// @param marketId The market.
    /// @param reasons OR of every reason observed holding, market and debt keys together.
    /// @custom:spec REQ-RISK-091, Q-399
    event BreakersPoked(uint256 indexed marketId, uint32 reasons);

    /// @notice Full pledge eligibility, rescue rule, minimum, breaker, charge and cap check; returns the charge or reverts.
    /// @dev Called by Collateralization inside `pledge` and `recredit`, after custody and after poking the market's
    /// LPOracle; `view`. A top-up is a pledge for an account with debt on any debt reserve; a re-credit is a pledge of
    /// the added units. If `requireRescue`, the pool-share cap fails, the market breaker of `marketId` (without
    /// `ORACLE`, and without `CONFIG_DRIFT` for a top-up) is tripped or the value is below `minPledgeUsd`, only a rescue
    /// top-up passes: indebted, health factor below `rescueHealthFactor` (1.10), charge at most the restore amount,
    /// value at least `min(minPledgeUsd, RESCUE_MIN_PLEDGE_USD)`; its units are all rescue units. Order: market `Active`
    /// (`MarketNotActive`, `MarketOffboarding`), `integrationId` equals the market's (`IntegrationMismatch`), `units > 0`
    /// (`ZeroLiquidity`), the sequencer gate for a new account (`SequencerDown`, `SequencerGrace`), price state of the
    /// pledged market (new account: Live, or Drifting only from a USD-band breach; top-up: Live or Drifting;
    /// `PriceNotAccepted`), the vault-token reserve and the Hub available (`AaveReserveUnavailable`,
    /// `HubSpokeUnavailable`), for a new account no enabled debt reserve paused (`DebtReservePaused`), `checkAaveConfig`
    /// (`ConfigDrift`) and `isHubSharesEqualAssets` (`HubSharesNotEqualAssets`), the rescue minimum (`BelowMinPledge`),
    /// the Hub `addCap` (`HubAddCapReached`) and the reserve limit (`UserReservesLimit`), cap tests with stress-floor
    /// booking at `lastAcceptedPrice` (`CapExceeded`) and the slice rule (`SliceNotAvailable`), then the pool-share cap,
    /// the market breaker and the rescue rule (`BelowMinPledge`, `NotRescueTopUp`, `PoolShareUnavailable`,
    /// `PoolShareExceeded`, `BreakerTripped`). The integration validated the position at custody (canonical position
    /// manager or pool, exact shape, AMMN-RT-01) and Collateralization refuses a 17th record, so neither is tested here.
    /// Cap tests use the n-token counters: each pool token's counter and the depositor's counter are keyed by the
    /// market's home Hub. Reads no pause state or freeze (the Adapter passes `requireRescue`). Uncaught Aave and AMM
    /// integration errors pass through.
    /// @param depositor The depositor the Adapter named.
    /// @param proxy The depositor's proxy for the market, resolved by the Adapter.
    /// @param marketId MarketRegistry market identifier.
    /// @param integrationId The AMM integration the caller named for the position.
    /// @param positionKey The position, in the integration's key format.
    /// @param units Units to credit: the position's units for a pledge, the added units for a re-credit.
    /// @param counters Collateralization's current counters for the market, each pool token, the depositor and the
    /// account's record count.
    /// @param requireRescue True under `Paused(General)` or for a frozen depositor: only a rescue top-up passes.
    /// @return charge The USD charge to book, its slice part, the rescue flag and the rescue units.
    /// @custom:spec REQ-RISK-006, REQ-RISK-009, REQ-RISK-010, REQ-RISK-011, REQ-RISK-012, REQ-RISK-013, REQ-RISK-014, REQ-RISK-016, REQ-RISK-017, REQ-RISK-018, REQ-RISK-019, REQ-RISK-020, REQ-RISK-021, REQ-RISK-022, REQ-RISK-023, REQ-RISK-024, REQ-RISK-025, REQ-RISK-026, REQ-RISK-027, REQ-RISK-028, REQ-RISK-029, REQ-RISK-030, REQ-RISK-047, REQ-RISK-057, REQ-RISK-058, REQ-RISK-064, REQ-RISK-065, REQ-RISK-066, REQ-RISK-067, REQ-RISK-073, REQ-RISK-074, SPEC-CAP-001, SPEC-CAP-002, SPEC-CAP-003, SPEC-CAP-005, SPEC-BRK-001, SPEC-BRK-002, SPEC-BRK-003, Q-230, Q-241, Q-252, Q-253, Q-376, Q-380
    function checkPledge(
        address depositor,
        address proxy,
        uint256 marketId,
        uint32 integrationId,
        bytes32 positionKey,
        uint128 units,
        PledgeCounters calldata counters,
        bool requireRescue
    ) external view returns (PledgeCharge memory charge);

    /// @notice Pre-borrow gate over the account's collateral market and every debt reserve of the account.
    /// @dev Called by the AaveAdapter before the proxy's borrow; callable by anyone. The Spoke and market are the
    /// proxy's `SPOKE()` and `MARKET_ID()`. In order: approved Spoke (`UnknownSpoke`); scope read from the Spoke; the
    /// account's only collateral reserve maps to its Active or Offboarding market (`UnknownCollateral`); debt reserves
    /// approved and matching their definitions (`ConfigDrift`); poke the market's LPOracle and the DebtOracle of every
    /// debt reserve without a fixed-price source; the market Live and fresh, each feed within its own heartbeat plus
    /// margin and the independent second source within the deviation band (`PriceNotLive`, `PriceTooOld`); on an L2
    /// chain the sequencer up and past its grace period (`PriceNotLive`); every debt reserve unpaused, on its recorded
    /// source and, unless fixed-price, its DebtOracle Live within its `borrowPriceMaxAge()` (`DebtReservePaused`,
    /// `UnexpectedDebtPriceSource`, `DebtPriceTooOld`); for a cross-Hub line, the lines enabled and the registry's
    /// draw-cap sum within the line (`CrossHubLinesDisabled`, `CreditLineExceeded`; the Adapter applies the funding
    /// Hub's pause state); no minimum on the debt a borrow leaves (`Q-381`);
    /// no collateral reserve paused on Aave (`AaveReservePaused`); no collateral market Offboarding and no collateral
    /// reserve frozen on Aave (`MarketOffboarding`, `ReserveFrozen`); no drift (`ConfigDrift`); Hub shares == assets
    /// (`HubSharesNotEqualAssets`); no liquidation halt (`LiquidationHalted`: 0 active keepers on the chain;
    /// `DebtLiquidationHalted`: a pool token with no usable route into that reserve's asset); no market breaker and
    /// no debt breaker of `debtReserveId` (`BreakerTripped`, `DebtBreakerTripped`): no temporary gate holding or inside
    /// `gateRecoverySeconds` of its last breach, and no security freeze holding or latched (Q-399). Reads no pause state or freeze.
    /// @param proxy The account.
    /// @param debtReserveId The reserve being borrowed; added to the debt scope.
    /// @param amount Amount being borrowed, base units of the reserve's asset; not read (there is no minimum debt).
    /// @custom:spec REQ-ADAPTER-009, REQ-ADAPTER-010, REQ-ADAPTER-011, REQ-ADAPTER-012, REQ-ADAPTER-013, REQ-ADAPTER-014, REQ-ADAPTER-015, REQ-ADAPTER-016, REQ-ADAPTER-018, REQ-ADAPTER-019, REQ-ADAPTER-020, REQ-ADAPTER-021, REQ-ADAPTER-022, REQ-ADAPTER-023, REQ-ADAPTER-024, REQ-ADAPTER-061, REQ-RISK-056, REQ-RISK-061, REQ-RISK-062, REQ-RISK-065, REQ-RISK-069, REQ-RISK-071, REQ-ORACLE-099, REQ-ORACLE-100, SPEC-PROXY-002, SPEC-BRK-001, SPEC-BRK-002, SPEC-BRK-003, SPEC-BRK-004, BOR-006, BOR-007, BOR-017, Q-229, Q-234, Q-238, Q-241, Q-248, Q-270, Q-380
    function preBorrowCheck(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external;

    /// @notice Pre-withdrawal gate for an account with debt.
    /// @dev Called by the AaveAdapter before a withdrawal or partial removal only when debt remains. Runs
    /// `preBorrowCheck`'s gates (pokes included) except the Offboarding and Aave-frozen refusals and the minimum-debt
    /// test; applies the market breaker and the debt breaker of every debt reserve held.
    /// @param proxy The account; its market's vault-token reserve is the one withdrawn.
    /// @custom:spec REQ-ADAPTER-025, REQ-ADAPTER-009, REQ-RISK-056, REQ-RISK-061, REQ-RISK-062, REQ-RISK-065, REQ-RISK-069, SPEC-PROXY-002, WDR-007, Q-229, Q-241
    function preWithdrawCheck(
        address proxy
    ) external;

    /// @notice Post-action health gate after a borrow, a withdraw-with-debt or a partial removal with debt.
    /// @dev Reads `spoke.getUserAccountData(proxy)`, removes the value of the account's rescue units
    /// (`Collateralization.getAccountRescueUnits(proxy, vaultToken)` of the account's market, SPEC-CF-005) and reverts with
    /// `HealthFactorTooLow(hfEx, required)` unless `hfEx >= required = max(1e18, hardHealthFloor(marketId),
    /// minHealthFactor)`: Aave's HF 1.00, the market's optional hard floor (0 = off, the default, Q-398) and the
    /// caller's minimum. The Lens previews the recommended borrow at HF 1.10 beside this maximum.
    /// @param proxy The account.
    /// @param minHealthFactor The caller's minimum, WAD; 0 for none.
    /// @return healthFactor The rescue-excluded health factor, WAD.
    /// @custom:spec REQ-ADAPTER-026, REQ-ADAPTER-027, REQ-ADAPTER-059, REQ-RISK-059, REQ-RISK-068, SPEC-PROXY-001, SPEC-PROXY-006, SPEC-CF-003, SPEC-CF-005, BOR-011, WDR-011, INV-082, Q-253
    function postHealthCheck(
        address proxy,
        uint256 minHealthFactor
    ) external view returns (uint256 healthFactor);

    /// @notice Spoke-wide and per-market Aave configuration drift checks, including the risk configuration (collateral
    /// factor above expected, bonus bound, liquidation target health factor).
    /// @dev The call reverts with `ConfigDrift(marketId, reason)` on the first failure (`marketId = 0` for Spoke-wide
    /// reasons). Spoke-wide: the Spoke is a standard, unmodified Aave V4 Spoke whose implementation matches the one
    /// recorded by `deployCdpSpoke`, its Hub is the recorded home Hub, the debt-reserve set and each debt reserve's
    /// funding Hub and price source match the registry. Per market: reserve identity, flags, `receiveSharesEnabled`
    /// false (a liquidator taking vault-token shares would hold collateral Avana can never settle, AMMN-RT-03),
    /// `liquidationFee` 0, no reinvestment controller, single Spoke, no draw, price
    /// source the market's LPOracle, risk-premium ordering. A drift trips the breaker of new activity only;
    /// liquidation never reads this check (Q-378).
    /// Used by new-account pledges, the borrow-side pre-checks and MarketRegistry activation; reads `reserveId` and
    /// `hubAssetId` from the market record and does not require the market to be Active, so `activateMarket` calls it
    /// while the market is still Registered.
    /// @param spoke The CDP Spoke.
    /// @param marketIds Market identifiers to check.
    /// @custom:spec REQ-ADAPTER-028, REQ-ADAPTER-029, REQ-ADAPTER-030, REQ-ADAPTER-031, REQ-ADAPTER-032, REQ-ADAPTER-033, REQ-ADAPTER-034, REQ-ADAPTER-035, REQ-ADAPTER-036, REQ-ADAPTER-063, REQ-ADAPTER-064, REQ-RISK-063, REQ-RISK-069, REQ-RISK-076, Q-281, Q-270, Q-378
    function checkAaveConfig(
        address spoke,
        uint256[] calldata marketIds
    ) external view;

    /// @notice Runs the Aave configuration drift check over every market of a CDP Spoke outside any user call.
    /// @dev Anyone; Avana's keeper calls it every block on each CDP Spoke. Runs `checkAaveConfig(spoke, marketIds)`
    /// over the Spoke's markets and, when it fails, emits `ConfigDriftDetected(spoke, reason)` instead of reverting; it
    /// changes no other state, because `CONFIG_DRIFT` is a condition breaker that every gated call evaluates itself.
    /// Detection of a changed Aave setting (for example `receiveSharesEnabled` turned on) is thus bounded to one block,
    /// and the emergency playbook starts from the event. Seizures by other liquidators between the Aave change and
    /// that response are an accepted residual risk bounded by the Spoke's draw caps (AMMN-RT-03).
    /// @param spoke The CDP Spoke.
    /// @return reason The first drift found, `None` when the settings hold.
    /// @custom:spec REQ-RISK-090, REQ-RISK-078, INV-093
    function pokeConfig(
        address spoke
    ) external returns (DriftReason reason);

    /// @notice Records the breaker conditions of a market and of every enabled debt reserve of its Spoke.
    /// @dev Anyone; Avana's keeper calls it every block. Evaluates from live state the market's `ORACLE`,
    /// `POOL_SHARE`, `POOL_DEPTH`, `ISSUER` and `CONFIG_DRIFT`, and `DEFICIT` and `ISSUER` of each enabled debt reserve,
    /// then calls `MARKET_REGISTRY.recordBreach(key, reasons)` once per key with any reason holding (temporary reasons
    /// set `lastBreachAt`, SPEC-BRK-007; security reasons latch, SPEC-BRK-008) and emits `BreakersPoked`. Never clears
    /// a latch or shortens a recovery and never reverts because a condition holds; it reads the same values the gated
    /// calls read, so it cannot record a breach the gates would not see. A reverting borrow cannot write state, which
    /// is why a poke writes the breach times. Gas is bounded by the market's token count (at most 8 issuer probes).
    /// @param marketId The market.
    /// @return reasons OR of every reason observed holding.
    /// @custom:spec REQ-RISK-091, SPEC-BRK-007, SPEC-BRK-008, Q-399
    function pokeBreakers(
        uint256 marketId
    ) external returns (uint32 reasons);

    /// @notice Whether the market's home Hub has added assets equal to added shares for its vault-token asset, exactly.
    /// @dev No tolerance. Called by new-account pledges, the borrow-side pre-checks and MarketRegistry activation (on a
    /// Registered market); does not require the market to be Active.
    /// @param marketId MarketRegistry market identifier.
    /// @return equal True when shares equal assets.
    /// @custom:spec REQ-ADAPTER-037, Q-189
    function isHubSharesEqualAssets(
        uint256 marketId
    ) external view returns (bool equal);

    /// @notice Requires the record left by a partial removal with debt to be worth at least `minPledgeUsd`.
    /// @dev `mulDiv(remainingUnits, lastAcceptedPrice, 10^d, Floor) >= minPledgeUsd(marketId)`, else
    /// `RecordBelowMinPledge`.
    /// @param marketId MarketRegistry market identifier.
    /// @param remainingUnits Credited units left in the record.
    /// @custom:spec REQ-RISK-070, REQ-RISK-075, WDR-031, Q-254
    function checkRemainingRecord(
        uint256 marketId,
        uint128 remainingUnits
    ) external view;
}
