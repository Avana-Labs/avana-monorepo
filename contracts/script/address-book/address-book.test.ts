// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The address book generator on a small fixture deployment (fixtures/ethereum-sepolia/: one Hub, a Uniswap v3 and a
// Uniswap v4 integration with one pool each, listed as a Full range and a Custom range market, made-up addresses, in
// the shapes of manifest.json, avana.json, markets.json, coverage.json and operation-listing-activate.json): the three
// sections it writes, the refusals (rehearsal, other chain, a deploy output that differs from the manifest,
// placeholder, missing value), the rows a deployment legitimately lacks, and that rerunning one network keeps the
// others.
// Run: node --test script/address-book/address-book.test.ts (from contracts/)

import assert from "node:assert/strict";
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { isPlaceholder } from "./model.ts";
import { assemble, generate, parseArgs, readSections } from "./address-book.ts";
import { cell, pct, seconds, units } from "./render.ts";

const FIXTURE = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "ethereum-sepolia");
const DATE = "2026-11-17";

/** A writable copy of the fixture and an empty output folder; `edit` changes one JSON file of the copy. */
function workspace() {
  const root = mkdtempSync(join(tmpdir(), "address-book-"));
  const dep = join(root, "deployment");
  cpSync(FIXTURE, dep, { recursive: true });
  const out = join(root, "out");
  const edit = (file: string, f: (j: any) => void) => {
    const p = join(dep, file);
    const j = JSON.parse(readFileSync(p, "utf8"));
    f(j);
    writeFileSync(p, JSON.stringify(j, null, 2));
  };
  const read = (page: string) => readFileSync(join(out, `${page}.md`), "utf8");
  return { root, dep, out, edit, read, done: () => rmSync(root, { recursive: true, force: true }) };
}

const manifest = () => JSON.parse(readFileSync(join(FIXTURE, "manifest.json"), "utf8"));

/** Every network section of a written page, joined. */
const sections = (page: string) => [...readSections(page).values()].join("\n");

/** Moves the copy to another chain: the manifest, avana.json and the activation operation. */
function moveChain(w: ReturnType<typeof workspace>, chainId: number, network: string, f: (j: any) => void = () => {}) {
  w.edit("manifest.json", (j) => {
    j.chainId = chainId;
    j.network = network;
    f(j);
  });
  w.edit("avana.json", (j) => {
    j.chainId = chainId;
  });
}

