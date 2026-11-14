// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Rolling samples per key, for the signals judged over a time window ("−10 % in 1 hour"). A drop is measured from
// the highest sample inside the window, so a fall spread over several reads within the hour still counts in full.

export class History {
  readonly #samples = new Map<string, { t: number; v: bigint }[]>();

  constructor(readonly windowSeconds: number) {}

  /** Adds a sample at unix time `t` and drops the ones older than the window. Samples arrive in time order. */
  record(key: string, t: number, v: bigint): void {
    let xs = this.#samples.get(key);
    if (!xs) this.#samples.set(key, (xs = []));
    const last = xs[xs.length - 1];
    if (last && t < last.t) throw new Error(`sample for ${key} at ${t} is older than the last one at ${last.t}`);
    xs.push({ t, v });
    const from = t - this.windowSeconds;
    let drop = 0;
    while (drop < xs.length && xs[drop]!.t < from) drop++;
    if (drop > 0) xs.splice(0, drop);
  }

  /** Highest sample within the window ending at the latest sample; null for an unknown key. */
  peak(key: string): bigint | null {
    const xs = this.#samples.get(key);
    if (!xs || xs.length === 0) return null;
    return xs.reduce((m, x) => (x.v > m ? x.v : m), xs[0]!.v);
  }

  /** `(peak − latest) · 10⁴ / peak`, rounded down; 0 when the value has not fallen or the peak is 0. */
  dropBps(key: string): bigint {
    const xs = this.#samples.get(key);
    const peak = this.peak(key);
    if (!xs || peak === null || peak === 0n) return 0n;
    const latest = xs[xs.length - 1]!.v;
    return latest >= peak ? 0n : ((peak - latest) * 10_000n) / peak;
  }

  /** Forgets keys not seen in the latest evaluation (a delisted market, a removed Spoke). */
  save(): Map<string, { t: number; v: bigint }[]> {
    return new Map([...this.#samples].map(([k, xs]) => [k, xs.map((x) => ({ ...x }))]));
  }

  restore(saved: ReadonlyMap<string, readonly { t: number; v: bigint }[]>): void {
    for (const [k, xs] of saved) this.#samples.set(k, xs.map((x) => ({ ...x })));
  }

  retain(keys: ReadonlySet<string>): void {
    for (const k of this.#samples.keys()) if (!keys.has(k)) this.#samples.delete(k);
  }
}
