// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Run: node --test script/testnet/rpc.test.ts (from contracts/)
// The test networks' provider choice and step failover, against mocked providers (packages/rpc/test/mock.ts): no
// network, no forge.

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { type Hex, keccak256 } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { CREDENTIALS, mockManager } from "../../../packages/rpc/test/mock.ts";
import { TESTNETS, activeRpcProvider, rpcUrl } from "../local/lib/env.ts";
import { redact } from "../local/lib/chain.ts";
import { broadcastSnapshot, changedBroadcasts, planFailover, setTestnetRpc, unconfirmed, useHealthyRpc } from "./rpc.ts";
import { preferredUpstream } from "./rpc-proxy.ts";

const sepolia = TESTNETS.find((c) => c.network === "sepolia")!;
const fast = { timeoutMs: 0, pollMs: 0, sleep: async () => {} };

function setup() {
  const m = mockManager(sepolia.chainId);
  setTestnetRpc(m.manager);
  return m;
}

/** A broadcast record like forge's run-latest.json: `sent` transactions with a hash, `receipts` for some of them. */
function record(dir: string, sent: { hash: Hex; from: string; nonce: number }[], receipts: Hex[] = []): string {
  const d = join(dir, "03_DeployAvana.s.sol", String(sepolia.chainId));
  mkdirSync(d, { recursive: true });
  const p = join(d, "run-latest.json");
  writeFileSync(
    p,
    JSON.stringify({
      transactions: [...sent.map((t) => ({ hash: t.hash, transaction: { from: t.from, nonce: `0x${t.nonce.toString(16)}` } })), { hash: null, transaction: { from: sent[0]?.from, nonce: "0x63" } }],
      receipts: receipts.map((h) => ({ transactionHash: h })),
    }),
  );
  return p;
}

test("each step starts on the healthiest provider, Alchemy first, its URL kept out of every log", async () => {
  const m = setup();
  assert.equal((await useHealthyRpc(sepolia)).provider, "alchemy");
  assert.equal(activeRpcProvider(sepolia), "alchemy");
  const url = rpcUrl(sepolia);
  assert.equal(redact(`error sending request for url (${url})`), "error sending request for url (<AVANA_RPC_URL>)");
  assert.ok(!redact(`key ${CREDENTIALS.ALCHEMY_API_KEY} token ${CREDENTIALS.QUICKNODE_TOKEN}`).includes(CREDENTIALS.ALCHEMY_API_KEY));
  m.alchemy.behaviour = "server";
  assert.equal((await useHealthyRpc(sepolia)).provider, "quicknode");
  assert.equal(activeRpcProvider(sepolia), "quicknode");
});

test("an RPC failure moves the step to the backup; a revert does not", async () => {
  setup();
  await useHealthyRpc(sepolia);
  const revert = await planFailover(sepolia, "Error: script failed: execution reverted: Paused()", [], [], fast);
  assert.deepEqual(revert, { move: false, reason: "not an RPC failure" });
  assert.equal(activeRpcProvider(sepolia), "alchemy");
  const timeout = await planFailover(sepolia, "Error: error sending request for url (<AVANA_RPC_URL>): operation timed out", [], [], fast);
  assert.deepEqual(timeout, { move: true, from: "alchemy", to: "quicknode", resume: false });
  assert.equal(activeRpcProvider(sepolia), "quicknode");
});

