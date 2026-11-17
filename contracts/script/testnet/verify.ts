// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The explorer verification of everything a test-network release deployed: Avana's contracts and the world around
// them (Aave V4 from step 01; step 02's tokens, feeds, Uniswap v3 and v4, Permit2, Slipstream and Aave V3), each against
// its own build output. A step's own `--verify` reaches only the default profile's artifacts; the world is built by
// other profiles (out-aave, out-univ3, …) with other compilers and settings, so it is verified here.
//
// Every contract created on the chain by the release is read from the forge broadcast records (each transaction's
// creation and the contracts it created in turn, `additionalContracts`) and from created.json (contracts the TypeScript
// steps deployed: the executor stand-in, the QuoterV2s, the changes runner's payloads). Each init code is matched to the
// artifact whose creation code it starts with (link placeholders taking any address), found through the metadata hashes
// both contain. The match gives the source and contract name, the compiler profile that built it (its out directory),
// the compiler version, optimizer runs, IR pipeline and EVM version from the artifact's metadata, the linked libraries
// and the constructor arguments (the rest of the init code). One `forge verify-contract` runs per contract, under
// FOUNDRY_PROFILE=<that profile> and with --compilation-profile naming the compiler profile within it whose settings
// built the artifact (forge cannot tell it from a missing cache, nor from one that records the contract under several),
// the explorer key only in the environment (ETHERSCAN_API_KEY, never an argument).
// A contract recorded in verified.json, or that the explorer reports verified already, is skipped, so a rerun only
// retries what is left. Init code that matches no artifact (data contracts, proxies of a factory outside the build) is
// listed as skipped.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { join, relative } from "node:path";

export interface Deployed {
  readonly address: string;
  readonly initCode: string;
}
export interface Artifact {
  readonly profile: string;
  readonly file: string;
  readonly source: string;
  readonly name: string;
  /** Creation code, lower-case hex without 0x; link placeholders `__$…$__` kept. */
  readonly creation: string;
  readonly links: { readonly at: number; readonly source: string; readonly name: string }[];
  readonly compiler: string;
  readonly optimizer: { readonly enabled: boolean; readonly runs?: number };
  readonly viaIR: boolean;
  readonly evmVersion?: string;
  /** The compiler profile within `profile` that built it (`--compilation-profile`); set when the index knows the
   * profiles' settings. */
  readonly compilationProfile?: string;
}
export interface Match {
  readonly artifact: Artifact;
  readonly args: string;
  readonly libraries: { readonly source: string; readonly name: string; readonly address: string }[];
}

/** Hex characters of creation code an artifact is indexed by. The builds carry no metadata hash (bytecode_hash =
 * "none"), so the index is the code's start, which holds the constructor's own code and the code-copy sizes. */
const KEY = 128;
/** The key of artifacts whose start holds a link placeholder: these are checked against every init code. */
const EARLY_LINK = "";
const strip = (h: string) => h.replace(/^0x/, "").toLowerCase();

/** The out directory of each Foundry profile: `out` for the default, `out = "…"` of each `[profile.<name>]`. */
export function profileOuts(foundryToml: string): Record<string, string> {
  const outs: Record<string, string> = { default: "out" };
  let profile: string | undefined;
  for (const line of foundryToml.split(/\r?\n/)) {
    const h = /^\[profile\.([A-Za-z0-9_-]+)\]\s*$/.exec(line);
    if (h) {
      profile = h[1];
      continue;
    }
    if (/^\[/.test(line)) profile = undefined;
    const o = /^out\s*=\s*"([^"]+)"/.exec(line);
    if (o && profile) outs[profile] = o[1]!;
  }
  return outs;
}

/** A compiler profile of a Foundry profile: the base settings (`default`) or one of `additional_compiler_profiles`. */
export interface CompilerProfile {
  readonly name: string;
  readonly runs?: number;
  readonly viaIR?: boolean;
}
/** Each Foundry profile's base settings and additional compiler profiles, those it leaves out taken from the default
 * profile's, as Foundry inherits them. */
