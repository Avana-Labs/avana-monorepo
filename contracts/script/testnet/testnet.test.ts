// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Run: node --test script/testnet/testnet.test.ts (from contracts/)

import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { CHAINS, TESTNETS, chainOf } from "../local/lib/env.ts";
import { FIRST_RELEASE, LATER_RELEASE, baseConfig, firstRelease, laterRelease, testValues } from "../local/lib/chain.ts";
import { type HubInput, type TestValues, planHub } from "../local/operator/hub.ts";
import { ADDRESS_ROLES, SIGNER_ROLES, type TestnetRoles, checkRoles, keysOf, parseConfigFile } from "./keys.ts";
import {
  NATIVE_V4_POOL_USD, WORLD_STEP, baseRoles, isNativeV4Pool, nativeV4PoolWei, syncNativeV4Pools, testnetPatch,
} from "./testnet.ts";

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
  assert.ok(!first.some((s) => s.startsWith("12-")));
  assert.equal(first.length, FIRST_RELEASE.length);
  // Only a test network's listing waits for the pools' TWAP history, right before its listing operation.
  assert.equal(later.indexOf("twap-history"), later.indexOf("09-listing-markets") - 1);
  assert.ok(!LATER_RELEASE.includes("twap-history"));
  assert.deepEqual(later.filter((s) => s !== "twap-history").length, LATER_RELEASE.length);
});

test("a test network's native-ETH Uniswap v4 pools take a few dollars of the deployer's ETH; the other v4 pools are the local stack's", () => {
  const r = {
    signers: Object.fromEntries(SIGNER_ROLES.map((k, i) => [k, addr(i + 1)])),
    addresses: Object.fromEntries(ADDRESS_ROLES.map((k, i) => [k, addr(100 + i)])),
  } as unknown as TestnetRoles;
  for (const [local, testnet] of [["ethereum", "sepolia"], ["base", "base-sepolia"]] as const) {
    const l = baseConfig(chainOf(local), baseRoles(r));
    const t = baseConfig(chainOf(testnet), baseRoles(r), testnetPatch(r, addr(999), "v9.9.9-rc.1"));
    const lp = l.world.uniswapV4Pools as Record<string, any>[];
    const tp = t.world.uniswapV4Pools as Record<string, any>[];
    assert.deepEqual(tp.map((p) => p.name), lp.map((p) => p.name), `${testnet}: the same v4 pools`);
    const native = tp.filter(isNativeV4Pool).map((p) => p.name).sort();
    assert.deepEqual(native, ["ETH-USDC-v4-500", "wstETH-ETH-v4-100"], `${testnet}: the native-ETH v4 pools`);
    for (const [i, p] of tp.entries()) {
      if (isNativeV4Pool(p)) assert.equal(p.usd, NATIVE_V4_POOL_USD, `${testnet} ${p.name}`);
      else assert.deepEqual(p, lp[i], `${testnet} ${p.name}: unchanged`);
    }
    // The local stack keeps its millions.
    assert.ok(lp.filter(isNativeV4Pool).every((p) => p.usd >= 1_000_000));
    // The ETH step 02 takes from the deployer, as 02_DeployWorld computes it: _amountForUsd(ETH, usd / 2), ETH priced
    // at WETH's price8 ($3,000): $5 a pool, 1,666,666,666,666,666 wei each.
    const price8 = BigInt(t.world.tokens.find((x: Record<string, any>) => x.symbol === "WETH").price8);
    const each = (BigInt(NATIVE_V4_POOL_USD) / 2n) * 10n ** 26n / price8;
    assert.equal(each, 1_666_666_666_666_666n);
    const wei = nativeV4PoolWei(t);
    assert.equal(wei, each * BigInt(native.length));
    assert.ok(wei > 0n && wei <= NATIVE_V4_TARGET_WEI, `${testnet}: ${wei} wei over the ${NATIVE_V4_TARGET_WEI} wei target`);
    assert.ok(nativeV4PoolWei(l) > 100n * 10n ** 18n, "the local stack's native pools take hundreds of ETH");
  }
});

