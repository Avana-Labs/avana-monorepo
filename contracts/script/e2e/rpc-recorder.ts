// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
//
// A JSON-RPC proxy for the indexer replay (services-replay.sh, runbook services/REPLAY.md): it answers each eth_call
// pinned to a block from what the node answered the first time, and forwards everything else to the node.
//
// Ponder keeps every successful pinned read in its sync store, but not a read that reverts or returns no data. The
// hourly sampler reads Hubs and Spokes that have no code yet at early blocks (discovery.ts), so the replay asks the node
// for those again, thousands of blocks later. A real archive node answers; anvil keeps the state of its last few
// thousand blocks only, and the replay fails. The proxy keeps each such answer, a multicall's sub-calls one by one (the
// replay's multicall holds only the sub-calls Ponder has no result for), so the replay reads exactly what the chain
// answered at that block.
//
//   node rpc-recorder.ts <port> <node URL> <record file>
//
// The record file holds one answer per line and is loaded again on start. Answers are keyed by block number, so the
// chain must not be rewound (evm_revert) while the proxy runs.

import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { createServer } from "node:http";
import { type Hex, decodeFunctionData, decodeFunctionResult, encodeFunctionResult, multicall3Abi, toFunctionSelector } from "viem";

type Req = { jsonrpc?: string; id?: unknown; method: string; params?: unknown[] };
type Res = { jsonrpc: "2.0"; id: unknown; result?: unknown; error?: { code: number; message: string; data?: unknown } };
type SubResult = { success: boolean; returnData: Hex };
type Stored = { result: unknown } | { error: Res["error"] };

const [portArg, upstream, recordFile] = process.argv.slice(2) as [string, string, string];
if (!portArg || !upstream || !recordFile) {
  console.error("usage: node rpc-recorder.ts <port> <node URL> <record file>");
  process.exit(2);
}

const AGGREGATE3 = toFunctionSelector("aggregate3((address,bool,bytes)[])");
const subCalls = new Map<string, SubResult>(); // block:target:callData
const calls = new Map<string, Stored>(); // block:to:data, plain eth_call
const stats = { served: 0, forwarded: 0 };

if (existsSync(recordFile)) {
  for (const line of readFileSync(recordFile, "utf8").split("\n")) {
    if (!line) continue;
    const r = JSON.parse(line) as { k: string; sub?: SubResult; call?: Stored };
    if (r.sub) subCalls.set(r.k, r.sub);
    if (r.call) calls.set(r.k, r.call);
  }
}
const keep = (line: object) => appendFileSync(recordFile, `${JSON.stringify(line)}\n`);

// Ponder asks for one read inside a multicall or, when it prefetches, on its own: either record answers the other.
function subAnswer(k: string): SubResult | undefined {
  const sub = subCalls.get(k);
  if (sub) return sub;
  const call = calls.get(k);
  if (!call) return undefined;
  return "result" in call ? { success: true, returnData: call.result as Hex } : { success: false, returnData: ((call.error?.data as Hex | undefined) ?? "0x") as Hex };
}
function callAnswer(k: string): Stored | undefined {
  const call = calls.get(k);
  if (call) return call;
  const sub = subCalls.get(k);
  if (!sub) return undefined;
  return sub.success ? { result: sub.returnData } : { error: { code: 3, message: "execution reverted", data: sub.returnData } };
}

async function forward(body: unknown): Promise<unknown> {
  stats.forwarded++;
  const res = await fetch(upstream, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
  return res.json();
}

/** A block number in hex: the only pin whose answer never changes. "latest", "pending" and hashes are forwarded. */
const pinned = (b: unknown): b is Hex => typeof b === "string" && /^0x[0-9a-f]+$/i.test(b) && b.length < 20;

async function handle(req: Req): Promise<unknown> {
  const params = req.params ?? [];
  const tx = params[0] as { to?: string; data?: string } | undefined;
  if (req.method !== "eth_call" || !tx?.to || !tx.data || !pinned(params[1]) || params.length > 2) return forward(req);
  const block = BigInt(params[1]).toString();
  const to = tx.to.toLowerCase();
  const data = tx.data.toLowerCase();

  if (data.startsWith(AGGREGATE3)) {
    const subs = decodeFunctionData({ abi: multicall3Abi, data: data as Hex }).args[0] as readonly { target: string; allowFailure: boolean; callData: Hex }[];
    const keys = subs.map((s) => `${block}:${s.target.toLowerCase()}:${s.callData.toLowerCase()}`);
    // A sub-call that must not fail and failed makes the whole call revert: forward those, as the node would answer.
    const answers = keys.map(subAnswer);
    if (answers.every((a, i) => a !== undefined && (subs[i]!.allowFailure || a.success))) {
      stats.served++;
      return { jsonrpc: "2.0", id: req.id, result: encodeFunctionResult({ abi: multicall3Abi, functionName: "aggregate3", result: answers as SubResult[] }) };
    }
    const res = (await forward(req)) as Res;
    if (typeof res.result === "string") {
      const out = decodeFunctionResult({ abi: multicall3Abi, functionName: "aggregate3", data: res.result as Hex }) as readonly SubResult[];
      out.forEach((r, i) => {
        if (subCalls.has(keys[i]!)) return;
        const sub = { success: r.success, returnData: r.returnData };
        subCalls.set(keys[i]!, sub);
        keep({ k: keys[i], sub });
      });
    }
    return res;
  }

  const key = `${block}:${to}:${data}`;
  const known = callAnswer(key);
  if (known) {
    stats.served++;
    return { jsonrpc: "2.0", id: req.id, ...known };
  }
  const res = (await forward(req)) as Res;
  // A result, or a revert (error code 3): both are the chain's answer. Any other error is the node's, and not kept.
  const stored: Stored | null = res.result !== undefined ? { result: res.result } : res.error?.code === 3 ? { error: res.error } : null;
  if (stored) {
    calls.set(key, stored);
    keep({ k: key, call: stored });
  }
  return res;
}

createServer((inReq, out) => {
  // A GET answers with the counts: services-replay.sh uses it to see the proxy is up and to report them.
  if (inReq.method === "GET") {
    out.writeHead(200, { "content-type": "text/plain" }).end(`${stats.served} calls answered from the record, ${stats.forwarded} forwarded, ${subCalls.size + calls.size} answers kept`);
    return;
  }
  let raw = "";
  inReq.on("data", (c) => (raw += c));
  inReq.on("end", async () => {
    try {
      const body = JSON.parse(raw) as Req | Req[];
      const res = Array.isArray(body) ? await Promise.all(body.map(handle)) : await handle(body);
      out.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(res));
    } catch (e) {
      out.writeHead(502, { "content-type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32603, message: String(e) } }));
    }
  });
}).listen(Number(portArg), "127.0.0.1", () => console.log(`rpc-recorder: port ${portArg} -> ${upstream}, ${subCalls.size + calls.size} answers loaded`));