export function compilerProfiles(foundryToml: string): Record<string, { readonly base: CompilerProfile; readonly additional: CompilerProfile[] }> {
  const own: Record<string, { runs?: number; viaIR?: boolean; additional?: CompilerProfile[] }> = { default: {} };
  const num = (s: string) => Number(s.replace(/_/g, ""));
  const lines = foundryToml.split(/\r?\n/);
  let profile: string | undefined;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    const h = /^\[profile\.([A-Za-z0-9_-]+)\]\s*$/.exec(line);
    if (h) {
      profile = h[1]!;
      own[profile] ??= {};
      continue;
    }
    if (/^\[/.test(line)) profile = undefined;
    if (!profile) continue;
    const p = own[profile]!;
    const runs = /^optimizer_runs\s*=\s*([0-9_]+)/.exec(line);
    if (runs) p.runs = num(runs[1]!);
    const ir = /^via_ir\s*=\s*(true|false)/.exec(line);
    if (ir) p.viaIR = ir[1] === "true";
    if (/^additional_compiler_profiles\s*=/.test(line)) {
      let text = line;
      while (!/\]\s*(#.*)?$/.test(text.replace(/\{[^}]*\}/g, "")) && i + 1 < lines.length) text += `\n${lines[++i]}`;
      p.additional = [...text.matchAll(/\{([^}]*)\}/g)].map(([, t]) => {
        const r = /optimizer_runs\s*=\s*([0-9_]+)/.exec(t!);
        const v = /via_ir\s*=\s*(true|false)/.exec(t!);
        return { name: /name\s*=\s*"([^"]+)"/.exec(t!)![1]!, runs: r ? num(r[1]!) : undefined, viaIR: v ? v[1] === "true" : undefined };
      });
    }
  }
  const d = own.default!;
  return Object.fromEntries(
    Object.entries(own).map(([name, p]) => [
      name,
      { base: { name: "default", runs: p.runs ?? d.runs, viaIR: p.viaIR ?? d.viaIR ?? false }, additional: p.additional ?? d.additional ?? [] },
    ]),
  );
}

/** The compiler profile that built `a`, for `forge verify-contract --compilation-profile`: the base settings when they
 * are the artifact's, else the first additional profile whose settings are. Forge otherwise reads it from the profile's
 * cache, and fails when the cache is missing or records the contract under several compiler profiles. */
export function compilationProfileOf(a: Pick<Artifact, "optimizer" | "viaIR">, p: { base: CompilerProfile; additional: CompilerProfile[] }): string {
  const fits = (c: CompilerProfile) => (c.viaIR === undefined || c.viaIR === a.viaIR) && (c.runs === undefined || c.runs === a.optimizer.runs);
  if (fits(p.base)) return "default";
  return p.additional.find(fits)?.name ?? "default";
}

function readArtifact(profile: string, file: string, contracts: string): Artifact | undefined {
  const j = JSON.parse(readFileSync(file, "utf8")) as Record<string, any>;
  const creation = strip(j.bytecode?.object ?? "");
  if (!creation) return undefined;
  const m = typeof j.metadata === "string" ? JSON.parse(j.metadata) : j.metadata;
  const target = Object.entries((m?.settings?.compilationTarget ?? {}) as Record<string, string>)[0];
  if (!target) return undefined;
  const links: Artifact["links"][number][] = [];
  for (const [source, libs] of Object.entries((j.bytecode.linkReferences ?? {}) as Record<string, Record<string, { start: number }[]>>)) {
    for (const [name, refs] of Object.entries(libs)) for (const r of refs) links.push({ at: r.start * 2, source, name });
  }
  return {
    profile,
    file: relative(contracts, file).split("\\").join("/"),
    source: target[0],
    name: target[1],
    creation,
    links,
    compiler: `v${m.compiler.version}`,
    optimizer: { enabled: Boolean(m.settings.optimizer?.enabled), runs: m.settings.optimizer?.runs },
    viaIR: Boolean(m.settings.viaIR),
    evmVersion: m.settings.evmVersion,
  };
}

