// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The failover layer the Aave toolbox does not have. A request goes to the endpoint in use (Alchemy first). An
// infrastructure failure takes the endpoint out of use and the next attempt goes to the backup at once; a revert or
// an invalid request is returned as it is, never retried. Attempts are Aave's: retryCount retries after the first,
// waiting retryDelay * 2^n (or the Retry-After the provider sent) except when the attempt moves to an endpoint in use.
//
// Sending a transaction is never duplicated across providers. eth_sendRawTransaction is tracked by its hash, sender
// and nonce: when a send fails in a way that leaves its fate unknown (a timeout, a dropped connection, a server
// error), the next endpoint is first asked for the hash, then for the sender's mined and pending nonces, and only a
// transaction found nowhere and whose nonce is still free is sent again, as the same signed bytes (never re-signed).
// A hash sent again by the caller after it was accepted is answered without sending. eth_sendTransaction (the node
// assigns the nonce) is sent once and never retried.

import { type Hex, createTransport, keccak256, parseTransaction, recoverTransactionAddress, type Transport } from "viem";
import type { TransportSettings } from "./config.ts";
import { type InfraFailure, InvalidRpcResponseError, NonceConsumedError, RpcUnavailableError, TransactionOutcomeUnknownError, classifyError } from "./errors.ts";
import type { Endpoint, HealthTracker, ProbeResult } from "./health.ts";
import type { Redactor } from "./redact.ts";

export type RequestArgs = { readonly method: string; readonly params?: unknown };
export type RequestFn = (args: RequestArgs) => Promise<unknown>;

/** What the failover layer of one chain and endpoint kind works with. */
export interface FailoverContext {
  readonly chainId: number;
  readonly health: HealthTracker;
  readonly settings: TransportSettings;
  readonly redactor: Redactor;
  readonly log: (message: string) => void;
  readonly sleep: (ms: number) => Promise<void>;
  readonly now: () => number;
  /** The endpoint's own request function (a viem transport with no retries of its own). */
  readonly requestOf: (e: Endpoint) => RequestFn;
  /** Transactions sent on this chain, by hash, shared by its HTTP and WebSocket layers. */
  readonly sends: Map<Hex, SendRecord>;
}

export interface SendRecord {
  readonly hash: Hex;
  readonly from: Hex;
  readonly nonce: number;
  /** A provider accepted it (or it was found on chain or in a mempool). */
  accepted: boolean;
  /** Providers whose send failed with an unknown outcome. */
  readonly unknownOn: string[];
  /** Providers the bytes were sent to (including failed sends). */
  readonly sentTo: string[];
}

const QUANTITY = new Set(["eth_blockNumber", "eth_chainId", "eth_getBalance", "eth_getTransactionCount", "eth_gasPrice", "eth_estimateGas", "eth_maxPriorityFeePerGas", "eth_blobBaseFee"]);
const DATA = new Set(["eth_call", "eth_getCode", "eth_getStorageAt"]);
const ALREADY_SENT = /already known|known transaction|already imported|already exists|ALREADY_EXISTS/i;
const MAX_RETRY_AFTER_MS = 60_000;

/** Checks the shape of a result (the content of a malformed one is not echoed). */
function validate(chainId: number, method: string, result: unknown): void {
  if (QUANTITY.has(method) && !(typeof result === "string" && /^0x[0-9a-fA-F]+$/.test(result))) throw new InvalidRpcResponseError(method, `expected a hex quantity, got ${typeof result}`);
  if (DATA.has(method) && !(typeof result === "string" && /^0x([0-9a-fA-F]{2})*$/.test(result))) throw new InvalidRpcResponseError(method, `expected hex data, got ${typeof result}`);
  if (method === "eth_chainId" && Number(BigInt(result as string)) !== chainId) throw new InvalidRpcResponseError(method, `the endpoint serves chain ${Number(BigInt(result as string))}, not ${chainId}`);
}

class ProbeTimeoutError extends Error {
  constructor(ms: number) {
    super(`probe timed out after ${ms} ms`);
    this.name = "TimeoutError";
  }
}

