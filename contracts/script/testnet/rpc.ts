// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The test networks' RPC, from the provider credentials (packages/rpc, AvanaRPCManager): ALCHEMY_API_KEY, and
// QUICKNODE_ENDPOINT_NAME with QUICKNODE_TOKEN for the backup, from the environment or the encrypted secrets store
// (`stack.ts secrets`). An explicit endpoint (SEPOLIA_RPC_URL, BASE_SEPOLIA_RPC_URL) replaces a chain's providers.
//
// - Each step starts on the healthiest provider (a probe of chain ID, head and latency; Alchemy first). Its URL reaches
//   forge only through the steps' environment (AVANA_RPC_URL, the foundry.toml endpoint avana_step; ETH_RPC_URL for
//   cast), never a command line or a log.
// - A step that fails on an infrastructure error (timeout, connection, rate limit, server error, stale node) is run
//   once more on the backup. First every transaction the failed attempt recorded in a forge broadcast record is
//   looked up on the backup (by hash, then by its sender's nonce) and waited for until mined, and every signer's
//   pending nonce must equal its mined one; then a step that had begun broadcasting continues with
//   `forge script --resume` (it sends only what is left, and stops if a sender's nonce moved), and a step that had
//   not is run again from the start. A revert or any other failure is never moved to another provider.

import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { AvanaRPCManager, CREDENTIAL_NAMES, type Endpoint, classifyText } from "../../../packages/rpc/src/index.ts";
import { type LocalChain, TESTNETS, activeRpcProvider, setActiveRpc } from "../local/lib/env.ts";

let manager: AvanaRPCManager | undefined;

type SecretName = (typeof CREDENTIAL_NAMES)[number] | "SEPOLIA_RPC_URL" | "BASE_SEPOLIA_RPC_URL";

/** The test networks' manager: credentials and explicit endpoints from the environment, else the secrets store. */
export async function testnetRpc(): Promise<AvanaRPCManager> {
  if (manager) return manager;
  const { secretValue } = await import("../local/lib/secrets.ts");
  const value = (n: SecretName) => process.env[n]?.trim() || secretValue(n);
  const credentials = Object.fromEntries(CREDENTIAL_NAMES.map((n) => [n, value(n)]));
  const chains: Record<number, { http: string }> = {};
  for (const c of TESTNETS) {
    const url = value(c.testnet!.rpcEnv as SecretName);
    if (url) chains[c.chainId] = { http: url };
  }
  manager = new AvanaRPCManager({ credentials, chains, logger: { warn: (m) => process.stdout.write(`${m}\n`) } });
  return manager;
}

/** Uses `m` instead of the store's (tests). */
export function setTestnetRpc(m: AvanaRPCManager | undefined): void {
  manager = m;
}

/** `text` with the provider credentials and endpoints replaced by their names. */
export const redactRpc = (text: string) => (manager ? manager.redact(text) : text);

/** Probes the chain's endpoints and makes the healthiest the one the steps use. */
export async function useHealthyRpc(c: LocalChain): Promise<Endpoint> {
  const m = await testnetRpc();
  const e = await m.selectHealthy(c.chainId);
  setActiveRpc(c, e.secretUrl(), e.provider);
  return e;
}

/** The chain's endpoints in order, and the one in use (no URL). */
export async function rpcSummary(c: LocalChain): Promise<string> {
  const m = await testnetRpc();
  const order = m.endpoints(c.chainId).map((e) => e.provider);
  return `${activeRpcProvider(c) ?? order[0]}${order.length > 1 ? ` (order ${order.join(", ")})` : " (no backup)"}`;
}

// ─── Forge broadcast records ───

/** Every run-latest.json under the chain's broadcast directory, with its modification time. */
export function broadcastSnapshot(dir: string): Map<string, number> {
  const out = new Map<string, number>();
  const walk = (d: string, depth: number) => {
    if (depth > 4 || !existsSync(d)) return;
    for (const f of readdirSync(d, { withFileTypes: true })) {
      const p = join(d, f.name);
      if (f.isDirectory()) walk(p, depth + 1);
      else if (f.name === "run-latest.json") out.set(p, statSync(p).mtimeMs);
    }
  };
  walk(dir, 0);
  return out;
}

/** The broadcast records written since `before`. */
export function changedBroadcasts(dir: string, before: ReadonlyMap<string, number>): string[] {
  return [...broadcastSnapshot(dir)].filter(([p, t]) => before.get(p) !== t).map(([p]) => p);
}