test("a rerun's config takes the small native-ETH v4 pools until the world step passes, and only then", () => {
  const r = {
    signers: Object.fromEntries(SIGNER_ROLES.map((k, i) => [k, addr(i + 1)])),
    addresses: Object.fromEntries(ADDRESS_ROLES.map((k, i) => [k, addr(100 + i)])),
  } as unknown as TestnetRoles;
  assert.equal(WORLD_STEP, "first:02-test-world");
  assert.ok(firstRelease(chainOf("sepolia"), { normal: 120, short: 60 }).includes(WORLD_STEP.slice("first:".length)));
  // A config an earlier run wrote: the patch without the native pools' size, as before this change.
  const old = baseConfig(chainOf("sepolia"), baseRoles(r), testnetPatch(r, addr(999), "v9.9.9-rc.1"));
  for (const p of old.world.uniswapV4Pools) if (p.name === "ETH-USDC-v4-500") p.usd = 2_000_000;
  for (const p of old.world.uniswapV4Pools) if (p.name === "wstETH-ETH-v4-100") p.usd = 1_000_000;
  const pass = { outcome: "pass" as const, detail: "", at: "", seconds: 0 };
  const fail = { ...pass, outcome: "fail" as const };
  const passed = Object.fromEntries(["multicall3", "00-factories", "place-executor", "01-aave-v4"].map((s) => [`first:${s}`, pass]));
  const dir = mkdtempSync(join(tmpdir(), "native-v4-"));
  try {
    const p = join(dir, "config-base.json");
    const write = () => writeFileSync(p, `${JSON.stringify(old, null, 2)}\n`);
    const read = () => JSON.parse(readFileSync(p, "utf8")) as Record<string, any>;
    const status = (steps: Record<string, typeof pass>) => ({ config: "deployments-local/sepolia/config-base.json", steps });
    // The world step has passed: the config is left as it is.
    write();
    assert.deepEqual(syncNativeV4Pools(p, status({ ...passed, [WORLD_STEP]: pass })), []);
    assert.deepEqual(read(), old);
    // No config recorded yet (a first run writes it patched): nothing to do.
    assert.deepEqual(syncNativeV4Pools(p, { steps: passed }), []);
    // The steps before the world passed, the world step failed or not run yet: the native pools shrink, nothing else.
    for (const steps of [{ ...passed, [WORLD_STEP]: fail }, passed, {}]) {
      write();
      assert.deepEqual(syncNativeV4Pools(p, status(steps)).sort(), ["ETH-USDC-v4-500", "wstETH-ETH-v4-100"]);
      const after = read();
      for (const q of after.world.uniswapV4Pools) assert.equal(q.usd, isNativeV4Pool(q) ? NATIVE_V4_POOL_USD : old.world.uniswapV4Pools.find((x: Record<string, any>) => x.name === q.name).usd);
      const rest = structuredClone(after);
      const was = structuredClone(old);
      rest.world.uniswapV4Pools = was.world.uniswapV4Pools = [];
      assert.deepEqual(rest, was);
      assert.ok(nativeV4PoolWei(after) <= NATIVE_V4_TARGET_WEI);
      // Again: already small, nothing changes.
      assert.deepEqual(syncNativeV4Pools(p, status(steps)), []);
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
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
    for (const k of ["network", "chainId", "release", "governance", "operatorHelpers", "keepers"]) delete c[k];
    delete c.parameters.timelockNormalDelay;
    delete c.parameters.globals.feeRecipient;
    delete c.chain.operationGasBudget;
    delete c.aaveLocal.aaveDao;
    delete c.aaveLocal.payloadsController;
    delete c.aave.governanceExecutor;
    for (const m of c.listing.markets) for (const r of m.routes) delete r.depthThreshold;
    for (const p of c.world.uniswapV4Pools) if (isNativeV4Pool(p)) delete p.usd;
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
