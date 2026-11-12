// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Deployment check of a release manifest against the chain (script/README.md "Verification before
// deployments/verified/"): every code hash, ERC-1967 implementation and admin slot (TEST-137), the runtime code of
// every Avana contract against the release build with immutables masked (TEST-134), the role snapshot replayed from
// RoleGranted/RoleRevoked (REQ-ACCESS-023, TEST-214), the timelock settings and the immutable wiring (REQ-ACCESS-027).

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { type Address, type Hex, type PublicClient, getAddress, keccak256, parseAbi, parseAbiItem, stringToBytes, zeroHash } from "viem";
import { adminOf, codeHash, implementationOf } from "./chain.ts";
import type { Immutable, ReleaseManifest, Upgradeable } from "./types.ts";

export type Outcome = "pass" | "fail" | "pending";
export interface Check {
  readonly name: string;
  readonly outcome: Outcome;
  readonly detail: string;
}

const ROLE = (s: string) => keccak256(stringToBytes(s));
const ROLES: Record<string, Hex> = {
  DEFAULT_ADMIN_ROLE: zeroHash,
  APPLICATION_ADMIN: ROLE("APPLICATION_ADMIN"),
  APPLICATION_PAUSE_GUARDIAN: ROLE("APPLICATION_PAUSE_GUARDIAN"),
  APPLICATION_FREEZE_GUARDIAN: ROLE("APPLICATION_FREEZE_GUARDIAN"),
  APPLICATION_RISK_STEWARD: ROLE("APPLICATION_RISK_STEWARD"),
  PROPOSER_ROLE: ROLE("PROPOSER_ROLE"),
  EXECUTOR_ROLE: ROLE("EXECUTOR_ROLE"),
  CANCELLER_ROLE: ROLE("CANCELLER_ROLE"),
  DAO_CANCELLER_ROLE: ROLE("DAO_CANCELLER_ROLE"),
};
const roleName = (h: string) => Object.entries(ROLES).find(([, v]) => v === h)?.[0] ?? h;

const GRANTED = parseAbiItem("event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender)");
const REVOKED = parseAbiItem("event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender)");

/** Current holders of every role of `contract`, replayed from its role events since `fromBlock`. */
async function roleHolders(client: PublicClient, contract: Address, fromBlock: number): Promise<Map<string, Set<string>>> {
  const holders = new Map<string, Set<string>>();
  const logs = await client.getLogs({ address: contract, events: [GRANTED, REVOKED], fromBlock: BigInt(fromBlock), toBlock: "latest" });
  logs.sort((a, b) => Number((a.blockNumber ?? 0n) - (b.blockNumber ?? 0n)) || (a.logIndex ?? 0) - (b.logIndex ?? 0));
  for (const log of logs) {
    const { role, account } = log.args as { role: Hex; account: Address };
    const set = holders.get(role) ?? new Set<string>();
    if (log.eventName === "RoleGranted") set.add(getAddress(account));
    else set.delete(getAddress(account));
    holders.set(role, set);
  }
  return holders;
}

/** Runtime code of the release artifact with every immutable position masked (Foundry `immutableReferences`). */
function artifactRuntime(contractsDir: string, artifact: string): { code: string; masks: { start: number; length: number }[] } | null {
  let outDir = "out";
  let spec = artifact;
  if (artifact.startsWith("out-aave:")) {
    outDir = "out-aave";
    spec = artifact.slice("out-aave:".length);
  }
  const [file, name] = spec.split(":");
  const dir = join(contractsDir, outDir, file!);
  const candidates = ["collateralization", "lporacle", "clvault"].map((p) => join(dir, `${name}.${p}.json`)).concat(join(dir, `${name}.json`));
  const profiled = candidates.find((c) => existsSync(c) && profileOf(file!) !== "" && c.includes(`.${profileOf(file!)}.json`));
  const path = profiled ?? join(dir, `${name}.json`);
  if (!existsSync(path)) return null;
  const a = JSON.parse(readFileSync(path, "utf8")) as {
    deployedBytecode: { object: string; immutableReferences?: Record<string, { start: number; length: number }[]> };
  };
  return { code: a.deployedBytecode.object.replace(/^0x/, ""), masks: Object.values(a.deployedBytecode.immutableReferences ?? {}).flat() };
}

/** The compiler profile a deployable file is restricted to (script/deploy/lib/DeployBase.sol `_profileOf`). */
function profileOf(file: string): string {
  if (file === "Collateralization.sol" || file.startsWith("DebtOracle") || (file.startsWith("LPVaultSwap") && file.endsWith("Logic.sol")) || (file.startsWith("Lens") && file.endsWith("Module.sol"))) {
    return "collateralization";
  }
  if (file === "UniswapV3Integration.sol" || file === "SlipstreamIntegration.sol") return "clvault";
  if (file.startsWith("LPOracle")) return "lporacle";
  return "";
}

