// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Mocked providers over one simulated chain: no network. Each mock answers from the shared chain state, or fails the
// way a provider fails (viem's own error classes, naming the endpoint's authenticated URL, so redaction is tested).

import { type Hex, HttpRequestError, RpcRequestError, TimeoutError, type Transport, custom, keccak256, parseTransaction, recoverTransactionAddress } from "viem";
import { AvanaRPCManager, type AvanaRPCManagerOptions, type Endpoint } from "../src/index.ts";

/** Fake credentials: the shape of real ones, valid nowhere. */
export const CREDENTIALS = {
  ALCHEMY_API_KEY: "alchemyTestKey0000000000000000000",
  QUICKNODE_ENDPOINT_NAME: "quiet-test-endpoint",
  QUICKNODE_TOKEN: "quicknodeTestToken000000000000000",
};

export type Behaviour = "ok" | "timeout" | "rate-limit" | "rate-limit-rpc" | "server" | "connection" | "malformed" | "revert" | "invalid-params" | "stale" | "wrong-chain";

export class Clock {
  t = 1_800_000_000_000;
  readonly sleeps: number[] = [];
  now = () => this.t;
  sleep = async (ms: number) => {
    this.sleeps.push(ms);
    this.t += ms;
  };
  advance(ms: number) {
    this.t += ms;
  }
}

/** The simulated chain every mock provider reads. */
export class MockChain {
  head = 5_000n;
  readonly txs = new Map<Hex, { from: Hex; nonce: number; mined: boolean }>();
  readonly mined = new Map<string, number>();
  readonly pending = new Map<string, number>();
  readonly id: number;
  readonly clock: Clock;
  constructor(id: number, clock: Clock) {
    this.id = id;
    this.clock = clock;
  }
  async accept(raw: Hex): Promise<Hex> {
    const hash = keccak256(raw);
    const from = (await recoverTransactionAddress({ serializedTransaction: raw as never })).toLowerCase();
    const nonce = parseTransaction(raw).nonce ?? 0;
    if (this.txs.has(hash)) throw new RpcRequestError({ body: {}, url: "", error: { code: -32000, message: "already known" } });
    if (nonce < (this.pending.get(from) ?? 0)) throw new RpcRequestError({ body: {}, url: "", error: { code: -32000, message: "nonce too low" } });
    this.txs.set(hash, { from: from as Hex, nonce, mined: false });
    this.pending.set(from, nonce + 1);
    return hash;
  }
}

export class MockProvider {
  readonly calls: { method: string; params: unknown }[] = [];
  /** What the next requests do: one behaviour, or one per method. */
  behaviour: Behaviour | ((method: string) => Behaviour) = "ok";
  /** A send that the provider takes in and then fails (the outcome is unknown to the caller). */
  acceptThenFail: Behaviour | undefined;
  retryAfter: string | undefined;
  lag = 0n;
  readonly name: string;
  readonly chain: MockChain;
  constructor(name: string, chain: MockChain) {
    this.name = name;
    this.chain = chain;
  }

  count(method: string): number {
    return this.calls.filter((c) => c.method === method).length;
  }

  transport(e: Endpoint): Transport {
    return custom({ request: (args: { method: string; params?: unknown }) => this.request(e, args) }, { retryCount: 0, key: this.name });
  }

