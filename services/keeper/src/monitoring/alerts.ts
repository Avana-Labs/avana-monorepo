// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Alert evaluation for the block-cadence signals the keeper computes from its own reads, and the rule that a
// page is sent only after the same value is read again on the second provider at the same block.

import { type ChainInfo, blocksFor } from "@avana/services-common";
import type { Level } from "./signals.ts";

export interface Alert {
  readonly signal: `M-${string}`;
  readonly level: Exclude<Level, "ok">;
  readonly chainId: number;
  readonly blockNumber: bigint;
  readonly subject: string;
  readonly detail: Readonly<Record<string, string>>;
}

export interface AlertSink {
  /** Warns reach the on-call engineer and the named responder; pages also reach both Safes' signers and the Aave Protocol Guardian contact. */
  send(alert: Alert): Promise<void>;
}

/** M-09: an account below HF 1 for 60 s warns and for 300 s pages; 3,600 s escalates to an Emergency Guardian decision. */
export function m09Level(chain: ChainInfo, liquidatableSince: bigint | null, now: bigint): Level | "escalate" {
  if (liquidatableSince === null) return "ok";
  const age = now - liquidatableSince;
  if (age >= BigInt(blocksFor(chain, 3_600))) return "escalate";
  if (age >= BigInt(blocksFor(chain, 300))) return "page";
  if (age >= BigInt(blocksFor(chain, 60))) return "warn";
  return "ok";
}

/** M-01: Cached warns on entry, Expired pages (state 2 and 3 of PriceState). */
export function m01Level(state: number): Level {
  if (state === 3) return "page";
  if (state === 2) return "warn";
  return "ok";
}

/**
 * The alerts a check raised at its last run, posted again at each head until it runs again. A check that reads only
 * every N seconds (KEEPER_SLOW_JOB_SECONDS) therefore keeps its alerts arriving at every head, as the monitor needs to
 * hold them open, and its alerts change only when it reads again.
 */
export class HeldAlerts {
  #held: Alert[] = [];
  readonly #target: AlertSink;
  /** Forwards to the target and keeps what the current run sends. */
  readonly sink: AlertSink;

  constructor(target: AlertSink) {
    this.#target = target;
    this.sink = {
      send: (a) => {
        this.#held.push(a);
        return this.#target.send(a);
      },
    };
  }

  /** A new run starts: what the previous one raised no longer holds. */
  begin(): void {
    this.#held = [];
  }

  /** Posts the last run's alerts again for `blockNumber`. */
  async replay(blockNumber: bigint): Promise<void> {
    for (const a of this.#held) await this.#target.send({ ...a, blockNumber });
  }
}

/**
 * Sends a page only when `confirm` (the same read on the second provider, pinned to the same block) agrees.
 * A disagreement is itself raised as a warn, because the providers disagreeing is an RPC fault to look at.
 */
export async function raise(sink: AlertSink, alert: Alert, confirm: () => Promise<boolean>): Promise<void> {
  if (alert.level === "page" && !(await confirm())) {
    await sink.send({ ...alert, level: "warn", detail: { ...alert.detail, note: "not confirmed on the second provider" } });
    return;
  }
  await sink.send(alert);
}