export interface SentTransaction {
  readonly hash: `0x${string}`;
  readonly from: `0x${string}`;
  readonly nonce: number;
}

/** The transactions a broadcast record says were sent and have no receipt in it. */
export function unconfirmed(record: string): SentTransaction[] {
  const r = JSON.parse(readFileSync(record, "utf8")) as {
    transactions?: { hash?: string | null; transaction?: { from?: string; nonce?: string } }[];
    receipts?: { transactionHash?: string }[];
  };
  const done = new Set((r.receipts ?? []).map((x) => x.transactionHash?.toLowerCase()));
  return (r.transactions ?? [])
    .filter((t) => t.hash && t.transaction?.from && t.transaction.nonce !== undefined && !done.has(t.hash.toLowerCase()))
    .map((t) => ({ hash: t.hash as `0x${string}`, from: t.transaction!.from as `0x${string}`, nonce: Number(BigInt(t.transaction!.nonce!)) }));
}

// ─── Failover of a step ───

export type FailoverPlan =
  | { readonly move: true; readonly from: string; readonly to: string; readonly resume: boolean }
  | { readonly move: false; readonly reason: string };

export interface SettleOptions {
  readonly timeoutMs?: number;
  readonly pollMs?: number;
  readonly sleep?: (ms: number) => Promise<void>;
}

/**
 * After a failed step: whether it is run again on another provider. Only an infrastructure failure moves; the backup
 * must pass its probe; the failed attempt's transactions (`records`, the broadcast records it wrote) and the
 * `signers`' nonces must have settled on it.
 */
export async function planFailover(c: LocalChain, output: string, records: readonly string[], signers: readonly string[], o: SettleOptions = {}): Promise<FailoverPlan> {
  const failure = classifyText(output);
  const from = activeRpcProvider(c);
  if (!failure) return { move: false, reason: "not an RPC failure" };
  if (!from) return { move: false, reason: "no provider in use" };
  const m = await testnetRpc();
  m.reportFailure(c.chainId, from, failure);
  let next: Endpoint;
  try {
    next = await m.selectHealthy(c.chainId);
  } catch (e) {
    return { move: false, reason: (e as Error).message };
  }
  if (next.provider === from) return { move: false, reason: `${from} ${failure}, and no other provider is healthy` };
  const left = await settle(m, c, next, records.flatMap(unconfirmed), signers, o);
  if (left) return { move: false, reason: `${from} ${failure}; on ${next.provider}: ${left}` };
  setActiveRpc(c, next.secretUrl(), next.provider);
  return { move: true, from, to: next.provider, resume: records.length > 0 };
}

/**
 * Waits until every transaction of `sent` is mined or known to be free to send again, and every signer has nothing
 * pending, as `e` sees the chain. Returns what is left unsettled when the wait ends, or undefined.
 */
export async function settle(m: AvanaRPCManager, c: LocalChain, e: Endpoint, sent: readonly SentTransaction[], signers: readonly string[], o: SettleOptions = {}): Promise<string | undefined> {
  const rpc = m.failover(c.chainId);
  const req = (method: string, params: unknown[]) => rpc.ctx.requestOf(e)({ method, params });
  const sleep = o.sleep ?? ((ms: number) => new Promise((r) => setTimeout(r, ms)));
  const deadline = Date.now() + (o.timeoutMs ?? 300_000);
  for (;;) {
    const left: string[] = [];
    for (const t of sent) {
      const where = await rpc.lookup(e, t);
      if (where === "nonce-used") return `nonce ${t.nonce} of ${t.from} was used by a transaction other than ${t.hash}`;
      if (where === "sent" && !(await req("eth_getTransactionReceipt", [t.hash]))) left.push(`${t.hash} pending`);
      if (where === "nonce-pending") left.push(`${t.from} nonce ${t.nonce} pending`);
    }
    for (const s of signers) {
      const [mined, pending] = await Promise.all([req("eth_getTransactionCount", [s, "latest"]), req("eth_getTransactionCount", [s, "pending"])]);
      if (BigInt(pending as string) > BigInt(mined as string)) left.push(`${s} has ${BigInt(pending as string) - BigInt(mined as string)} pending`);
    }
    if (left.length === 0) return undefined;
    if (Date.now() >= deadline) return `still pending: ${left.join(", ")}; rerun deploy once they are mined`;
    await sleep(o.pollMs ?? 5_000);
  }
}
