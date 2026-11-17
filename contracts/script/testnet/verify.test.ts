// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Run: node --test script/testnet/verify.test.ts (from contracts/)

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { deployedContracts, indexArtifacts, matchArtifact, profileOuts, verifyCommand, verifyRelease } from "./verify.ts";

// Real creation codes are far longer than the index key (64 bytes); each fixture body is 100 bytes.
const meta = (n: number) => `${n.toString(16).padStart(2, "0")}`.repeat(100);
// A: a default-profile contract with one constructor argument.
const A = `6080604052${meta(1)}`;
// L: an IR-built contract of another profile that links one library.
const PLACEHOLDER = `__$${"ab".repeat(17)}$__`;
const L = `60aa73${PLACEHOLDER}${meta(2)}`;
// F: a factory whose creation code embeds A's (so it contains A's metadata hash too).
const F = `60ff${A}${meta(3)}`;
const LIB = "11".repeat(20);
const ARG = "00".repeat(31) + "2a";

function artifact(dir: string, file: string, name: string, source: string, creation: string, settings: Record<string, unknown>, links = {}) {
  mkdirSync(join(dir, `${file}.sol`), { recursive: true });
  writeFileSync(
    join(dir, `${file}.sol`, `${name}.json`),
    JSON.stringify({
      bytecode: { object: `0x${creation}`, linkReferences: links },
      metadata: { compiler: { version: "0.8.28+commit.7893614a" }, settings: { compilationTarget: { [source]: name }, ...settings } },
    }),
  );
}

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "verify-test-"));
  writeFileSync(join(root, "foundry.toml"), '[profile.default]\nsrc = "src"\nout = "out"\n\n[profile.aave]\nsrc = "x"\nout = "out-aave"\n[rpc_endpoints]\nout = "not a profile"\n');
  artifact(join(root, "out"), "A", "A", "src/A.sol", A, { optimizer: { enabled: true, runs: 10000 }, evmVersion: "cancun" });
  artifact(join(root, "out"), "F", "F", "src/F.sol", F, { optimizer: { enabled: true, runs: 200 }, evmVersion: "cancun" });
  artifact(join(root, "out-aave"), "L", "L", "dependencies/aave/L.sol", L, { optimizer: { enabled: true, runs: 22300 }, viaIR: true, evmVersion: "cancun" }, {
    "dependencies/aave/Lib.sol": { Lib: [{ start: 3, length: 20 }] },
  });
  const out = join(root, "deployments-local", "sepolia");
  const runs = join(out, "forge-broadcast", "02_DeployWorld.s.sol", "11155111");
  mkdirSync(runs, { recursive: true });
  writeFileSync(
    join(runs, "run-1.json"),
    JSON.stringify({
      transactions: [
        { hash: "0x01", transactionType: "CREATE", contractAddress: "0x00000000000000000000000000000000000000a1", transaction: { input: `0x${A}${ARG}` } },
        { hash: "0x02", transactionType: "CALL", additionalContracts: [{ transactionType: "CREATE2", address: "0x00000000000000000000000000000000000000b2", initCode: `0x${L.replace(PLACEHOLDER, LIB)}` }] },
        { hash: "0x03", transactionType: "CREATE", contractAddress: "0x00000000000000000000000000000000000000c3", transaction: { input: "0x600b5981380380925939f300" } },
        { hash: "0x04", transactionType: "CREATE", contractAddress: "0x00000000000000000000000000000000000000d4", transaction: { input: `0x${F}` } },
        { hash: "0x05", transactionType: "CREATE", contractAddress: "0x00000000000000000000000000000000000000e5", transaction: { input: `0x${A}${ARG}` } },
      ],
      receipts: ["0x01", "0x02", "0x03", "0x04"].map((h) => ({ transactionHash: h, status: "0x1" })).concat([{ transactionHash: "0x05", status: "0x0" }]),
    }),
  );
  writeFileSync(join(out, "created.json"), JSON.stringify([{ address: "0x00000000000000000000000000000000000000f6", initCode: `0x${A}${"00".repeat(32)}` }]));
  return { root, out, broadcast: join(out, "forge-broadcast") };
}

