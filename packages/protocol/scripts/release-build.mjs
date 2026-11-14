#!/usr/bin/env node
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Writes the release record of a tagged build: the bytecode hashes of every deployable Avana artifact, the CREATE3 salts
// the deploy scripts derive from the tag, the address of the CREATE3 factory, and the ABI hash. The fields it shares with
// the release manifest (release, commit, abiHash, deployer, create3Factory, every code hash) are checked against the
// manifest schema (deployments/release-manifest.schema.json), so a deployment manifest of this release can be compared
// with the record field by field. Run by .github/workflows/release.yml after the release build; deploys nothing.
//
//   node packages/protocol/scripts/release-build.mjs --release v0.1.0-alpha.1 --commit <sha> [--out-dir dist/release]
//        [--contracts contracts] [--abi-index packages/protocol/src/abis/index.ts] [--deployer 0x...]
//        [--lp-vault-ids 1,2] [--operator-helpers 1]
//
// --contracts and --abi-index point at the tagged checkout, so the workflow can record an older tag with this script.
// A tag older than the deploy scripts (no AvanaCreate3Factory in its build) or than this package (no ABI_HASH) gets
// null for create3Factory and abiHash and no salts: nothing at that tag derives an address from it.
//
// Salts follow contracts/script/deploy/lib/DeployBase.sol: salt(name) = keccak256("avana.<release>.<name>"). The CREATE3
// factory is CREATE2-deployed through the Safe Singleton Factory with salt 0, and namespaces each salt by its caller
// (AvanaCreate3Factory.sol), so with --deployer the record also lists the address every named contract gets on any chain.

import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { encodeAbiParameters, getAddress, getContractAddress, keccak256, stringToBytes } from "viem";
import { releaseManifestSchema, validate } from "../src/manifest/schema.ts";

const PKG = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const REPO = resolve(PKG, "../..");

/** Safe Singleton Factory (DeployBase.SAFE_SINGLETON_FACTORY). */
export const SAFE_SINGLETON_FACTORY = "0x914d7Fec6aaC8cd542e72Bca78B30650d45643d7";
/** Solady CREATE3 proxy init code hash (dependencies/solady-0.1.26/src/utils/CREATE3.sol). */
const CREATE3_PROXY_INITCODE_HASH = "0x21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f";
/** Names the deploy scripts pass to `_deploy3` / `_predict` (script/deploy/lib/AvanaCoreDeploy.sol, AvanaPeripheryDeploy.sol). */
export const CREATE3_NAMES = [
  "AaveAdapter",
  "AaveV3FlashSource",
  "AvanaTimelock",
  "Collateralization",
  "FlashLiquidator",
  "Lens",
  "Lock",
  "LPVaultSwap",
  "MarketRegistry",
  "ParameterStore",
  "PayoutEscrow",
  "ProxyManager",
  "RiskModule",
  "VaultTokenFactory",
];
/** Builds the record covers: Avana sources in out/ (default profile) and Avana's own files in out-aave/ (aave profile). */
const BUILDS = [
  { dir: "out", prefix: "", include: (src) => src.startsWith("src/") || src === "script/deploy/AvanaCreate3Factory.sol" },
  { dir: "out-aave", prefix: "out-aave:", include: (src) => src.startsWith("aave-deploy/") },
];

/** keccak256("avana.<release>.<name>"), as DeployBase._salt. */
export const saltOf = (release, name) => keccak256(stringToBytes(`avana.${release}.${name}`));

/** AvanaCreate3Factory.predict(caller, salt): Solady CREATE3 over the caller-namespaced salt. */
export function predictCreate3(factory, caller, salt) {
  const namespaced = keccak256(encodeAbiParameters([{ type: "address" }, { type: "bytes32" }], [caller, salt]));
  const proxy = getContractAddress({ opcode: "CREATE2", from: factory, salt: namespaced, bytecodeHash: CREATE3_PROXY_INITCODE_HASH });
  return getContractAddress({ opcode: "CREATE", from: proxy, nonce: 1n });
}

const codeHash = (object) => {
  const hex = object.replace(/^0x/, "");
  if (hex.length === 0 || hex.includes("__$")) return null; // abstract, interface, or unlinked libraries
  return keccak256(`0x${hex}`);
};

/** Every deployable artifact of the release builds, sorted by artifact name, then build file. */
export function readArtifacts(contractsDir) {
  const rows = [];
  const compilers = {};
  for (const build of BUILDS) {
    const root = join(contractsDir, build.dir);
    if (!existsSync(root)) throw new Error(`missing ${root}; run the release build first (docs/release.md)`);
    for (const file of readdirSync(root).filter((f) => f.endsWith(".sol")).sort()) {
      for (const json of readdirSync(join(root, file)).filter((j) => j.endsWith(".json")).sort()) {
        const a = JSON.parse(readFileSync(join(root, file, json), "utf8"));
        const target = a.metadata?.settings?.compilationTarget ?? {};
        const source = Object.keys(target)[0];
        if (!source || !build.include(source)) continue;
        const runtime = a.deployedBytecode?.object ?? "0x";
        if (runtime.replace(/^0x/, "").length === 0) continue;
        const contract = target[source];
        const profile = json.slice(contract.length + 1, -".json".length) || null; // <Contract>.<profile>.json
        const s = a.metadata.settings;
        compilers[build.dir] ??= { solc: a.metadata.compiler.version, evmVersion: s.evmVersion, bytecodeHash: s.metadata?.bytecodeHash ?? "ipfs" };
        rows.push({
          artifact: `${build.prefix}${file}:${contract}`,
          profile,
          path: `${build.dir}/${file}/${json}`,
          source,
          // Per artifact: files restricted to another compiler profile (foundry.toml compilation_restrictions) differ.
          optimizerRuns: s.optimizer?.enabled ? s.optimizer.runs : null,
          viaIR: s.viaIR ?? false,
          creationCodeHash: codeHash(a.bytecode?.object ?? "0x"),
          runtimeCodeHash: codeHash(runtime),
          immutablePositions: Object.values(a.deployedBytecode.immutableReferences ?? {}).flat().length,
          libraries: Object.values(a.bytecode?.linkReferences ?? {}).flatMap((l) => Object.keys(l)).sort(),
        });
      }
    }
  }
  rows.sort((x, y) => (x.artifact === y.artifact ? x.path.localeCompare(y.path) : x.artifact.localeCompare(y.artifact)));
  return { rows, compilers };
}