const messageOf = (e: unknown) => {
  const parts: string[] = [];
  for (let x = e, i = 0; x && typeof x === "object" && i < 10; x = (x as { cause?: unknown }).cause, i++) {
    const o = x as Record<string, unknown>;
    for (const k of ["shortMessage", "details", "message"]) if (typeof o[k] === "string") parts.push(o[k] as string);
  }
  return parts.join(" ");
};

export class FailoverRpc {
  #probing: Promise<void> | undefined;

  readonly ctx: FailoverContext;

  constructor(ctx: FailoverContext) {
    this.ctx = ctx;
  }

  get health(): HealthTracker {
    return this.ctx.health;
  }

  async request(args: RequestArgs): Promise<unknown> {
    this.maintain();
    if (args.method === "eth_sendRawTransaction") return this.#sendRaw(args);
    if (args.method === "eth_sendTransaction") return this.#sendOnce(args);
    const { retryCount } = this.ctx.settings;
    const attempts: { provider: string; failure: InfraFailure }[] = [];
    let last: { e: Endpoint; error: unknown } | undefined;
    for (let i = 0; i <= retryCount; i++) {
      const e = this.ctx.health.current();
      await this.#backoff(i, e, last);
      const t0 = this.ctx.now();
      try {
        const result = await this.ctx.requestOf(e)(args);
        validate(this.ctx.chainId, args.method, result);
        this.ctx.health.recordSuccess(e, this.ctx.now() - t0);
        return result;
      } catch (error) {
        const failure = this.#failure(e, error, args.method, i, t0);
        attempts.push({ provider: e.provider, failure });
        last = { e, error };
      }
    }
    throw new RpcUnavailableError(this.ctx.chainId, args.method, attempts, last?.error);
  }