test("writes the network's section of all three pages from the deployment", () => {
  const w = workspace();
  try {
    generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE });
    const m = manifest();
    const addresses = w.read("addresses");
    assert.match(addresses, /^---\ntitle: Contract Addresses\n/);
    assert.match(addresses, /\nupdated: 2026-11-17\n/);
    assert.match(addresses, /## Ethereum Sepolia\n- network: ethereum-sepolia\n- chainId: 11155111\n- explorer: https:\/\/sepolia\.etherscan\.io\n/);
    assert.ok(addresses.includes("1 Hub with 1 Lend Spoke and 2 CDP Spokes, and 4 markets on 2 pools"));
    assert.ok(addresses.includes(`| stable | Aave V4 Hub, tier 1.`) && addresses.includes(m.aave.hubs[0].address));
    assert.ok(addresses.includes("| uniV3Stable | stable | Aave V4 CDP Spoke where Uniswap v3 positions are collateral for borrowing GHO and USDC."));
    assert.ok(addresses.includes("| uniV4Stable | stable | Aave V4 CDP Spoke where Uniswap v4 positions are collateral for borrowing GHO and USDC."));
    assert.ok(addresses.includes(`| lendStable | Supply-only Aave V4 Spoke`));
    // Avana's core: the AccessManager and each integration's stack, from the manifest and avana.json alike.
    assert.ok(addresses.includes(`| AccessManager | OpenZeppelin AccessManager`) && addresses.includes(m.avana.accessManager.address));
    for (const x of m.avana.integrations) {
      const v = x.kind === "uniswap-v3" ? "Uniswap v3" : "Uniswap v4";
      for (const [k, name] of [["lpVault", "LPVault"], ["riskModule", "RiskModule"], ["liquidationModule", "LiquidationModule"], ["aaveAdapter", "AaveAdapter"], ["flashloanRepay", "FlashloanRepay"]]) {
        assert.match(addresses, new RegExp(`\\| ${v} ${name} \\| [^\\n]* \\| ${x[k].address} \\|`));
      }
    }
    for (const l of m.coverage.firstLossReserves) assert.match(addresses, new RegExp(`\\| First-Loss Reserve, ${l.symbol} \\(stable Hub\\) \\| [^\\n]* \\| ${l.address} \\|`));
    for (const l of m.coverage.daoDeficitOffsets) assert.match(addresses, new RegExp(`\\| DAO deficit offset, ${l.symbol} \\(stable Hub\\) \\| [^\\n]* \\| ${l.address} \\|`));
    // Two markets per pool, each with its vault token and LPOracle; each RiskModule numbers its own markets.
    for (const x of m.markets) {
      const spoke = m.aave.borrowSpokes.find((s: any) => s.address === x.spoke).label;
      const range = x.kind === "full-range" ? "Full range" : "Custom range";
      assert.ok(addresses.includes(`| ${spoke} | ${x.marketId} | ${x.name} | ${range} | USDC/USDT | ${x.vaultToken.address} | ${x.lpOracle.address} |`));
    }
    assert.ok(addresses.includes(`| FlashLiquidator 1 (Uniswap v3) |`) && addresses.includes(m.avana.flashLiquidators[0].address));
    assert.ok(addresses.includes("| Aave V4 hubConfigurator | Aave DAO payloads configure the Hubs through it. |"));
    assert.ok(addresses.includes("| Uniswap v4 PoolManager |") && addresses.includes(m.uniswapV4.poolManager.address));
    // No Slipstream integration: its externals are left out; Hubs and Spokes appear once, in their own tables.
    assert.ok(!addresses.includes("CLFactory") && !addresses.includes("| Spoke uniV3Stable |") && !addresses.includes("| Hub stable |"));
    assert.ok(addresses.includes("| GHO | Debt asset borrowable on uniV3Stable and uniV4Stable. A test stand-in. |"));
    assert.ok(addresses.includes("| USDT | Pool token of markets on uniV3Stable and uniV4Stable. A test stand-in. |"));
    assert.ok(!addresses.includes("sequencer uptime feed"));

    const parameters = w.read("parameters");
    assert.ok(parameters.includes("| uniV3Stable | 1 | uni-USDC-USDT-100 (USDC/USDT) | Full range | 0xf100000000000000000000000000000000000035 | -887272 to 887272 | 90% | 4.5% | 5,000,000 | 6 |"));
    assert.ok(parameters.includes("| uniV3Stable | 2 | uni-USDC-USDT-100 (USDC/USDT) | Custom range | 0xf100000000000000000000000000000000000035 | -101 to 100 | 90% | 4.5% | 5,000,000 | 6 |"));
    // A Uniswap v4 market's Pool is its PoolId.
    assert.ok(parameters.includes(`| uniV4Stable | 2 | univ4-USDC-USDT-100 (USDC/USDT) | Custom range | ${m.markets[3].pool} | -101 to 100 | 90% | 4.5% | 2,000,000 | 6 |`));
    assert.ok(parameters.includes(`| uniV3Stable | stable | USDC | 1 | 6 | ${m.coverage.firstLossReserves[1].address} |`));
    assert.ok(parameters.includes("| stable | GHO | 100,000 GHO | 75,000 GHO |"));
    assert.ok(parameters.includes("| stable | USDC | 1,000,000 USDC | 75,000 USDC |"));
    assert.ok(parameters.includes("| USDT / USD (primary) | 0xf100000000000000000000000000000000000062 | 86,400 s (1 day) | uniV3Stable market 1, uniV3Stable market 2, uniV4Stable market 1, uniV4Stable market 2 |"));
    assert.ok(parameters.includes("| Governance delay | 345,600 s (4 days) |"));
    assert.ok(parameters.includes("| Keeper top-up | 3 to 10 ETH |"));
    assert.ok(parameters.includes("| Sequencer uptime feed | None | Ethereum has no sequencer"));
    assert.ok(parameters.includes("## All networks"));

    const access = w.read("access-controls");
    assert.ok(access.includes("| Governance Safe | On this network a single account, not a Safe; the intended holder is a 4-of-7 Safe. `AVANA_GOVERNANCE_ROLE`"));
    assert.ok(access.includes(`| Liquidation keeper | Registered in the keeper registry of every RiskModule;`) && access.includes(`| ${m.roles.keepers[0]} |`));
    assert.ok(access.includes("Also the `OPERATOR` of the Uniswap v3 FlashLiquidator and the Uniswap v4 FlashLiquidator."));
    assert.ok(access.includes(`| Keeper top-up wallet |`) && access.includes(m.roles.keeperTopUp.wallet));
    assert.ok(access.includes("| Governance delay (`AVANA_GOVERNANCE_ROLE`) | 345,600 s (4 days) |"));

    for (const page of ["addresses", "parameters", "access-controls"]) {
      const text = w.read(page);
      assert.ok(!text.includes("\r"), `${page} has LF line endings`);
      assert.ok(!/@\{|MISSING|undefined|NaN/.test(text), `${page} holds no unresolved value`);
      assert.ok(!/\blaunch\b|sandbox/i.test(text), `${page} avoids the excluded wording`);
      // The pre-refactor system is gone from the pages, templates included.
      const gone = /MarketRegistry|AvanaTimelock|Timelock|ParameterStore|DebtOracle|LPVaultSwap|PayoutEscrow|ProxyManager|VaultTokenFactory|AvanaGasVault|\bLens\b|MAX_MARKET_COUNT|MIN_NORMAL_DELAY|SHORT_DELAY|normalDelay|routeDepthThreshold|swap route|[Cc]redit line|twapWindow/;
      assert.ok(!gone.test(text), `${page} names no removed contract or setting: ${gone.exec(text)?.[0]}`);
    }
  } finally {
    w.done();
  }
});

