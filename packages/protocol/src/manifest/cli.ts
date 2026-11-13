#!/usr/bin/env node
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Release manifest tool. From packages/protocol (or `npm run manifest -w @avana/protocol -- <command>`):
//
//   produce --network <n> --rpc-env <VAR> [--release vX.Y.Z] [--commit <sha>] [--out <file>]
//       Writes the manifest of the deployment the scripts made on <n>. Default output: deployments/<n>/<release>.json
//       for ethereum, base and sepolia; contracts/deployments-local/<n>/manifest.json for anvil.
//   verify --manifest <file> --rpc-env <VAR>
//       Checks the manifest against the chain; exits 1 on any failed check, prints pending ones.
//   table --manifest <file> [--explorer <url>] [--out <file>]
//       Writes the public Markdown contract table.
//   publish --manifest <file> --rpc-env <VAR> [--explorer <url>]
//       verify, then copy the manifest to deployments/verified/<network>-<release>.json and write
//       deployments/<network>/README.md. Refuses learning deployments (anvil, or a release with a -local, -test or
//       -learn suffix) and any manifest with a failed or pending check.
//   schema [--out <file>]
//       Writes deployments/release-manifest.schema.json from schema.ts.
//   upstream --rpc-env RPC_MAINNET
//       Checks that the Aave V4 build Avana deploys on test networks (contracts/out-aave/, pinned a3ef63e) is the code
//       the Aave DAO runs on Ethereum (upstream.ts): every Hub, Spoke, AaveOracle, rate strategy, configurator, the
//       AccessManager, TreasurySpoke and LiquidationLogic, immutables and linked library addresses masked.
//
// The RPC URL is read from the environment variable named by --rpc-env (RPC_MAINNET, RPC_BASE, RPC_SEPOLIA,
// RPC_BASE_SEPOLIA, RPC_ANVIL); --rpc <url> is accepted for a local node. URLs are never printed.

import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { type PublicClient, createPublicClient, http } from "viem";
import { readGitCommit } from "./chain.ts";
import { produceManifest } from "./produce.ts";
import { parseManifest, releaseManifestSchema } from "./schema.ts";
import { contractTable } from "./table.ts";
import { verifyUpstream } from "./upstream.ts";
import { verifyManifest } from "./verify.ts";

const REPO = resolve(dirname(fileURLToPath(import.meta.url)), "../../../..");
const CONTRACTS = join(REPO, "contracts");
const LEARNING = /-(local|test|learn)(\.|$)/;

const [command, ...rest] = process.argv.slice(2);
const opt = (name: string): string | undefined => {
  const i = rest.indexOf(`--${name}`);
  return i === -1 ? undefined : rest[i + 1];
};
const need = (name: string): string => {
  const v = opt(name);
  if (!v) throw new Error(`--${name} is required`);
  return v;
};
function client(): PublicClient {
  const direct = opt("rpc");
  const envName = opt("rpc-env");
  const url = direct ?? (envName ? process.env[envName] : undefined);
  if (!url) throw new Error(envName ? `${envName} is not set` : "--rpc-env <VAR> or --rpc <url> is required");
  return createPublicClient({ transport: http(url) }) as PublicClient;
}
const write = (path: string, text: string) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
  process.stdout.write(`wrote ${path}\n`);
};

async function verify(path: string): Promise<boolean> {
  const m = parseManifest(readFileSync(path, "utf8"), path);
  const checks = await verifyManifest(m, client(), CONTRACTS);
  for (const c of checks) process.stdout.write(`${c.outcome.toUpperCase().padEnd(7)} ${c.name}${c.detail ? ` — ${c.detail}` : ""}\n`);
  const count = (o: string) => checks.filter((c) => c.outcome === o).length;
  process.stdout.write(`\n${count("pass")} passed, ${count("fail")} failed, ${count("pending")} pending\n`);
  if (count("fail") > 0) process.exitCode = 1;
  return count("fail") === 0 && count("pending") === 0;
}

async function main() {
  switch (command) {
    case "produce": {
      const network = need("network");
      const manifest = await produceManifest({
        client: client(),
        contractsDir: CONTRACTS,
        network,
        commit: opt("commit") ?? readGitCommit(REPO),
        ...(opt("release") ? { release: opt("release")! } : {}),
      });
      const local = network === "anvil";
      const out = opt("out") ?? (local ? join(CONTRACTS, "deployments-local", network, "manifest.json") : join(REPO, "deployments", network, `${manifest.release}.json`));
      write(out, `${JSON.stringify(manifest, null, 2)}\n`);
      break;
    }
    case "verify":
      await verify(need("manifest"));
      break;
    case "table": {
      const path = need("manifest");
      const m = parseManifest(readFileSync(path, "utf8"), path);
      const text = contractTable(m, opt("explorer"));
      const out = opt("out");
      if (out) write(out, text);
      else process.stdout.write(text);
      break;
    }
    case "publish": {
      const path = need("manifest");
      const m = parseManifest(readFileSync(path, "utf8"), path);
      if (m.network === "anvil" || LEARNING.test(m.release)) throw new Error(`${m.release} on ${m.network} is a learning deployment; it is never published`);
      if (!(await verify(path))) throw new Error("verification has failed or pending checks; nothing published");
      const verified = join(REPO, "deployments", "verified", `${m.network}-${m.release}.json`);
      mkdirSync(dirname(verified), { recursive: true });
      copyFileSync(path, verified);
      process.stdout.write(`wrote ${verified}\n`);
      write(join(REPO, "deployments", m.network, "README.md"), contractTable(m, opt("explorer")));
      break;
    }
    case "schema":
      write(opt("out") ?? join(REPO, "deployments", "release-manifest.schema.json"), `${JSON.stringify(releaseManifestSchema, null, 2)}\n`);
      break;
    case "upstream": {
      const checks = await verifyUpstream(client(), CONTRACTS);
      for (const c of checks) process.stdout.write(`${c.outcome.toUpperCase().padEnd(7)} ${c.name}${c.detail ? ` — ${c.detail}` : ""}\n`);
      const count = (o: string) => checks.filter((c) => c.outcome === o).length;
      process.stdout.write(`\n${count("pass")} passed, ${count("fail")} failed, ${count("pending")} pending\n`);
      if (count("fail") + count("pending") > 0) process.exitCode = 1;
      break;
    }
    default:
      throw new Error("usage: manifest <produce|verify|table|publish|schema|upstream> [options]; see the header of src/manifest/cli.ts");
  }
}

main().catch((err: unknown) => {
  process.stderr.write(`${err instanceof Error ? err.message : String(err)}\n`);
  process.exit(1);
});
