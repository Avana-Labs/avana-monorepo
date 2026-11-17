// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Run: node --test script/testnet/verify.test.ts (from contracts/)

import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { ARGS_ON_COMMAND_LINE, cloneImplementation, compilationProfileOf, compilerProfiles, deployedContracts, indexArtifacts, isCreate3Helper, matchArtifact, profileOuts, proxyRequest, sourceRequest, verifyCommand, verifyRelease } from "./verify.ts";

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
// An EIP-1167 clone of A (as Slipstream's factory makes its pools), and the CREATE3 deployer helper.
const CLONE = `3d602d80600a3d3981f3363d3d373d3d3d363d73${"00".repeat(19)}a15af43d82803e903d91602b57fd5bf3`;
const CREATE3_HELPER = "67363d3d37363d34f03d5260086018f3";

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
        {
          hash: "0x06",
          transactionType: "CALL",
          additionalContracts: [
            { transactionType: "CREATE2", address: "0x0000000000000000000000000000000000000c10", initCode: `0x${CLONE}` },
            { transactionType: "CREATE2", address: "0x0000000000000000000000000000000000000c30", initCode: `0x${CREATE3_HELPER}` },
          ],
        },
      ],
      receipts: ["0x01", "0x02", "0x03", "0x04", "0x06"].map((h) => ({ transactionHash: h, status: "0x1" })).concat([{ transactionHash: "0x05", status: "0x0" }]),
    }),
  );
  writeFileSync(join(out, "created.json"), JSON.stringify([{ address: "0x00000000000000000000000000000000000000f6", initCode: `0x${A}${"00".repeat(32)}` }]));
  return { root, out, broadcast: join(out, "forge-broadcast") };
}

test("profiles map to their out directories; other tables are not profiles", () => {
  assert.deepEqual(profileOuts('[profile.default]\nout = "out"\n[profile.univ3]\nout = "out-univ3"\n[etherscan]\nout = "x"\n'), { default: "out", univ3: "out-univ3" });
});

// The default profile's extra compiler profiles span several lines; univ3 empties them, chainlink inherits them, and
// aave declares its own on one line.
const TOML = `[profile.default]
out = "out"
optimizer_runs = 10_000
via_ir = false
additional_compiler_profiles = [
  { name = "collateralization", optimizer = true, via_ir = true, optimizer_runs = 200 },
  { name = "lporacle", optimizer = true, via_ir = false, optimizer_runs = 200 },
]

[profile.aave]
out = "out-aave"
optimizer_runs = 44_444_444
additional_compiler_profiles = [{ name = "hub", via_ir = true, optimizer_runs = 22_300 }, { name = "spoke", via_ir = true, optimizer_runs = 750 }]

[profile.univ3]
optimizer_runs = 800
additional_compiler_profiles = []

[profile.chainlink]
optimizer_runs = 1_000_000

[etherscan]
optimizer_runs = 1
`;

test("each profile's compiler profiles: its own, or the default profile's when it names none", () => {
  const c = compilerProfiles(TOML);
  assert.deepEqual(Object.keys(c).sort(), ["aave", "chainlink", "default", "univ3"]);
  assert.deepEqual(c.default!.base, { name: "default", runs: 10_000, viaIR: false });
  assert.deepEqual(c.default!.additional.map((x) => [x.name, x.runs, x.viaIR]), [["collateralization", 200, true], ["lporacle", 200, false]]);
  assert.deepEqual(c.aave!.base, { name: "default", runs: 44_444_444, viaIR: false });
  assert.deepEqual(c.aave!.additional.map((x) => x.name), ["hub", "spoke"]);
  assert.deepEqual(c.univ3!.additional, []);
  assert.deepEqual(c.chainlink!.base, { name: "default", runs: 1_000_000, viaIR: false });
  assert.deepEqual(c.chainlink!.additional.map((x) => x.name), ["collateralization", "lporacle"]);
});

test("an artifact's compiler profile is the one whose settings built it, the base settings first", () => {
  const c = compilerProfiles(TOML);
  const at = (runs: number, viaIR: boolean) => ({ optimizer: { enabled: true, runs }, viaIR });
  assert.equal(compilationProfileOf(at(10_000, false), c.default!), "default");
  assert.equal(compilationProfileOf(at(200, true), c.default!), "collateralization");
  assert.equal(compilationProfileOf(at(200, false), c.default!), "lporacle");
  assert.equal(compilationProfileOf(at(22_300, true), c.aave!), "hub");
  assert.equal(compilationProfileOf(at(750, true), c.aave!), "spoke");
  // Profiles that inherit extra compiler profiles but build everything with their base settings.
  assert.equal(compilationProfileOf(at(1_000_000, false), c.chainlink!), "default");
  assert.equal(compilationProfileOf(at(800, false), c.univ3!), "default");
});

test("every contract a release created is read: forge creations, contracts created inside a call, and created.json", () => {
  const f = fixture();
  const d = deployedContracts(f.broadcast, 11_155_111, join(f.out, "created.json"));
  assert.deepEqual(d.map((x) => x.address.slice(-2)).sort(), ["10", "30", "a1", "b2", "c3", "d4", "f6"], "a reverted creation (e5) is not a contract");
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
    args: ["verify-contract", "0xa1", "src/A.sol:A", "--chain", "11155111", "--compiler-version", "v0.8.28+commit.7893614a", "--num-of-optimizations", "10000", "--evm-version", "cancun", "--constructor-args", `0x${ARG}`, "--watch", "--retries", "20", "--delay", "15"],
  });
  assert.deepEqual(verifyCommand(matchArtifact(index, `0x${L.replace(PLACEHOLDER, LIB)}`)!, "0xb2", 84_532), {
    profile: "aave",
    args: [
      "verify-contract", "0xb2", "dependencies/aave/L.sol:L", "--chain", "84532", "--compiler-version", "v0.8.28+commit.7893614a", "--num-of-optimizations", "22300",
      "--via-ir", "--evm-version", "cancun", "--libraries", `dependencies/aave/Lib.sol:Lib:0x${LIB}`, "--watch", "--retries", "20", "--delay", "15",
    ],
  });
});