/** The schema of the record, built from the manifest schema's own definitions so the shared fields cannot drift. */
function recordSchema() {
  const p = releaseManifestSchema.properties;
  const hash = releaseManifestSchema.$defs.immutable.properties.codeHash;
  const nullableHash = { anyOf: [hash, { type: "null" }] };
  const nullableAddress = { anyOf: [p.deployer, { type: "null" }] };
  return {
    ...releaseManifestSchema,
    type: "object",
    additionalProperties: true,
    required: ["release", "commit", "abiHash", "create3Factory", "deployer", "salts", "artifacts"],
    properties: {
      release: p.release,
      commit: p.commit,
      abiHash: { anyOf: [p.abiHash, { type: "null" }] },
      create3Factory: nullableAddress,
      deployer: nullableAddress,
      salts: { type: "array", items: { type: "object", required: ["name", "salt", "address"], properties: { name: { type: "string" }, salt: hash, address: nullableAddress } } },
      artifacts: {
        type: "array",
        items: {
          type: "object",
          required: ["artifact", "path", "source", "creationCodeHash", "runtimeCodeHash"],
          properties: { artifact: { type: "string" }, path: { type: "string" }, source: { type: "string" }, creationCodeHash: nullableHash, runtimeCodeHash: nullableHash },
        },
      },
    },
  };
}

/** ABI_HASH of the tagged checkout's packages/protocol, or null when the tag predates it. */
export async function readAbiHash(indexPath) {
  if (!existsSync(indexPath)) return null;
  const { ABI_HASH } = await import(pathToFileURL(indexPath).href);
  return ABI_HASH ?? null;
}

export function buildRecord({ release, commit, contractsDir, abiHash = null, deployer = null, lpVaultIds = [], operatorHelpers = 0 }) {
  const { rows, compilers } = readArtifacts(contractsDir);
  const factoryRow = rows.find((r) => r.artifact === "AvanaCreate3Factory.sol:AvanaCreate3Factory");
  const create3Factory = factoryRow?.creationCodeHash
    ? getContractAddress({ opcode: "CREATE2", from: SAFE_SINGLETON_FACTORY, salt: `0x${"00".repeat(32)}`, bytecodeHash: factoryRow.creationCodeHash })
    : null;
  const names = !create3Factory ? [] : [
    ...CREATE3_NAMES,
    ...lpVaultIds.map((id) => `LPVault.${id}`),
    ...Array.from({ length: operatorHelpers }, (_, i) => `OperatorFlashLiquidator.${i}`),
  ];
  const caller = deployer ? getAddress(deployer) : null;
  const salts = names.map((name) => {
    const salt = saltOf(release, name);
    return { name, salt, address: caller ? predictCreate3(create3Factory, caller, salt) : null };
  });
  const record = {
    schemaVersion: 1,
    release,
    commit,
    abiHash,
    compilers,
    create3Factory,
    deployer: caller,
    saltRule: 'keccak256("avana.<release>.<name>")',
    salts,
    artifacts: rows,
  };
  const errors = validate(record, recordSchema());
  if (errors.length) throw new Error(`release record does not match the manifest schema:\n${errors.map((e) => `  ${e.path}: ${e.message}`).join("\n")}`);
  return record;
}

async function main() {
  const opt = (name) => {
    const i = process.argv.indexOf(`--${name}`);
    return i === -1 ? undefined : process.argv[i + 1];
  };
  const release = opt("release");
  const commit = opt("commit");
  if (!release || !commit) throw new Error("usage: release-build.mjs --release vX.Y.Z --commit <sha> [--out-dir <dir>] [--contracts <dir>] [--deployer 0x...]");
  const contractsDir = resolve(opt("contracts") ?? join(REPO, "contracts"));
  const outDir = resolve(opt("out-dir") ?? join(REPO, "dist/release"));
  const record = buildRecord({
    release,
    commit,
    contractsDir,
    abiHash: await readAbiHash(resolve(opt("abi-index") ?? join(PKG, "src/abis/index.ts"))),
    deployer: opt("deployer") || null,
    lpVaultIds: (opt("lp-vault-ids") ?? "").split(",").filter(Boolean).map(Number),
    operatorHelpers: Number(opt("operator-helpers") ?? 0),
  });
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, "release.json"), `${JSON.stringify(record, null, 2)}\n`);
  writeFileSync(
    join(outDir, "bytecode-hashes.txt"),
    record.artifacts.map((r) => `${r.runtimeCodeHash ?? "-".repeat(66)}  ${r.creationCodeHash ?? "-".repeat(66)}  ${r.path}`).join("\n") + "\n",
  );
  writeFileSync(join(outDir, "artifacts.txt"), record.artifacts.map((r) => r.path).join("\n") + "\n");
  console.log(`${release} (${commit}): ${record.artifacts.length} artifacts, ${record.salts.length} salts, CREATE3 factory ${record.create3Factory}, ABI_HASH ${record.abiHash}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
