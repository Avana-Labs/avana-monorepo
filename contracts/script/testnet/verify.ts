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
// FOUNDRY_PROFILE=<that profile>, the explorer key only in the environment (ETHERSCAN_API_KEY, never an argument).
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

/** Every artifact of every profile's out directory, indexed by the start of its creation code. */
export function indexArtifacts(contracts: string, outs: Record<string, string>): Map<string, Artifact[]> {
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
        const a = readArtifact(profile, join(d, f), contracts);
        if (!a) continue;
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

/** The `forge verify-contract` invocation of one match: its arguments and the profile it runs under. */
export function verifyCommand(m: Match, address: string, chainId: number): { profile: string; args: string[] } {
  const a = m.artifact;
  const args = ["verify-contract", address, `${a.source}:${a.name}`, "--chain", String(chainId), "--compiler-version", a.compiler];
  if (a.optimizer.enabled && a.optimizer.runs !== undefined) args.push("--num-of-optimizations", String(a.optimizer.runs));
  if (a.viaIR) args.push("--via-ir");
  if (a.evmVersion) args.push("--evm-version", a.evmVersion);
  if (m.args) args.push("--constructor-args", `0x${m.args}`);
  for (const l of m.libraries) args.push("--libraries", `${l.source}:${l.name}:${l.address}`);
  args.push("--watch");
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

async function submitProxy(chainId: number, address: string, implementation: string | undefined): Promise<string | undefined> {
  const key = process.env.ETHERSCAN_API_KEY!;
  const { url, form } = proxyRequest(chainId, address, implementation);
  const post = await fetch(url, { method: "POST", body: new URLSearchParams({ ...form, apikey: key }) });
  const sent = (await post.json()) as { status: string; result: string };
  if (sent.status !== "1") return sent.result;
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 5_000));
    const check = await fetch(`${url}&module=contract&action=checkproxyverification&guid=${encodeURIComponent(sent.result)}&apikey=${key}`);
    const c = (await check.json()) as { status: string; result: string };
    if (c.status === "1") return undefined;
    if (!/pending|in queue/i.test(c.result)) return c.result;
  }
  return "the explorer did not answer in time";
}

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
  const index = indexArtifacts(o.contracts, profileOuts(readFileSync(join(o.contracts, "foundry.toml"), "utf8")));
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
    const { profile, args } = verifyCommand(m, d.address, o.chainId);
    if (o.dryRun) {
      o.say(`  FOUNDRY_PROFILE=${profile} ETHERSCAN_API_KEY=<redacted> forge ${args.join(" ")}`);
      continue;
    }
    const r = spawnSync("forge", args, { cwd: o.contracts, env: { ...process.env, FOUNDRY_PROFILE: profile }, encoding: "utf8", maxBuffer: 1 << 26 });
    const text = `${r.stdout ?? ""}${r.stderr ?? ""}`;
    if (r.status === 0 || /already verified/i.test(text)) {
      ledger[key] = `${m.artifact.source}:${m.artifact.name}`;
      save();
      verified++;
      o.say(`  verified ${d.address} ${m.artifact.name}`);
    } else {
      failed.push(`${d.address} ${m.artifact.name}: ${text.trim().split(/\r?\n/).filter((l) => /error|fail/i.test(l)).slice(0, 2).join(" ")}`);
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
