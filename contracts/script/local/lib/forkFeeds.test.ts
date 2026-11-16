// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Run: node --test script/local/lib/forkFeeds.test.ts (from contracts/)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";
import type { Address } from "viem";
import { loadForkFeeds, planFeeds, SLOTS, twapUsdAnswer, worldFeeds } from "./forkFeeds.ts";

const P = "0x00000000000000000000000000000000000000f1";
const file = JSON.parse(readFileSync(new URL("../fork-feeds.json", import.meta.url), "utf8"));

test("the committed fork-feeds.json loads for both chains, with no feed address written yet", () => {
  for (const net of ["ethereum", "base"]) {
    const e = loadForkFeeds(file, net);
    assert.ok(Object.keys(e).length > 10);
    for (const x of Object.values(e)) if (x.primary !== undefined) assert.equal(x.primary, "");
  }
});

test("loadForkFeeds refuses an entry with both or neither source, and a TWAP pair that is not the token's", () => {
  assert.throws(() => loadForkFeeds({ n: { A: { primary: P, twap: { pair: "A/B", quote: "B" } } } }, "n"), /either primary/);
  assert.throws(() => loadForkFeeds({ n: { A: {} } }, "n"), /either primary/);
  assert.throws(() => loadForkFeeds({ n: { A: { twap: { pair: "C/B", quote: "B" } } } }, "n"), /must be A/);
  assert.throws(() => loadForkFeeds({ n: { A: { primary: "0x12" } } }, "n"), /not an address/);
});

test("planFeeds: a real primary keeps its proxy and mocks the rest; a TWAP token mocks all four", () => {
  const plan = planFeeds({ USDC: { primary: P }, AUSD: { twap: { pair: "AUSD/USDC", quote: "USDC" } } }, ["USDC", "AUSD", "USDC"]);
  assert.deepEqual(plan.USDC!.primary, { kind: "real", proxy: P });
  for (const s of ["alternate", "standby", "second"] as const) assert.deepEqual(plan.USDC![s], { kind: "mock", seed: { from: "primary" } });
  for (const s of SLOTS) assert.deepEqual(plan.AUSD![s], { kind: "mock", seed: { from: "twap", pair: "AUSD/USDC", quote: "USDC" } });
});

test("planFeeds refuses a missing token, an unread feed and a quote with no feed, listing each", () => {
  assert.throws(
    () => planFeeds({ A: { primary: "" }, B: { twap: { pair: "B/C", quote: "C" } }, C: { twap: { pair: "C/A", quote: "A" } } }, ["A", "B", "D"]),
    (e: Error) => /A: primary feed not read/.test(e.message) && /B: quote C needs a real feed/.test(e.message) && /D: no entry/.test(e.message),
  );
});

test("twapUsdAnswer: WETH priced from a USDC/WETH pool (USDC token0, 6 vs 18 decimals)", () => {
  // ETH at 3,000 USDC: token0 (USDC) in token1 (WETH) is 1/3000 = 1.0001^tick x 1e-12.
  const tick = Math.round(Math.log(1e12 / 3000) / Math.log(1.0001));
  const usdc = 100_000_000n; // $1.00, 8 decimals
  const a = twapUsdAnswer({ meanTick: tick, tokenIsToken0: false, tokenDecimals: 18, quoteDecimals: 6, quoteAnswer: usdc, quoteFeedDecimals: 8, feedDecimals: 8 });
  assert.ok(Math.abs(Number(a) / 1e8 - 3000) / 3000 < 1e-4, `${a}`);
  // The same pool prices USDC in WETH the other way round.
  const b = twapUsdAnswer({ meanTick: tick, tokenIsToken0: true, tokenDecimals: 6, quoteDecimals: 18, quoteAnswer: a, quoteFeedDecimals: 8, feedDecimals: 8 });
  assert.ok(Math.abs(Number(b) / 1e8 - 1) < 1e-4, `${b}`);
});

test("twapUsdAnswer: equal decimals at tick 0 is the quote's price, in the feed's decimals", () => {
  assert.equal(twapUsdAnswer({ meanTick: 0, tokenIsToken0: true, tokenDecimals: 8, quoteDecimals: 8, quoteAnswer: 9_500_000_000_000n, quoteFeedDecimals: 8, feedDecimals: 8 }), 9_500_000_000_000n);
  assert.equal(twapUsdAnswer({ meanTick: 0, tokenIsToken0: true, tokenDecimals: 8, quoteDecimals: 8, quoteAnswer: 100_000_000n, quoteFeedDecimals: 8, feedDecimals: 18 }), 10n ** 18n);
});

test("worldFeeds writes each slot's proxy and aggregator, and keeps a real feed's proxy", () => {
  const plan = planFeeds({ USDC: { primary: P } }, ["USDC"]);
  const at = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
  const deployed = { USDC: { primary: { proxy: P as Address, aggregator: at(2) }, alternate: { proxy: at(3), aggregator: at(4) }, standby: { proxy: at(5), aggregator: at(6) }, second: { proxy: at(7), aggregator: at(8) } } };
  const w = worldFeeds(plan, deployed);
  assert.equal(w.USDC!.primary!.toLowerCase(), P);
  assert.equal(w.USDC!.secondAggregator!.toLowerCase(), at(8));
  assert.throws(() => worldFeeds(plan, { USDC: { ...deployed.USDC, primary: { proxy: at(9), aggregator: at(2) } } }), /must stay/);
});
