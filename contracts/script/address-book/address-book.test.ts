// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The address book generator on a small fixture deployment (fixtures/ethereum-sepolia/: one Hub, a Uniswap v3 and a
// Uniswap v4 Stable Spoke with one market each, made-up addresses): the three sections it writes, the refusals
// (rehearsal, other chain, placeholder, missing value), the rows a deployment legitimately lacks, and that rerunning
// one network keeps the others.
// Run: node --test script/address-book/address-book.test.ts (from contracts/)

import assert from "node:assert/strict";
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { isPlaceholder } from "./model.ts";
import { assemble, generate, parseArgs, readSections } from "./address-book.ts";
import { cell, pct, seconds } from "./render.ts";

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

test("writes the network's section of all three pages from the deployment", () => {
  const w = workspace();
  try {
    generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE });
    const m = manifest();
    const addresses = w.read("addresses");
    assert.match(addresses, /^---\ntitle: Contract Addresses\n/);
    assert.match(addresses, /\nupdated: 2026-11-17\n/);
    assert.match(addresses, /## Ethereum Sepolia\n- network: ethereum-sepolia\n- chainId: 11155111\n- explorer: https:\/\/sepolia\.etherscan\.io\n/);
    assert.ok(addresses.includes(`| Avana Ethereum Hub | Standard Aave V4 Hub`));
    assert.ok(addresses.includes(m.aave.hubs[0].address));
    assert.ok(addresses.includes("### Uniswap v3 Spokes") && addresses.includes("### Uniswap v4 Spokes") && !addresses.includes("### Aero Slipstream Spokes"));
    assert.ok(addresses.includes("hookless stablecoin pools are collateral for borrowing GHO and USDC"));
    // Vault tokens, LPOracles and market IDs, one row per market.
    for (const x of m.markets) assert.ok(addresses.includes(`| ${x.marketId} | ${x.vaultToken.address} | ${x.lpOracle.address} |`));
    // No gas vault in this deployment: the row stays, marked as not deployed.
    assert.ok(addresses.includes("| AvanaGasVault | Holds the chain's native gas token and refills Avana's own keeper signers up to a per-signer cap over any 24 hours. Immutable. | Not deployed on this network |"));
    // The test network's GHO price stand-in; USDC is priced by its own Chainlink feed, with no oracle contract of Avana's.
    assert.ok(addresses.includes("| Fixed $1 price source, GHO |"));
    assert.ok(!addresses.includes("DebtOracle"));
    assert.ok(!addresses.includes("sequencer uptime feed"));

    const parameters = w.read("parameters");
    assert.ok(parameters.includes("| Uniswap v3 Stable | USDC/USDT LP | 80% | 4% | No | 400 bps | 0% | Max | No |"));
    assert.ok(parameters.includes("| Spoke | Market | Pool | v3 reference pool | Fee tier or tick spacing |"));
    assert.ok(parameters.includes(m.markets.find((x: any) => x.poolId).poolId));
    assert.ok(parameters.includes("| `SHORT_DELAY` | 60 s |"));
    assert.ok(parameters.includes("| `normalDelay` | 432,000 s (5 days) |"));
    // The floor of a test network's timelock (minNormalDelay of chain 11155111), not the 345,600 s of a public chain.
    assert.ok(parameters.includes("| `MIN_NORMAL_DELAY` | 60 s |"));
    assert.ok(parameters.includes("| `MIN_NORMAL_DELAY` | Per network |"));
    assert.ok(parameters.includes("| `routeDepthThreshold` | 5,000,000 |"));
    assert.ok(!parameters.includes("pokeMinGas"));
    assert.ok(parameters.includes("| Uniswap v3 Stable | 156 bps | 50 bps |"));
    assert.ok(!parameters.includes("Credit line"));
    assert.ok(parameters.includes("[Fixed $1 price source, GHO](/developers/reference/addresses?network=ethereum-sepolia#avana-core)"));
    assert.ok(parameters.includes("## All networks"));
    assert.ok(!/primary and a standby signer|Standby keeper \|/.test(parameters));

    const access = w.read("access-controls");
    assert.ok(access.includes(`| Governance Safe | On this network a single account, not a Safe;`));
    assert.ok(access.includes(`| ${m.roles.keepers[0]} |`));
    assert.ok(!access.includes("Standby keeper"));
    assert.ok(access.includes("| Short delay (`SHORT_DELAY`) | 60 s |"));
    assert.ok(access.includes("| Minimum normal delay (`MIN_NORMAL_DELAY`) | 60 s |"));
    assert.ok(!access.includes("AvanaGasVault's `GUARDIAN`"));

    for (const page of ["addresses", "parameters", "access-controls"]) {
      const text = w.read(page);
      assert.ok(!text.includes("\r"), `${page} has LF line endings`);
      assert.ok(!/@\{|MISSING|undefined|NaN/.test(text), `${page} holds no unresolved value`);
      assert.ok(!/\blaunch\b|sandbox/i.test(text), `${page} avoids the excluded wording`);
    }
  } finally {
    w.done();
  }
});

