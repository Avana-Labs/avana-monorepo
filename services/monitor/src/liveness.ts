// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Safe signer liveness (M-23, services/README.md: "liveness answers below threshold + 1" pages). Time is cut into
// periods (24 hours by default). In each period every signer of a watched Safe signs `livenessMessage` with their
// signer key (EIP-191 personal_sign) and posts it to /v1/liveness. Once the answer window of a period has passed (12
// hours by default), the Safe pages if fewer than threshold + 1 of its current owners answered; until then the
// previous period's result stands. The signature is the authentication: it must recover to the signer it names, and
// only current owners count. A Safe owner that is itself a contract (EIP-1271) cannot answer this way.

import { type Address, type Hex, recoverMessageAddress } from "viem";

export interface LivenessConfig {
  readonly periodSeconds: number;
  readonly windowSeconds: number;
}

export const DEFAULT_LIVENESS: LivenessConfig = { periodSeconds: 86_400, windowSeconds: 43_200 };

/** The text a signer signs for one Safe and one period. */
export function livenessMessage(chainId: number, safe: string, period: number): string {
  return `Avana signer liveness\nchain ${chainId}\nsafe ${safe.toLowerCase()}\nperiod ${period}`;
}

const key = (chainId: number, safe: string, period: number) => `${chainId}|${safe.toLowerCase()}|${period}`;

export class LivenessBook {
  readonly #answers = new Map<string, Set<string>>();

  constructor(readonly cfg: LivenessConfig = DEFAULT_LIVENESS) {}

  periodOf(t: number): number {
    return Math.floor(t / this.cfg.periodSeconds);
  }

  /** The period whose answers decide the level at `t`: the current one once its window passed, else the previous. */
  judgedPeriod(t: number): number {
    const p = this.periodOf(t);
    return t - p * this.cfg.periodSeconds >= this.cfg.windowSeconds ? p : p - 1;
  }

  record(chainId: number, safe: string, period: number, signer: Address): void {
    const k = key(chainId, safe, period);
    let s = this.#answers.get(k);
    if (!s) this.#answers.set(k, (s = new Set()));
    s.add(signer.toLowerCase());
    this.#prune(period);
  }

  /** The current owners that answered for the period. */
  answered(chainId: number, safe: string, period: number, owners: readonly string[]): string[] {
    const s = this.#answers.get(key(chainId, safe, period)) ?? new Set<string>();
    return owners.map((o) => o.toLowerCase()).filter((o) => s.has(o));
  }

  save(): Map<string, Set<string>> {
    return new Map([...this.#answers].map(([k, v]) => [k, new Set(v)]));
  }

  restore(saved: ReadonlyMap<string, ReadonlySet<string>>): void {
    for (const [k, v] of saved) this.#answers.set(k, new Set(v));
  }

  /** Keeps the last three periods. */
  #prune(period: number): void {
    for (const k of this.#answers.keys()) if (Number(k.split("|")[2]) < period - 2) this.#answers.delete(k);
  }
}

export interface LivenessAnswer {
  readonly chainId: number;
  readonly safe: string;
  readonly period: number;
  readonly signer: string;
  readonly signature: string;
}

/**
 * Checks one posted answer against the watched Safes and the current time; records it and returns null, or returns
 * why it is refused. Only the current period is accepted, so an answer cannot be prepared in advance or replayed.
 */
export async function acceptAnswer(book: LivenessBook, watched: (chainId: number, safe: string) => boolean, a: LivenessAnswer, now: number): Promise<string | null> {
  if (!Number.isInteger(a.chainId) || !/^0x[0-9a-fA-F]{40}$/.test(a.safe) || !/^0x[0-9a-fA-F]{40}$/.test(a.signer) || !/^0x[0-9a-fA-F]{130}$/.test(a.signature)) return "malformed answer";
  if (!watched(a.chainId, a.safe)) return "not a watched Safe";
  if (a.period !== book.periodOf(now)) return `period ${a.period} is not the current period ${book.periodOf(now)}`;
  let recovered: Address;
  try {
    recovered = await recoverMessageAddress({ message: livenessMessage(a.chainId, a.safe, a.period), signature: a.signature as Hex });
  } catch {
    return "signature does not recover";
  }
  if (recovered.toLowerCase() !== a.signer.toLowerCase()) return "signature is not the named signer's";
  book.record(a.chainId, a.safe, a.period, recovered);
  return null;
}
