// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The RPC manager against mocked providers: no network. Tests 4 and 9 also run viem's real HTTP transport against a
// local HTTP server, and test 10 its real WebSocket transport against a local WebSocket server (127.0.0.1 only).

import { type AddressInfo } from "node:net";
import { type IncomingMessage, type Server, type ServerResponse, createServer } from "node:http";
import { http, type Hex, RpcRequestError } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { afterEach, describe, expect, it } from "vitest";
import { WebSocketServer } from "ws";
import {
  AvanaRPCManager,
  InvalidRpcResponseError,
  NonceConsumedError,
  RpcUnavailableError,
  UnsupportedChainError,
  alchemy as alchemyProvider,
  classifyError,
  classifyText,
  configFromEnv,
  quicknode as quicknodeProvider,
} from "../src/index.ts";
import { CREDENTIALS, SECRETS, mockManager } from "./mock.ts";

const SEPOLIA = 11_155_111;
const CHAINS = [1, 11_155_111, 8_453, 84_532];

const noSecret = (text: string) => {
  for (const s of SECRETS) expect(text).not.toContain(s);
};

const servers: { close(cb?: () => void): void }[] = [];
afterEach(async () => {
  await Promise.all(servers.splice(0).map((s) => new Promise<void>((r) => s.close(() => r()))));
});