test("a gas vault in the manifest is listed with its roles", () => {
  const w = workspace();
  try {
    const m = manifest();
    const vault = "0xf200000000000000000000000000000000000001";
    w.edit("manifest.json", (j) => {
      j.avana.gasVault = { address: vault, codeHash: `0x${"ab".repeat(32)}`, startBlock: 1, artifact: "AvanaGasVault.sol:AvanaGasVault", treasury: j.feeRecipient, timelock: j.avana.timelock.address, guardian: j.roles.emergencyGuardian, maxSigners: 8 };
    });
    generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE });
    assert.ok(w.read("addresses").includes(`| ${vault} |`));
    const access = w.read("access-controls");
    assert.ok(access.includes("and the AvanaGasVault's `GUARDIAN`"));
    assert.ok(access.includes("The ParameterStore's `feeRecipient` and the AvanaGasVault's `TREASURY`"));
    assert.ok(access.includes("Also the signer of the OperatorFlashLiquidator and a signer the AvanaGasVault refills."));
    assert.ok(m.avana.gasVault === null);
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
      j.avana.firstLossReserves[1].address = "0x0000000000000000000000000000000000000002";
      j.external = j.external.filter((e: any) => e.name !== "USDT / USD (primary)");
    });
    w.edit("operation-listing-activate.json", (j) => {
      delete j.delay;
    });
    let message = "";
    try {
      generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE });
    } catch (e) {
      message = (e as Error).message;
    }
    assert.match(message, /nothing written/);
    assert.match(message, /placeholder: First-Loss Reserve of USDC/);
    assert.match(message, /missing: external feed "USDT \/ USD \(primary\)"/);
    assert.match(message, /missing: operation-listing-activate\.json delay/);
    assert.ok(!existsSync(w.out));
  } finally {
    w.done();
  }
});

test("a test network needs a depth threshold on every route; a local chain may list none", () => {
  const w = workspace();
  try {
    w.edit("config-hub-sample.json", (j) => {
      for (const mk of j.listing.markets) for (const r of mk.routes) delete r.depthThreshold;
    });
    assert.throws(() => generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE }), /routeDepthThreshold/);
    w.edit("manifest.json", (j) => {
      j.chainId = 31337;
      j.network = "ethereum";
    });
    w.edit("config-hub-sample.json", (j) => {
      j.chainId = 31337;
    });
    generate({ network: "local-ethereum", deployment: w.dep, out: w.out, date: DATE });
    const parameters = w.read("parameters");
    assert.ok(parameters.includes("## Local Ethereum development chain\n- network: local-ethereum\n- chainId: 31337\n\n"));
    assert.ok(parameters.includes("| `routeDepthThreshold` | Not set |"));
    assert.ok(w.read("addresses").includes("A local development chain (chain ID 31337)"));
  } finally {
    w.done();
  }
});

test("a sequencer feed adds its address and grace period", () => {
  const w = workspace();
  try {
    const feed = "0xf300000000000000000000000000000000000001";
    w.edit("manifest.json", (j) => {
      j.chainId = 84532;
      j.network = "base-sepolia";
      j.sequencerFeed = feed;
    });
    w.edit("config-hub-sample.json", (j) => {
      j.chainId = 84532;
      j.chain = { blockTime: 2, hasSequencer: true, sequencerFeed: feed, sequencerGraceSeconds: 3600 };
    });
    generate({ network: "base-sepolia", deployment: w.dep, out: w.out, date: DATE });
    assert.ok(w.read("addresses").includes(`| Chainlink L2 sequencer uptime feed | Recorded in the ParameterStore; Avana's borrow and liquidation gates do not read it. | ${feed} |`));
    const parameters = w.read("parameters");
    assert.ok(parameters.includes("| `sequencer.gracePeriod` | 3,600 s (1 hour) |"));
    assert.ok(parameters.includes("| `twapMinObservations` | 901 |"));
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
    const sections = readSections(first);
    sections.set("base-sepolia", other);
    writeFileSync(join(w.out, "addresses.md"), assemble(readFileSync(join(dirname(fileURLToPath(import.meta.url)), "templates", "addresses.md"), "utf8"), sections, DATE));
    generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE });
    const again = w.read("addresses");
    assert.equal(readSections(again).get("base-sepolia"), other);
    assert.equal(readSections(again).get("ethereum-sepolia"), readSections(first).get("ethereum-sepolia"));
    assert.ok(again.indexOf("network: ethereum-sepolia") < again.indexOf("network: base-sepolia"), "sections follow the network order");
    generate({ network: "ethereum-sepolia", deployment: w.dep, out: w.out, date: DATE });
    assert.equal(w.read("addresses"), again);
  } finally {
    w.done();
  }
});

test("helpers: arguments, placeholders, percentages and durations", () => {
  assert.deepEqual(parseArgs(["--network", "local-base", "--deployment", "d", "--allow-rehearsal"]), { network: "local-base", deployment: "d", allowRehearsal: true });
  assert.throws(() => parseArgs(["--network", "local-base"]), /usage/);
  assert.throws(() => parseArgs(["--bogus"]), /unknown argument/);
  assert.ok(isPlaceholder("0x0000000000000000000000000000000000000001"));
  assert.ok(isPlaceholder(`0x${"0".repeat(56)}12345678`));
  assert.ok(!isPlaceholder("0xf100000000000000000000000000000000000001"));
  assert.deepEqual([8000, 650, 8889, 50, 1, 0].map(pct), ["80%", "6.5%", "88.89%", "0.5%", "0.01%", "0%"]);
  assert.deepEqual([60, 120, 3600, 43_200, 432_000, 1_800].map(seconds), ["60 s", "120 s", "3,600 s (1 hour)", "43,200 s (12 hours)", "432,000 s (5 days)", "1,800 s"]);
});

test("a table cell escapes backslashes before pipes", () => {
  // Backslashes first: otherwise `a\|b` would become `a\\|b`, whose pipe ends the cell.
  assert.equal(cell("a\\|b"), "a\\\\\\|b");
  assert.equal(cell("x | y \\ z"), "x \\| y \\\\ z");
  assert.equal(cell("plain"), "plain");
});
