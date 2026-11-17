// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Run: node --test script/testnet/testnet.test.ts (from contracts/)

import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { test } from "node:test";
import { CHAINS, TESTNETS, chainOf } from "../local/lib/env.ts";
import { FIRST_RELEASE, LATER_RELEASE, baseConfig, firstRelease, laterRelease, testValues } from "../local/lib/chain.ts";
import { type HubInput, type TestValues, planHub } from "../local/operator/hub.ts";
import { ADDRESS_ROLES, SIGNER_ROLES, type TestnetRoles, checkRoles, keysOf, parseConfigFile } from "./keys.ts";
import { baseRoles, testnetPatch } from "./testnet.ts";

const addr = (n: number) => `0x${n.toString(16).padStart(40, "0")}`;
const signers = Object.fromEntries(SIGNER_ROLES.map((k, i) => [k, addr(i + 1)]));
const roles = Object.fromEntries(ADDRESS_ROLES.map((k, i) => [k, addr(100 + i)]));
const KEYS = ["KEYSTORE_DIR", "PASSWORD_FILE", "DEPLOYER", "GOVERNANCE", "PAYLOADS_CONTROLLER", "ORACLES"];

test("the committed config template parses, holds every key and only placeholders", () => {
  const t = parseConfigFile(readFileSync(new URL("./test-network-config.example", import.meta.url), "utf8"));
  assert.deepEqual(Object.keys(t).sort(), [...KEYS, ...ADDRESS_ROLES].sort());
  for (const v of Object.values(t)) assert.match(v, /^<[^>]+>(,<[^>]+>)*$/);
  assert.ok(keysOf(t).errors.length > 0, "a placeholder is never taken for a keystore");
  assert.equal(checkRoles(signers, t).length, ADDRESS_ROLES.length, "a placeholder is never taken for an address");
});

test("the config file names every keystore, each once, under absolute paths", () => {
  const dir = process.platform === "win32" ? "C:\\k" : "/k";
  const good = { KEYSTORE_DIR: dir, PASSWORD_FILE: `${dir}p`, DEPLOYER: "a", GOVERNANCE: "b", PAYLOADS_CONTROLLER: "c", ORACLES: "d,e,f,g" };
  const { keys, errors } = keysOf(good);
  assert.deepEqual(errors, []);
  assert.equal(Object.keys(keys!.keystores).length, SIGNER_ROLES.length);
  assert.match(keysOf({ ...good, ORACLES: "d,e,f" }).errors.join(), /ORACLES/);
  assert.match(keysOf({ ...good, GOVERNANCE: "a" }).errors.join(), /its own keystore/);
  assert.match(keysOf({ ...good, KEYSTORE_DIR: "k" }).errors.join(), /KEYSTORE_DIR/);
  assert.match(keysOf({ ...good, DEPLOYER: undefined }).errors.join(), /deployer: no keystore/);
});

test("sound roles pass; a missing signer, a bad address and a shared account are each refused", () => {
  assert.deepEqual(checkRoles(signers, roles), []);
  const { deployer: _d, ...noDeployer } = signers;
  assert.match(checkRoles(noDeployer, roles).join(), /signer deployer: no keystore/);
  assert.match(checkRoles(signers, { ...roles, KEEPER: "0x12" }).join(), /KEEPER: not an address/);
  // The treasury is never the deployer or the keeper.
  assert.match(checkRoles(signers, { ...roles, TREASURY: signers.deployer }).join(), /TREASURY and signer deployer are one account/);
  assert.match(checkRoles(signers, { ...roles, TREASURY: roles.KEEPER!.toUpperCase().replace("0X", "0x") }).join(), /one account/);
});

test("the test networks share the local chains' Hub folders and resolve by name and chain ID", () => {
  assert.equal(chainOf("sepolia").chainId, 11_155_111);
  assert.equal(chainOf("84532").network, "base-sepolia");
  assert.deepEqual(TESTNETS.map((c) => c.hubs), CHAINS.map((c) => c.hubs));
  for (const c of CHAINS) assert.equal(c.testnet, undefined);
});