test("profiles map to their out directories; other tables are not profiles", () => {
  assert.deepEqual(profileOuts('[profile.default]\nout = "out"\n[profile.univ3]\nout = "out-univ3"\n[etherscan]\nout = "x"\n'), { default: "out", univ3: "out-univ3" });
});

test("every contract a release created is read: forge creations, contracts created inside a call, and created.json", () => {
  const f = fixture();
  const d = deployedContracts(f.broadcast, 11_155_111, join(f.out, "created.json"));
  assert.deepEqual(d.map((x) => x.address.slice(-2)).sort(), ["a1", "b2", "c3", "d4", "f6"], "a reverted creation (e5) is not a contract");
});

test("each init code matches its own build output, with its constructor arguments and linked libraries", () => {
  const f = fixture();
  const index = indexArtifacts(f.root, profileOuts('[profile.default]\nout = "out"\n[profile.aave]\nout = "out-aave"\n'));
  const a = matchArtifact(index, `0x${A}${ARG}`)!;
  assert.equal(a.artifact.name, "A");
  assert.equal(a.args, ARG);
  const l = matchArtifact(index, `0x${L.replace(PLACEHOLDER, LIB)}`)!;
  assert.equal(l.artifact.profile, "aave");
  assert.deepEqual(l.libraries, [{ source: "dependencies/aave/Lib.sol", name: "Lib", address: `0x${LIB}` }]);
  // The factory embeds A's creation code: it matches F, not A.
  assert.equal(matchArtifact(index, `0x${F}`)!.artifact.name, "F");
  assert.equal(matchArtifact(index, "0x600b5981380380925939f300"), undefined);
});

test("the forge verify-contract command carries the profile, compiler settings, arguments and libraries", () => {
  const f = fixture();
  const index = indexArtifacts(f.root, { default: "out", aave: "out-aave" });
  assert.deepEqual(verifyCommand(matchArtifact(index, `0x${A}${ARG}`)!, "0xa1", 11_155_111), {
    profile: "default",
    args: ["verify-contract", "0xa1", "src/A.sol:A", "--chain", "11155111", "--compiler-version", "v0.8.28+commit.7893614a", "--num-of-optimizations", "10000", "--evm-version", "cancun", "--constructor-args", `0x${ARG}`, "--watch"],
  });
  assert.deepEqual(verifyCommand(matchArtifact(index, `0x${L.replace(PLACEHOLDER, LIB)}`)!, "0xb2", 84_532), {
    profile: "aave",
    args: [
      "verify-contract", "0xb2", "dependencies/aave/L.sol:L", "--chain", "84532", "--compiler-version", "v0.8.28+commit.7893614a", "--num-of-optimizations", "22300",
      "--via-ir", "--evm-version", "cancun", "--libraries", `dependencies/aave/Lib.sol:Lib:0x${LIB}`, "--watch",
    ],
  });
});

test("a dry run prints each command with the key redacted, and a contract already verified is skipped", () => {
  const f = fixture();
  writeFileSync(join(f.out, "verified.json"), JSON.stringify({ "0x00000000000000000000000000000000000000d4": "src/F.sol:F" }));
  const lines: string[] = [];
  process.env.ETHERSCAN_API_KEY = "secret-key-value";
  const r = verifyRelease({ contracts: f.root, outDir: f.out, broadcastRoot: f.broadcast, chainId: 11_155_111, dryRun: true, say: (s) => lines.push(s) });
  delete process.env.ETHERSCAN_API_KEY;
  const commands = lines.filter((l) => l.includes("forge verify-contract"));
  assert.equal(commands.length, 3, "a1, b2 and f6; d4 is verified already and c3 matches no build output");
  assert.ok(commands.every((l) => l.includes("ETHERSCAN_API_KEY=<redacted>") && !l.includes("secret-key-value")));
  assert.ok(commands.some((l) => l.startsWith("  FOUNDRY_PROFILE=aave ") && l.includes("--via-ir")));
  assert.equal(r.skipped, 2);
  assert.equal(r.failed.length, 0);
});
