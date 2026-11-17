// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Run: node --test script/e2e/refresh-feeds.test.ts (from contracts/)
// The live refresh's retry of a transmit whose nonce a lagging RPC node refused: no network.

import assert from "node:assert/strict";
import { test } from "node:test";
import { isStaleNonce, retryStaleNonce } from "./refresh-feeds.ts";

/** A send that fails with each of `errors` in turn, then returns "0xabc"; `calls` counts the attempts. */
function sender(errors: string[]) {
  const s = {
    calls: 0,
    send: async () => {
      const e = errors[s.calls++];
      if (e !== undefined) throw new Error(e);
      return "0xabc";
    },
  };
  return s;
}

test("a stale nonce is recognised in both wordings, a revert is not", () => {
  assert.equal(isStaleNonce(new Error("nonce too low: next nonce 349, tx nonce 348")), true);
  assert.equal(isStaleNonce(new Error("Nonce provided for the transaction is lower than the current nonce of the account")), true);
  assert.equal(isStaleNonce(new Error("execution reverted")), false);
});

test("a send refused twice for a stale nonce returns its value on the third call", async () => {
  const s = sender(["nonce too low: next nonce 349, tx nonce 348", "nonce too low: next nonce 349, tx nonce 348"]);
  assert.equal(await retryStaleNonce(s.send, 6, 0), "0xabc");
  assert.equal(s.calls, 3);
});

test("any other error is thrown after one call", async () => {
  const s = sender(["execution reverted"]);
  await assert.rejects(retryStaleNonce(s.send, 6, 0), /execution reverted/);
  assert.equal(s.calls, 1);
});

test("a nonce still stale after `tries` calls is thrown", async () => {
  const s = sender(Array<string>(10).fill("nonce too low"));
  await assert.rejects(retryStaleNonce(s.send, 4, 0), /nonce too low/);
  assert.equal(s.calls, 4);
});