/** Every artifact of every profile's out directory, indexed by the start of its creation code; with `compilers`, each
 * names the compiler profile that built it. */
export function indexArtifacts(contracts: string, outs: Record<string, string>, compilers?: ReturnType<typeof compilerProfiles>): Map<string, Artifact[]> {
  const index = new Map<string, Artifact[]>();
  for (const [profile, out] of Object.entries(outs)) {
    const dir = join(contracts, out);
    if (!existsSync(dir)) continue;
    for (const sub of readdirSync(dir)) {
      // Test and script contracts are never deployed by a release.
      if (!sub.endsWith(".sol") || sub.endsWith(".t.sol") || sub.endsWith(".s.sol")) continue;
      const d = join(dir, sub);
      if (!statSync(d).isDirectory()) continue;
      for (const f of readdirSync(d).filter((x) => x.endsWith(".json"))) {
        const read = readArtifact(profile, join(d, f), contracts);
        if (!read) continue;
        const a = compilers?.[profile] ? { ...read, compilationProfile: compilationProfileOf(read, compilers[profile]) } : read;
        const key = a.links.some((l) => l.at < KEY) ? EARLY_LINK : a.creation.slice(0, KEY);
        index.set(key, [...(index.get(key) ?? []), a]);
      }
    }
  }
  return index;
}

/** `initCode` as `a`'s creation code followed by constructor arguments, with each linked library's address. */
export function matchOne(a: Artifact, initCode: string): Match | undefined {
  const code = strip(initCode);
  if (code.length < a.creation.length) return undefined;
  const libraries: Match["libraries"][number][] = [];
  let i = 0;
  for (const l of [...a.links].sort((x, y) => x.at - y.at)) {
    if (code.slice(i, l.at) !== a.creation.slice(i, l.at)) return undefined;
    const address = `0x${code.slice(l.at, l.at + 40)}`;
    if (!libraries.some((x) => x.source === l.source && x.name === l.name)) libraries.push({ source: l.source, name: l.name, address });
    i = l.at + 40;
  }
  if (code.slice(i, a.creation.length) !== a.creation.slice(i)) return undefined;
  return { artifact: a, args: code.slice(a.creation.length), libraries };
}

/** The artifact `initCode` was built from: among those its start selects, the longest creation code that is a prefix
 * of it, the default profile first. */
export function matchArtifact(index: Map<string, Artifact[]>, initCode: string): Match | undefined {
  const code = strip(initCode);
  const candidates = [...(index.get(code.slice(0, KEY)) ?? []), ...(index.get(EARLY_LINK) ?? [])];
  // A creation code shorter than the key is its own key.
  for (const [k, list] of index) if (k !== EARLY_LINK && k.length < KEY && code.startsWith(k)) candidates.push(...list);
  const found = candidates.map((a) => matchOne(a, code)).filter((m): m is Match => m !== undefined);
  found.sort((x, y) => y.artifact.creation.length - x.artifact.creation.length || Number(x.artifact.profile !== "default") - Number(y.artifact.profile !== "default"));
  return found[0];
}

