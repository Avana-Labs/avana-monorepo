// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// AvanaRPCManager: Avana's RPC clients, resolved the way aave-address-book's scripts/clients.ts resolves them
// (getClient(chainId) over the Aave toolbox's provider credentials and transport values), with the failover,
// health checks, safe transaction sending, WebSocket clients and redaction the toolbox does not have.
//
//   const rpc = AvanaRPCManager.fromEnv();            // ALCHEMY_API_KEY, QUICKNODE_ENDPOINT_NAME, QUICKNODE_TOKEN
//   const client = rpc.getClient(11155111);           // viem PublicClient, multicall batching
//   const wallet = createWalletClient({ account, chain: sepolia, transport: rpc.transport(11155111) });
//   const ep = await rpc.selectHealthy(84532);        // for a child process: ep.secretUrl() into its environment

import { type Chain, type PublicClient, type Transport, createPublicClient, http, webSocket } from "viem";
import type { Hex } from "viem";
import { type RpcChain, rpcChain } from "./chains.ts";
import { AAVE_TRANSPORT_DEFAULTS, type ChainSettings, DEFAULT_HEALTH_POLICY, type HealthPolicy, type TransportSettings, configFromEnv } from "./config.ts";
import { Endpoint, type EndpointReport, HealthTracker } from "./health.ts";
import { type Credentials, type EndpointKind, PROVIDERS, ProviderConfigError, type RpcProvider, configured } from "./providers.ts";
import { Redactor } from "./redact.ts";
import { FailoverRpc, type RequestFn, type SendRecord, failoverTransport } from "./transport.ts";

export interface RpcLogger {
  warn(message: string): void;
}

export interface AvanaRPCManagerOptions {
  /** Provider credentials by variable name. */
  readonly credentials?: Credentials;
  /** Provider order for every chain (default alchemy, quicknode). */
  readonly providers?: readonly string[];
  /** Per-chain settings: provider order, explicit endpoints, freshness limits. */
  readonly chains?: Readonly<Record<number, ChainSettings>>;
  /** Extra providers (or replacements), by id. */
  readonly registry?: Readonly<Record<string, RpcProvider>>;
  readonly transport?: Partial<TransportSettings>;
  readonly health?: Partial<HealthPolicy>;
  /** Where failovers and recoveries are reported (redacted); console.warn by default, null for none. */
  readonly logger?: RpcLogger | null;
  readonly now?: () => number;
  readonly sleep?: (ms: number) => Promise<void>;
  /** Builds an endpoint's own viem transport (tests swap it for a mock). Its retries must be off. */
  readonly transportFor?: (endpoint: Endpoint, settings: TransportSettings) => Transport;
}

/** viem's http/webSocket transport for an endpoint, with Aave's values and no retries of its own. */
export function defaultTransportFor(e: Endpoint, s: TransportSettings): Transport {
  if (e.kind === "http") return http(e.secretUrl(), { timeout: s.timeout, batch: s.batch, retryCount: 0, key: e.provider, name: e.provider });
  return webSocket(e.secretUrl(), { timeout: s.timeout, retryCount: 0, reconnect: s.wsReconnect, keepAlive: { interval: s.wsKeepAlive }, key: e.provider, name: e.provider });
}

interface Layer {
  readonly rpc: FailoverRpc;
  readonly transports: Map<Endpoint, ReturnType<Transport>>;
}

export class AvanaRPCManager {
  readonly redactor = new Redactor();
  readonly settings: TransportSettings;
  readonly policy: HealthPolicy;
  readonly #credentials: Credentials;
  readonly #order: readonly string[];
  readonly #chains: Readonly<Record<number, ChainSettings>>;
  readonly #registry: Readonly<Record<string, RpcProvider>>;
  readonly #logger: RpcLogger | null;
  readonly #now: () => number;
  readonly #sleep: (ms: number) => Promise<void>;
  readonly #transportFor: (endpoint: Endpoint, settings: TransportSettings) => Transport;
  readonly #layers = new Map<string, Layer>();
  readonly #clients = new Map<string, PublicClient>();
  readonly #sends = new Map<number, Map<Hex, SendRecord>>();

