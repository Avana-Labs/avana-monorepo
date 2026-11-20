// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Deployment check of a release manifest against the chain (script/README.md "Verification before
// deployments/verified/"): every code hash, the runtime code of every Avana contract against the release build with
// immutables masked (TEST-134), the immutable wiring of each integration's core stack, every market against the
// RiskModule (two per pool, same LTV, fixed band), the keeper registry, and the Avana AccessManager's admin and the
// deployer's renunciation replayed from its role events.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { type Address, type Hex, type PublicClient, getAddress, parseAbi, parseAbiItem } from "viem";
import { riskModuleAbi } from "../abis/index.ts";
import { codeHash, getLogsChunked, implementationOf } from "./chain.ts";
import type { Immutable, ReleaseManifest } from "./types.ts";

export type Outcome = "pass" | "fail" | "pending";
export interface Check {
  readonly name: string;
  readonly outcome: Outcome;
  readonly detail: string;
}

const GRANTED = parseAbiItem("event RoleGranted(uint64 indexed roleId, address indexed account, uint32 delay, uint48 since, bool newMember)");
const REVOKED = parseAbiItem("event RoleRevoked(uint64 indexed roleId, address indexed account)");
/** OpenZeppelin AccessManager's ADMIN_ROLE. */
const ADMIN_ROLE = 0n;

/** Current members of every role of an OpenZeppelin AccessManager, replayed from its role events since `fromBlock`. */
async function managerRoles(client: PublicClient, manager: Address, fromBlock: number): Promise<Map<bigint, Set<string>>> {
  const holders = new Map<bigint, Set<string>>();
  const head = await client.getBlockNumber();
  const logs = await getLogsChunked(client, { address: manager, events: [GRANTED, REVOKED], fromBlock: BigInt(fromBlock), toBlock: head });
  logs.sort((a, b) => Number((a.blockNumber ?? 0n) - (b.blockNumber ?? 0n)) || (a.logIndex ?? 0) - (b.logIndex ?? 0));
  for (const log of logs) {
    const { roleId, account } = log.args as { roleId: bigint; account: Address };
    const set = holders.get(roleId) ?? new Set<string>();
    if (log.eventName === "RoleGranted") set.add(getAddress(account));
    else set.delete(getAddress(account));
    holders.set(roleId, set);
  }
  return holders;
}

/**
 * Runtime code of the release artifact with every immutable position masked (Foundry `immutableReferences`).
 * `artifact` is `<File>.sol:<Contract>` in contracts/out, or `<build>:<File>.sol:<Contract>` with build `out-aave` or
 * `liquidator` (packages/liquidator/out).
 */
function artifactRuntime(contractsDir: string, artifact: string): { code: string; masks: { start: number; length: number }[] } | null {
  const parts = artifact.split(":");
  const [build, file, name] = parts.length === 3 ? parts : ["out", ...parts];
  const outDir = build === "liquidator" ? join(contractsDir, "..", "packages", "liquidator", "out") : join(contractsDir, build!);
  const dir = join(outDir, file!);
  // A contract another compiler profile also builds has one artifact per profile; the default one is `.default.json`.
  const path = [join(dir, `${name}.json`), join(dir, `${name}.default.json`)].find(existsSync);
  if (!path) return null;
  const a = JSON.parse(readFileSync(path, "utf8")) as {
    deployedBytecode: { object: string; immutableReferences?: Record<string, { start: number; length: number }[]> };
  };
  return { code: a.deployedBytecode.object.replace(/^0x/, ""), masks: Object.values(a.deployedBytecode.immutableReferences ?? {}).flat() };
}

function mask(code: string, masks: { start: number; length: number }[]): string {
  const chars = code.split("");
  for (const m of masks) for (let i = m.start * 2; i < (m.start + m.length) * 2; i++) chars[i] = "0";
  return chars.join("");
}