/** Every contract a broadcast directory records for `chainId` (every run of every script), and those of created.json. */
export function deployedContracts(broadcastRoot: string, chainId: number, created?: string): Deployed[] {
  const out = new Map<string, Deployed>();
  const add = (address: string | undefined, initCode: string | undefined) => {
    if (address && initCode && strip(initCode).length > 0) out.set(address.toLowerCase(), { address, initCode });
  };
  if (existsSync(broadcastRoot)) {
    for (const script of readdirSync(broadcastRoot)) {
      const dir = join(broadcastRoot, script, String(chainId));
      if (!existsSync(dir)) continue;
      for (const f of readdirSync(dir).filter((x) => /^run-\d+\.json$/.test(x)).sort()) {
        const run = JSON.parse(readFileSync(join(dir, f), "utf8")) as { transactions?: Record<string, any>[]; receipts?: Record<string, any>[] };
        const ok = new Set((run.receipts ?? []).filter((r) => r.status === "0x1" || r.status === 1).map((r) => String(r.transactionHash).toLowerCase()));
        for (const t of run.transactions ?? []) {
          if (t.hash && run.receipts && !ok.has(String(t.hash).toLowerCase())) continue;
          if (t.transactionType === "CREATE" || t.transactionType === "CREATE2") add(t.contractAddress, t.transaction?.input);
          for (const c of t.additionalContracts ?? []) add(c.address, c.initCode);
        }
      }
    }
  }
  if (created && existsSync(created)) for (const c of JSON.parse(readFileSync(created, "utf8")) as Deployed[]) add(c.address, c.initCode);
  return [...out.values()];
}

/** The longest constructor arguments (hex characters) passed to forge on its command line. Windows refuses a command
 * line over 32,767 characters, and the Aave V4 instance batches take a Spoke's or Hub's creation code (about 50,000):
 * longer arguments go to the explorer's API with the standard JSON input forge prints instead. */
export const ARGS_ON_COMMAND_LINE = 16_000;
/** How long forge checks a submitted verification: the explorer's queue can hold one for minutes, and forge's default
 * (5 checks, 5 seconds apart) gave up on contracts the explorer verified later. */
const WAIT = ["--retries", "20", "--delay", "15"];

/** The `forge verify-contract` invocation of one match: its arguments and the profile it runs under. With constructor
 * arguments too long for a command line, forge prints the standard JSON input (`--show-standard-json-input`) and the
 * arguments are returned for the explorer request (sourceRequest). */
export function verifyCommand(m: Match, address: string, chainId: number): { profile: string; args: string[]; constructorArgs?: string } {
  const a = m.artifact;
  const inline = m.args.length <= ARGS_ON_COMMAND_LINE;
  const args = ["verify-contract", address, `${a.source}:${a.name}`, "--chain", String(chainId), "--compiler-version", a.compiler];
  if (a.optimizer.enabled && a.optimizer.runs !== undefined) args.push("--num-of-optimizations", String(a.optimizer.runs));
  if (a.viaIR) args.push("--via-ir");
  if (a.evmVersion) args.push("--evm-version", a.evmVersion);
  if (a.compilationProfile) args.push("--compilation-profile", a.compilationProfile);
  if (m.args && inline) args.push("--constructor-args", `0x${m.args}`);
  for (const l of m.libraries) args.push("--libraries", `${l.source}:${l.name}:${l.address}`);
  if (!inline) return { profile: a.profile, args: [...args, "--show-standard-json-input"], constructorArgs: m.args };
  args.push("--watch", ...WAIT);
  return { profile: a.profile, args };
}

export interface VerifyOptions {
  readonly contracts: string;
  readonly outDir: string;
  readonly broadcastRoot: string;
  readonly chainId: number;
  readonly dryRun: boolean;
  readonly say: (s: string) => void;
}

/** The implementation an EIP-1167 minimal proxy (a clone: Slipstream's pools and gauges, for example) delegates to. */
export function cloneImplementation(initCode: string): string | undefined {
  const m = /363d3d373d3d3d363d73([0-9a-f]{40})5af43d82803e903d91602b57fd5bf3/.exec(strip(initCode));
  return m ? `0x${m[1]}` : undefined;
}

/** The CREATE3 deployer proxy (16 bytes of init code): a helper only the CREATE3 factory calls, never verified. */
export const isCreate3Helper = (initCode: string) => strip(initCode) === "67363d3d37363d34f03d5260086018f3";