test("refuses a rehearsal's folder unless allowed", () => {
  const w = workspace();
  try {
    writeFileSync(join(w.dep, ".rehearsal"), "");
    assert.throws(() => generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE }), /rehearsal/);
    assert.ok(!existsSync(w.out));
    generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE, allowRehearsal: true });
    assert.ok(existsSync(join(w.out, "addresses.md")));
  } finally {
    w.done();
  }
});

test("refuses a manifest of another chain", () => {
  const w = workspace();
  try {
    assert.throws(() => generate({ network: "base-sepolia", deployment: w.dep, out: w.out, date: DATE }), /is for chain 11155111, not base-sepolia \(84532\)/);
    assert.throws(() => generate({ network: "nowhere", deployment: w.dep, out: w.out }), /unknown network/);
  } finally {
    w.done();
  }
});

test("lists every placeholder and missing value, and writes nothing", () => {
  const w = workspace();
  try {
    w.edit("manifest.json", (j) => {
      j.coverage.firstLossReserves[1].address = "0x0000000000000000000000000000000000000002";
      j.external = j.external.filter((e: any) => e.name !== "USDT");
    });
    w.edit("operation-listing-activate.json", (j) => {
      delete j.delay;
    });
    rmSync(join(w.dep, "markets.json"));
    assert.throws(() => generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE }), /no markets\.json in .*: run the deploy step that writes it/);
    cpSync(join(FIXTURE, "markets.json"), join(w.dep, "markets.json"));
    let message = "";
    try {
      generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE });
    } catch (e) {
      message = (e as Error).message;
    }
    assert.match(message, /nothing written/);
    assert.match(message, /placeholder: First-Loss Reserve of USDC on Hub stable/);
    assert.match(message, /missing: symbol of token 0xf10000000000000000000000000000000000002c/);
    assert.match(message, /missing: operation-listing-activate\.json delay/);
    assert.ok(!existsSync(w.out));
  } finally {
    w.done();
  }
});

test("refuses deploy output that differs from the manifest, and a governance delay outside 4 to 5 days", () => {
  const w = workspace();
  try {
    w.edit("markets.json", (j) => {
      j.vaultTokens[0] = "0xf1000000000000000000000000000000000000ff";
    });
    w.edit("avana.json", (j) => {
      j.riskModules[1] = "0xf1000000000000000000000000000000000000fe";
    });
    w.edit("operation-listing-activate.json", (j) => {
      j.delay = 60;
    });
    let message = "";
    try {
      generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE });
    } catch (e) {
      message = (e as Error).message;
    }
    assert.match(message, /the manifest and markets\.json differ: market 1 of integration 1 vault token/);
    assert.match(message, /the manifest and avana\.json differ: integration 3 riskModule/);
    assert.match(message, /delay 60 s is outside the governance delay's 4 to 5 days/);
    assert.ok(!existsSync(w.out));
  } finally {
    w.done();
  }
});

test("a local chain has no explorer line and says how it is deployed", () => {
  const w = workspace();
  try {
    moveChain(w, 31337, "ethereum");
    generate({ network: "local-ethereum", deployment: w.dep, out: w.out, date: DATE });
    const parameters = w.read("parameters");
    assert.ok(parameters.includes("## Local Ethereum development chain\n- network: local-ethereum\n- chainId: 31337\n\n"));
    assert.ok(w.read("addresses").includes("A local development chain (chain ID 31337)"));
    assert.ok(w.read("addresses").includes("On this local development chain these are test tokens."));
  } finally {
    w.done();
  }
});