  constructor(options: AvanaRPCManagerOptions = {}) {
    this.#credentials = options.credentials ?? {};
    this.#registry = { ...PROVIDERS, ...options.registry };
    this.#order = options.providers ?? ["alchemy", "quicknode"];
    this.#chains = options.chains ?? {};
    this.settings = { ...AAVE_TRANSPORT_DEFAULTS, ...options.transport };
    this.policy = { ...DEFAULT_HEALTH_POLICY, ...options.health };
    this.#logger = options.logger === undefined ? { warn: (m) => console.warn(m) } : options.logger;
    this.#now = options.now ?? Date.now;
    this.#sleep = options.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.#transportFor = options.transportFor ?? defaultTransportFor;
    for (const p of Object.values(this.#registry)) for (const n of p.credentialNames) this.redactor.add(this.#credentials[n], n);
    for (const [id, s] of Object.entries(this.#chains)) {
      this.redactor.add(s.http, `RPC_${rpcChain(Number(id)).symbol}`);
      this.redactor.add(s.ws, `RPC_WS_${rpcChain(Number(id)).symbol}`);
    }
  }

  /** A manager configured by the environment (config.ts lists the variables). */
  static fromEnv(env: Readonly<Record<string, string | undefined>> = process.env, options: Omit<AvanaRPCManagerOptions, "credentials" | "providers" | "chains"> = {}): AvanaRPCManager {
    const c = configFromEnv(env);
    return new AvanaRPCManager({ ...options, credentials: c.credentials, providers: c.providers, chains: c.chains });
  }

  chain(chainId: number): RpcChain {
    return rpcChain(chainId);
  }

  /**
   * The chain's endpoints of `kind`, primary first: the explicit endpoint alone when one is set (RPC_<SYM>, as the
   * Aave toolbox's getExplicitRPC), else every configured provider serving the chain, in the chain's order.
   */
  endpoints(chainId: number, kind: EndpointKind = "http"): Endpoint[] {
    const c = rpcChain(chainId);
    const s = this.#chains[chainId] ?? {};
    const explicit = kind === "http" ? s.http : s.ws;
    if (explicit) return [new Endpoint("explicit", chainId, kind, explicit)];
    const out: Endpoint[] = [];
    for (const id of s.providers ?? this.#order) {
      const p = this.#registry[id];
      if (!p) throw new ProviderConfigError(`unknown RPC provider ${id}`);
      if (p.slug(chainId) === undefined || !configured(p, this.#credentials)) continue;
      const url = p.url(chainId, kind, this.#credentials);
      this.redactor.add(url, `${p.id.toUpperCase()}_${c.symbol}_${kind.toUpperCase()}_URL`);
      out.push(new Endpoint(p.id, chainId, kind, url));
    }
    if (out.length === 0) {
      throw new ProviderConfigError(
        `no RPC endpoint for chain ${chainId}: set ALCHEMY_API_KEY (and QUICKNODE_ENDPOINT_NAME with QUICKNODE_TOKEN for the backup), or RPC_${c.symbol}${kind === "ws" ? ` / RPC_WS_${c.symbol}` : ""}`,
      );
    }
    return out;
  }

  #layer(chainId: number, kind: EndpointKind): Layer {
    const key = `${chainId}:${kind}`;
    let layer = this.#layers.get(key);
    if (layer) return layer;
    const c = rpcChain(chainId);
    const s = this.#chains[chainId] ?? {};
    const health = new HealthTracker(this.endpoints(chainId, kind), this.policy, { maxLagBlocks: s.maxLagBlocks ?? c.maxLagBlocks, maxHeadAgeMs: s.maxHeadAgeMs ?? c.maxHeadAgeMs }, this.#now);
    const transports = new Map<Endpoint, ReturnType<Transport>>();
    const instance = (e: Endpoint) => {
      let t = transports.get(e);
      if (!t) {
        t = this.#transportFor(e, this.settings)({ chain: c.chain as Chain, retryCount: 0 });
        transports.set(e, t);
      }
      return t;
    };
    let sends = this.#sends.get(chainId);
    if (!sends) this.#sends.set(chainId, (sends = new Map()));
    const rpc = new FailoverRpc({
      chainId,
      health,
      settings: this.settings,
      redactor: this.redactor,
      log: (m) => this.#logger?.warn(this.redactor.text(`[avana-rpc] ${m}`)),
      sleep: this.#sleep,
      now: this.#now,
      requestOf: (e) => instance(e).request as unknown as RequestFn,
      sends,
    });
    layer = { rpc, transports };
    this.#layers.set(key, layer);
    // Instantiate eagerly so a WebSocket connects (and reconnects) on its own.
    for (const e of health.endpoints) instance(e);
    return layer;
  }

  /** The failover layer of the chain (health, probes, the send ledger). */
  failover(chainId: number, kind: EndpointKind = "http"): FailoverRpc {
    return this.#layer(chainId, kind).rpc;
  }

  /** A viem transport over the chain's endpoints with failover: for wallet clients and anything built on viem. */
  transport(chainId: number, kind: EndpointKind = "http"): Transport {
    const layer = this.#layer(chainId, kind);
    const subscribe =
      kind === "ws"
        ? (args: unknown) => {
            const t = layer.transports.get(layer.rpc.health.current()) as { value?: { subscribe?: (a: unknown) => Promise<unknown> } } | undefined;
            if (!t?.value?.subscribe) throw new Error("the WebSocket endpoint in use cannot subscribe");
            return t.value.subscribe(args);
          }
        : undefined;
    return failoverTransport(layer.rpc, kind, subscribe);
  }

  /** The chain's PublicClient over HTTP (Aave's getClient: multicall batching), one per chain. */
  getClient(chainId: number): PublicClient {
    return this.#client(chainId, "http");
  }

  /** The chain's PublicClient over WebSocket, one per chain: subscriptions, and requests with failover. */
  getWebSocketClient(chainId: number): PublicClient {
    return this.#client(chainId, "ws");
  }

  #client(chainId: number, kind: EndpointKind): PublicClient {
    const key = `${chainId}:${kind}`;
    let c = this.#clients.get(key);
    if (!c) {
      c = createPublicClient({ chain: rpcChain(chainId).chain, transport: this.transport(chainId, kind), batch: { multicall: this.settings.multicall } }) as PublicClient;
      this.#clients.set(key, c);
    }
    return c;
  }

  /** Probes every endpoint of the chain now and returns their health (no URL in it). */
  async probe(chainId: number, kind: EndpointKind = "http"): Promise<EndpointReport[]> {
    const layer = this.#layer(chainId, kind);
    await layer.rpc.probe();
    return layer.rpc.health.report();
  }

  /**
   * Probes the chain's endpoints and returns the one to use: the first in order that is in use after the probe. For a
   * child process (forge, cast) that takes one URL. Throws, redacted, when every endpoint failed its probe.
   */
  async selectHealthy(chainId: number, kind: EndpointKind = "http"): Promise<Endpoint> {
    const layer = this.#layer(chainId, kind);
    const results = await layer.rpc.probe();
    const e = layer.rpc.health.current();
    if (layer.rpc.health.isDown(e) && ![...results.values()].some((r) => r.ok)) {
      throw new Error(this.redactor.text(`chain ${chainId}: no RPC endpoint is healthy (${[...results].map(([x, r]) => `${x.provider} ${r.ok ? "stale or slow" : r.failure}`).join(", ")})`));
    }
    return e;
  }

  /** Takes `provider` out of use on the chain (a child process reported an infrastructure failure through it). */
  reportFailure(chainId: number, provider: string, failure: Parameters<HealthTracker["recordFailure"]>[1], kind: EndpointKind = "http"): void {
    const layer = this.#layer(chainId, kind);
    const e = layer.rpc.health.endpoints.find((x) => x.provider === provider);
    if (!e) return;
    for (let i = 0; i < this.policy.failoverAfter; i++) layer.rpc.health.recordFailure(e, failure);
  }

  health(chainId: number, kind: EndpointKind = "http"): EndpointReport[] {
    return this.#layer(chainId, kind).rpc.health.report();
  }

  /** `text` with every credential and authenticated URL replaced by its name. */
  redact(text: string): string {
    return this.redactor.text(text);
  }

  /** Closes the WebSocket connections. */
  async close(): Promise<void> {
    for (const layer of this.#layers.values()) {
      for (const t of layer.transports.values()) {
        const v = (t as { value?: { getRpcClient?: () => Promise<{ close(): void }> } }).value;
        if (v?.getRpcClient) (await v.getRpcClient().catch(() => undefined))?.close();
      }
    }
  }
}