  async request(e: Endpoint, { method, params }: { method: string; params?: unknown }): Promise<unknown> {
    this.calls.push({ method, params });
    const url = e.secretUrl();
    const body = { method, params };
    const b = typeof this.behaviour === "function" ? this.behaviour(method) : this.behaviour;
    const fail = (x: Behaviour): never => {
      if (x === "timeout") throw new TimeoutError({ body, url });
      if (x === "rate-limit") {
        const headers = new Headers(this.retryAfter ? { "Retry-After": this.retryAfter } : {});
        throw new HttpRequestError({ body, url, status: 429, headers, details: "Too Many Requests" });
      }
      if (x === "rate-limit-rpc") throw new RpcRequestError({ body, url, error: { code: -32005, message: "Your app has exceeded its compute units per second capacity" } });
      if (x === "server") throw new HttpRequestError({ body, url, status: 503, details: "Service Unavailable" });
      if (x === "connection") throw new HttpRequestError({ body, url, cause: new TypeError("fetch failed") });
      if (x === "revert") throw new RpcRequestError({ body, url, error: { code: 3, message: "execution reverted: Paused()", data: "0x9e87fac8" } });
      if (x === "invalid-params") throw new RpcRequestError({ body, url, error: { code: -32602, message: "invalid argument 0: hex string without 0x prefix" } });
      throw new Error(`no failure ${x}`);
    };
    if (method === "eth_sendRawTransaction" && this.acceptThenFail) {
      await this.chain.accept((params as Hex[])[0]!);
      fail(this.acceptThenFail);
    }
    if (b !== "ok" && b !== "malformed" && b !== "stale" && b !== "wrong-chain") fail(b);
    const c = this.chain;
    const head = b === "stale" ? c.head - 100n : c.head - this.lag;
    switch (method) {
      case "eth_chainId":
        return `0x${(b === "wrong-chain" ? 1 : c.id).toString(16)}`;
      case "eth_blockNumber":
        return b === "malformed" ? "<html>bad gateway</html>" : `0x${head.toString(16)}`;
      case "eth_getBlockByNumber": {
        const ts = BigInt(Math.floor(c.clock.now() / 1000)) - (b === "stale" ? 3_600n : 0n);
        return b === "malformed" ? "<html>" : { number: `0x${head.toString(16)}`, timestamp: `0x${ts.toString(16)}`, hash: `0x${"ab".repeat(32)}` };
      }
      case "eth_call":
        return "0x" + "00".repeat(31) + "2a";
      case "eth_sendRawTransaction":
        return c.accept((params as Hex[])[0]!);
      case "eth_getTransactionByHash": {
        const t = c.txs.get((params as Hex[])[0]!);
        return t ? { hash: (params as Hex[])[0], nonce: `0x${t.nonce.toString(16)}` } : null;
      }
      case "eth_getTransactionReceipt": {
        const t = c.txs.get((params as Hex[])[0]!);
        return t?.mined ? { status: "0x1" } : null;
      }
      case "eth_getTransactionCount": {
        const [addr, tag] = params as [string, string];
        const m = tag === "pending" ? c.pending : c.mined;
        return `0x${(m.get(addr.toLowerCase()) ?? 0).toString(16)}`;
      }
      default:
        throw new RpcRequestError({ body, url, error: { code: -32601, message: `the method ${method} does not exist` } });
    }
  }
}

/** A manager over the two mocks (any endpoint other than Alchemy's and QuickNode's is refused). */
export function mockManager(
  chainId = 11_155_111,
  options: Partial<AvanaRPCManagerOptions> = {},
): { manager: AvanaRPCManager; alchemy: MockProvider; quicknode: MockProvider; chain: MockChain; clock: Clock; logs: string[] } {
  const clock = new Clock();
  const chain = new MockChain(chainId, clock);
  const alchemy = new MockProvider("alchemy", chain);
  const quicknode = new MockProvider("quicknode", chain);
  const logs: string[] = [];
  const manager = new AvanaRPCManager({
    credentials: CREDENTIALS,
    now: clock.now,
    sleep: clock.sleep,
    logger: { warn: (m) => logs.push(m) },
    transportFor: (e) => {
      if (e.provider === "alchemy") return alchemy.transport(e);
      if (e.provider === "quicknode") return quicknode.transport(e);
      throw new Error(`no mock for ${e.provider}`);
    },
    ...options,
  });
  return { manager, alchemy, quicknode, chain, clock, logs };
}

/** Every value a test must never find in an error or a log. */
export const SECRETS = Object.values(CREDENTIALS);
