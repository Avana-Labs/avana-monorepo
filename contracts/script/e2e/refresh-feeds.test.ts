// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Run: node --test script/e2e/refresh-feeds.test.ts (from contracts/)
// The feed refresh's burst sender against a fake chain: nonces, receipts, bursts and the stale-nonce resend. No network.

import assert from "node:assert/strict";
import { test } from "node:test";
import type { Hex } from "viem";
import { type RoundSender, isStaleNonce, sendRounds } from "./refresh-feeds.ts";

type Round = { aggregator: string };

/**
 * A fake chain for one signer. `stale` lists the sends (by call number, from 1) the node refuses as "nonce too low";
 * `reverts` lists the aggregators whose round reverts. Records every send, the nonce read before each burst attempt
 * and the order of sends and receipt waits.
 */
function chain(opts: { stale?: number[]; reverts?: string[]; error?: number } = {}) {
  let mined = 0;
  let calls = 0;
  const sends: { aggregator: string; nonce: number }[] = [];
  const starts: number[] = [];
  const log: string[] = [];
  const sender: RoundSender<Round, Round> = {
    prepare: async (r) => r,
    start: async () => {
      starts.push(mined);
      return mined;
    },
    send: async (r, nonce) => {
      calls++;
      if (opts.error === calls) throw new Error("execution reverted");
      if (opts.stale?.includes(calls)) throw new Error(`nonce too low: next nonce ${mined + 1}, tx nonce ${nonce}`);
      assert.equal(nonce, mined, "each send carries the next unused nonce");
      mined++;
      sends.push({ aggregator: r.aggregator, nonce });
      log.push(`send ${r.aggregator}`);
      return `0x${nonce.toString(16).padStart(2, "0")}` as Hex;
    },
    receipt: async (hash) => {
      log.push(`receipt ${hash}`);
      const s = sends[Number.parseInt(hash.slice(2), 16)]!;
      return { status: opts.reverts?.includes(s.aggregator) ? "reverted" : "success" };
    },
  };
  return { sends, starts, log, sender };
}

const rounds = (...names: string[]) => names.map((aggregator) => ({ aggregator }));
const key = (r: Round) => r.aggregator;

test("a stale nonce is recognised in both wordings, a revert is not", () => {
  assert.equal(isStaleNonce(new Error("nonce too low: next nonce 349, tx nonce 348")), true);
  assert.equal(isStaleNonce(new Error("Nonce provided for the transaction is lower than the current nonce of the account")), true);
  assert.equal(isStaleNonce(new Error("execution reverted")), false);
});

test("one burst: consecutive nonces from one read, every send before any receipt, every receipt awaited", async () => {
  const c = chain();
  const hashes = await sendRounds(rounds("a", "b", "c", "d"), key, c.sender, 50, 6, 0);
  assert.deepEqual(c.starts, [0]);
  assert.deepEqual(
    c.sends.map((s) => s.nonce),
    [0, 1, 2, 3],
  );
  assert.deepEqual(c.log, ["send a", "send b", "send c", "send d", "receipt 0x00", "receipt 0x01", "receipt 0x02", "receipt 0x03"]);
  assert.equal(hashes.length, 4);
});

test("bursts are capped, and the next starts only after the last one's receipts", async () => {
  const c = chain();
  await sendRounds(rounds("a", "b", "c", "d", "e"), key, c.sender, 2, 6, 0);
  assert.deepEqual(c.starts, [0, 2, 4]);
  assert.deepEqual(c.log, [
    "send a",
    "send b",
    "receipt 0x00",
    "receipt 0x01",
    "send c",
    "send d",
    "receipt 0x02",
    "receipt 0x03",
    "send e",
    "receipt 0x04",
  ]);
});

test("two rounds for one aggregator never share a burst", async () => {
  const c = chain();
  await sendRounds(rounds("a", "b", "a"), key, c.sender, 50, 6, 0);
  assert.deepEqual(c.log, ["send a", "send b", "receipt 0x00", "receipt 0x01", "send a", "receipt 0x02"]);
});

test("a nonce refused mid-burst: what went out is awaited, the rest is resent on a fresh nonce", async () => {
  const c = chain({ stale: [3] });
  const hashes = await sendRounds(rounds("a", "b", "c", "d"), key, c.sender, 50, 6, 0);
  assert.deepEqual(c.starts, [0, 2]);
  assert.deepEqual(
    c.sends.map((s) => `${s.aggregator}@${s.nonce}`),
    ["a@0", "b@1", "c@2", "d@3"],
  );
  assert.equal(hashes.length, 4);
});

test("a nonce refused on the first send of a burst is retried until the node catches up", async () => {
  const c = chain({ stale: [1, 2] });
  await sendRounds(rounds("a", "b"), key, c.sender, 50, 6, 0);
  assert.deepEqual(c.starts, [0, 0, 0]);
  assert.equal(c.sends.length, 2);
});

test("a nonce still refused after `tries` attempts is thrown", async () => {
  const c = chain({ stale: [1, 2, 3] });
  await assert.rejects(sendRounds(rounds("a"), key, c.sender, 50, 3, 0), /nonce too low/);
  assert.equal(c.sends.length, 0);
});

test("any other send error is thrown at once", async () => {
  const c = chain({ error: 2 });
  await assert.rejects(sendRounds(rounds("a", "b", "c"), key, c.sender, 50, 6, 0), /execution reverted/);
  assert.deepEqual(c.starts, [0]);
});

test("a reverted round is thrown", async () => {
  const c = chain({ reverts: ["b"] });
  await assert.rejects(sendRounds(rounds("a", "b", "c"), key, c.sender, 50, 6, 0), /transmit 0x01 reverted/);
});
