// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The signals M-01 to M-37 of services/README.md (Monitoring and alerting): what each reads, its warn and page
// levels, who responds and which playbook of docs/spec/03-operations/06-emergency-operations.md they follow. The router
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
  { id: "M-01", name: "LPOracle refusing to price a market (a stale or invalid feed leg)", source: "snapshot", warn: "—", page: "latestAnswer reverts", responders: ["operators", "emergencyGuardian"], playbook: "P-02 (EMG-076)" },
  { id: "M-02", name: "Feed disagreement start (retired: the stateless LPOracle records no disagreement)", source: "snapshot", warn: "—", page: "—", responders: ["operators", "emergencyGuardian"], playbook: "P-02 (EMG-076)" },
  { id: "M-03", name: "Feed leg age, collateral feeds (LPOracle legs)", source: "snapshot", warn: "past the feed's heartbeat", page: "past 1.5 heartbeats", responders: ["operators"], playbook: "P-02 (EMG-076)" },
  { id: "M-04", name: "Debt feed age", source: "snapshot", warn: "past the feed's heartbeat", page: "past 1.5 heartbeats", responders: ["operators", "aave"], playbook: "P-02 (EMG-076)" },
  { id: "M-05", name: "USD band distance (retired: M-36 watches the Custom band edge)", source: "snapshot", warn: "—", page: "—", responders: ["guardians"], playbook: "P-03 (EMG-077)" },
  { id: "M-06", name: "Collateral value per market at oracle prices", source: "snapshot", warn: "−10 % in 1 hour", page: "−25 % in 1 hour", responders: ["guardians"], playbook: "P-03 (EMG-077)" },
  { id: "M-07", name: "Live pool share (retired: no pool-share breaker in the new core)", source: "snapshot", warn: "—", page: "—", responders: ["riskProviders"], playbook: "P-04 (EMG-078)" },
  { id: "M-08", name: "Breakers (retired: the new core has none; a frozen reserve is M-24)", source: "snapshot", warn: "—", page: "—", responders: ["guardians"], playbook: "per reason" },
  { id: "M-09", name: "Accounts below HF 1 not liquidated; bot runner silent", source: "keeper", warn: "60 s", page: "300 s, or a bot runner instance 3 blocks behind", responders: ["standbyKeeper", "keeperOnCall", "guardians"], playbook: "P-08 (EMG-082)" },
  { id: "M-10", name: "Liquidation failures (LiquidationBot) and share of collateral seized", source: "keeper", warn: "1 failure per market per hour; 10 % seized in 1 hour", page: "3 failures per market per hour; 20 % seized in 1 hour", responders: ["governance", "guardians"], playbook: "P-04 (EMG-078)" },
  { id: "M-11", name: "Route depth at stress size (retired: liquidation is in kind, no swap routes)", source: "fork", warn: "—", page: "—", responders: ["governance"], playbook: "P-04 (EMG-078)" },
  { id: "M-12", name: "GSM exposure headroom (retired with the swap routes)", source: "fork", warn: "—", page: "—", responders: ["riskProviders"], playbook: "P-04 (EMG-078)" },
  { id: "M-13", name: "First-Loss Reserve balance; DAO deficit offset balance", source: "snapshot", warn: "a reserve below 150 % of its minimum; the offset below its minimum", page: "a reserve below 100 % of its minimum", responders: ["avanaLabs", "aaveDao"], playbook: "P-09 (EMG-083)" },
  { id: "M-14", name: "Draw-cap coverage (First-Loss Reserve balance against RiskModule.coverage required)", source: "snapshot", warn: "below 150 %", page: "below 100 % (borrowing stops: CoverageBelowRatio)", responders: ["riskProviders", "aaveDao"], playbook: "P-09 (EMG-083)" },
  { id: "M-15", name: "Hub deficit per asset", source: "snapshot", warn: "any", page: "uncovered after 24 hours", responders: ["coverageRole"], playbook: "P-09 (EMG-083)" },
  { id: "M-16", name: "Liquidatable account the LiquidationBot cannot fund (no balance and no flash path)", source: "keeper", warn: "—", page: "every", responders: ["avanaLabs", "keeperOnCall"], playbook: "P-09 (EMG-083)" },
  { id: "M-17", name: "Keeper gas balance (retired: M-35, read by the monitor)", source: "keeper", warn: "—", page: "—", responders: ["avanaLabs"], playbook: "P-08 (EMG-082)" },
  { id: "M-18", name: "drawn / drawCap per asset", source: "snapshot", warn: "80 %", page: "90 %", responders: ["riskProviders"], playbook: "P-10 (EMG-084)" },
  { id: "M-19", name: "Hub utilization and Lend Spoke withdrawals", source: "snapshot", warn: "utilization 90 %", page: "utilization 98 %, or a withdrawal above 10 % of supply within 1 hour", responders: ["aaveDao", "guardians"], playbook: "P-10 (EMG-084)" },
  { id: "M-20", name: "Aave configuration changes on a CDP Spoke", source: "events", warn: "any change", page: "—", responders: ["emergencyGuardian"], playbook: "P-12 (EMG-086)" },
  { id: "M-21", name: "Backing check (retired: no Collateralization or Lens in the new core)", source: "events", warn: "—", page: "—", responders: ["engineering"], playbook: "P-05 (EMG-079)" },
  { id: "M-22", name: "Avana AccessManager operations and roles", source: "events", warn: "an operation scheduled", page: "a role granted or revoked, a function's role changed, a target closed", responders: ["cancellers"], playbook: "P-06 (EMG-080)" },
  { id: "M-23", name: "Safe owner, threshold, guard or module change; signer liveness", source: "external", warn: "every", page: "every; liveness answers below threshold + 1", responders: ["signers"], playbook: "P-07 (EMG-081)" },
  { id: "M-24", name: "A market or debt reserve frozen, paused or reopened on its Spoke (depeg = freeze)", source: "snapshot", warn: "every", page: "—", responders: ["signers"], playbook: "per reason" },
  { id: "M-25", name: "Token issuer probes and blocklists", source: "external", warn: "probe change; a blocklist naming another Avana contract", page: "a blocklist naming an LPVault, AaveAdapter, LiquidationModule or FlashloanRepay", responders: ["guardians"], playbook: "P-11 (EMG-085)" },
  { id: "M-26", name: "Keeper code-check mismatch (retired: the bot runner calls immutable contracts)", source: "keeper", warn: "—", page: "—", responders: ["keeperOnCall"], playbook: "P-08 (EMG-082)" },
  { id: "M-27", name: "Frontend bundle hash, DNS and hosting change", source: "external", warn: "any", page: "hash mismatch", responders: ["engineering"], playbook: "P-13 (EMG-087)" },
  { id: "M-28", name: "Liquidity leaving a listed pool", source: "snapshot", warn: "−20 % in 1 hour", page: "−40 % in 1 hour", responders: ["riskProviders", "guardians"], playbook: "P-04 (EMG-078)" },
  { id: "M-29", name: "Rate curve per lend asset", source: "snapshot", warn: "any change of a curve's values", page: "GHO baseDrawnRate below the Core Hub GHO base rate", responders: ["aaveDao", "riskProviders"], playbook: "P-10 (EMG-084)" },
  { id: "M-30", name: "Keeper discovery mismatch (retired)", source: "keeper", warn: "—", page: "—", responders: ["keeperOnCall"], playbook: "P-08 (EMG-082)" },
  { id: "M-31", name: "Keeper gas spend anomaly (retired)", source: "keeper", warn: "—", page: "—", responders: ["avanaLabs", "keeperOnCall"], playbook: "P-08 (EMG-082)" },
  { id: "M-32", name: "Keeper class budget reached (retired)", source: "keeper", warn: "—", page: "—", responders: ["keeperOnCall", "avanaLabs"], playbook: "P-08 (EMG-082)" },
  { id: "M-33", name: "Standby keeper signer balance (retired: M-35)", source: "keeper", warn: "—", page: "—", responders: ["avanaLabs"], playbook: "P-08 (EMG-082)" },
  { id: "M-34", name: "Oracle poke overdue (retired: the stateless oracles are never poked)", source: "snapshot", warn: "—", page: "—", responders: ["keeperOnCall", "operators"], playbook: "P-08 (EMG-082)" },
  { id: "M-35", name: "Keeper wallet gas balance and the keeper top-up wallet", source: "snapshot", warn: "a keeper wallet below keeperTopUp.minBalanceWei (run 11-fund-keepers); the top-up wallet below one full refill", page: "a keeper wallet below a third of minBalanceWei", responders: ["avanaLabs", "keeperOnCall"], playbook: "P-08 (EMG-082)" },
  { id: "M-36", name: "Custom range market price near its band edge", source: "snapshot", warn: "within 10 % of the band's width from an edge", page: "outside the band", responders: ["riskProviders", "guardians"], playbook: "P-03 (EMG-077)" },
  { id: "M-37", name: "Depeg above 1 % on a Stable or Correlated pair (response: freeze)", source: "snapshot", warn: "depegged and already frozen", page: "depegged while the market's reserve is open: freeze it", responders: ["emergencyGuardian", "guardians", "riskProviders"], playbook: "P-03 (EMG-077)" },
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
