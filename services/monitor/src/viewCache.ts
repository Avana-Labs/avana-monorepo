// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Contract facts kept between rounds. A few reads do not change between upgrades: a Hub asset's underlying and
// decimals, an oracle's or token's decimals and a deficit offset's First-Loss layer. Their successful answer is kept per
// provider, keyed by contract address, function and arguments, and served to later rounds for FACT_TTL_MS, so most
// rounds' multicalls carry only the reads whose answers can change. A contract behind a proxy can change these on an
// upgrade, so each fact is read again once it is FACT_TTL_MS old. A failed read is never kept and is read again next
// round. A Spoke's oracle (`ORACLE`) is not a fact: the Spokes are proxies and it is read every round.

import type { CallResult, ContractCall, ViewClient } from "@avana/services-common/views";

/** Functions whose successful answer is kept for a given contract and arguments. */
export const FACTS: ReadonlySet<string> = new Set(["getAssetUnderlyingAndDecimals", "decimals", "FIRST_LOSS_LAYER"]);

/** How long a kept fact is served before it is read again: 10 minutes. */
export const FACT_TTL_MS = 10 * 60 * 1000;

const keyOf = (c: ContractCall) => `${c.address.toLowerCase()}:${c.functionName}:${JSON.stringify(c.args ?? [], (_k, v: unknown) => (typeof v === "bigint" ? v.toString(10) : v))}`;

/** One provider's kept facts; `wrap` gives a round's pinned client that reads through them. */
export class FactCache {
  readonly #facts = new Map<string, { readonly result: CallResult; readonly at: number }>();
  readonly #now: () => number;
  readonly #ttlMs: number;

  constructor(opts: { readonly now?: () => number; readonly ttlMs?: number } = {}) {
    this.#now = opts.now ?? Date.now;
    this.#ttlMs = opts.ttlMs ?? FACT_TTL_MS;
  }

  get size(): number {
    return this.#facts.size;
  }

  wrap(client: ViewClient): ViewClient {
    return {
      multicall: async (calls) => {
        const now = this.#now();
        const kept = (c: ContractCall) => {
          if (!FACTS.has(c.functionName)) return undefined;
          const f = this.#facts.get(keyOf(c));
          return f && now - f.at < this.#ttlMs ? f.result : undefined;
        };
        const out: (CallResult | undefined)[] = calls.map(kept);
        const missing = calls.flatMap((c, i) => (out[i] === undefined ? [i] : []));
        if (missing.length > 0) {
          const read = await client.multicall(missing.map((i) => calls[i]!));
          missing.forEach((i, j) => {
            const r = read[j]!;
            out[i] = r;
            if (r.status === "success" && FACTS.has(calls[i]!.functionName)) this.#facts.set(keyOf(calls[i]!), { result: r, at: now });
          });
        }
        return out as CallResult[];
      },
    };
  }
}