test("with the profiles' settings known, the command names the compiler profile that built the contract", () => {
  const f = fixture();
  const index = indexArtifacts(f.root, { default: "out", aave: "out-aave" }, compilerProfiles(TOML));
  const a = verifyCommand(matchArtifact(index, `0x${A}${ARG}`)!, "0xa1", 11_155_111).args;
  assert.deepEqual(a.slice(a.indexOf("--compilation-profile"), a.indexOf("--compilation-profile") + 2), ["--compilation-profile", "default"]);
  const l = verifyCommand(matchArtifact(index, `0x${L.replace(PLACEHOLDER, LIB)}`)!, "0xb2", 84_532).args;
  assert.deepEqual(l.slice(l.indexOf("--compilation-profile"), l.indexOf("--compilation-profile") + 2), ["--compilation-profile", "hub"]);
});

test("constructor arguments too long for a command line go to the explorer with forge's standard JSON input", () => {
  const f = fixture();
  const index = indexArtifacts(f.root, { default: "out", aave: "out-aave" });
  // The Aave V4 instance batches take a Spoke's creation code: about 50,000 hex characters, over Windows' 32,767.
  const long = "ab".repeat(25_000);
  assert.ok(long.length > ARGS_ON_COMMAND_LINE);
  const c = verifyCommand(matchArtifact(index, `0x${A}${long}`)!, "0xa1", 84_532);
  assert.equal(c.constructorArgs, long);
  assert.equal(c.args.at(-1), "--show-standard-json-input");
  assert.ok(!c.args.includes("--constructor-args") && !c.args.includes("--watch"));
  assert.ok(c.args.join(" ").length < ARGS_ON_COMMAND_LINE);
  assert.equal(verifyCommand(matchArtifact(index, `0x${A}${ARG}`)!, "0xa1", 84_532).constructorArgs, undefined);
  assert.deepEqual(sourceRequest(84_532, "0xa1", "src/A.sol:A", "v0.8.28+commit.7893614a", long), {
    url: "https://api.etherscan.io/v2/api?chainid=84532",
    form: {
      module: "contract",
      action: "verifysourcecode",
      codeformat: "solidity-standard-json-input",
      contractaddress: "0xa1",
      contractname: "src/A.sol:A",
      compilerversion: "v0.8.28+commit.7893614a",
      constructorArguements: long,
    },
  });
});

test("a clone names its implementation; the CREATE3 helper is told apart; a proxy request carries no key", () => {
  assert.equal(cloneImplementation(`0x${CLONE}`), `0x${"00".repeat(19)}a1`);
  assert.equal(cloneImplementation(`0x${A}`), undefined);
  assert.ok(isCreate3Helper(`0x${CREATE3_HELPER}`) && !isCreate3Helper(`0x${CLONE}`));
  assert.deepEqual(proxyRequest(84_532, "0xc10", "0xa1"), {
    url: "https://api.etherscan.io/v2/api?chainid=84532",
    form: { module: "contract", action: "verifyproxycontract", address: "0xc10", expectedimplementation: "0xa1" },
  });
});

test("a dry run prints each command with the key redacted, and a contract already verified is skipped", async () => {
  const f = fixture();
  writeFileSync(join(f.out, "verified.json"), JSON.stringify({ "0x00000000000000000000000000000000000000d4": "src/F.sol:F" }));
  const lines: string[] = [];
  process.env.ETHERSCAN_API_KEY = "secret-key-value";
  const r = await verifyRelease({ contracts: f.root, outDir: f.out, broadcastRoot: f.broadcast, chainId: 11_155_111, dryRun: true, say: (s) => lines.push(s) });
  delete process.env.ETHERSCAN_API_KEY;
  const commands = lines.filter((l) => l.includes("forge verify-contract"));
  assert.equal(commands.length, 3, "a1, b2 and f6; d4 is verified already and c3 matches no build output");
  assert.ok(commands.every((l) => l.includes("ETHERSCAN_API_KEY=<redacted>") && !l.includes("secret-key-value")));
  assert.ok(commands.some((l) => l.startsWith("  FOUNDRY_PROFILE=aave ") && l.includes("--via-ir")));
  assert.ok(commands.every((l) => l.includes("--compilation-profile default")), "the fixture's profiles have no extra compiler profiles");
  // The clone is verified as a proxy of A, with the key redacted; the CREATE3 helper is skipped as one.
  const proxies = lines.filter((l) => l.includes("verifyproxycontract"));
  assert.equal(proxies.length, 1);
  assert.ok(proxies[0]!.includes("expectedimplementation=0x00000000000000000000000000000000000000a1") && proxies[0]!.includes("apikey=%3Credacted%3E"));
  assert.ok(lines.some((l) => l.includes("0x0000000000000000000000000000000000000c30: a CREATE3 helper proxy")));
  assert.ok(!lines.some((l) => l.includes("secret-key-value")));
  assert.equal(r.skipped, 3);
  assert.equal(r.failed.length, 0);
});
