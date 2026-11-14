// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The signals M-01 to M-29 of services/README.md (Monitoring and alerting): what each reads, its warn and page
// levels, who responds and which playbook of spec/03-operations/06-emergency-operations.md they follow. The router
// sends each alert to the responders named here, so no time is spent deciding who acts.

export type SignalId = `M-${string}`;
export type Level = "ok" | "warn" | "page";

/** Where a signal's value comes from. */
export type Source =
  /** The chain snapshot read at one block (`@avana/services-common/views`). */
  | "snapshot"
  /** Alerts and heartbeats the keeper instances post to the ingest endpoint. */
  | "keeper"
  /** Contract events from the indexer or RPC logs. */
  | "events"
  /** The daily fork simulation (and the one before every listing). */
  | "fork"
  /** Reads outside the protocol contracts: Safes, token issuers, the frontend. */
  | "external";

/** The people or systems an alert is sent to (services/README.md, the Responder column). */
export type Responder =
  | "operators"
  | "emergencyGuardian"
  | "guardians"
  | "riskProviders"
  | "governance"
  | "standbyKeeper"
  | "keeperOnCall"
  | "avanaLabs"
  | "aaveDao"
  | "aave"
  | "coverageRole"
  | "engineering"
  | "cancellers"
  | "signers";

export interface SignalDef {
  readonly id: SignalId;
  readonly name: string;
  readonly source: Source;
  readonly warn: string;
  readonly page: string;
  readonly responders: readonly Responder[];
  readonly playbook: string;
}

export const SIGNALS: readonly SignalDef[] = [
  { id: "M-01", name: "LPOracle and DebtOracle price state", source: "snapshot", warn: "Cached on entry", page: "Expired", responders: ["operators", "emergencyGuardian"], playbook: "P-02 (EMG-076)" },
  { id: "M-02", name: "Feed disagreement start", source: "snapshot", warn: "on entry", page: "30 minutes before disagreementPauseMax ends", responders: ["operators", "emergencyGuardian"], playbook: "P-02 (EMG-076)" },
  { id: "M-03", name: "Feed leg age, collateral and DebtOracle legs", source: "snapshot", warn: "above 50 % of feedMaxAge", page: "above 90 %", responders: ["operators"], playbook: "P-02 (EMG-076)" },
  { id: "M-04", name: "Debt feed age", source: "snapshot", warn: "above borrowPriceMaxAge", page: "above 90 % of liquidationPriceMaxAge", responders: ["operators", "aave"], playbook: "P-02 (EMG-076)" },
  { id: "M-05", name: "USD band distance √(q0·q1)", source: "snapshot", warn: "below 0.95", page: "below 0.90", responders: ["guardians"], playbook: "P-03 (EMG-077)" },
  { id: "M-06", name: "Collateral value per market at oracle prices", source: "snapshot", warn: "−10 % in 1 hour", page: "−25 % in 1 hour", responders: ["guardians"], playbook: "P-03 (EMG-077)" },
  { id: "M-07", name: "Live pool share", source: "snapshot", warn: "above 15 %", page: "above 20 % (POOL_SHARE breaker trips)", responders: ["riskProviders"], playbook: "P-04 (EMG-078)" },
  { id: "M-08", name: "Breaker latched or condition true", source: "snapshot", warn: "every", page: "any latched security freeze", responders: ["guardians"], playbook: "per reason" },
  { id: "M-09", name: "Accounts below HF 1 not liquidated", source: "keeper", warn: "60 s", page: "300 s; 3,600 s escalates to an Emergency Guardian decision", responders: ["standbyKeeper", "keeperOnCall", "guardians"], playbook: "P-08 (EMG-082)" },
  { id: "M-10", name: "Liquidation reverts by reason, RouteFailed, share of collateral seized", source: "keeper", warn: "1 per market per hour; 10 % seized in 1 hour", page: "3 per market per hour; 20 % seized in 1 hour", responders: ["governance", "guardians"], playbook: "P-04 (EMG-078)" },
  { id: "M-11", name: "Route depth at stress size", source: "fork", warn: "below 120 %", page: "below 100 %", responders: ["governance"], playbook: "P-04 (EMG-078)" },
  { id: "M-12", name: "GSM exposure headroom per token", source: "fork", warn: "below 2× the market's stress size", page: "below 1×", responders: ["riskProviders"], playbook: "P-04 (EMG-078)" },
  { id: "M-13", name: "First-Loss Reserve balance; DAO deficit offset balance", source: "snapshot", warn: "below 150 % of firstLossReserveMinimum; the offset below 100 % of daoDeficitOffset", page: "below 100 %", responders: ["avanaLabs", "aaveDao"], playbook: "P-09 (EMG-083)" },
  { id: "M-14", name: "Tail coverage ratio", source: "snapshot", warn: "below 150 %", page: "below 100 %", responders: ["riskProviders", "aaveDao"], playbook: "P-09 (EMG-083)" },
  { id: "M-15", name: "Hub deficit per asset", source: "snapshot", warn: "any", page: "uncovered after 24 hours", responders: ["coverageRole"], playbook: "P-09 (EMG-083)" },
  { id: "M-16", name: "Keeper debt-asset float", source: "keeper", warn: "below 150 % of the largest single debtToCover the caps allow", page: "below 100 %", responders: ["avanaLabs"], playbook: "P-09 (EMG-083)" },
  { id: "M-17", name: "Keeper gas balance; Aave V3 Pool idle liquidity", source: "keeper", warn: "gas below 3 days of median spend; idle liquidity below 2× the largest single debtToCover", page: "gas below 1 day; idle liquidity below 1×", responders: ["avanaLabs"], playbook: "P-08 (EMG-082)" },
  { id: "M-18", name: "drawn / drawCap per asset", source: "snapshot", warn: "80 %", page: "90 %", responders: ["riskProviders"], playbook: "P-10 (EMG-084)" },
  { id: "M-19", name: "Hub utilization and Lend Spoke withdrawals", source: "snapshot", warn: "utilization 90 %", page: "utilization 98 %, or a withdrawal above 10 % of supply within 1 hour", responders: ["aaveDao", "guardians"], playbook: "P-10 (EMG-084)" },
  { id: "M-20", name: "Aave configuration against recorded values", source: "events", warn: "any change", page: "ConfigDrift live", responders: ["emergencyGuardian"], playbook: "P-12 (EMG-086)" },
  { id: "M-21", name: "Backing-check failure, CounterSaturated", source: "events", warn: "—", page: "every", responders: ["engineering"], playbook: "P-05 (EMG-079)" },
  { id: "M-22", name: "Timelock CallScheduled", source: "events", warn: "every", page: "role change, upgrade, setShortDelaySelector, setNormalDelay, unfreezeAddress, restorePriceRoute", responders: ["cancellers"], playbook: "P-06 (EMG-080)" },
  { id: "M-23", name: "Safe owner, threshold, guard or module change; signer liveness", source: "external", warn: "every", page: "every; liveness answers below threshold + 1", responders: ["signers"], playbook: "P-07 (EMG-081)" },
  { id: "M-24", name: "Pause state and reason, address freeze, standby switch, manual breaker", source: "snapshot", warn: "every", page: "—", responders: ["signers"], playbook: "per reason" },
  { id: "M-25", name: "Token issuer probes and blocklists", source: "external", warn: "probe change", page: "blocklist of LPVaultSwap, the LPVault, Collateralization or the AaveAdapter", responders: ["guardians"], playbook: "P-11 (EMG-085)" },
  { id: "M-26", name: "Keeper code-check mismatch", source: "keeper", warn: "—", page: "every", responders: ["keeperOnCall"], playbook: "P-08 (EMG-082)" },
  { id: "M-27", name: "Frontend bundle hash, DNS and hosting change", source: "external", warn: "any", page: "hash mismatch", responders: ["engineering"], playbook: "P-13 (EMG-087)" },
  { id: "M-28", name: "Liquidity leaving a listed pool", source: "snapshot", warn: "−20 % in 1 hour", page: "−40 % in 1 hour", responders: ["riskProviders", "guardians"], playbook: "P-04 (EMG-078)" },
  { id: "M-29", name: "Rate curve per lend asset", source: "snapshot", warn: "any change of a curve's values", page: "GHO baseDrawnRate below the Core Hub GHO base rate", responders: ["aaveDao", "riskProviders"], playbook: "P-10 (EMG-084)" },
];