test("a sequencer feed adds its row; a chain without an Aave V3 Pool has no FlashloanRepay", () => {
  const w = workspace();
  try {
    const feed = "0xf300000000000000000000000000000000000001";
    moveChain(w, 84532, "base-sepolia", (j) => {
      j.sequencerFeed = feed;
      for (const x of j.avana.integrations) x.flashloanRepay.address = "0x0000000000000000000000000000000000000000";
    });
    w.edit("avana.json", (j) => {
      j.flashloanRepays = j.flashloanRepays.map(() => "0x0000000000000000000000000000000000000000");
    });
    generate({ network: "base-sepolia", deployment: w.dep, out: w.out, date: DATE });
    const addresses = w.read("addresses");
    assert.ok(addresses.includes(`| Chainlink L2 sequencer uptime feed | Recorded in the release manifest; no Avana contract reads it. | ${feed} |`));
    assert.ok(addresses.includes("| Uniswap v3 FlashloanRepay | Not deployed on this network: the chain has no Aave V3 Pool. | — |"));
    assert.ok(w.read("parameters").includes("| Sequencer uptime feed | Chainlink L2 sequencer uptime feed | Recorded in the release manifest; no Avana contract reads it."));
    // A sequencer feed on a chain without a sequencer is refused.
    const v = workspace();
    try {
      v.edit("manifest.json", (j) => {
        j.sequencerFeed = feed;
      });
      assert.throws(() => generate({ network: "ethereum-sepolia", deployment: v.dep, out: v.out, date: DATE }), /a sequencer feed is recorded on a chain without a sequencer/);
    } finally {
      v.done();
    }
  } finally {
    w.done();
  }
});

test("rerunning one network keeps the other networks' sections and is stable", () => {
  const w = workspace();
  try {
    generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE });
    const first = w.read("addresses");
    // Another network's section, as an earlier run wrote it.
    const other = "## Base Sepolia\n- network: base-sepolia\n- chainId: 84532\n\nKept as it is.";
    const kept = readSections(first);
    kept.set("base-sepolia", other);
    writeFileSync(join(w.out, "addresses.md"), assemble(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "templates", "addresses.md"), "utf8"), kept, DATE));
    generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE });
    const again = w.read("addresses");
    assert.equal(readSections(again).get("base-sepolia"), other);
    assert.equal(readSections(again).get("ethereum-sepolia"), readSections(first).get("ethereum-sepolia"));
    assert.ok(again.indexOf("network: ethereum-sepolia") < again.indexOf("network: base-sepolia"), "sections follow the network order");
    assert.ok(sections(again).includes("Kept as it is."));
    generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE });
    assert.equal(w.read("addresses"), again);
  } finally {
    w.done();
  }
});

test("helpers: arguments, placeholders, percentages, durations and token units", () => {
  assert.deepEqual(parseArgs(["--network", "local-base", "--deployment", "d", "--allow-rehearsal"]), { network: "local-base", deployment: "d", allowRehearsal: true });
  assert.throws(() => parseArgs(["--network", "local-base"]), /usage/);
  assert.throws(() => parseArgs(["--bogus"]), /unknown argument/);
  assert.throws(() => parseArgs(["--network", "local-base", "--deployment", "d", "--config", "c.json"]), /unknown argument --config/);
  assert.ok(isPlaceholder("0x0000000000000000000000000000000000000001"));
  assert.ok(isPlaceholder(`0x${"0".repeat(56)}12345678`));
  assert.ok(!isPlaceholder("0xf100000000000000000000000000000000000001"));
  assert.deepEqual([8000, 650, 8889, 50, 1, 0].map(pct), ["80%", "6.5%", "88.89%", "0.5%", "0.01%", "0%"]);
  assert.deepEqual([60, 120, 3600, 43_200, 345_600, 1_800].map(seconds), ["60 s", "120 s", "3,600 s (1 hour)", "43,200 s (12 hours)", "345,600 s (4 days)", "1,800 s"]);
  assert.equal(units("1000000000000", 6), "1,000,000");
  assert.equal(units("1500000000000000000", 18), "1.5");
  assert.equal(units("7", undefined), "MISSING");
});

test("a table cell escapes backslashes before pipes", () => {
  // Backslashes first: otherwise `a\|b` would become `a\\|b`, whose pipe ends the cell.
  assert.equal(cell("a\\|b"), "a\\\\\\|b");
  assert.equal(cell("x | y \\ z"), "x \\| y \\\\ z");
  assert.equal(cell("plain"), "plain");
});
