// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Run: node --test script/local/operator/hub.test.ts (from contracts/)
// The page text the Hub files give every listing: what the app shows by name, FAQ and risk card, as the test networks
// list it. Metadata is frozen at listing, so this is checked before anything is listed.

import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { test } from "node:test";
import { keccak256 } from "viem";
import { parseMetadata } from "../../../../services/convex/convex/lib/metadata.ts";
import { chainOf } from "../lib/env.ts";
import { baseConfig, testValues } from "../lib/chain.ts";
import { baseRoles, testnetPatch } from "../../testnet/testnet.ts";
import { ADDRESS_ROLES, SIGNER_ROLES, type TestnetRoles } from "../../testnet/keys.ts";
import { type HubInput, type TestValues, planHub } from "./hub.ts";

const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}`;
const roles = {
  signers: Object.fromEntries(SIGNER_ROLES.map((k, i) => [k, addr(i + 1)])),
  addresses: Object.fromEntries(ADDRESS_ROLES.map((k, i) => [k, addr(100 + i)])),
} as unknown as TestnetRoles;
const FIVE = ["pairVolatility", "liquidityDepth", "oracle", "smartContract", "expectedIl"];

function planned(testnet: "sepolia" | "base-sepolia") {
  const chain = chainOf(testnet);
  let config = baseConfig(chain, baseRoles(roles), testnetPatch(roles, addr(999), "v9.9.9-rc.1"));
  const dir = new URL(`../../deploy/hubs/${chain.hubs}/`, import.meta.url);
  for (const f of readdirSync(dir).filter((x) => x.endsWith(".json") && x !== "world.json").sort()) {
    config = planHub(config, JSON.parse(readFileSync(new URL(f, dir), "utf8")) as HubInput, testValues() as TestValues, chain.chainId).config;
  }
  return { chain, config };
}

for (const testnet of ["sepolia", "base-sepolia"] as const) {
  test(`${testnet}: Lend, Borrow and market pages carry the app's names and FAQs`, () => {
    const { config } = planned(testnet);
    const names: Record<string, string> = { GHO: "Gho Token", USDC: "USD Coin", USDT: "Tether USD" };
    for (const h of config.aavePayload.hubs) {
      for (const [symbol, c] of Object.entries(h.lendContent ?? {}) as [string, any][]) {
        if (names[symbol]) assert.equal(c.name, names[symbol], `${h.label} lend ${symbol}`);
        assert.ok(!/ on the /.test(c.name), `${h.label} lend ${symbol}: ${c.name}`);
        assert.equal(c.faqs.length, 5, `${h.label} lend ${symbol} FAQs`);
      }
    }
    for (const d of config.listing.debtReserves) {
      if (names[d.symbol]) assert.equal(d.content.name, names[d.symbol], `asset ${d.symbol} on ${d.spoke}`);
      assert.ok(d.content.faqs.length >= 5, `asset ${d.symbol} FAQs`);
    }
    for (const m of config.listing.markets) {
      assert.match(m.content.name, /^\S+ \/ \S+$/, `${m.name}: page name is the pair`);
      assert.ok(m.content.faqs.length >= 5, `${m.name} FAQs`);
    }
  });

  test(`${testnet}: every market's risk card lists the five factors, unrated, with bps only from the test values`, () => {
    const { config } = planned(testnet);
    const tv = testValues() as TestValues;
    for (const m of config.listing.markets) {
      const factors: { id: string; level: string; text: string; bps?: number }[] = m.content.risk.factors;
      const ids = factors.map((f) => f.id);
      for (const id of FIVE.filter((x) => x !== "liquidityDepth")) assert.ok(ids.includes(id), `${m.name} lists ${id}`);
      for (const f of factors.filter((x) => ["oracle", "smartContract", "expectedIl"].includes(x.id))) {
        assert.equal(f.text, "Not rated on the test networks.", `${m.name} ${f.id} text`);
      }
      const given = tv.markets?.[m.name]?.riskFactorBps ?? {};
      for (const f of factors) assert.equal(f.bps, given[f.id], `${m.name} ${f.id}: bps only from the test values`);
    }
  });

  test(`${testnet}: the pages pass the app's metadata loader`, () => {
    const { chain, config } = planned(testnet);
    const page = (c: any) => ({ stats: [], history: [], ...c });
    const entries = [
      ...config.listing.markets.map((m: any, i: number) => ({ scope: "pool", key: String(i + 1), ...page(m.content) })),
      ...config.listing.debtReserves.map((d: any, i: number) => ({ scope: "asset", key: `${addr(500)}:${i}`, ...page(d.content) })),
      ...config.aavePayload.hubs.flatMap((h: any, j: number) =>
        Object.values(h.lendContent ?? {}).map((c: any, i: number) => ({ scope: "lend", key: `${addr(600 + j)}:${i}`, ...page(c) })),
      ),
    ];
    const bytes = new TextEncoder().encode(`${JSON.stringify({ version: 2, chainId: chain.chainId, entries }, null, 2)}\n`);
    assert.doesNotThrow(() => parseMetadata(bytes, keccak256(bytes), chain.chainId));
  });
}