test("a test network's release deploys the executor before Aave V4 and waits its own delays; the local ones are unchanged", () => {
  const sepolia = chainOf("sepolia");
  const first = firstRelease(sepolia, { normal: 120, short: 60 });
  assert.ok(first.indexOf("place-executor") < first.indexOf("01-aave-v4"));
  assert.ok(first.includes("advance:121") && !first.some((s) => s === "advance:432001"));
  const later = laterRelease(sepolia, { normal: 120, short: 60 });
  assert.deepEqual(later.filter((s) => s.startsWith("advance:")), ["advance:121", "advance:121", "advance:121", "advance:61"]);
  // The local stack's ledgers name these steps: they must not move.
  assert.deepEqual(FIRST_RELEASE.slice(0, 4), ["multicall3", "00-factories", "01-aave-v4", "place-executor"]);
  assert.deepEqual(LATER_RELEASE.filter((s) => s.startsWith("advance:")), ["advance:432001", "advance:432001", "advance:432001", "advance:43201"]);
  assert.equal(first.length, FIRST_RELEASE.length);
  // Only a test network's listing waits for the pools' TWAP history, right before its listing operation.
  assert.equal(later.indexOf("twap-history"), later.indexOf("09-listing-markets") - 1);
  assert.ok(!LATER_RELEASE.includes("twap-history"));
  assert.deepEqual(later.filter((s) => s !== "twap-history").length, LATER_RELEASE.length);
});

test("a test network's market parameters are the local stack's, from test-values.json alone", () => {
  const tv = testValues() as TestValues;
  const roles = {
    signers: Object.fromEntries(SIGNER_ROLES.map((k, i) => [k, addr(i + 1)])),
    addresses: Object.fromEntries(ADDRESS_ROLES.map((k, i) => [k, addr(100 + i)])),
  } as unknown as TestnetRoles;
  // Only these differ: the roles, the release, the delays and gas budget of a public chain, the network's name and
  // ID, and the route depth threshold a chain that is not a development node requires (from the test values too).
  const strip = (cfg: Record<string, any>) => {
    const c = structuredClone(cfg);
    for (const k of ["network", "chainId", "release", "governance", "gasVault", "operatorHelpers", "keepers"]) delete c[k];
    delete c.parameters.timelockNormalDelay;
    delete c.parameters.globals.feeRecipient;
    delete c.chain.operationGasBudget;
    delete c.aaveLocal.aaveDao;
    delete c.aaveLocal.payloadsController;
    delete c.aave.governanceExecutor;
    for (const m of c.listing.markets) for (const r of m.routes) delete r.depthThreshold;
    return c;
  };
  for (const [local, testnet] of [["ethereum", "sepolia"], ["base", "base-sepolia"]] as const) {
    const lc = chainOf(local);
    const tc = chainOf(testnet);
    let l = baseConfig(lc, baseRoles(roles));
    let t = baseConfig(tc, baseRoles(roles), testnetPatch(roles, addr(999), "v9.9.9-rc.1"));
    const dir = new URL(`../deploy/hubs/${tc.hubs}/`, import.meta.url);
    for (const f of readdirSync(dir).filter((x) => x.endsWith(".json") && x !== "world.json").sort()) {
      const input = JSON.parse(readFileSync(new URL(f, dir), "utf8")) as HubInput;
      l = planHub(l, input, tv, lc.chainId).config;
      t = planHub(t, input, tv, tc.chainId).config;
    }
    assert.ok(t.listing.markets.length > 0, `${testnet}: its Hub files list markets`);
    assert.deepEqual(strip(t), strip(l), `${testnet}: every value but the roles and delays is the local stack's`);
    // The values come from test-values.json: the DAO's per debt asset and per token, the market ladder per market.
    for (const d of t.aavePayload.debtAssets) for (const [k, v] of Object.entries(tv.debtAssets?.[d.symbol] ?? {})) if (k in d) assert.deepEqual(d[k], v, `${testnet} ${d.symbol}.${k}`);
    for (const tok of t.listing.tokens) for (const [k, v] of Object.entries({ ...tv.tokens?.default, ...tv.tokens?.[tok.symbol] })) assert.deepEqual(tok[k], v, `${testnet} ${tok.symbol}.${k}`);
    for (const m of t.listing.markets) {
      const mv = { ...tv.markets?.default, ...tv.spokes?.[m.spoke], ...tv.markets?.[m.name] } as Record<string, unknown>;
      for (const k of ["poolRiskFactorBps", "maxLiquidationBonus", "collateralRisk", "marketUsdCap", "topUpSliceUsd", "consistencyToleranceBps"]) assert.deepEqual(m[k], mv[k], `${testnet} ${m.name}.${k}`);
      if (mv.collateralFactorBps !== undefined) assert.equal(m.collateralFactorBps, mv.collateralFactorBps, `${testnet} ${m.name}.collateralFactorBps`);
      for (const r of m.routes) assert.equal(r.depthThreshold, tv.routeDepthThreshold, `${testnet} ${m.name} route depth threshold`);
    }
  }
});
