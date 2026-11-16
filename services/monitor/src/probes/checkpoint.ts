// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// M-34, oracle poke overdue: every market's LPOracle `priceCheckpoint().at`, read from the chain at the round's block.
// The keeper pokes each oracle at least every CHECKPOINT_INTERVAL (3,600 s) less a 60 s lead, and the price-drop alert
// needs a checkpoint under 2 hours old (REQ-ORACLE-088), so a checkpoint older than 7,200 s pages. It reads the chain,
// not the keeper, so it fires whether the keeper is down, out of gas, or running but failing to land its pokes. Like
// every monitor page it is confirmed on the second provider at the same block (the same `at` read there).

import { lpOracleAbi } from "@avana/protocol/abis";
import { some } from "@avana/services-common/views";
import type { Address } from "viem";
import { type Probe, text } from "../probe.ts";
import type { Level } from "../signals.ts";
import type { Finding } from "../types.ts";

/** A checkpoint older than this pages: twice CHECKPOINT_INTERVAL, the age limit of the price-drop alert's reference. */
export const CHECKPOINT_OVERDUE_SECONDS = 7_200;

export interface MarketCheckpoint {
  readonly marketId: string;
  readonly name: string;
  readonly lpOracle: Address;
  /** Unix seconds of the last checkpoint; 0 when the oracle has never stored one. */
  readonly at: bigint;
}

export interface CheckpointInput {
  readonly now: number;
  /** null: that market's read failed this round. */
  readonly markets: ReadonlyMap<string, MarketCheckpoint | null>;
}

export const checkpointSubject = (marketId: string) => `market:${marketId}:checkpoint`;

/** M-34: a checkpoint older than 7,200 s pages; at exactly 7,200 s it is not yet overdue. */
export function m34(at: bigint, now: number): Level {
  return BigInt(now) - at > BigInt(CHECKPOINT_OVERDUE_SECONDS) ? "page" : "ok";
}

export function checkpointProbe(): Probe<CheckpointInput> {
  return {
    name: "checkpoint",

    async read(ctx) {
      const markets = ctx.snapshot.markets;
      const r = await some(ctx.views, markets.map((m) => ({ address: m.lpOracle, abi: lpOracleAbi, functionName: "priceCheckpoint" })));
      const out = new Map<string, MarketCheckpoint | null>();
      markets.forEach((m, i) => {
        const v = r[i] as readonly [bigint, bigint | number] | null;
        out.set(m.marketId, v ? { marketId: m.marketId, name: m.name, lpOracle: m.lpOracle, at: BigInt(v[1]) } : null);
      });
      return { now: ctx.block.timestamp, markets: out };
    },

    evaluate(input) {
      const out: Finding[] = [];
      for (const [id, m] of input.markets) {
        const subject = checkpointSubject(id);
        if (!m) {
          out.push({ signal: "M-34", kind: "unread", level: "ok", subject, detail: {} });
          continue;
        }
        const age = BigInt(input.now) - m.at;
        out.push({ signal: "M-34", kind: "condition", level: m34(m.at, input.now), subject, detail: { market: m.name, lpOracle: m.lpOracle, checkpointAt: m.at.toString(10), ageSeconds: age.toString(10), overdueAfterSeconds: String(CHECKPOINT_OVERDUE_SECONDS), playbook: "P-08" } });
      }
      return out;
    },

    evidence(input, subject) {
      const [kind, id] = subject.split(":");
      const m = kind === "market" ? input.markets.get(id!) : undefined;
      return m ? text(m) : null;
    },
  };
}