test("a step that began broadcasting resumes on the backup once its sent transactions are settled there", async () => {
  const m = setup();
  await useHealthyRpc(sepolia);
  const dir = mkdtempSync(join(tmpdir(), "avana-broadcast-"));
  const before = broadcastSnapshot(dir);
  const account = privateKeyToAccount(generatePrivateKey());
  const raw = await account.signTransaction({ chainId: sepolia.chainId, nonce: 0, to: "0x0000000000000000000000000000000000000001", value: 1n, gas: 21_000n, maxFeePerGas: 2n, maxPriorityFeePerGas: 1n });
  const hash = keccak256(raw);
  // The failed attempt sent one transaction (Alchemy took it in), then lost its connection.
  await m.chain.accept(raw);
  m.chain.txs.get(hash)!.mined = true;
  m.chain.mined.set(account.address.toLowerCase(), 1);
  const p = record(dir, [{ hash, from: account.address, nonce: 0 }]);
  assert.deepEqual(changedBroadcasts(dir, before), [p]);
  assert.deepEqual(unconfirmed(p), [{ hash, from: account.address, nonce: 0 }]);
  const plan = await planFailover(sepolia, "Error: tcp connect error: Connection refused (os error 10061)", [p], [account.address], fast);
  assert.deepEqual(plan, { move: true, from: "alchemy", to: "quicknode", resume: true });
  // It was looked up on the backup (by hash and receipt), and nothing was sent anywhere.
  assert.equal(m.quicknode.count("eth_getTransactionByHash"), 1);
  assert.equal(m.quicknode.count("eth_sendRawTransaction") + m.alchemy.count("eth_sendRawTransaction"), 0);
  assert.equal(m.chain.txs.size, 1);
  // No new record since: nothing changed.
  assert.deepEqual(changedBroadcasts(dir, broadcastSnapshot(dir)), []);
});

test("no failover while a transaction of the failed attempt is still pending, or its nonce went to another", async () => {
  {
    const m = setup();
    await useHealthyRpc(sepolia);
    const dir = mkdtempSync(join(tmpdir(), "avana-broadcast-"));
    const account = privateKeyToAccount(generatePrivateKey());
    const raw = await account.signTransaction({ chainId: sepolia.chainId, nonce: 0, to: "0x0000000000000000000000000000000000000001", value: 1n, gas: 21_000n, maxFeePerGas: 2n, maxPriorityFeePerGas: 1n });
    await m.chain.accept(raw);
    const p = record(dir, [{ hash: keccak256(raw), from: account.address, nonce: 0 }]);
    const plan = await planFailover(sepolia, "HTTP error 503 with body: Service Unavailable", [p], [account.address], fast);
    assert.equal(plan.move, false);
    assert.match((plan as { reason: string }).reason, /alchemy server; on quicknode: still pending: 0x[0-9a-f]{64} pending, 0x[0-9a-fA-F]{40} has 1 pending; rerun deploy once they are mined/);
    assert.equal(activeRpcProvider(sepolia), "alchemy");
  }
  {
    const m = setup();
    await useHealthyRpc(sepolia);
    const dir = mkdtempSync(join(tmpdir(), "avana-broadcast-"));
    const account = privateKeyToAccount(generatePrivateKey());
    m.chain.mined.set(account.address.toLowerCase(), 1);
    const p = record(dir, [{ hash: `0x${"11".repeat(32)}`, from: account.address, nonce: 0 }]);
    const plan = await planFailover(sepolia, "operation timed out", [p], [], fast);
    assert.equal(plan.move, false);
    assert.match((plan as { reason: string }).reason, /nonce 0 of 0x[0-9a-fA-F]{40} was used by a transaction other than 0x1111/);
  }
});

test("the RPC proxies send each request to the first endpoint not failed in the last 30 s", () => {
  let t = 0;
  const pick = preferredUpstream(2, 30_000, () => t);
  assert.equal(pick.next(), 0);
  assert.equal(pick.failed(0), true); // the backup is in use: move at once
  assert.equal(pick.next(), 1);
  t += 29_999;
  assert.equal(pick.next(), 1);
  t += 1;
  assert.equal(pick.next(), 0); // the primary again after its cool-down
  assert.equal(pick.failed(0), true);
  assert.equal(pick.failed(1), false); // every endpoint failed: back off
  t += 1;
  assert.equal(pick.next(), 0); // the one that failed longest ago
});

test("no failover without a healthy backup", async () => {
  const m = mockManager(sepolia.chainId, { credentials: { ALCHEMY_API_KEY: CREDENTIALS.ALCHEMY_API_KEY } });
  setTestnetRpc(m.manager);
  await useHealthyRpc(sepolia);
  const plan = await planFailover(sepolia, "Too Many Requests", [], [], fast);
  assert.deepEqual(plan, { move: false, reason: "alchemy rate-limit, and no other provider is healthy" });
});
