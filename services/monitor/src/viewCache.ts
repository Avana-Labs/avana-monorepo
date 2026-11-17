// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Contract facts kept between rounds. A few reads never change once they have answered: a Hub asset's underlying and
// decimals, an oracle's or token's decimals, a Spoke's oracle and a deficit offset's First-Loss layer (each an
// immutable or a constant of its contract). Their first successful answer is kept per provider and served to every
// later round, so a round's multicalls carry only the reads whose answers can change. A failed read is never kept and
// is read again next round.

import type { CallResult, ContractCall, ViewClient } from "@avana/services-common/views";

/** Functions whose successful answer is fixed for a given contract and arguments. */
export const FACTS: ReadonlySet<string> = new Set(["getAssetUnderlyingAndDecimals", "decimals", "ORACLE", "FIRST_LOSS_LAYER"]);

const keyOf = (c: ContractCall) => `${c.address.toLowerCase()}:${c.functionName}:${JSON.stringify(c.args ?? [], (_k, v: unknown) => (typeof v === "bigint" ? v.toString(10) : v))}`;

/** One provider's kept facts; `wrap` gives a round's pinned client that reads through them. */
export class FactCache {
  readonly #facts = new Map<string, CallResult>();

  get size(): number {
    return this.#facts.size;
  }

  wrap(client: ViewClient): ViewClient {
    return {
      multicall: async (calls) => {
        const out: (CallResult | undefined)[] = calls.map((c) => (FACTS.has(c.functionName) ? this.#facts.get(keyOf(c)) : undefined));
        const missing = calls.flatMap((c, i) => (out[i] === undefined ? [i] : []));
        if (missing.length > 0) {
          const read = await client.multicall(missing.map((i) => calls[i]!));
          missing.forEach((i, j) => {
            const r = read[j]!;
            out[i] = r;
            if (r.status === "success" && FACTS.has(calls[i]!.functionName)) this.#facts.set(keyOf(calls[i]!), r);
          });
        }
        return out as CallResult[];
      },
    };
  }
}