/** A verified contract that is itself a proxy of a stored implementation, marked as such on the explorer too. */
const UPGRADEABLE_PROXY = /^(ERC1967Proxy|TransparentUpgradeableProxy|BeaconProxy|[A-Za-z]*UpgradeabilityProxy)$/;

/** The explorer's proxy verification request (Etherscan v2): the proxy, and the implementation a clone delegates to. */
export function proxyRequest(chainId: number, address: string, implementation?: string): { url: string; form: Record<string, string> } {
  return {
    url: `https://api.etherscan.io/v2/api?chainid=${chainId}`,
    form: { module: "contract", action: "verifyproxycontract", address, ...(implementation ? { expectedimplementation: implementation } : {}) },
  };
}

/** The explorer's source verification request (Etherscan v2) for a standard JSON input, sent with the input as
 * `sourceCode`: the contract, its compiler and its constructor arguments. */
export function sourceRequest(chainId: number, address: string, contract: string, compiler: string, constructorArgs: string): { url: string; form: Record<string, string> } {
  return {
    url: `https://api.etherscan.io/v2/api?chainid=${chainId}`,
    form: {
      module: "contract",
      action: "verifysourcecode",
      codeformat: "solidity-standard-json-input",
      contractaddress: address,
      contractname: contract,
      compilerversion: compiler,
      // The explorer's own spelling.
      constructorArguements: constructorArgs,
    },
  };
}

/** Submits `form` and waits for the explorer's verdict through `check`: undefined once verified, else its message. */
async function submit(url: string, form: Record<string, string>, check: string): Promise<string | undefined> {
  const key = process.env.ETHERSCAN_API_KEY!;
  const post = await fetch(url, { method: "POST", body: new URLSearchParams({ ...form, apikey: key }) });
  const sent = (await post.json()) as { status: string; result: string };
  if (sent.status !== "1") return /already verified/i.test(sent.result) ? undefined : sent.result;
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 5_000));
    const res = await fetch(`${url}&module=contract&action=${check}&guid=${encodeURIComponent(sent.result)}&apikey=${key}`);
    const c = (await res.json()) as { status: string; result: string };
    if (c.status === "1" || /already verified/i.test(c.result)) return undefined;
    if (!/pending|in queue|rate limit/i.test(c.result)) return c.result;
  }
  return "the explorer did not answer in time";
}

const submitProxy = (chainId: number, address: string, implementation: string | undefined) => {
  const { url, form } = proxyRequest(chainId, address, implementation);
  return submit(url, form, "checkproxyverification");
};

/**
 * Verifies every contract of the release not yet verified: each against its build output, then every proxy as a proxy
 * of its implementation (upgradeable proxies, and the minimal-proxy clones of a verified implementation, which have
 * no source of their own). Only CREATE3 helpers stay unverified. Returns how many verified, were skipped and failed.
 */