function mask(code: string, masks: { start: number; length: number }[]): string {
  const chars = code.split("");
  for (const m of masks) for (let i = m.start * 2; i < (m.start + m.length) * 2; i++) chars[i] = "0";
  return chars.join("");
}

export async function verifyManifest(m: ReleaseManifest, client: PublicClient, contractsDir: string): Promise<Check[]> {
  const checks: Check[] = [];
  const add = (name: string, ok: boolean | "pending", detail = "") => checks.push({ name, outcome: ok === "pending" ? "pending" : ok ? "pass" : "fail", detail });

  add("chain id", (await client.getChainId()) === m.chainId, `manifest ${m.chainId}`);

  const immutables: [string, Immutable][] = [
    ["AvanaTimelock", m.avana.timelock],
    ["ProxyManager", m.avana.proxyManager],
    ["Collateralization", m.avana.collateralization],
    ["VaultTokenFactory", m.avana.vaultTokenFactory],
    ["PayoutEscrow", m.avana.payoutEscrow],
    ["Lock", m.avana.lock],
    ["Lens", m.avana.lens],
    ["LensAaveSizing", m.avana.lensAaveSizing],
    ["AaveV3FlashSource", m.avana.flashSource],
    ["FlashLiquidator", m.avana.flashLiquidator],
    ["DebtOracle implementation", m.avana.debtOracleImplementation],
    ...m.avana.lensModules.map((x, i): [string, Immutable] => [`Lens module ${i}`, x]),
    ...m.avana.operatorHelpers.map((x, i): [string, Immutable] => [`OperatorFlashLiquidator ${i}`, x]),
    ...m.avana.lpVaults.map((x): [string, Immutable] => [`LPVault ${x.integrationId} (${x.kind})`, x]),
    ...(m.avana.clOraclePricing ? [["LPOracleCL implementation", m.avana.clOraclePricing] as [string, Immutable]] : []),
  ];
  const upgradeables: [string, Upgradeable][] = [
    ["AaveAdapter", m.avana.aaveAdapter],
    ["LPVaultSwap", m.avana.lpVaultSwap],
    ["MarketRegistry", m.avana.marketRegistry],
    ["ParameterStore", m.avana.parameterStore],
    ["RiskModule", m.avana.riskModule],
  ];
  const compare = async (label: string, address: Address, expectedHash: Hex, artifact: string | null) => {
    const onChain = await codeHash(client, address).catch(() => "0x" as Hex);
    add(`code hash ${label}`, onChain === expectedHash, address);
    if (!artifact) return;
    const ref = artifactRuntime(contractsDir, artifact);
    if (!ref) return add(`release bytecode ${label}`, "pending", `artifact ${artifact} not in this build`);
    const code = ((await client.getCode({ address })) ?? "0x").replace(/^0x/, "");
    const same = code.length === ref.code.length && mask(code, ref.masks) === mask(ref.code, ref.masks);
    add(`release bytecode ${label}`, same, `${artifact}, ${ref.masks.length} immutable positions masked`);
  };
  for (const [label, x] of immutables) await compare(label, x.address, x.codeHash, x.artifact);
  for (const [label, u] of upgradeables) {
    add(`ERC-1967 implementation ${label}`, (await implementationOf(client, u.address)) === u.implementation, u.implementation);
    add(`no ProxyAdmin ${label}`, (await adminOf(client, u.address)) === 0n);
    await compare(`${label} proxy`, u.address, u.codeHash, null);
    await compare(`${label} implementation`, u.implementation, u.implementationCodeHash, u.implementationArtifact);
    for (const l of u.logics) await compare(`${label} ${l.name}`, l.address, l.codeHash, l.artifact);
  }
  for (const e of m.external) add(`code hash ${e.group} ${e.name}`, (await codeHash(client, e.address).catch(() => "0x")) === e.codeHash, e.address);

  // Timelock settings (REQ-ACCESS-027).
  const tl = parseAbi([
    "function normalDelay() view returns (uint256)",
    "function MIN_NORMAL_DELAY() view returns (uint256)",
    "function publicExecution() view returns (bool)",
  ]);
  const t = m.avana.timelock.address;
  add("timelock normalDelay", Number(await client.readContract({ address: t, abi: tl, functionName: "normalDelay" })) === m.roles.timelock.normalDelay);
  add("timelock MIN_NORMAL_DELAY = 345,600", (await client.readContract({ address: t, abi: tl, functionName: "MIN_NORMAL_DELAY" })) === 345_600n);
  add("timelock publicExecution", (await client.readContract({ address: t, abi: tl, functionName: "publicExecution" })) === m.roles.timelock.publicExecution);

  // Role snapshot (REQ-ACCESS-023, TEST-214): every holder is in the table, every table entry holds its role.
  const r = m.roles;
  const g = (xs: readonly Address[]) => new Set(xs.map((x) => getAddress(x)));
  const expect: [string, Address, Record<string, Set<string>>, string[]][] = [
    ["AvanaTimelock", t, {
      DEFAULT_ADMIN_ROLE: g([t]),
      PROPOSER_ROLE: g(r.timelock.proposers),
      // Public execution is OpenZeppelin's EXECUTOR_ROLE held by address(0) (REQ-ACCESS-021, TEST-214).
      EXECUTOR_ROLE: g([...r.timelock.executors, ...(r.timelock.publicExecution ? ["0x0000000000000000000000000000000000000000" as Address] : [])]),
      CANCELLER_ROLE: g(r.timelock.cancellers),
      DAO_CANCELLER_ROLE: g(r.timelock.daoCancellers),
    }, []],
    ["MarketRegistry", m.avana.marketRegistry.address, {
      DEFAULT_ADMIN_ROLE: g([t]), APPLICATION_ADMIN: g([t]),
      APPLICATION_PAUSE_GUARDIAN: g(r.marketRegistryGuardians), APPLICATION_FREEZE_GUARDIAN: g(r.marketRegistryGuardians),
    }, ["APPLICATION_PAUSE_GUARDIAN", "APPLICATION_FREEZE_GUARDIAN"]],
    ["ParameterStore", m.avana.parameterStore.address, {
      DEFAULT_ADMIN_ROLE: g([t]), APPLICATION_ADMIN: g([t]),
      APPLICATION_PAUSE_GUARDIAN: g(r.parameterStorePauseGuardians), APPLICATION_RISK_STEWARD: g(r.riskStewards),
    }, ["APPLICATION_PAUSE_GUARDIAN", "APPLICATION_RISK_STEWARD"]],
    ["AaveAdapter", m.avana.aaveAdapter.address, { DEFAULT_ADMIN_ROLE: g([t]), APPLICATION_ADMIN: g([t]) }, []],
    ["RiskModule", m.avana.riskModule.address, { DEFAULT_ADMIN_ROLE: g([t]), APPLICATION_ADMIN: g([t]) }, []],
    ["LPVaultSwap", m.avana.lpVaultSwap.address, { DEFAULT_ADMIN_ROLE: g([t]), APPLICATION_ADMIN: g([t]) }, []],
  ];
  const deployer = getAddress(m.deployer);
  for (const [label, address, table, firstOperation] of expect) {
    const held = await roleHolders(client, address, m.avana.timelock.startBlock);
    for (const [role, holders] of held) {
      if (!Object.values(ROLES).includes(role as Hex) && holders.size > 0) add(`${label} unknown role`, false, `${role}: ${[...holders].join(", ")}`);
    }
    for (const [name, want] of Object.entries(table)) {
      const have = held.get(ROLES[name]!) ?? new Set<string>();
      const extra = [...have].filter((a) => !want.has(a));
      const missing = [...want].filter((a) => !have.has(a));
      const label2 = `${label} ${name}`;
      if (extra.length > 0) add(label2, false, `holders outside the table: ${extra.join(", ")}`);
      else if (missing.length > 0 && firstOperation.includes(name) && have.size === 0) add(label2, "pending", "granted by the guardian-roles operation, not executed yet");
      else add(label2, missing.length === 0, missing.length ? `missing: ${missing.join(", ")}` : `${want.size} holder(s)`);
    }
    const deployerRoles = [...held].filter(([, h]) => h.has(deployer)).map(([role]) => roleName(role));
    add(`${label}: deployer holds no role`, deployerRoles.length === 0, deployerRoles.join(", "));
  }

  // Immutable wiring (REQ-VTOKEN-044, REQ-ESCROW-001).
  const getter = (n: string) => parseAbi([`function ${n}() view returns (address)`]);
  const read = (address: Address, n: string) => client.readContract({ address, abi: getter(n), functionName: n }) as Promise<Address>;
  add("VaultTokenFactory.TIMELOCK", (await read(m.avana.vaultTokenFactory.address, "TIMELOCK")) === t);
  add("PayoutEscrow.LP_VAULT_SWAP", (await read(m.avana.payoutEscrow.address, "LP_VAULT_SWAP")) === m.avana.lpVaultSwap.address);
  for (const v of m.avana.lpVaults) {
    add(`LPVault ${v.integrationId} TIMELOCK`, (await read(v.address, "TIMELOCK")) === t);
    add(`LPVault ${v.integrationId} MARKET_REGISTRY`, (await read(v.address, "MARKET_REGISTRY")) === m.avana.marketRegistry.address);
  }
  add("concentrated-liquidity LPOracle implementation", m.avana.clOraclePricing ? true : "pending", m.avana.clOraclePricing ? "" : "LPOracleCL not deployed: integrations unregistered, no market listable");
  return checks;
}
