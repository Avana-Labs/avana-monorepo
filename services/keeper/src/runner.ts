// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The bot runner's pass: for each integration of the release manifest, the LiquidationBot (packages/liquidator/) with that
// integration's AaveAdapter, LiquidationModule and, when its operator is this runner's signer, FlashLiquidator. Each
// pass gathers the accounts (the indexer stream, else the bot's own RPC scan of `AccountCreated`), runs every bot
// unless the kill switch has halted the runner, turns the outcomes into alerts for the monitor and reports the head.
//
// Alerts (services/monitor signals): M-16 pages at once for a liquidatable account no bot can fund (no balance and no
// flash path); M-10 warns for a liquidation that failed, per market; M-09 warns once an account stays liquidatable for
// 60 s of block time and pages at 300 s.

import type { Address, Hash } from "viem";
import type { Account, Config, Outcome } from "@avana/liquidator/bot";
import type { Alert, AlertSink } from "./alerts.ts";

/** What the runner needs of a LiquidationBot. */
export interface Bot {
  pass(accounts: readonly Account[]): Promise<Outcome[]>;
}

/** What the runner needs of the bot's own account discovery. */
export interface AccountSource {
  refresh(): Promise<Account[]>;
}

export interface Instance {
  readonly integrationId: number;
  /** Lower-case AaveAdapter address, the key of its accounts in the bot stream. */
  readonly adapter: string;
  readonly bot: Bot;
  /** The bot's RPC scan, used while the stream is off or failing. */
  readonly rpcAccounts: AccountSource;
}

export interface Head {
  readonly number: bigint;
  readonly timestamp: number;
}

export interface PassReport {
  readonly halted: boolean;
  readonly outcomes: readonly (Outcome & { readonly integrationId: number })[];
  readonly alerts: readonly Alert[];
  readonly source: "stream" | "rpc";
}

export const M09_WARN_SECONDS = 60;
export const M09_PAGE_SECONDS = 300;

export class Runner {
  /** Accounts each AaveAdapter announced on the stream (lower-case adapter → account → market). */
  private readonly streamed = new Map<string, Map<Address, bigint>>();
  /** Unix seconds since which each account has been liquidatable without a sent liquidation. */
  private readonly liquidatableSince = new Map<string, number>();

  constructor(
    private readonly chainId: number,
    private readonly instances: readonly Instance[],
    private readonly sink: AlertSink,
    private readonly state: { halted: boolean },
    /** Reads the bot stream; null when the runner discovers over RPC only. */
    private readonly stream: (() => Promise<{ ok: boolean; accounts: ReadonlyMap<string, readonly Account[]> }>) | null,
    private readonly heartbeat: (block: bigint) => void = () => {},
    private readonly log: (message: string, fields?: Record<string, unknown>) => void = () => {},
  ) {}

  async pass(head: Head): Promise<PassReport> {
    let streamOk = false;
    if (this.stream) {
      const r = await this.stream();
      streamOk = r.ok;
      for (const [adapter, accounts] of r.accounts) {
        const set = this.streamed.get(adapter) ?? new Map<Address, bigint>();
        for (const a of accounts) set.set(a.account, a.marketId);
        this.streamed.set(adapter, set);
      }
      if (!r.ok) this.log("bot stream failed: discovering over RPC this pass");
    }
    const outcomes: (Outcome & { integrationId: number })[] = [];
    if (!this.state.halted) {
      for (const x of this.instances) {
        const accounts = streamOk ? [...(this.streamed.get(x.adapter) ?? new Map())].map(([account, marketId]) => ({ account, marketId })) : await x.rpcAccounts.refresh();
        for (const o of await x.bot.pass(accounts)) outcomes.push({ ...o, integrationId: x.integrationId });
      }
    } else this.log("halted: no liquidation is sent");
    const alerts = this.alerts(head, outcomes);
    for (const a of alerts) await this.sink.send(a);
    this.heartbeat(head.number);
    return { halted: this.state.halted, outcomes, alerts, source: streamOk ? "stream" : "rpc" };
  }

  private alerts(head: Head, outcomes: readonly (Outcome & { integrationId: number })[]): Alert[] {
    const out: Alert[] = [];
    const base = { chainId: this.chainId, blockNumber: head.number };
    const still = new Set<string>();
    for (const o of outcomes) {
      const key = `${o.integrationId}:${o.account.toLowerCase()}`;
      const d = o.decision;
      if (d.kind === "skip") continue;
      if (d.kind === "unfunded") {
        out.push({ ...base, signal: "M-16", level: "page", subject: `account:${o.account.toLowerCase()}`, detail: { marketId: o.marketId.toString(10), debt: d.debt.toString(10), note: "no balance of the debt asset and no flash path" } });
      }
      if (d.kind === "error") {
        out.push({ ...base, signal: "M-10", level: "warn", subject: `market:${o.marketId}`, detail: { account: o.account.toLowerCase(), reason: d.message.slice(0, 500) } });
      }
      const sent = (o as { hash?: Hash }).hash !== undefined;
      if (sent) {
        this.liquidatableSince.delete(key);
        continue;
      }
      still.add(key);
      const since = this.liquidatableSince.get(key) ?? head.timestamp;
      this.liquidatableSince.set(key, since);
      const age = head.timestamp - since;
      if (age >= M09_WARN_SECONDS) {
        out.push({ ...base, signal: "M-09", level: age >= M09_PAGE_SECONDS ? "page" : "warn", subject: `account:${o.account.toLowerCase()}`, detail: { marketId: o.marketId.toString(10), liquidatableSeconds: String(age), decision: d.kind } });
      }
    }
    // An account no longer reported liquidatable (healthy, or liquidated by someone else) is forgotten.
    if (!this.state.halted) for (const k of this.liquidatableSince.keys()) if (!still.has(k)) this.liquidatableSince.delete(k);
    return out;
  }
}

/** The LiquidationBot configuration of one integration: the shared settings with that integration's contracts. */
export function instanceConfig(
  settings: Omit<Config, "adapter" | "liquidationModule" | "flashLiquidator" | "debtReserves" | "spokeDebtReserves">,
  x: { aaveAdapter: Address; liquidationModule: Address; flashLiquidator?: Address },
  spokeDebtReserves: ReadonlyMap<string, readonly bigint[]>,
): Config {
  if (x.flashLiquidator && !settings.swapRouter) throw new Error("LIQUIDATION_BOT_SWAP_ROUTER is required while the manifest names a FlashLiquidator this signer operates");
  return {
    ...settings,
    adapter: x.aaveAdapter,
    liquidationModule: x.liquidationModule,
    ...(x.flashLiquidator ? { flashLiquidator: x.flashLiquidator } : {}),
    debtReserves: [],
    spokeDebtReserves,
  };
}