  /** Waits before attempt `i`, unless it moves to an endpoint in use (a failover is immediate). */
  async #backoff(i: number, e: Endpoint, last: { e: Endpoint; error: unknown } | undefined): Promise<void> {
    if (i === 0 || !last || (e !== last.e && !this.ctx.health.isDown(e))) return;
    const header = (last.error as { headers?: { get?: (n: string) => string | null } } | undefined)?.headers?.get?.("Retry-After");
    const retryAfter = header && /^\d+$/.test(header.trim()) ? Math.min(Number(header) * 1000, MAX_RETRY_AFTER_MS) : undefined;
    await this.ctx.sleep(retryAfter ?? ~~(1 << (i - 1)) * this.ctx.settings.retryDelay);
  }

  /** Scrubs `error`; rethrows it when it is not an infrastructure failure; else counts it and returns its kind. */
  #failure(e: Endpoint, error: unknown, method: string, attempt: number, t0: number): InfraFailure {
    this.ctx.redactor.error(error);
    const failure = classifyError(error);
    if (!failure) {
      // The provider answered: the request itself is refused, the same on every provider.
      this.ctx.health.recordSuccess(e, this.ctx.now() - t0);
      throw error;
    }
    const out = this.ctx.health.recordFailure(e, failure);
    this.ctx.log(
      `chain ${this.ctx.chainId}: ${e.provider} ${failure} on ${method} (attempt ${attempt + 1}/${this.ctx.settings.retryCount + 1})` +
        (out ? `; ${e.provider} out of use, ${this.ctx.health.current().provider} serves` : ""),
    );
    return failure;
  }

  async #sendOnce(args: RequestArgs): Promise<unknown> {
    const e = this.ctx.health.current();
    const t0 = this.ctx.now();
    try {
      const r = await this.ctx.requestOf(e)(args);
      this.ctx.health.recordSuccess(e, this.ctx.now() - t0);
      return r;
    } catch (error) {
      const failure = this.#failure(e, error, args.method, 0, t0);
      throw new TransactionOutcomeUnknownError(undefined, undefined, `eth_sendTransaction failed on ${e.provider} (${failure}); the node assigns its nonce, so it is never sent again`, error);
    }
  }

  async #sendRaw(args: RequestArgs): Promise<Hex> {
    const raw = (args.params as unknown[] | undefined)?.[0];
    if (typeof raw !== "string" || !raw.startsWith("0x")) throw new InvalidRpcResponseError("eth_sendRawTransaction", "the request carries no signed transaction");
    const hash = keccak256(raw as Hex);
    let rec = this.ctx.sends.get(hash);
    if (rec?.accepted) return hash;
    if (!rec) {
      const tx = parseTransaction(raw as Hex);
      const from = await recoverTransactionAddress({ serializedTransaction: raw as Parameters<typeof recoverTransactionAddress>[0]["serializedTransaction"] });
      rec = { hash, from, nonce: tx.nonce ?? 0, accepted: false, unknownOn: [], sentTo: [] };
      this.ctx.sends.set(hash, rec);
    }
    const { retryCount } = this.ctx.settings;
    const attempts: { provider: string; failure: InfraFailure }[] = [];
    let last: { e: Endpoint; error: unknown } | undefined;
    for (let i = 0; i <= retryCount; i++) {
      const e = this.ctx.health.current();
      await this.#backoff(i, e, last);
      const t0 = this.ctx.now();
      if (rec.unknownOn.length) {
        // An earlier send may have reached the network: settle it on this endpoint before sending anything.
        let found: Awaited<ReturnType<FailoverRpc["lookup"]>>;
        try {
          found = await this.lookup(e, rec);
          this.ctx.health.recordSuccess(e, this.ctx.now() - t0);
        } catch (error) {
          attempts.push({ provider: e.provider, failure: this.#failure(e, error, "transaction lookup", i, t0) });
          last = { e, error };
          continue;
        }
        if (found === "sent") {
          rec.accepted = true;
          this.ctx.log(`chain ${this.ctx.chainId}: transaction ${hash} found on ${e.provider}; not sent again`);
          return hash;
        }
        if (found === "nonce-used") throw new NonceConsumedError(hash, rec.nonce);
        if (found === "nonce-pending") throw new TransactionOutcomeUnknownError(hash, rec.nonce, `another transaction with nonce ${rec.nonce} is pending on ${e.provider}`);
      }
      rec.sentTo.push(e.provider);
      try {
        const r = await this.ctx.requestOf(e)(args);
        this.ctx.health.recordSuccess(e, this.ctx.now() - t0);
        if (typeof r !== "string" || r.toLowerCase() !== hash.toLowerCase()) throw new InvalidRpcResponseError("eth_sendRawTransaction", "the answer is not the transaction's hash");
        rec.accepted = true;
        return hash;
      } catch (error) {
        this.ctx.redactor.error(error);
        if (ALREADY_SENT.test(messageOf(error))) {
          rec.accepted = true;
          return hash;
        }
        if (!classifyError(error) && !rec.unknownOn.length) this.ctx.sends.delete(hash);
        const failure = this.#failure(e, error, "eth_sendRawTransaction", i, t0);
        rec.unknownOn.push(e.provider);
        attempts.push({ provider: e.provider, failure });
        last = { e, error };
      }
    }
    throw new TransactionOutcomeUnknownError(hash, rec.nonce, `no provider settled it (${attempts.map((a) => `${a.provider} ${a.failure}`).join(", ")})`, last?.error);
  }

  /** Where a transaction stands on endpoint `e`: known by hash, its nonce mined by another, pending, or free. */
  async lookup(e: Endpoint, rec: Pick<SendRecord, "hash" | "from" | "nonce">): Promise<"sent" | "nonce-used" | "nonce-pending" | "absent"> {
    const req = this.ctx.requestOf(e);
    if (await req({ method: "eth_getTransactionByHash", params: [rec.hash] })) return "sent";
    const mined = BigInt((await req({ method: "eth_getTransactionCount", params: [rec.from, "latest"] })) as string);
    if (mined > BigInt(rec.nonce)) return (await req({ method: "eth_getTransactionReceipt", params: [rec.hash] })) ? "sent" : "nonce-used";
    const pending = BigInt((await req({ method: "eth_getTransactionCount", params: [rec.from, "pending"] })) as string);
    return pending > BigInt(rec.nonce) ? "nonce-pending" : "absent";
  }

  /** Starts the probes that are due (recovery of endpoints out of use; the periodic freshness check), not awaited. */
  maintain(): void {
    if (this.#probing) return;
    const due = this.ctx.health.fullProbeDue() ? [...this.ctx.health.endpoints] : this.ctx.health.recoveryDue();
    if (due.length === 0) return;
    this.#probing = this.probe(due)
      .then(() => undefined, () => undefined)
      .finally(() => {
        this.#probing = undefined;
      });
  }

  /** Resolves once the background probes in flight are done. */
  async idle(): Promise<void> {
    await this.#probing;
  }

  /** Probes `endpoints` (all by default): chain ID, latest head, latency; applies the results to the health. */
  async probe(endpoints: readonly Endpoint[] = this.ctx.health.endpoints): Promise<Map<Endpoint, ProbeResult>> {
    const results = new Map<Endpoint, ProbeResult>(await Promise.all(endpoints.map(async (e) => [e, await this.#probeOne(e)] as const)));
    const { out, back } = this.ctx.health.applyProbes(results);
    for (const e of out) {
      const r = results.get(e);
      this.ctx.log(`chain ${this.ctx.chainId}: ${e.provider} out of use (${r && !r.ok ? r.failure : "stale or slow"}); ${this.ctx.health.current().provider} serves`);
    }
    for (const e of back) this.ctx.log(`chain ${this.ctx.chainId}: ${e.provider} healthy again; ${this.ctx.health.current().provider} serves`);
    return results;
  }

  async #probeOne(e: Endpoint): Promise<ProbeResult> {
    const req = this.ctx.requestOf(e);
    const t0 = this.ctx.now();
    let timer: ReturnType<typeof setTimeout> | undefined;
    const limit = this.ctx.health.policy.probeTimeoutMs;
    try {
      const [id, block] = (await Promise.race([
        Promise.all([req({ method: "eth_chainId" }), req({ method: "eth_getBlockByNumber", params: ["latest", false] })]),
        new Promise<never>((_, reject) => {
          timer = setTimeout(() => reject(new ProbeTimeoutError(limit)), limit);
          timer.unref?.();
        }),
      ])) as [unknown, { number?: unknown; timestamp?: unknown } | null];
      if (typeof id !== "string" || !/^0x[0-9a-f]+$/i.test(id) || Number(BigInt(id)) !== this.ctx.chainId) return { ok: false, failure: "malformed" };
      if (!block || typeof block.number !== "string" || typeof block.timestamp !== "string") return { ok: false, failure: "malformed" };
      return { ok: true, latencyMs: this.ctx.now() - t0, head: BigInt(block.number), timestamp: BigInt(block.timestamp) };
    } catch (error) {
      this.ctx.redactor.error(error);
      return { ok: false, failure: classifyError(error) ?? "malformed" };
    } finally {
      clearTimeout(timer);
    }
  }
}

/**
 * A viem transport over the failover layer. Its own retries are off: FailoverRpc retries. For WebSocket endpoints
 * `subscribe` goes to the endpoint in use (viem's socket re-subscribes after it reconnects).
 */
export function failoverTransport(rpc: FailoverRpc, kind: "http" | "ws", subscribe?: (args: unknown) => Promise<unknown>): Transport {
  const providers = rpc.health.endpoints.map((e) => e.provider).join(",");
  return () =>
    createTransport(
      {
        key: `avana-${kind}`,
        name: `Avana RPC (${providers})`,
        type: kind === "ws" ? "webSocket" : "avanaFailover",
        retryCount: 0,
        timeout: rpc.ctx.settings.timeout,
        request: ((args: RequestArgs) => rpc.request(args)) as never,
      },
      subscribe ? { subscribe } : undefined,
    );
}