const BY_ID: ReadonlyMap<SignalId, SignalDef> = new Map(SIGNALS.map((s) => [s.id, s]));

export function signal(id: SignalId): SignalDef {
  const def = BY_ID.get(id);
  if (!def) throw new Error(`unknown signal ${id}`);
  return def;
}

/** Level of a value that is bad when high (`above`) or when low (`below`); a value at the limit is not past it. */
export function thresholdLevel(value: number, warnAt: number, pageAt: number, direction: "above" | "below"): Level {
  const past = (limit: number) => (direction === "above" ? value > limit : value < limit);
  if (past(pageAt)) return "page";
  if (past(warnAt)) return "warn";
  return "ok";
}

/**
 * Level of `value / base` against limits given as fractions `num / den`, exact in integers. `atOrAbove` counts a value
 * at the limit (a level stated as "80 %"); `above` and `below` do not.
 */
export function ratioLevel(value: bigint, base: bigint, warn: readonly [bigint, bigint], page: readonly [bigint, bigint], direction: "above" | "atOrAbove" | "below"): Level {
  if (base <= 0n) throw new Error("ratioLevel: base must be positive");
  // value / base past num / den  ⇔  value · den past num · base, since base > 0 and den > 0.
  const past = ([num, den]: readonly [bigint, bigint]) => {
    const l = value * den;
    const r = num * base;
    return direction === "above" ? l > r : direction === "atOrAbove" ? l >= r : l < r;
  };
  if (past(page)) return "page";
  if (past(warn)) return "warn";
  return "ok";
}

export const maxLevel = (a: Level, b: Level): Level => (a === "page" || b === "page" ? "page" : a === "warn" || b === "warn" ? "warn" : "ok");