export async function verifyRelease(o: VerifyOptions): Promise<{ verified: number; skipped: number; failed: string[] }> {
  if (!o.dryRun && !process.env.ETHERSCAN_API_KEY) throw new Error("ETHERSCAN_API_KEY is not set, in the environment or the encrypted secrets store");
  const ledgerPath = join(o.outDir, "verified.json");
  const ledger = (existsSync(ledgerPath) ? JSON.parse(readFileSync(ledgerPath, "utf8")) : {}) as Record<string, string>;
  const save = () => writeFileSync(ledgerPath, `${JSON.stringify(ledger, null, 2)}\n`);
  const toml = readFileSync(join(o.contracts, "foundry.toml"), "utf8");
  const index = indexArtifacts(o.contracts, profileOuts(toml), compilerProfiles(toml));
  const failed: string[] = [];
  const proxies: { address: string; implementation?: string; name: string }[] = [];
  let verified = 0;
  let skipped = 0;
  for (const d of deployedContracts(o.broadcastRoot, o.chainId, join(o.outDir, "created.json"))) {
    const key = d.address.toLowerCase();
    const m = matchArtifact(index, d.initCode);
    const clone = m ? undefined : cloneImplementation(d.initCode);
    if (clone) proxies.push({ address: d.address, implementation: clone, name: "minimal proxy" });
    if (m && UPGRADEABLE_PROXY.test(m.artifact.name)) proxies.push({ address: d.address, name: m.artifact.name });
    if (ledger[key] || clone) {
      if (ledger[key]) skipped++;
      continue;
    }
    if (!m) {
      o.say(`  skip ${d.address}: ${isCreate3Helper(d.initCode) ? "a CREATE3 helper proxy" : "no build output matches its init code"}`);
      skipped++;
      continue;
    }
    const { profile, args, constructorArgs } = verifyCommand(m, d.address, o.chainId);
    const contract = `${m.artifact.source}:${m.artifact.name}`;
    if (o.dryRun) {
      const request = constructorArgs === undefined ? undefined : sourceRequest(o.chainId, d.address, contract, m.artifact.compiler, constructorArgs);
      const post = request ? ` | POST ${request.url} ${new URLSearchParams({ ...request.form, constructorArguements: `<${constructorArgs!.length / 2} bytes>`, sourceCode: "<the standard JSON input>", apikey: "<redacted>" }).toString()}` : "";
      o.say(`  FOUNDRY_PROFILE=${profile} ETHERSCAN_API_KEY=<redacted> forge ${args.join(" ")}${post}`);
      continue;
    }
    const r = spawnSync("forge", args, { cwd: o.contracts, env: { ...process.env, FOUNDRY_PROFILE: profile }, encoding: "utf8", maxBuffer: 1 << 26 });
    const text = `${r.stdout ?? ""}${r.stderr ?? ""}`;
    let error: string | undefined;
    if (r.error || r.status !== 0) {
      if (!/already verified/i.test(text)) error = r.error?.message ?? (text.trim().split(/\r?\n/).filter((l) => /error|fail/i.test(l)).slice(0, 2).join(" ") || `forge exited with ${r.status}`);
    } else if (constructorArgs !== undefined) {
      const { url, form } = sourceRequest(o.chainId, d.address, contract, m.artifact.compiler, constructorArgs);
      error = await submit(url, { ...form, sourceCode: r.stdout.trim() }, "checkverifystatus");
    }
    if (error === undefined) {
      ledger[key] = contract;
      save();
      verified++;
      o.say(`  verified ${d.address} ${m.artifact.name}`);
    } else {
      failed.push(`${d.address} ${m.artifact.name}: ${error}`);
      o.say(`  FAILED ${d.address} ${m.artifact.name}`);
    }
  }
  // The proxies, once their implementations are verified.
  for (const p of proxies) {
    const key = `proxy:${p.address.toLowerCase()}`;
    if (ledger[key]) {
      skipped++;
      continue;
    }
    const { url, form } = proxyRequest(o.chainId, p.address, p.implementation);
    if (o.dryRun) {
      o.say(`  POST ${url} ${new URLSearchParams({ ...form, apikey: "<redacted>" }).toString()}`);
      continue;
    }
    const err = await submitProxy(o.chainId, p.address, p.implementation);
    if (err) {
      failed.push(`${p.address} ${p.name} as a proxy: ${err}`);
      o.say(`  FAILED ${p.address} as a proxy`);
    } else {
      ledger[key] = p.implementation ?? "proxy";
      save();
      verified++;
      o.say(`  verified ${p.address} as a proxy${p.implementation ? ` of ${p.implementation}` : ""}`);
    }
  }
  return { verified, skipped, failed };
}

/** Records a contract deployed outside forge (a TypeScript step) for the verification pass. */
export function recordCreated(outDir: string, address: string, initCode: string): void {
  const path = join(outDir, "created.json");
  const list = (existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : []) as Deployed[];
  if (!list.some((x) => x.address.toLowerCase() === address.toLowerCase())) list.push({ address, initCode });
  writeFileSync(path, `${JSON.stringify(list, null, 2)}\n`);
}
