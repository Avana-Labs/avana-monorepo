// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Monitoring signals M-01 to M-26 (services/README.md, Monitoring and alerting). The keeper evaluates the ones it
// already reads each block; the rest run on their stated cadence from indexer events or a daily fork simulation.
// Every page is confirmed on a second RPC provider at a known block before it is sent (EMG-075).

export type Level = "ok" | "warn" | "page";
export type Cadence = "block" | "event" | "dailyFork" | "external";

export interface SignalDef {
  readonly id: `M-${string}`;
  readonly name: string;
  readonly cadence: Cadence;
  /** The reads (EVENTS.md, Live reads) or events the signal is computed from. */
  readonly inputs: readonly string[];
  readonly warn: string;
  readonly page: string;
  readonly responder: string;
  readonly playbook: string;
}

/** Level for a value that is bad when high (`above`) or when low (`below`). */
export function thresholdLevel(value: number, warnAt: number, pageAt: number, direction: "above" | "below"): Level {
  const past = (limit: number) => (direction === "above" ? value > limit : value < limit);
  if (past(pageAt)) return "page";
  if (past(warnAt)) return "warn";
  return "ok";
}

export const SIGNALS: readonly SignalDef[] = [
  { id: "M-01", name: "LPOracle and DebtOracle price state", cadence: "block", inputs: ["Lens.getPriceState", "Lens.getDebtPriceState"], warn: "Cached on entry", page: "Expired", responder: "operators, then the Emergency Guardian", playbook: "P-02 (EMG-076)" },
  { id: "M-02", name: "Feed disagreement start", cadence: "block", inputs: ["PriceView.disagreeSince", "disagreementPauseMax"], warn: "on entry", page: "30 minutes before disagreementPauseMax ends", responder: "operators, then the Emergency Guardian", playbook: "P-02 (EMG-076)" },
  { id: "M-03", name: "Feed leg age (collateral and DebtOracle legs)", cadence: "block", inputs: ["feed latestRoundData", "feedMaxAge"], warn: "> 50 % of feedMaxAge", page: "> 90 %", responder: "operators", playbook: "P-02 (EMG-076)" },
  { id: "M-04", name: "Debt feed age", cadence: "block", inputs: ["DebtPriceView.age", "borrowPriceMaxAge", "liquidationPriceMaxAge"], warn: "> borrowPriceMaxAge", page: "> 90 % of liquidationPriceMaxAge", responder: "operators, Aave", playbook: "P-02 (EMG-076)" },
  { id: "M-05", name: "USD band distance √(q0·q1)", cadence: "block", inputs: ["LPOracle.getTokenPrices"], warn: "< 0.95", page: "< 0.90", responder: "guardians", playbook: "P-03 (EMG-077)" },
  { id: "M-06", name: "Collateral value per market at oracle prices", cadence: "block", inputs: ["Lens.checkBacking", "LPOracle.latestAnswer"], warn: "−10 % in 1 h", page: "−25 % in 1 h", responder: "guardians", playbook: "P-03 (EMG-077)" },
  { id: "M-07", name: "Live pool share", cadence: "block", inputs: ["Collateralization.poolUnits", "pool liquidity"], warn: "> 15 %", page: "> 20 %", responder: "risk service providers", playbook: "P-04 (EMG-078)" },
  { id: "M-08", name: "Breaker latched or condition true", cadence: "block", inputs: ["Lens.getBreakerStatus", "Lens.getDebtBreakerStatus", "eth_call pokeBreakers"], warn: "every", page: "security freeze latched (reopensAt = max uint64)", responder: "guardians", playbook: "per reason" },
  { id: "M-09", name: "Accounts below HF 1 not liquidated", cadence: "block", inputs: ["Spoke.getUserAccountData", "cache liquidatableSince"], warn: "60 s (5 Ethereum, 30 Base blocks)", page: "300 s (25 Ethereum, 150 Base blocks); 3,600 s escalates", responder: "standby keeper, keeper on-call, guardians", playbook: "P-08 (EMG-082)" },
  { id: "M-10", name: "Liquidation reverts by reason, RouteFailed, share seized", cadence: "event", inputs: ["keeper attempt log", "LPVaultSwap.RouteFailed", "LPVaultSwap.LiquidationSettled"], warn: "1 per market per hour; 10 % seized in 1 h", page: "3 per market per hour; 20 % seized in 1 h", responder: "governance (routes), guardians", playbook: "P-04 (EMG-078)" },
  { id: "M-11", name: "Route depth at stress size", cadence: "dailyFork", inputs: ["fork simulation", "routeDepthThresholdGho", "buyRouteDepthThresholdGho"], warn: "< 120 %", page: "< 100 %", responder: "governance", playbook: "P-04 (EMG-078)" },
  { id: "M-12", name: "GSM exposure headroom per token", cadence: "dailyFork", inputs: ["GSM exposure", "market stress size"], warn: "< 2× stress size", page: "< 1×", responder: "risk service providers", playbook: "P-04 (EMG-078)" },
  { id: "M-13", name: "First-Loss Reserve balance", cadence: "block", inputs: ["AvanaFirstLossReserve.totalFunded", "firstLossReserveMinimum"], warn: "< 150 % of minimum", page: "< 100 %", responder: "Avana Labs top-up", playbook: "P-09 (EMG-083)" },
  { id: "M-14", name: "Tail coverage ratio", cadence: "block", inputs: ["Lens.getTailCoverage", "live debt by token"], warn: "< 150 %", page: "< 100 %", responder: "risk service providers, Aave DAO", playbook: "P-09 (EMG-083)" },
  { id: "M-15", name: "Hub deficit per asset", cadence: "event", inputs: ["Spoke.ReportDeficit", "Hub.getSpokeDeficitRay", "Lens.uncoveredDeficit"], warn: "any", page: "uncovered after 24 h", responder: "COVERAGE_ROLE holder", playbook: "P-09 (EMG-083)" },
  { id: "M-16", name: "Keeper debt-asset float", cadence: "block", inputs: ["funding Safe balance", "open reservations"], warn: "< 150 % of the largest debtToCover the caps allow", page: "< 100 %", responder: "Avana Labs", playbook: "P-09 (EMG-083)" },
  { id: "M-17", name: "Keeper gas and flash lender idle liquidity", cadence: "block", inputs: ["signer balance", "helper.maxFlashLoan"], warn: "gas < 3 days; idle < 2× largest debtToCover", page: "gas < 1 day; idle < 1×", responder: "Avana Labs", playbook: "P-08 (EMG-082)" },
  { id: "M-18", name: "drawn / drawCap per asset", cadence: "block", inputs: ["Hub.getSpokeTotalOwed", "Hub.getSpokeConfig"], warn: "80 %", page: "90 %", responder: "risk service providers", playbook: "P-10 (EMG-084)" },
  { id: "M-19", name: "Hub utilization and Lend Spoke withdrawals", cadence: "block", inputs: ["Hub.getAssetLiquidity", "Hub.getAddedAssets", "Lend Spoke Withdraw events"], warn: "utilization 90 %", page: "utilization 98 %, or a withdrawal > 10 % of supply within 1 h", responder: "Aave DAO, guardians", playbook: "P-10 (EMG-084)" },
  { id: "M-20", name: "Aave configuration against recorded values", cadence: "block", inputs: ["eth_call pokeConfig", "Spoke config events", "Spoke implementation slot"], warn: "any change", page: "ConfigDrift live", responder: "Emergency Guardian", playbook: "P-12 (EMG-086)" },
  { id: "M-21", name: "Backing-check failure, CounterSaturated", cadence: "event", inputs: ["Lens.checkBacking", "Collateralization.CounterSaturated"], warn: "—", page: "every", responder: "engineering", playbook: "P-05 (EMG-079)" },
  { id: "M-22", name: "Timelock CallScheduled", cadence: "event", inputs: ["AvanaTimelock.CallScheduled", "Upgraded", "RoleGranted", "RoleRevoked"], warn: "every", page: "role change, upgrade, beacon change, setShortDelaySelector, setNormalDelay, unfreezeAddress, restorePriceRoute", responder: "every canceller", playbook: "P-06 (EMG-080)" },
  { id: "M-23", name: "Safe owner, threshold, guard or module change; signer liveness", cadence: "external", inputs: ["Safe getOwners, getThreshold, guard and module slots", "signer liveness answers"], warn: "every", page: "every; liveness below threshold + 1", responder: "every signer", playbook: "P-07 (EMG-081)" },
  { id: "M-24", name: "Pause state and reason, address freeze, standby switch, manual breaker", cadence: "event", inputs: ["PauseStateChanged", "PauseReasonChanged", "AddressFrozen", "StandbyRouteActivated", "BreakerLatched"], warn: "every", page: "—", responder: "every signer", playbook: "per reason" },
  { id: "M-25", name: "Token issuer probes and blocklists", cadence: "block", inputs: ["paused()", "basisPointsRate()", "issuer blocklist events", "PayoutEscrow.RemainderEscrowed to feeRecipient"], warn: "probe change", page: "blocklist of LPVaultSwap, the LPVault, Collateralization or the AaveAdapter", responder: "guardians", playbook: "P-11 (EMG-085)" },
  { id: "M-26", name: "Keeper code-check mismatch", cadence: "block", inputs: ["implementation slots", "runtime code hashes"], warn: "—", page: "every", responder: "keeper on-call", playbook: "P-08 (EMG-082)" },
];
