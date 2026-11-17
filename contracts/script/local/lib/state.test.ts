// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Run: node --test script/local/lib/state.test.ts (from contracts/)

import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { gzipSync } from "node:zlib";
import { decodeHex, dumpState, firstStateBlock, hexStateToJson } from "./state.ts";

const STATE = JSON.stringify({ block: { number: "0x14ae" }, accounts: { "0x01": { nonce: 1, code: "0x6001", storage: {} } }, blocks: [] });
const HEX = `0x${gzipSync(STATE).toString("hex")}`;

/** Splits `s` into chunks of the given sizes (the last chunk takes the rest), as a socket would deliver it. */
async function* chunks(s: string, sizes: number[]): AsyncGenerator<Buffer> {
  let i = 0;
  for (const n of sizes) {
    if (i >= s.length) break;
    yield Buffer.from(s.slice(i, i + n), "latin1");
    i += n;
  }
  if (i < s.length) yield Buffer.from(s.slice(i), "latin1");
}

async function decoded(src: AsyncIterable<Buffer>, framing: "jsonrpc" | "raw"): Promise<Buffer> {
  const out: Buffer[] = [];
  for await (const b of decodeHex(src, framing)) out.push(b);
  return Buffer.concat(out);
}

function tmp(): { dir: string; done: () => void } {
  const dir = mkdtempSync(join(tmpdir(), "anvil-state-"));
  return { dir, done: () => rmSync(dir, { recursive: true, force: true }) };
}

test("decodeHex: a JSON-RPC result split at any byte decodes to the same bytes", async () => {
  const reply = `{"jsonrpc":"2.0","id":1,"result":"${HEX}"}`;
  const want = Buffer.from(HEX.slice(2), "hex");
  for (const sizes of [[1], [3, 1, 1, 7], [11, 1], [33, 1, 1, 1], [34], [35], [36, 5]]) {
    const one = sizes.length === 1 ? Array(reply.length).fill(sizes[0]) : sizes;
    assert.deepEqual(await decoded(chunks(reply, one), "jsonrpc"), want, `chunks ${sizes}`);
  }
});

test("decodeHex: an error reply throws its message", async () => {
  await assert.rejects(decoded(chunks('{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}', [9]), "jsonrpc"), /Method not found/);
});

test("decodeHex: a reply cut inside its result throws", async () => {
  await assert.rejects(decoded(chunks(`{"jsonrpc":"2.0","id":1,"result":"${HEX.slice(0, 40)}`, [16]), "jsonrpc"), /ended inside its result/);
});

test("decodeHex: a raw hex file with a trailing newline decodes", async () => {
  assert.deepEqual(await decoded(chunks(`${HEX}\n`, [1, 2, 5]), "raw"), Buffer.from(HEX.slice(2), "hex"));
});

test("hexStateToJson: the stack's earlier anvil-state.hex becomes anvil's JSON state", async () => {
  const t = tmp();
  try {
    writeFileSync(join(t.dir, "anvil-state.hex"), HEX);
    await hexStateToJson(join(t.dir, "anvil-state.hex"), join(t.dir, "anvil-state.json"));
    assert.equal(readFileSync(join(t.dir, "anvil-state.json"), "utf8"), STATE);
  } finally {
    t.done();
  }
});

test("dumpState: streams anvil_dumpState into the JSON state; a failed dump keeps the previous state", async () => {
  const t = tmp();
  let reply = `{"jsonrpc":"2.0","id":1,"result":"${HEX}"}`;
  const server = createServer((req, res) => {
    req.resume();
    req.on("end", () => {
      res.writeHead(200, { "content-type": "application/json" });
      for (let i = 0; i < reply.length; i += 7) res.write(reply.slice(i, i + 7));
      res.end();
    });
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  const url = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const path = join(t.dir, "anvil-state.json");
  try {
    await dumpState(url, path);
    assert.equal(readFileSync(path, "utf8"), STATE);
    reply = `{"jsonrpc":"2.0","id":1,"result":"${HEX.slice(0, 60)}"}`;
    await assert.rejects(dumpState(url, path));
    assert.equal(readFileSync(path, "utf8"), STATE);
    assert.equal(existsSync(`${path}.partial`), false);
  } finally {
    server.close();
    t.done();
  }
});

test("firstStateBlock: 0 on a node with every state, the restore block on a restored node, in few probes", async () => {
  assert.equal(await firstStateBlock(17882, async () => true), 0);
  for (const floor of [1, 2, 5294, 17881, 17882]) {
    let probes = 0;
    const got = await firstStateBlock(17882, async (n) => {
      probes++;
      return n >= floor;
    });
    assert.equal(got, floor);
    assert.ok(probes <= 17, `${probes} probes`);
  }
});