/** A local HTTP server answering with `handler` (or never, when it returns undefined). */
async function localHttp(handler: (body: string, res: ServerResponse) => void): Promise<string> {
  const server: Server = createServer((req: IncomingMessage, res) => {
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", () => handler(body, res));
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
  servers.push({ close: (cb) => (server.closeAllConnections(), server.close(cb)) });
  return `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
}

describe("AvanaRPCManager", () => {
  it("1. selects Alchemy as the primary provider", async () => {
    const { manager, alchemy, quicknode } = mockManager();
    const [primary] = manager.endpoints(SEPOLIA);
    expect(primary!.provider).toBe("alchemy");
    const url = new URL(primary!.secretUrl());
    expect(url.protocol).toBe("https:");
    expect(url.hostname.split(".")[0]).toBe(alchemyProvider.slug(SEPOLIA));
    expect(url.pathname).toBe(`/v2/${CREDENTIALS.ALCHEMY_API_KEY}`);
    expect(await manager.getClient(SEPOLIA).getBlockNumber({ cacheTime: 0 })).toBe(5_000n);
    expect(alchemy.count("eth_blockNumber")).toBe(1);
    expect(quicknode.calls).toHaveLength(0);
    // An endpoint never prints its URL.
    expect(String(primary)).toBe(`alchemy:${SEPOLIA}:http`);
    expect(JSON.stringify({ primary })).not.toContain(CREDENTIALS.ALCHEMY_API_KEY);
  });

  it("2. configures QuickNode as the secondary provider", () => {
    const { manager } = mockManager();
    const eps = manager.endpoints(SEPOLIA);
    expect(eps.map((e) => e.provider)).toEqual(["alchemy", "quicknode"]);
    const url = new URL(eps[1]!.secretUrl());
    expect(url.hostname.split(".").slice(0, 2)).toEqual([CREDENTIALS.QUICKNODE_ENDPOINT_NAME, quicknodeProvider.slug(SEPOLIA)]);
    expect(url.pathname).toBe(`/${CREDENTIALS.QUICKNODE_TOKEN}`);
    // Ethereum mainnet's QuickNode endpoint has no network slug (as in the Aave toolbox).
    expect(new URL(manager.endpoints(1)[1]!.secretUrl()).hostname.split(".")).toHaveLength(3);
    // WebSocket endpoints: same hosts, wss.
    expect(manager.endpoints(SEPOLIA, "ws").map((e) => new URL(e.secretUrl()).protocol)).toEqual(["wss:", "wss:"]);
    // Only the providers whose credentials are all set are used; the order is configurable per chain.
    expect(new AvanaRPCManager({ credentials: { ALCHEMY_API_KEY: CREDENTIALS.ALCHEMY_API_KEY, QUICKNODE_TOKEN: CREDENTIALS.QUICKNODE_TOKEN } }).endpoints(SEPOLIA).map((e) => e.provider)).toEqual(["alchemy"]);
    expect(new AvanaRPCManager({ credentials: { QUICKNODE_ENDPOINT_NAME: CREDENTIALS.QUICKNODE_ENDPOINT_NAME, QUICKNODE_TOKEN: CREDENTIALS.QUICKNODE_TOKEN } }).endpoints(SEPOLIA)[0]!.provider).toBe("quicknode");
    const env = configFromEnv({ ...CREDENTIALS, AVANA_RPC_PROVIDERS_BASE: "quicknode,alchemy" });
    const m = new AvanaRPCManager({ credentials: env.credentials, providers: env.providers, chains: env.chains });
    expect(m.endpoints(8_453).map((e) => e.provider)).toEqual(["quicknode", "alchemy"]);
    expect(m.endpoints(SEPOLIA).map((e) => e.provider)).toEqual(["alchemy", "quicknode"]);
    // The explicit override is the chain's only endpoint (the escape hatch), and is redacted like a credential.
    const o = AvanaRPCManager.fromEnv({ ...CREDENTIALS, RPC_SEPOLIA: "https://override.example.invalid/fixture-not-real" }, { logger: null });
    expect(o.endpoints(SEPOLIA).map((e) => e.provider)).toEqual(["explicit"]);
    expect(o.endpoints(84_532).map((e) => e.provider)).toEqual(["alchemy", "quicknode"]);
    expect(o.redact("connect https://override.example.invalid/fixture-not-real refused")).toBe("connect <RPC_SEPOLIA> refused");
    expect(() => new AvanaRPCManager({}).endpoints(SEPOLIA)).toThrow(/ALCHEMY_API_KEY/);
    expect(() => configFromEnv({ AVANA_RPC_PROVIDERS: "alchemy,nobody" })).toThrow(/unknown RPC provider nobody/);
  });

  it("3. resolves each chain ID to its chain and endpoints", async () => {
    for (const id of CHAINS) {
      const { manager } = mockManager(id);
      const client = manager.getClient(id);
      expect(client.chain!.id).toBe(id);
      expect(await client.getChainId()).toBe(id);
      for (const e of manager.endpoints(id)) {
        const slug = (e.provider === "alchemy" ? alchemyProvider : quicknodeProvider).slug(id);
        if (slug) expect(new URL(e.secretUrl()).hostname).toContain(`${slug}.`);
      }
      expect(manager.getClient(id)).toBe(client);
    }
    expect(() => mockManager().manager.getClient(10)).toThrow(UnsupportedChainError);
    // An endpoint serving another chain is taken out of use by the probe.
    const { manager, alchemy } = mockManager();
    alchemy.behaviour = "wrong-chain";
    expect((await manager.selectHealthy(SEPOLIA)).provider).toBe("quicknode");
    expect(manager.health(SEPOLIA)[0]).toMatchObject({ provider: "alchemy", down: true, lastFailure: "malformed" });
  });

  it("4. fails over when the primary times out", async () => {
    // Alchemy: viem's real HTTP transport to a local server that never answers, with a 200 ms timeout.
    const silent = await localHttp(() => undefined);
    const { quicknode } = mockManager();
    const logs: string[] = [];
    const manager = new AvanaRPCManager({
      credentials: CREDENTIALS,
      transport: { timeout: 200 },
      logger: { warn: (m) => logs.push(m) },
      transportFor: (e, s) => (e.provider === "alchemy" ? http(silent, { timeout: s.timeout, retryCount: 0 }) : quicknode.transport(e)),
    });
    expect(await manager.getClient(SEPOLIA).getBlockNumber({ cacheTime: 0 })).toBe(5_000n);
    expect(manager.health(SEPOLIA)[0]).toMatchObject({ provider: "alchemy", down: true, lastFailure: "timeout" });
    expect(manager.health(SEPOLIA)[1]).toMatchObject({ provider: "quicknode", inUse: true });
    expect(logs.join("\n")).toMatch(/alchemy timeout on eth_blockNumber .*alchemy out of use, quicknode serves/);
    // The mocked form of the same failure (viem's TimeoutError) is classified the same way.
    const m = mockManager();
    m.alchemy.behaviour = "timeout";
    expect(await m.manager.getClient(SEPOLIA).getBlockNumber({ cacheTime: 0 })).toBe(5_000n);
    expect(m.quicknode.count("eth_blockNumber")).toBe(1);
    expect(m.clock.sleeps).toEqual([]);
  });

  it("5. fails over at once when the primary is rate-limited", async () => {
    for (const b of ["rate-limit", "rate-limit-rpc"] as const) {
      const { manager, alchemy, quicknode, clock, logs } = mockManager();
      alchemy.behaviour = b;
      alchemy.retryAfter = "30";
      expect(await manager.getClient(SEPOLIA).getBlockNumber({ cacheTime: 0 })).toBe(5_000n);
      expect(alchemy.count("eth_blockNumber")).toBe(1);
      expect(quicknode.count("eth_blockNumber")).toBe(1);
      // Moving to a provider in use does not wait (not even the Retry-After the rate-limited one sent).
      expect(clock.sleeps).toEqual([]);
      expect(manager.health(SEPOLIA)[0]!.lastFailure).toBe("rate-limit");
      for (const l of logs) noSecret(l);
    }
  });

  it("6. falls back automatically, and never on a revert or an invalid request", async () => {
    const { manager, alchemy, quicknode } = mockManager();
    const client = manager.getClient(SEPOLIA);
    alchemy.behaviour = "server";
    expect(await client.getBlockNumber({ cacheTime: 0 })).toBe(5_000n);
    // Alchemy is out of use: the next requests go to QuickNode without trying Alchemy first.
    alchemy.behaviour = "ok";
    await client.getBlockNumber({ cacheTime: 0 });
    await client.getBlockNumber({ cacheTime: 0 });
    expect(alchemy.count("eth_blockNumber")).toBe(1);
    expect(quicknode.count("eth_blockNumber")).toBe(3);
    // A revert, and an invalid request, are returned at once from the provider that answered: no retry, no failover.
    const m = mockManager();
    for (const b of ["revert", "invalid-params"] as const) {
      m.alchemy.behaviour = b;
      const err = await m.manager.getClient(SEPOLIA).request({ method: "eth_call", params: [{ to: "0x0000000000000000000000000000000000000001", data: "0x" }, "latest"] }).catch((e: unknown) => e);
      expect(classifyError(err)).toBeUndefined();
      noSecret(String((err as Error).message));
    }
    expect(m.alchemy.count("eth_call")).toBe(2);
    expect(m.quicknode.calls).toHaveLength(0);
    expect(m.manager.health(SEPOLIA)[0]).toMatchObject({ down: false, failures: 0 });
    expect(m.clock.sleeps).toEqual([]);
  });

  it("7. returns to Alchemy once it is healthy again, without flapping", async () => {
    const { manager, alchemy, quicknode, clock, logs } = mockManager();
    const client = manager.getClient(SEPOLIA);
    const rpc = manager.failover(SEPOLIA);
    const served = async () => {
      const q = quicknode.count("eth_blockNumber");
      await client.getBlockNumber({ cacheTime: 0 });
      await rpc.idle();
      return quicknode.count("eth_blockNumber") > q ? "quicknode" : "alchemy";
    };
    alchemy.behaviour = "server";
    expect(await served()).toBe("quicknode");
    alchemy.behaviour = "ok";
    // Inside the 30 s cool-down Alchemy is not tried, even by a freshness probe counting towards recovery.
    clock.advance(10_000);
    expect(await served()).toBe("quicknode");
    clock.advance(10_000);
    expect(await served()).toBe("quicknode");
    // After the cool-down, three good probes 10 s apart are needed; a bad one in between starts over.
    clock.advance(10_000);
    expect(await served()).toBe("quicknode"); // +30 s: good probe 1
    clock.advance(10_000);
    alchemy.behaviour = "server";
    expect(await served()).toBe("quicknode"); // +40 s: the probe fails, the count and the cool-down restart
    alchemy.behaviour = "ok";
    clock.advance(10_000);
    expect(await served()).toBe("quicknode"); // +10 s after it: inside the cool-down
    clock.advance(10_000);
    expect(await served()).toBe("quicknode"); // +20 s
    clock.advance(10_000);
    expect(await served()).toBe("quicknode"); // +30 s: good probe 1
    clock.advance(10_000);
    expect(await served()).toBe("quicknode"); // good probe 2
    clock.advance(10_000);
    expect(await served()).toBe("quicknode"); // good probe 3 runs beside this request: Alchemy back in use after it
    expect(await served()).toBe("alchemy");
    expect(manager.health(SEPOLIA)[0]).toMatchObject({ provider: "alchemy", inUse: true, down: false });
    expect(logs.some((l) => /alchemy healthy again; alchemy serves/.test(l))).toBe(true);
    expect(quicknode.count("eth_blockNumber")).toBeGreaterThan(5);
    // A stale head (behind the best head, or too old) takes the provider out of use on the next probe.
    const s = mockManager();
    s.alchemy.behaviour = (method) => (method === "eth_getBlockByNumber" ? "stale" : "ok");
    expect((await s.manager.selectHealthy(SEPOLIA)).provider).toBe("quicknode");
    expect(s.manager.health(SEPOLIA)[0]).toMatchObject({ down: true, lastFailure: "stale" });
    const lagging = mockManager();
    lagging.alchemy.lag = 10n;
    expect((await lagging.manager.selectHealthy(SEPOLIA)).provider).toBe("quicknode");
  });

  it("8. reports both providers down, redacted", async () => {
    const { manager, alchemy, quicknode, logs } = mockManager();
    alchemy.behaviour = "server";
    quicknode.behaviour = "connection";
    const err = (await manager.getClient(SEPOLIA).getBlockNumber({ cacheTime: 0 }).catch((e: unknown) => e)) as Error;
    expect(err).toBeInstanceOf(Error);
    let unavailable: unknown = err;
    while (unavailable && !(unavailable instanceof RpcUnavailableError)) unavailable = (unavailable as { cause?: unknown }).cause;
    expect(unavailable).toBeInstanceOf(RpcUnavailableError);
    expect((unavailable as RpcUnavailableError).attempts).toHaveLength(6);
    expect((unavailable as RpcUnavailableError).attempts.map((a) => a.provider)).toEqual(["alchemy", "quicknode", "alchemy", "quicknode", "alchemy", "quicknode"]);
    noSecret(`${err.message}\n${err.stack}\n${(unavailable as Error).message}\n${String(((unavailable as Error).cause as Error).message)}`);
    for (const l of logs) noSecret(l);
    await expect(manager.selectHealthy(SEPOLIA)).rejects.toThrow(/no RPC endpoint is healthy \(alchemy server, quicknode connection\)/);
  });

  it("9. treats an invalid RPC response as a provider failure", async () => {
    const { manager, alchemy, quicknode } = mockManager();
    alchemy.behaviour = "malformed";
    expect(await manager.getClient(SEPOLIA).getBlockNumber({ cacheTime: 0 })).toBe(5_000n);
    expect(manager.health(SEPOLIA)[0]).toMatchObject({ down: true, lastFailure: "malformed" });
    expect(quicknode.count("eth_blockNumber")).toBe(1);
    expect(classifyError(new InvalidRpcResponseError("eth_blockNumber", "x"))).toBe("malformed");
    // viem's real HTTP transport receiving an HTML page with status 200 (a proxy's error page).
    const html = await localHttp((_, res) => res.writeHead(200, { "content-type": "text/html" }).end("<html>upstream error</html>"));
    const q = mockManager();
    const manager2 = new AvanaRPCManager({
      credentials: CREDENTIALS,
      logger: null,
      transportFor: (e, s) => (e.provider === "alchemy" ? http(html, { timeout: s.timeout, retryCount: 0 }) : q.quicknode.transport(e)),
    });
    expect(await manager2.getClient(SEPOLIA).getBlockNumber({ cacheTime: 0 })).toBe(5_000n);
    expect(manager2.health(SEPOLIA)[0]).toMatchObject({ down: true, lastFailure: "malformed" });
  });

  it("10. reconnects a dropped WebSocket", async () => {
    const wss = new WebSocketServer({ port: 0, host: "127.0.0.1" });
    servers.push(wss);
    await new Promise<void>((r) => wss.on("listening", () => r()));
    let connections = 0;
    let head = 7;
    wss.on("connection", (socket) => {
      connections++;
      socket.on("message", (data) => {
        const req = JSON.parse(String(data)) as { id: number; method: string };
        const result = req.method === "eth_chainId" ? `0x${SEPOLIA.toString(16)}` : `0x${(head++).toString(16)}`;
        socket.send(JSON.stringify({ jsonrpc: "2.0", id: req.id, result }));
      });
    });
    const url = `ws://127.0.0.1:${(wss.address() as AddressInfo).port}`;
    const manager = new AvanaRPCManager({ chains: { [SEPOLIA]: { ws: url } }, transport: { retryDelay: 50, wsReconnect: { attempts: 5, delay: 50 } }, logger: null });
    expect(manager.endpoints(SEPOLIA, "ws").map((e) => e.provider)).toEqual(["explicit"]);
    const client = manager.getWebSocketClient(SEPOLIA);
    expect(await client.getBlockNumber({ cacheTime: 0 })).toBe(7n);
    for (const s of wss.clients) s.terminate();
    await new Promise((r) => setTimeout(r, 20));
    expect(await client.getBlockNumber({ cacheTime: 0 })).toBe(8n);
    expect(connections).toBe(2);
    await manager.close();
  });

  it("11. sends a transaction once, never duplicated across providers", async () => {
    const account = privateKeyToAccount(generatePrivateKey());
    const sign = (nonce: number) =>
      account.signTransaction({ chainId: SEPOLIA, nonce, to: "0x0000000000000000000000000000000000000001", value: 1n, gas: 21_000n, maxFeePerGas: 2n, maxPriorityFeePerGas: 1n });
    // a) Alchemy takes the transaction in, then times out: QuickNode finds it by hash, nothing is sent again.
    {
      const { manager, alchemy, quicknode, chain, logs } = mockManager();
      const raw = await sign(0);
      alchemy.acceptThenFail = "timeout";
      const hash = await manager.getClient(SEPOLIA).sendRawTransaction({ serializedTransaction: raw });
      expect(chain.txs.size).toBe(1);
      expect(chain.txs.has(hash)).toBe(true);
      expect(alchemy.count("eth_sendRawTransaction")).toBe(1);
      expect(quicknode.count("eth_sendRawTransaction")).toBe(0);
      expect(quicknode.count("eth_getTransactionByHash")).toBe(1);
      expect(logs.join("\n")).toContain(`transaction ${hash} found on quicknode; not sent again`);
      // b) The caller sends the same bytes again: answered from the ledger, no provider is asked.
      const before = alchemy.calls.length + quicknode.calls.length;
      expect(await manager.getClient(SEPOLIA).sendRawTransaction({ serializedTransaction: raw })).toBe(hash);
      expect(alchemy.calls.length + quicknode.calls.length).toBe(before);
    }
    // c) Alchemy refuses the connection before taking it in: QuickNode finds neither the hash nor a used nonce, and
    //    sends the same signed bytes (the same hash: it can only ever be mined once).
    {
      const { manager, alchemy, quicknode, chain } = mockManager();
      const raw = await sign(0);
      alchemy.behaviour = "connection";
      const hash = await manager.getClient(SEPOLIA).sendRawTransaction({ serializedTransaction: raw });
      expect(quicknode.count("eth_getTransactionByHash")).toBe(1);
      expect(quicknode.count("eth_getTransactionCount")).toBe(2);
      expect(quicknode.count("eth_sendRawTransaction")).toBe(1);
      expect((quicknode.calls.find((c) => c.method === "eth_sendRawTransaction")!.params as Hex[])[0]).toBe(raw);
      expect([...chain.txs.keys()]).toEqual([hash]);
    }
    // d) The nonce was meanwhile used by another transaction: nothing is sent again.
    {
      const { manager, alchemy, quicknode, chain } = mockManager();
      const raw = await sign(0);
      alchemy.behaviour = "server";
      chain.mined.set(account.address.toLowerCase(), 1);
      await expect(manager.getClient(SEPOLIA).sendRawTransaction({ serializedTransaction: raw })).rejects.toSatisfy((e: unknown) => {
        for (let x = e; x; x = (x as { cause?: unknown }).cause) if (x instanceof NonceConsumedError) return true;
        return false;
      });
      expect(quicknode.count("eth_sendRawTransaction")).toBe(0);
      expect(chain.txs.size).toBe(0);
    }
    // e) A refusal by the node (nonce too low) is returned at once: no lookup, no other provider.
    {
      const { manager, alchemy, quicknode, chain } = mockManager();
      chain.pending.set(account.address.toLowerCase(), 3);
      await expect(manager.getClient(SEPOLIA).sendRawTransaction({ serializedTransaction: await sign(0) })).rejects.toThrow(/nonce too low/);
      expect(alchemy.count("eth_sendRawTransaction")).toBe(1);
      expect(quicknode.calls).toHaveLength(0);
    }
  });

  it("12. retries as Aave's clients do: 5 retries, 500 ms exponential backoff, only infrastructure failures", async () => {
    // One provider failing: 1 attempt + 5 retries, waiting 500, 1000, 2000, 4000, 8000 ms (viem's backoff formula).
    const { manager, alchemy, clock } = mockManager(SEPOLIA, { credentials: { ALCHEMY_API_KEY: CREDENTIALS.ALCHEMY_API_KEY } });
    alchemy.behaviour = "server";
    await expect(manager.getClient(SEPOLIA).getBlockNumber({ cacheTime: 0 })).rejects.toThrow(/failed on every provider after 6 attempts/);
    expect(alchemy.count("eth_blockNumber")).toBe(6);
    expect(clock.sleeps).toEqual([500, 1_000, 2_000, 4_000, 8_000]);
    // A Retry-After header is honoured when the request stays on the same provider.
    const r = mockManager(SEPOLIA, { credentials: { ALCHEMY_API_KEY: CREDENTIALS.ALCHEMY_API_KEY } });
    r.alchemy.retryAfter = "2";
    let n = 0;
    r.alchemy.behaviour = () => (n++ < 1 ? "rate-limit" : "ok");
    expect(await r.manager.getClient(SEPOLIA).getBlockNumber({ cacheTime: 0 })).toBe(5_000n);
    expect(r.clock.sleeps).toEqual([2_000]);
    // Two providers: still 6 attempts in all; the first move to the backup does not wait, the rest back off.
    const b = mockManager();
    b.alchemy.behaviour = "server";
    b.quicknode.behaviour = "server";
    await expect(b.manager.getClient(SEPOLIA).getBlockNumber({ cacheTime: 0 })).rejects.toThrow(/after 6 attempts/);
    expect(b.alchemy.count("eth_blockNumber") + b.quicknode.count("eth_blockNumber")).toBe(6);
    expect(b.clock.sleeps).toEqual([1_000, 2_000, 4_000, 8_000]);
    // A revert: one attempt, no wait. The Aave values are the defaults.
    const v = mockManager();
    v.alchemy.behaviour = "revert";
    await expect(v.manager.getClient(SEPOLIA).request({ method: "eth_call", params: [{ to: "0x0000000000000000000000000000000000000001", data: "0x" }, "latest"] })).rejects.toThrow(/execution reverted/);
    expect(v.alchemy.count("eth_call")).toBe(1);
    expect(v.clock.sleeps).toEqual([]);
    expect(v.manager.settings).toMatchObject({ timeout: 30_000, batch: true, retryCount: 5, retryDelay: 500, multicall: true });
  });
});

