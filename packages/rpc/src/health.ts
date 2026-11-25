// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One chain's endpoints and their health. The first endpoint not out of use serves (the configured order: Alchemy,
// then QuickNode). An endpoint goes out of use after `failoverAfter` consecutive infrastructure failures, or at once
// when a probe finds its head stale or its chain wrong. It comes back only after `recoverAfter` consecutive good
// probes, the first one `recoverCooldownMs` after it went out and the next ones `probeIntervalMs` apart, so a provider
// that answers once between failures does not take the traffic back (no flapping).

import type { HealthPolicy } from "./config.ts";
import type { InfraFailure } from "./errors.ts";
import type { EndpointKind } from "./providers.ts";

/** An endpoint of one chain. Its URL carries the provider's credentials: it is not enumerable, and an endpoint prints
 * as `provider:chain:kind`. */
export class Endpoint {
  readonly provider: string;
  readonly chainId: number;
  readonly kind: EndpointKind;
  readonly #url: string;
  constructor(provider: string, chainId: number, kind: EndpointKind, url: string) {
    this.provider = provider;
    this.chainId = chainId;
    this.kind = kind;
    this.#url = url;
  }
  /** The authenticated URL: hand it only to a transport or a child process's environment, never to a log. */
  secretUrl(): string {
    return this.#url;
  }
  toString(): string {
    return `${this.provider}:${this.chainId}:${this.kind}`;
  }
  toJSON(): string {
    return this.toString();
  }
  [Symbol.for("nodejs.util.inspect.custom")](): string {
    return `Endpoint(${this.toString()})`;
  }
}

export type ProbeResult =
  | { readonly ok: true; readonly latencyMs: number; readonly head: bigint; readonly timestamp: bigint }
  | { readonly ok: false; readonly failure: InfraFailure };

export interface EndpointReport {
  readonly provider: string;
  readonly inUse: boolean;
  readonly down: boolean;
  readonly failures: number;
  readonly lastFailure: InfraFailure | undefined;
  readonly latencyMs: number | undefined;
  readonly head: bigint | undefined;
}

interface State {
  failures: number;
  down: boolean;
  downAt: number;
  lastFailure: InfraFailure | undefined;
  goodProbes: number;
  lastProbeAt: number;
  latencyMs: number | undefined;
  head: bigint | undefined;
}

export class HealthTracker {
  readonly #state = new Map<Endpoint, State>();
  readonly endpoints: readonly Endpoint[];
  readonly policy: HealthPolicy;
  readonly limits: { readonly maxLagBlocks: number; readonly maxHeadAgeMs: number };
  readonly now: () => number;
  lastFullProbeAt: number;

  constructor(endpoints: readonly Endpoint[], policy: HealthPolicy, limits: { readonly maxLagBlocks: number; readonly maxHeadAgeMs: number }, now: () => number) {
    this.endpoints = endpoints;
    this.policy = policy;
    this.limits = limits;
    this.now = now;
    if (endpoints.length === 0) throw new Error("a chain needs at least one endpoint");
    for (const e of endpoints) this.#state.set(e, { failures: 0, down: false, downAt: 0, lastFailure: undefined, goodProbes: 0, lastProbeAt: -Infinity, latencyMs: undefined, head: undefined });
    this.lastFullProbeAt = now();
  }

  #s(e: Endpoint): State {
    return this.#state.get(e)!;
  }

  isDown(e: Endpoint): boolean {
    return this.#s(e).down;
  }

  /** The endpoints in the order to try: those in use in configured order, then those out of use, longest out first. */
  order(): Endpoint[] {
    const up = this.endpoints.filter((e) => !this.#s(e).down);
    const down = this.endpoints.filter((e) => this.#s(e).down).sort((a, b) => this.#s(a).downAt - this.#s(b).downAt);
    return [...up, ...down];
  }

  /** The endpoint that serves now. */
  current(): Endpoint {
    return this.order()[0]!;
  }

  recordSuccess(e: Endpoint, latencyMs: number): void {
    const s = this.#s(e);
    s.latencyMs = latencyMs;
    s.failures = 0;
    // Tried because every endpoint was out of use, and it answered: it serves again.
    if (s.down && this.endpoints.every((x) => this.#s(x).down)) s.down = false;
  }

  /** Counts an infrastructure failure; true when it takes the endpoint out of use. */
  recordFailure(e: Endpoint, failure: InfraFailure): boolean {
    const s = this.#s(e);
    s.failures++;
    s.goodProbes = 0;
    s.lastFailure = failure;
    if (s.down) {
      s.downAt = this.now();
      return false;
    }
    if (s.failures >= this.policy.failoverAfter || failure === "stale") {
      s.down = true;
      s.downAt = this.now();
      return true;
    }
    return false;
  }

  /** Endpoints out of use whose next recovery probe is due. */
  recoveryDue(): Endpoint[] {
    const t = this.now();
    return this.endpoints.filter((e) => {
      const s = this.#s(e);
      return s.down && t - s.downAt >= this.policy.recoverCooldownMs && t - s.lastProbeAt >= this.policy.probeIntervalMs;
    });
  }

  /** Whether the background freshness probe of every endpoint is due. */
  fullProbeDue(): boolean {
    return this.policy.backgroundProbes && this.now() - this.lastFullProbeAt >= this.policy.probeIntervalMs;
  }

  /**
   * Applies probe results. A probe is good when it answered within maxLatencyMs, its head is at most maxLagBlocks
   * behind the best head of this round (or the best head known) and at most maxHeadAgeMs old. Returns the endpoints
   * whose use changed, for the log.
   */
  applyProbes(results: ReadonlyMap<Endpoint, ProbeResult>): { readonly out: Endpoint[]; readonly back: Endpoint[] } {
    const t = this.now();
    const out: Endpoint[] = [];
    const back: Endpoint[] = [];
    let best = -1n;
    for (const s of this.#state.values()) if (s.head !== undefined && s.head > best) best = s.head;
    for (const r of results.values()) if (r.ok && r.head > best) best = r.head;
    for (const [e, r] of results) {
      const s = this.#s(e);
      s.lastProbeAt = t;
      let failure: InfraFailure | undefined;
      if (!r.ok) failure = r.failure;
      else {
        s.latencyMs = r.latencyMs;
        s.head = r.head;
        if (r.latencyMs > this.policy.maxLatencyMs) failure = "timeout";
        else if (r.head + BigInt(this.limits.maxLagBlocks) < best) failure = "stale";
        else if (t - Number(r.timestamp) * 1000 > this.limits.maxHeadAgeMs) failure = "stale";
      }
      if (failure === undefined) {
        // A good probe counts towards recovery only after the cool-down (a freshness probe can come sooner).
        if (s.down && t - s.downAt >= this.policy.recoverCooldownMs) {
          s.goodProbes++;
          if (s.goodProbes >= this.policy.recoverAfter) {
            s.down = false;
            s.failures = 0;
            s.goodProbes = 0;
            back.push(e);
          }
        } else if (!s.down) s.failures = 0;
      } else if (this.recordFailure(e, failure)) out.push(e);
    }
    if (results.size === this.endpoints.length) this.lastFullProbeAt = t;
    return { out, back };
  }

  report(): EndpointReport[] {
    const cur = this.current();
    return this.endpoints.map((e) => {
      const s = this.#s(e);
      return { provider: e.provider, inUse: e === cur, down: s.down, failures: s.failures, lastFailure: s.lastFailure, latencyMs: s.latencyMs, head: s.head };
    });
  }
}
