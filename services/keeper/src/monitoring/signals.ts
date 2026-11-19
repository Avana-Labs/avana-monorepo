// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Monitoring signals M-01 to M-34 (services/README.md, Monitoring and alerting). The keeper evaluates the ones it
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
  { id: "M-01", name: "LPOracle and debt price freshness", cadence: "block", inputs: ["Lens.getPriceState", "Lens.getDebtPriceState"], warn: "borrow price stale", page: "liquidation price stale", responder: "operators, then the Emergency Guardian", playbook: "P-02 (EMG-076)" },
  { id: "M-02", name: "Feed disagreement start (retired: the stateless LPOracle records no disagreement)", cadence: "block", inputs: [], warn: "—", page: "—", responder: "operators, then the Emergency Guardian", playbook: "P-02 (EMG-076)" },
  { id: "M-03", name: "Feed leg age (collateral and debt feeds)", cadence: "block", inputs: ["feed latestRoundData", "feedMaxAge"], warn: "> 50 % of feedMaxAge", page: "> 90 %", responder: "operators", playbook: "P-02 (EMG-076)" },
  { id: "M-04", name: "Debt feed age", cadence: "block", inputs: ["DebtPriceView.age", "borrowPriceMaxAge", "liquidationPriceMaxAge"], warn: "> borrowPriceMaxAge", page: "> 90 % of liquidationPriceMaxAge", responder: "operators, Aave", playbook: "P-02 (EMG-076)" },
  { id: "M-05", name: "USD band distance √(q0·q1)", cadence: "block", inputs: ["LPOracle.getPrices"], warn: "< 0.95", page: "< 0.90", responder: "guardians", playbook: "P-03 (EMG-077)" },
  { id: "M-06", name: "Collateral value per market at oracle prices", cadence: "block", inputs: ["Lens.checkBacking", "LPOracle.latestAnswer"], warn: "−10 % in 1 h", page: "−25 % in 1 h", responder: "guardians", playbook: "P-03 (EMG-077)" },
  { id: "M-07", name: "Live pool share", cadence: "block", inputs: ["Collateralization.poolUnits", "pool liquidity"], warn: "> 15 %", page: "> 20 %", responder: "risk service providers", playbook: "P-04 (EMG-078)" },
  { id: "M-08", name: "Breaker latched or condition true", cadence: "block", inputs: ["Lens.getBreakerStatus", "Lens.getDebtBreakerStatus", "eth_call pokeBreakers"], warn: "every", page: "security freeze latched (reopensAt = max uint64)", responder: "guardians", playbook: "per reason" },
  { id: "M-09", name: "Accounts below HF 1 not liquidated", cadence: "block", inputs: ["Spoke.getUserAccountData", "cache liquidatableSince"], warn: "60 s (5 Ethereum, 30 Base blocks)", page: "300 s (25 Ethereum, 150 Base blocks); 3,600 s escalates", responder: "standby keeper, keeper on-call, guardians", playbook: "P-08 (EMG-082)" },
  { id: "M-10", name: "Liquidation reverts by reason, RouteFailed, share seized", cadence: "event", inputs: ["keeper attempt log", "LPVaultSwap.RouteFailed", "LPVaultSwap.LiquidationSettled"], warn: "1 per market per hour; 10 % seized in 1 h", page: "3 per market per hour; 20 % seized in 1 h", responder: "governance (routes), guardians", playbook: "P-04 (EMG-078)" },
  { id: "M-11", name: "Route depth at stress size", cadence: "dailyFork", inputs: ["fork simulation", "routeDepthThreshold(marketId, token, debtAsset, kind) in base units of the debt asset"], warn: "< 120 %", page: "< 100 %", responder: "governance", playbook: "P-04 (EMG-078)" },
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
  { id: "M-27", name: "Frontend bundle hash, DNS and hosting change", cadence: "external", inputs: ["frontend bundle sha256", "DNS records", "hosting headers"], warn: "any", page: "hash mismatch", responder: "engineering", playbook: "P-13 (EMG-087)" },
  { id: "M-28", name: "Liquidity leaving a listed pool", cadence: "block", inputs: ["pool liquidity()", "pool liquidity around the current price"], warn: "−20 % in 1 h", page: "−40 % in 1 h", responder: "risk service providers, guardians", playbook: "P-04 (EMG-078)" },
  { id: "M-29", name: "Rate curve per lend asset", cadence: "block", inputs: ["Hub interest-rate data", "Hub drawn rate", "GHO baseDrawnRate", "Core Hub GHO base rate"], warn: "any change of a curve's values", page: "GHO baseDrawnRate below the Core Hub GHO base rate", responder: "Aave DAO, risk service providers", playbook: "P-10 (EMG-084)" },
  { id: "M-30", name: "Keeper discovery mismatch", cadence: "block", inputs: ["indexer stream UserProxyCreated", "RPC UserProxyCreated logs on both providers", "KEEPER_DISCOVERY_MISMATCH_PAGE_SECONDS"], warn: "any account one source holds and the other lacks", page: "one-sided for KEEPER_DISCOVERY_MISMATCH_PAGE_SECONDS (1 h by default)", responder: "keeper on-call", playbook: "P-08 (EMG-082)" },
  { id: "M-31", name: "Keeper gas spend anomaly", cadence: "block", inputs: ["keeper spend log (gasUsed, effective gas price, L1 fee per included transaction)", "KEEPER_GAS_DAILY_SPEND_WEI"], warn: "rolling 24 h spend > 3x the 7-day median daily spend", page: "> 5x", responder: "Avana Labs, keeper on-call", playbook: "P-08 (EMG-082)" },
  { id: "M-32", name: "Keeper class budget reached", cadence: "block", inputs: ["keeper spend log by fee class", "KEEPER_DAILY_BUDGET_WEI_{SCHEDULED,LAZY}"], warn: "—", page: "a scheduled or lazy class reaches its rolling 24 h budget and stops", responder: "keeper on-call, Avana Labs", playbook: "P-08 (EMG-082)" },
  { id: "M-33", name: "Standby keeper signer below its minimum balance", cadence: "block", inputs: ["standby signer balance", "KEEPER_STANDBY_MIN_BALANCE_WEI"], warn: "standby balance < its minBalance", page: "—", responder: "Avana Labs", playbook: "P-08 (EMG-082)" },
  { id: "M-34", name: "Oracle poke overdue (retired: the stateless oracles are never poked)", cadence: "block", inputs: [], warn: "—", page: "—", responder: "keeper on-call, operators", playbook: "P-08 (EMG-082)" },
];