describe("failure classification of tool output (forge, cast)", () => {
  it("tells infrastructure failures from reverts", () => {
    expect(classifyText("Error: error sending request for url (<AVANA_RPC_URL>): operation timed out")).toBe("timeout");
    expect(classifyText("server returned an error response: error code 429: Your app has exceeded its compute units per second capacity")).toBe("rate-limit");
    expect(classifyText("HTTP error 503 with body: Service Unavailable")).toBe("server");
    expect(classifyText("Error: tcp connect error: Connection refused (os error 10061)")).toBe("connection");
    expect(classifyText("Error: script failed: execution reverted: Paused()")).toBeUndefined();
    expect(classifyText("Error: EOA nonce changed unexpectedly while sending transactions. Expected 4 got 5")).toBeUndefined();
    expect(classifyText("compilation failed")).toBeUndefined();
  });
});

describe("a revert never triggers failover", () => {
  it("classifies forge's revert output and viem's execution-reverted errors as not an RPC failure", async () => {
    const forge = [
      "Error: script failed: execution reverted: Paused()",
      "Error: Simulated execution failed.\nError: script failed: custom error 0x9e87fac8",
      "Error: server returned an error response: error code 3: execution reverted: TimelockTimeout(), data: \"0x2a1c4f9e\"",
      // A revert reason that names a timeout or a rate limit is still a revert.
      "Error: Failed to send transaction\nContext:\n- server returned an error response: error code 3: execution reverted: RateLimited(), data: \"0x\"",
      "Error: Transaction Failure: 0x8f3c Reverted: operation timed out waiting for the price",
    ];
    for (const out of forge) expect(classifyText(out)).toBeUndefined();
    for (const error of [
      { code: 3, message: "execution reverted: Paused()", data: "0x9e87fac8" },
      { code: -32000, message: "execution reverted" },
      { code: -32603, message: "execution reverted: request timed out" },
    ]) {
      const e = new RpcRequestError({ body: {}, url: "", error });
      expect(classifyError(e)).toBeUndefined();
    }
    // Through the manager: a revert from the primary is returned once, with no failover and no change of provider.
    const { manager, alchemy, quicknode } = mockManager();
    alchemy.behaviour = "revert";
    await expect(manager.getClient(SEPOLIA).request({ method: "eth_call", params: [{ to: "0x0000000000000000000000000000000000000001", data: "0x" }, "latest"] })).rejects.toThrow(/execution reverted/);
    expect(quicknode.calls).toHaveLength(0);
    expect(manager.health(SEPOLIA)[0]).toMatchObject({ provider: "alchemy", inUse: true, down: false });
  });
});

describe("provider URL templates", () => {
  it("hold only public host patterns: every credential comes from the caller", () => {
    for (const p of [alchemyProvider, quicknodeProvider]) {
      for (const id of CHAINS) {
        for (const kind of ["http", "ws"] as const) {
          let rest = p.url(id, kind, CREDENTIALS);
          for (const s of SECRETS) rest = rest.split(s).join("");
          // What is left is scheme, slug, provider host and path separators: no key- or token-like run.
          expect(rest).not.toMatch(/[A-Za-z0-9_-]{24,}/);
          expect(rest).toMatch(/^(https|wss):\/\/[a-z0-9.-]*\.(g\.alchemy\.com\/v2\/|quiknode\.pro\/)$/);
        }
      }
      // With no credentials there is no URL at all.
      expect(() => p.url(SEPOLIA, "http", {})).toThrow(/is not set/);
    }
  });
});
