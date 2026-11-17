// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// A chain's saved state, streamed to and from disk. anvil_dumpState returns the state gzip-compressed and hex-encoded:
// on a long-running stack that is well over Node's 512 MB string limit, so the reply is never held as a string. It is
// decoded as it arrives (hex, then gzip) into anvil's JSON state, which `anvil --load-state` reads at start.

import { createReadStream, createWriteStream, renameSync, rmSync } from "node:fs";
import { request } from "node:http";
import type { IncomingMessage } from "node:http";
import { pipeline } from "node:stream/promises";
import { createGunzip } from "node:zlib";

const HEAD_LIMIT = 1 << 20;
const RESULT = /"result"\s*:\s*"/;

/**
 * Decodes a hex payload to bytes as it streams. `jsonrpc`: the payload is the string `result` of a JSON-RPC reply
 * (an `error` reply, or one without a string result, throws). `raw`: the whole input is the hex string, whitespace
 * ignored. A leading `0x` is dropped in both.
 */
export async function* decodeHex(source: AsyncIterable<Buffer | string>, framing: "jsonrpc" | "raw"): AsyncGenerator<Buffer> {
  let phase: "head" | "body" | "tail" = framing === "jsonrpc" ? "head" : "body";
  let head = "";
  let pending = "";
  let stripped = false;
  for await (const chunk of source) {
    if (phase === "tail") continue;
    let text = typeof chunk === "string" ? chunk : chunk.toString("latin1");
    if (phase === "head") {
      head += text;
      const m = RESULT.exec(head);
      if (!m) {
        if (head.length > HEAD_LIMIT) throw new Error(`no string result in the first ${HEAD_LIMIT} bytes of the reply: ${head.slice(0, 200)}`);
        continue;
      }
      text = head.slice(m.index + m[0].length);
      phase = "body";
    }
    let end = false;
    if (framing === "jsonrpc") {
      const q = text.indexOf('"');
      if (q >= 0) {
        text = text.slice(0, q);
        end = true;
      }
    } else text = text.replace(/\s+/g, "");
    pending += text;
    if (!stripped) {
      if (pending.length < 2 && !end) continue;
      pending = pending.replace(/^0x/i, "");
      stripped = true;
    }
    const out = flushHex(pending, end);
    pending = out.rest;
    if (out.bytes.length) yield out.bytes;
    if (end) phase = "tail";
  }
  if (phase === "head") throw new Error(`no string result in the reply: ${errorOf(head)}`);
  if (framing === "jsonrpc") {
    if (phase !== "tail") throw new Error("the reply ended inside its result");
    return;
  }
  const out = flushHex(stripped ? pending : pending.replace(/^0x/i, ""), true);
  if (out.bytes.length) yield out.bytes;
}

/** Decodes the even-length prefix of `hex`; with `final`, the whole string, which must then be of even length. */
function flushHex(hex: string, final: boolean): { bytes: Buffer; rest: string } {
  if (final && hex.length % 2) throw new Error("odd-length hex payload");
  const n = hex.length - (hex.length % 2);
  const body = hex.slice(0, n);
  if (!/^[0-9a-fA-F]*$/.test(body)) throw new Error("the payload is not hex");
  return { bytes: Buffer.from(body, "hex"), rest: hex.slice(n) };
}

function errorOf(reply: string): string {
  try {
    const j = JSON.parse(reply) as { error?: { message?: string } };
    if (j.error?.message) return j.error.message;
  } catch {
    /* not a whole JSON reply */
  }
  return reply.slice(0, 200);
}

/** Writes `path` from a source of gzip-compressed hex, through a temporary file: a failure leaves `path` as it was. */
async function writeState(source: AsyncIterable<Buffer | string>, framing: "jsonrpc" | "raw", path: string): Promise<void> {
  const tmp = `${path}.partial`;
  try {
    await pipeline(source, (s: AsyncIterable<Buffer | string>) => decodeHex(s, framing), createGunzip(), createWriteStream(tmp));
    renameSync(tmp, path);
  } catch (e) {
    rmSync(tmp, { force: true });
    throw e;
  }
}

function post(url: string, body: string): Promise<IncomingMessage> {
  return new Promise((resolve, reject) => {
    const req = request(url, { method: "POST", headers: { "content-type": "application/json" } }, resolve);
    req.on("error", reject);
    req.end(body);
  });
}

/** Saves the node's state (anvil_dumpState) to `path` as anvil's JSON state, for `anvil --load-state`. */
export async function dumpState(url: string, path: string): Promise<void> {
  const res = await post(url, JSON.stringify({ jsonrpc: "2.0", id: 1, method: "anvil_dumpState", params: [] }));
  if (res.statusCode !== 200) {
    res.resume();
    throw new Error(`anvil_dumpState: HTTP ${res.statusCode}`);
  }
  await writeState(res, "jsonrpc", path);
}

/** Converts a state saved as anvil_dumpState's hex (the stack's earlier `anvil-state.hex`) to anvil's JSON state. */
export async function hexStateToJson(hexPath: string, path: string): Promise<void> {
  await writeState(createReadStream(hexPath), "raw", path);
}
