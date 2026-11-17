// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The test-network app's plan and RPC proxy, offline: every service's environment from fixture manifests shaped like
// the test networks' (fixtures/<network>/), the outputs check, the private config, the secrets file of the deploying
// checkout, the redaction, and the proxy forwarding JSON-RPC and a WebSocket to a local stand-in upstream without ever
// writing its URL.
// Run: node --test script/testnet/app/plan.test.ts (from contracts/)

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createCipheriv, createHash, randomBytes, scryptSync } from "node:crypto";
import { cpSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { type AddressInfo, createServer as createNetServer } from "node:net";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { readSecretsFile } from "../../local/lib/secrets.ts";
import { deploymentRowFrom } from "../../local/lib/services.ts";
import { corsHeaders, upgradeRequest, wsUpstreamOf } from "../rpc-proxy.ts";
import {
  type Plan,
  APP_CHAINS,
  NETWORK_LABEL,
  appPorts,
  checkOutputs,
  convexVars,
  faucetEnv,
  faucetSignerOf,
  indexerEnv,
  keeperEnv,
  monitorEnv,
  parseConfigFile,
  proxyEnv,
  redact,
  selectChains,
  webappEnv,
} from "./plan.ts";

const FIXTURES = fileURLToPath(new URL("./fixtures", import.meta.url));
const PROXY = fileURLToPath(new URL("../rpc-proxy.ts", import.meta.url));
/** A stand-in for a provider URL with its key: it must appear in no service's environment and no log line. */
const UPSTREAM = "https://eth-sepolia.example.invalid/v2/fixture-key-not-real";

const secrets = {
  exportSecret: "export-secret-value",
  monitorStatusToken: "monitor-token-value",
  keeperTokens: { sepolia: "keeper-token-sepolia", baseSepolia: "keeper-token-base-sepolia" },
  sessionSecret: "session-secret-value",
  rateLimitSecret: "rate-limit-secret-value",
  siweJwk: '{"kty":"RSA","kid":"fixture"}',
};
const plan = (chains = selectChains(undefined)): Plan => ({ chains, ports: appPorts({}), deployments: FIXTURES, run: "/run/testnet-app", secrets });
const tlsFiles = { cert: "/tls/cert.pem", key: "/tls/key.pem" };

test("--chains picks the test networks by name or chain ID, in a fixed order, and refuses any other", () => {
  assert.deepEqual(selectChains(undefined).map((c) => c.chainId), [11155111, 84532]);
  assert.deepEqual(selectChains("base-sepolia,sepolia").map((c) => c.network), ["sepolia", "base-sepolia"]);
  assert.deepEqual(selectChains("84532").map((c) => c.network), ["base-sepolia"]);
  assert.throws(() => selectChains("ethereum"), /no test network ethereum/);
  assert.throws(() => selectChains(","), /names no chain/);
});

test("the app's ports are none of the local stack's, move one at a time and never collide", () => {
  const p = appPorts({});
  const local = [8545, 8546, 8549, 8550, 8559, 8560, 42070, 42080, 3000, 9464, 9465, 9470, 8788];
  for (const port of [p.indexer, p.content, p.keeperMetrics, p.keeperKill, p.monitor, p.faucet, p.webapp, ...Object.values(p.proxy)]) assert.ok(!local.includes(port), `port ${port}`);
  assert.equal(appPorts({ APP_PORT_WEBAPP: "3200" }).webapp, 3200);
  assert.throws(() => appPorts({ APP_PORT_FAUCET: String(p.indexer) }), /one port/);
  assert.throws(() => appPorts({ APP_PORT_INDEXER: "80" }), /port number/);
});

test("the deploy outputs are served only when each manifest is the network's, with its world file and no rehearsal mark", () => {
  assert.deepEqual(checkOutputs(FIXTURES, APP_CHAINS), []);
  const dir = mkdtempSync(join(tmpdir(), "testnet-app-"));
  cpSync(FIXTURES, dir, { recursive: true });
  writeFileSync(join(dir, "sepolia", ".rehearsal"), "");
  const m = JSON.parse(readFileSync(join(dir, "base-sepolia", "manifest.json"), "utf8"));
  writeFileSync(join(dir, "base-sepolia", "manifest.json"), JSON.stringify({ ...m, chainId: 31338 }));
  const errors = checkOutputs(dir, APP_CHAINS);
  assert.equal(errors.length, 2);
  assert.match(errors[0]!, /sepolia: .* rehearsal/);
  assert.match(errors[1]!, /base-sepolia: the manifest is for chain 31338, not 84532/);
  assert.match(checkOutputs(join(dir, "none"), APP_CHAINS.slice(0, 1))[0]!, /no manifest/);
});

test("the faucet signs with the private config's DEPLOYER keystore; only paths are read", () => {
  const f = parseConfigFile("# private\nKEYSTORE_DIR=/keys\nPASSWORD_FILE=/keys/password\nDEPLOYER=deployer\nKEEPER=0x0000000000000000000000000000000000000001\n");
  assert.deepEqual(faucetSignerOf(f), { keystore: join("/keys", "deployer"), passwordFile: "/keys/password" });
  assert.throws(() => faucetSignerOf({ KEYSTORE_DIR: "/keys" }), /PASSWORD_FILE, DEPLOYER/);
  assert.throws(() => faucetSignerOf({ ...f, DEPLOYER: "../deployer" }), /DEPLOYER/);
  assert.throws(() => parseConfigFile("not a pair"), /KEY=VALUE/);
});

test("every service reads the test networks through the local proxies, never the RPC URL", () => {
  const p = plan();
  const envs = {
    indexer: indexerEnv(p),
    convex: convexVars(p),
    keeper: keeperEnv(p, tlsFiles, {}),
    monitor: monitorEnv(p),
    faucet: faucetEnv(p, { keystore: "/keys/deployer", passwordFile: "/keys/password" }, "0"),
    webapp: webappEnv(p, { url: "http://127.0.0.1:3210", siteUrl: "http://127.0.0.1:3211" }),
  };
  for (const [name, env] of Object.entries(envs)) {
    for (const [k, v] of Object.entries(env)) {
      assert.ok(!v.includes("example.invalid") && !v.includes("fixture-key"), `${name} ${k}`);
      if (/^(RPC_|NEXT_PUBLIC_RPC_|FAUCET_RPC_)/.test(k)) assert.match(v, /^(http|ws):\/\/(127\.0\.0\.1|localhost):866[56]$/, `${name} ${k}`);
    }
  }
  assert.deepEqual(proxyEnv(UPSTREAM, ["http://127.0.0.1:3100"]), { PROXY_UPSTREAMS: UPSTREAM, PROXY_CORS_ORIGINS: "http://127.0.0.1:3100" });
  for (const env of [envs.keeper, envs.monitor]) assert.notEqual(env.RPC_SEPOLIA, env.RPC_SEPOLIA_FALLBACK);
});

test("the indexer, keeper and monitor run on the testnet network set from the fixture manifests", () => {
  const p = plan();
  const manifests = APP_CHAINS.map((c) => join(FIXTURES, c.network, "manifest.json")).join(",");
  const indexer = indexerEnv(p);
  assert.equal(indexer.INDEXER_NETWORK_SET, "testnet");
  assert.equal(indexer.AVANA_MANIFEST, manifests);
  assert.equal(indexer.RPC_BASE_SEPOLIA_WS, "ws://127.0.0.1:8666");
  assert.equal(indexer.INDEXER_EXPORT_KEYS, "testnet-app:export-secret-value");
  assert.ok(!Object.keys(indexer).some((k) => k.startsWith("CHAIN_ID_")), "the test networks keep their own chain IDs");

  const monitor = monitorEnv(p);
  assert.equal(monitor.MONITOR_NETWORK_SET, "testnet");
  assert.equal(monitor.MONITOR_KEEPER_INSTANCES, "keeper-sepolia:sepolia,keeper-baseSepolia:baseSepolia");
  assert.equal(monitor.MONITOR_KEEPER_TOKEN_KEEPER_BASESEPOLIA, "keeper-token-base-sepolia");

  const only = indexerEnv(plan(selectChains("base-sepolia")));
  assert.equal(only.AVANA_MANIFEST, join(FIXTURES, "base-sepolia", "manifest.json"));
  assert.equal(only.RPC_SEPOLIA, undefined);
});

test("the keeper observes unless a KMS key is set for a chain, and never takes a local keystore", () => {
  const p = plan();
  const observe = keeperEnv(p, tlsFiles, {});
  assert.equal(observe.KEEPER_MODE, "observe");
  assert.equal(observe.KEEPER_NETWORK_SET, "testnet");
  assert.ok(!Object.keys(observe).some((k) => k.startsWith("KEEPER_LOCAL_KEYSTORE") || k.startsWith("KEEPER_KMS") || k.startsWith("KEEPER_GAS")));
  const active = keeperEnv(p, tlsFiles, { KEEPER_KMS_KEY_ID_BASE_SEPOLIA: "alias/keeper-base-sepolia" });
  assert.equal(active.KEEPER_MODE, "active");
  assert.equal(active.KEEPER_KMS_KEY_ID_BASE_SEPOLIA, "alias/keeper-base-sepolia");
  assert.ok(active.KEEPER_GAS_CEILING_WEI_BASE_SEPOLIA && active.KEEPER_GAS_DAILY_SPEND_WEI_BASE_SEPOLIA);
  assert.equal(active.KEEPER_GAS_CEILING_WEI_SEPOLIA, undefined);
});

test("Convex schedules its crons on the selected test networks and trusts the webapp's issuer", () => {
  const v = convexVars(plan());
  assert.equal(v.AVANA_CHAIN_IDS, "11155111,84532");
  assert.equal(v.SIWE_JWT_ISSUER, "http://127.0.0.1:3100");
  assert.equal(v.INDEXER_EXPORT_URL, "http://127.0.0.1:42170");
  assert.equal(v.LISTING_CONTENT_URL, "http://127.0.0.1:8888");
  assert.equal(convexVars(plan(selectChains("sepolia"))).AVANA_CHAIN_IDS, "11155111");
});

test("the faucet mints on the test networks from the deployer keystore, by the app's chain names", () => {
  const f = faucetEnv(plan(), { keystore: "/keys/deployer", passwordFile: "/keys/password" }, "0.01");
  assert.equal(f.FAUCET_CHAIN_KIND, "testnet");
  assert.equal(f.FAUCET_CHAIN_IDS, "11155111,84532");
  assert.equal(f.FAUCET_SIGNER_KEYSTORE, "/keys/deployer");
  assert.equal(f.FAUCET_GAS_ETH, "0.01");
  assert.equal(f.FAUCET_RPC_ETHEREUM, "http://127.0.0.1:8665");
  assert.equal(f.FAUCET_MANIFEST_BASE, join(FIXTURES, "base-sepolia", "manifest.json"));
});

test("the webapp opens on Sepolia with the Sepolia badge, the local Convex and the faucet", () => {
  const w = webappEnv(plan(), { url: "http://127.0.0.1:3210", siteUrl: "http://127.0.0.1:3211" });
  assert.equal(w.NEXT_PUBLIC_AVANA_NETWORK_LABEL, NETWORK_LABEL);
  assert.equal(NETWORK_LABEL, "Sepolia");
  assert.equal(w.NEXT_PUBLIC_AVANA_ETHEREUM_CHAIN_ID, "11155111");
  assert.equal(w.NEXT_PUBLIC_AVANA_BASE_CHAIN_ID, "84532");
  assert.equal(w.NEXT_PUBLIC_AVANA_CHAIN_ID, "11155111");
  assert.equal(w.NEXT_PUBLIC_RPC_BASE, "http://127.0.0.1:8666");
  assert.equal(w.NEXT_PUBLIC_SIWE_ISSUER, convexVars(plan()).SIWE_JWT_ISSUER);
  assert.equal(w.FAUCET_URL, "http://127.0.0.1:42180");
  assert.equal(w.CONVEX_RATE_LIMIT_SECRET, convexVars(plan()).CONVEX_RATE_LIMIT_SECRET);
  assert.equal(webappEnv(plan(selectChains("base-sepolia")), { url: "u", siteUrl: undefined }).NEXT_PUBLIC_AVANA_CHAIN_ID, "84532");
});

test("each chain's deployments row comes from its manifest, with the network's explorer", () => {
  const m = JSON.parse(readFileSync(join(FIXTURES, "base-sepolia", "manifest.json"), "utf8"));
  const world = JSON.parse(readFileSync(join(FIXTURES, "base-sepolia", "world.json"), "utf8"));
  const row = deploymentRowFrom(84532, m, world, [{ spoke: m.aave.lendSpokes[0].address, oracle: "0x000000000000000000000000000000000000b0a1" }], "https://sepolia.basescan.org");
  assert.equal(row.chainId, 84532);
  assert.equal(row.explorerUrl, "https://sepolia.basescan.org");
  assert.equal(row.lens, m.avana.lens.address);
  assert.deepEqual(row.cdpSpokes, m.aave.borrowSpokes.map((s: { address: string }) => s.address));
  assert.equal(row.nativeUsdFeed, world.feeds.WETH.primary);
  assert.deepEqual(row.lpVaults, [{ integrationId: 1, address: m.avana.lpVaults[0].address }]);
  assert.deepEqual(row.external, [
    { group: "token", name: "USDC", address: m.external[0].address, standIn: true },
    { group: "feed", name: "USDC / USD (primary)", address: m.external[1].address, standIn: true },
  ]);
});

test("the RPC URLs are read from the deploying checkout's encrypted secrets file", () => {
  const dir = mkdtempSync(join(tmpdir(), "testnet-app-secrets-"));
  const password = join(dir, "password");
  writeFileSync(password, "fixture-password\n");
  const salt = randomBytes(16);
  const iv = randomBytes(12);
  const c = createCipheriv("aes-256-gcm", scryptSync("fixture-password", salt, 32), iv);
  const data = Buffer.concat([c.update(JSON.stringify({ SEPOLIA_RPC_URL: UPSTREAM }), "utf8"), c.final()]);
  writeFileSync(join(dir, "secrets.enc"), Buffer.concat([salt, iv, c.getAuthTag(), data]).toString("base64"));
  assert.deepEqual(readSecretsFile(join(dir, "secrets.enc"), password), { SEPOLIA_RPC_URL: UPSTREAM });
  assert.deepEqual(readSecretsFile(join(dir, "none.enc"), password), {});
  writeFileSync(password, "another-password\n");
  assert.throws(() => readSecretsFile(join(dir, "secrets.enc"), password));
});

test("every printed line is redacted: the URL, its host and path, and its key", () => {
  const s = { SEPOLIA_RPC_URL: UPSTREAM };
  assert.equal(redact(`fetch ${UPSTREAM} failed`, s), "fetch <SEPOLIA_RPC_URL> failed");
  assert.equal(redact("POST eth-sepolia.example.invalid/v2/fixture-key-not-real: 429", s), "POST <SEPOLIA_RPC_URL>: 429");
  assert.equal(redact("path /v2/fixture-key-not-real", s), "path <SEPOLIA_RPC_URL>");
  assert.equal(redact("nothing secret", { SHORT: "abc" }), "nothing secret");
});

test("the proxy's WebSocket upstream and upgrade request name the upstream only, never the client's origin", () => {
  assert.equal(wsUpstreamOf(UPSTREAM).href, "wss://eth-sepolia.example.invalid/v2/fixture-key-not-real");
  assert.equal(wsUpstreamOf("http://127.0.0.1:1/x").protocol, "ws:");
  assert.throws(() => wsUpstreamOf("ftp://x"), /http\(s\) or ws\(s\)/);
  const req = upgradeRequest(wsUpstreamOf(UPSTREAM), { host: "127.0.0.1:8665", origin: "http://127.0.0.1:3100", "sec-websocket-key": "abc", "sec-websocket-version": "13", connection: "Upgrade" });
  assert.match(req, /^GET \/v2\/fixture-key-not-real HTTP\/1\.1\r\nHost: eth-sepolia\.example\.invalid\r\n/);
  assert.match(req, /sec-websocket-key: abc\r\n/);
  assert.ok(!/origin|127\.0\.0\.1/i.test(req));
  assert.deepEqual(corsHeaders("http://evil.example", ["http://127.0.0.1:3100"]), {});
  assert.equal(corsHeaders("http://127.0.0.1:3100", ["http://127.0.0.1:3100"])["access-control-allow-origin"], "http://127.0.0.1:3100");
});

async function freePort(): Promise<number> {
  const s = createNetServer();
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", r));
  const port = (s.address() as AddressInfo).port;
  await new Promise<void>((r) => s.close(() => r()));
  return port;
}

test("the proxy forwards JSON-RPC and a WebSocket to its upstream, answers the webapp's origin, and never prints the URL", async () => {
  // A local stand-in for the provider: JSON-RPC over HTTP, and a WebSocket that greets with one text frame.
  const seen: string[] = [];
  const upstream = createServer((req, res) => {
    seen.push(req.url ?? "");
    let body = "";
    req.on("data", (d) => (body += d));
    req.on("end", () => res.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", id: JSON.parse(body).id, result: "0xaa36a7" })));
  });
  upstream.on("upgrade", (req, socket) => {
    seen.push(`ws ${req.url}`);
    socket.on("error", () => {});
    const accept = createHash("sha1").update(`${req.headers["sec-websocket-key"]}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest("base64");
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    socket.write(Buffer.from([0x81, 5, ...Buffer.from("hello")]));
  });
  await new Promise<void>((r) => upstream.listen(0, "127.0.0.1", r));
  const url = `http://127.0.0.1:${(upstream.address() as AddressInfo).port}/v2/fixture-key-not-real`;
  const port = await freePort();
  const child = spawn(process.execPath, [PROXY, String(port)], { env: { ...process.env, PROXY_UPSTREAMS: url, PROXY_CORS_ORIGINS: "http://127.0.0.1:3100" }, stdio: ["ignore", "pipe", "pipe"] });
  let out = "";
  child.stdout.on("data", (d) => (out += d));
  child.stderr.on("data", (d) => (out += d));
  try {
    for (let i = 0; i < 100 && !out.includes("rpc proxy on"); i++) await new Promise((r) => setTimeout(r, 100));
    const r = await fetch(`http://127.0.0.1:${port}`, { method: "POST", headers: { "content-type": "application/json", origin: "http://127.0.0.1:3100" }, body: JSON.stringify({ jsonrpc: "2.0", id: 7, method: "eth_chainId" }) });
    assert.deepEqual(await r.json(), { jsonrpc: "2.0", id: 7, result: "0xaa36a7" });
    assert.equal(r.headers.get("access-control-allow-origin"), "http://127.0.0.1:3100");
    const other = await fetch(`http://127.0.0.1:${port}`, { method: "OPTIONS", headers: { origin: "http://evil.example" } });
    assert.equal(other.status, 403);

    const message = await new Promise<string>((resolve, reject) => {
      const ws = new WebSocket(`ws://127.0.0.1:${port}`);
      ws.onmessage = (e) => {
        resolve(String(e.data));
        ws.close();
      };
      ws.onerror = () => reject(new Error("websocket through the proxy failed"));
    });
    assert.equal(message, "hello");
    assert.deepEqual(seen, ["/v2/fixture-key-not-real", "ws /v2/fixture-key-not-real"]);
    assert.ok(!out.includes("fixture-key") && !out.includes(String((upstream.address() as AddressInfo).port)), out);
  } finally {
    child.kill();
    upstream.closeAllConnections();
    await new Promise<void>((r) => upstream.close(() => r()));
  }
});