const GETTERS = ["LP_VAULT", "RISK_MODULE", "LIQUIDATION_MODULE", "ADAPTER", "POOL", "OPERATOR"] as const;
const GETTER_ABI = parseAbi(GETTERS.map((n) => `function ${n}() view returns (address)`));
const AUTHORITY = parseAbi(["function authority() view returns (address)"]);

export async function verifyManifest(m: ReleaseManifest, client: PublicClient, contractsDir: string): Promise<Check[]> {
  const checks: Check[] = [];
  const add = (name: string, ok: boolean | "pending", detail = "") => checks.push({ name, outcome: ok === "pending" ? "pending" : ok ? "pass" : "fail", detail });
  const read = (address: Address, n: (typeof GETTERS)[number]) => client.readContract({ address, abi: GETTER_ABI, functionName: n }).then((a) => getAddress(a as string));
  const same = (a: string, b: string) => getAddress(a) === getAddress(b);

  add("chain id", (await client.getChainId()) === m.chainId, `manifest ${m.chainId}`);

  const compare = async (label: string, x: Pick<Immutable, "address" | "codeHash" | "artifact">) => {
    const onChain = await codeHash(client, x.address).catch(() => "0x" as Hex);
    add(`code hash ${label}`, onChain === x.codeHash, x.address);
    if (!x.artifact) return;
    const ref = artifactRuntime(contractsDir, x.artifact);
    if (!ref) return add(`release bytecode ${label}`, "pending", `artifact ${x.artifact} not in this build`);
    const code = ((await client.getCode({ address: x.address })) ?? "0x").replace(/^0x/, "");
    const ok = code.length === ref.code.length && mask(code, ref.masks) === mask(ref.code, ref.masks);
    add(`release bytecode ${label}`, ok, `${x.artifact}, ${ref.masks.length} immutable positions masked`);
  };

  await compare("Avana AccessManager", m.avana.accessManager);
  for (const x of m.avana.integrations) {
    const tag = `integration ${x.integrationId} (${x.kind})`;
    for (const k of ["lpVault", "riskModule", "liquidationModule", "aaveAdapter", "flashloanRepay"] as const) await compare(`${tag} ${k}`, x[k]);
    // Immutable wiring: one stack per LPVault.
    add(`${tag} RiskModule.LP_VAULT`, same(await read(x.riskModule.address, "LP_VAULT"), x.lpVault.address));
    add(`${tag} RiskModule.LIQUIDATION_MODULE`, same(await read(x.riskModule.address, "LIQUIDATION_MODULE"), x.liquidationModule.address));
    add(`${tag} LiquidationModule.RISK_MODULE`, same(await read(x.liquidationModule.address, "RISK_MODULE"), x.riskModule.address));
    add(`${tag} AaveAdapter.RISK_MODULE`, same(await read(x.aaveAdapter.address, "RISK_MODULE"), x.riskModule.address));
    add(`${tag} FlashloanRepay.ADAPTER`, same(await read(x.flashloanRepay.address, "ADAPTER"), x.aaveAdapter.address));
    add(`${tag} FlashloanRepay.POOL`, same(await read(x.flashloanRepay.address, "POOL"), m.aave.v3Pool.address));
    for (const k of ["lpVault", "riskModule", "liquidationModule", "aaveAdapter"] as const) {
      const authority = await client.readContract({ address: x[k].address, abi: AUTHORITY, functionName: "authority" }).catch(() => null);
      if (authority !== null) add(`${tag} ${k} authority`, same(authority, m.avana.accessManager.address), authority);
    }
    // Keeper registry: borrowing stops while it is empty.
    const keepers = (await client.readContract({ address: x.riskModule.address, abi: riskModuleAbi, functionName: "getKeepers" })).map((k) => getAddress(k));
    const missing = m.roles.keepers.filter((k) => !keepers.includes(getAddress(k)));
    add(`${tag} keepers registered`, keepers.length > 0 && missing.length === 0, missing.length ? `missing: ${missing.join(", ")}` : `${keepers.length} keeper(s)`);
  }
  for (const f of m.avana.flashLiquidators) {
    const x = m.avana.integrations.find((i) => i.integrationId === f.integrationId);
    await compare(`FlashLiquidator ${f.address}`, f);
    add(`FlashLiquidator ${f.address} LIQUIDATION_MODULE`, !!x && same(await read(f.address, "LIQUIDATION_MODULE"), x.liquidationModule.address));
    add(`FlashLiquidator ${f.address} OPERATOR`, same(await read(f.address, "OPERATOR"), f.operator));
    add(`FlashLiquidator ${f.address} POOL`, same(await read(f.address, "POOL"), m.aave.v3Pool.address));
  }

  // Markets: each matches the RiskModule's record, and each pool's pair is Full + Custom with one LTV.
  for (const mk of m.markets) {
    const tag = `market ${mk.marketId} (${mk.name})`;
    const x = m.avana.integrations.find((i) => i.integrationId === mk.integrationId);
    if (!x) {
      add(tag, false, `integration ${mk.integrationId} not in the manifest`);
      continue;
    }
    await compare(`${tag} vault token`, mk.vaultToken);
    await compare(`${tag} LPOracle`, mk.lpOracle);
    const r = await client.readContract({ address: x.riskModule.address, abi: riskModuleAbi, functionName: "getMarket", args: [BigInt(mk.marketId)] });
    const kind = r.kind === 0 ? "full-range" : "custom-range";
    add(`${tag} RiskModule record`,
      kind === mk.kind && r.bandLower === mk.bandLower && r.bandUpper === mk.bandUpper && r.ltvBps === mk.ltvBps &&
        same(r.spoke, mk.spoke) && same(r.vaultToken, mk.vaultToken.address) && same(r.lpOracle, mk.lpOracle.address) &&
        r.reserveId === BigInt(mk.reserveId) && r.pool.toLowerCase() === mk.pool.toLowerCase(),
      `${kind} [${r.bandLower}, ${r.bandUpper}] ltv ${r.ltvBps}`);
    add(`${tag} active`, r.active ? true : "pending", r.active ? "" : "activated by 09_ListMarkets activate, not run yet");
    const pair = await client.readContract({ address: x.riskModule.address, abi: riskModuleAbi, functionName: "marketsOf", args: [mk.pool] });
    add(`${tag} pool's ${mk.kind} market`, (mk.kind === "full-range" ? pair.fullRange : pair.customRange) === BigInt(mk.marketId));
  }
  for (const x of [...m.coverage.firstLossReserves, ...m.coverage.daoDeficitOffsets]) await compare(`loss layer ${x.hubLabel} ${x.symbol}`, x);
  for (const r of m.debtReserves) {
    add(`debt reserve ${r.spoke}/${r.debtReserveId} First-Loss Reserve listed`, m.coverage.firstLossReserves.some((f) => same(f.address, r.firstLossReserve)), r.firstLossReserve);
  }
  for (const u of [...m.aave.hubs, ...m.aave.borrowSpokes, ...m.aave.lendSpokes, m.aave.v3Pool]) {
    add(`ERC-1967 implementation ${u.address}`, (await implementationOf(client, u.address)) === u.implementation || u.implementation === u.address, u.implementation);
  }
  for (const e of m.external) add(`code hash ${e.group} ${e.name}`, (await codeHash(client, e.address).catch(() => "0x")) === e.codeHash, e.address);

  // The Avana AccessManager: the Aave governance executor is its only admin and the deployer holds no role.
  const roles = await managerRoles(client, m.avana.accessManager.address, m.avana.accessManager.startBlock);
  const admins = [...(roles.get(ADMIN_ROLE) ?? [])];
  add("AccessManager ADMIN_ROLE", admins.length === 1 && same(admins[0]!, m.roles.aaveGovernanceExecutor), admins.join(", "));
  const deployer = getAddress(m.deployer);
  const held = [...roles].filter(([, h]) => h.has(deployer)).map(([id]) => id.toString());
  add("AccessManager: deployer holds no role", held.length === 0, held.join(", "));
  return checks;
}
