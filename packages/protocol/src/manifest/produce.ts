// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Release manifest producer: reads what the step 9 deploy scripts wrote (contracts/deployments-local/<network>/:
// avana.json from 03_DeployAvana, markets.json from 09_ListMarkets, coverage.json from 07_DeployFirstLossReserves, and
// aave.json / world.json on test networks), the network's inputs (contracts/script/deploy/config/<network>.json) and
// the Foundry broadcast receipts, then reads every code hash, the tokens, reserve IDs and feeds of each market and the
// keeper registry from the chain, and writes a manifest that validates against schema.ts.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { type Address, type Hex, type PublicClient, getAddress, parseAbi, zeroAddress } from "viem";
import { ABI_HASH, lpOracleAbi, lpVaultAbi, riskModuleAbi } from "../abis/index.ts";
import { broadcastBlocks, codeHash, firstBlockWithCode, implementationOf } from "./chain.ts";
import { validate } from "./schema.ts";
import type { DebtReserve, External, FlashLiquidator, Immutable, Integration, LossLayer, Market, ReleaseManifest, Upgradeable } from "./types.ts";

export interface ProduceOptions {
  readonly client: PublicClient;
  /** contracts/ of the checkout that ran the deployment. */
  readonly contractsDir: string;
  readonly network: string;
  readonly commit: string;
  /** Overrides the release of the deploy output. */
  readonly release?: string;
}

const art = (name: string) => `${name}.sol:${name}`;

/** The LPVault artifact each integration kind deploys (`03_DeployAvana._lpVaultCode`). */
export function integrationArtifacts(kind: string): { lpVault: string } {
  switch (kind) {
    case "uniswap-v3":
      return { lpVault: art("UniswapV3Integration") };
    case "slipstream":
      return { lpVault: art("SlipstreamIntegration") };
    case "uniswap-v4":
      return { lpVault: art("UniswapV4Integration") };
    default:
      throw new Error(`unknown integration kind ${kind}`);
  }
}

type Json = Record<string, unknown>;

function readJson(path: string): Json {
  if (!existsSync(path)) throw new Error(`missing ${path}: run the deploy step that writes it`);
  return JSON.parse(readFileSync(path, "utf8")) as Json;
}

function at(obj: Json, path: string): unknown {
  return path.split(".").reduce<unknown>((o, k) => (o as Json | undefined)?.[k], obj);
}

/** Resolves a config address, literal or a `$<file>:<path>` reference to a deploy output (DeployInputs.sol). */
function resolveAddress(value: unknown, outputs: (file: string) => Json): Address {
  if (typeof value !== "string") throw new Error(`not an address: ${JSON.stringify(value)}`);
  if (!value.startsWith("$")) return getAddress(value);
  const [file, path] = value.slice(1).split(":");
  return getAddress(at(outputs(file!), path!.replace(/^\./, "")) as string);
}

/** One column of a deploy output, checked to be an array of `n` entries. */
function column<T>(out: Json, key: string, n?: number): T[] {
  const v = out[key];
  if (!Array.isArray(v)) throw new Error(`deploy output has no array ${key}`);
  if (n !== undefined && v.length !== n) throw new Error(`deploy output ${key} has ${v.length} entries, expected ${n}`);
  return v as T[];
}

const ERC20 = parseAbi(["function decimals() view returns (uint8)"]);
const FLASH = parseAbi(["function OPERATOR() view returns (address)", "function LIQUIDATION_MODULE() view returns (address)"]);

export async function produceManifest(o: ProduceOptions): Promise<ReleaseManifest> {
  const { client, contractsDir, network } = o;
  const outDir = join(contractsDir, "deployments-local", network);
  const cache = new Map<string, Json>();
  const outputs = (file: string) => {
    if (!cache.has(file)) cache.set(file, readJson(join(outDir, `${file}.json`)));
    return cache.get(file)!;
  };
  const has = (file: string) => existsSync(join(outDir, `${file}.json`));
  const config = readJson(join(contractsDir, process.env.AVANA_CONFIG ?? `script/deploy/config/${network}.json`));
  const cfgAddr = (path: string) => resolveAddress(at(config, path), outputs);
  const avana = outputs("avana");
  const chainId = await client.getChainId();
  if (chainId !== Number(avana.chainId)) throw new Error(`RPC chain ${chainId} is not the deployment's ${String(avana.chainId)}`);

  const blocks = broadcastBlocks(contractsDir, chainId);
  const startBlock = async (a: Address) => blocks.get(a.toLowerCase()) ?? (await firstBlockWithCode(client, a));
  const imm = async (a: unknown, artifact: string | null): Promise<Immutable> => {
    const address = getAddress(a as string);
    return { address, codeHash: await codeHash(client, address), startBlock: await startBlock(address), artifact };
  };
  const external: External[] = [];
  const ext = async (name: string, group: string, a: unknown, standIn: boolean) => {
    const address = getAddress(a as string);
    external.push({ name, group, address, codeHash: await codeHash(client, address), implementation: await implementationOf(client, address), standIn });
  };
  const thirdPartyUpg = async (a: Address): Promise<Upgradeable> => {
    const implementation = (await implementationOf(client, a)) ?? a;
    return { address: a, codeHash: await codeHash(client, a), implementation, implementationCodeHash: await codeHash(client, implementation), startBlock: await startBlock(a) };
  };
  const read = <T>(address: Address, abi: readonly unknown[], functionName: string, args: readonly unknown[] = []) =>
    client.readContract({ address, abi: abi as never, functionName: functionName as never, args: args as never }) as Promise<T>;

  // Aave V4: the network's own deployment (aave.json) on test networks, the config's literal addresses otherwise.
  const aaveOut = has("aave") ? outputs("aave") : null;
  const hubCfg = (at(config, "aave.hubs") as { hub: string; tier: number; label?: string }[]) ?? [];
  const hubs: (Upgradeable & { label: string; tier: number })[] = [];
  for (const h of hubCfg) {
    const a = resolveAddress(h.hub, outputs);
    const label = h.label ?? Object.entries((aaveOut?.hubs as Record<string, { proxy: string }>) ?? {}).find(([, v]) => getAddress(v.proxy) === a)?.[0] ?? a;
    hubs.push({ ...(await thirdPartyUpg(a)), label, tier: h.tier });
  }
  const borrowSpokes: (Upgradeable & { label: string })[] = [];
  const lendSpokes: (Upgradeable & { label: string })[] = [];
  for (const [label, s] of Object.entries((aaveOut?.spokes as Record<string, { proxy: string; oracle: string }>) ?? {})) {
    const u = { ...(await thirdPartyUpg(getAddress(s.proxy))), label };
    (label.startsWith("lend") ? lendSpokes : borrowSpokes).push(u);
    await ext(`Spoke ${label}`, "aave-v4", s.proxy, false);
    await ext(`AaveOracle ${label}`, "aave-v4", s.oracle, false);
  }
  if (aaveOut) {
    for (const k of ["accessManager", "hubConfigurator", "spokeConfigurator", "treasurySpoke", "liquidationLogic"]) await ext(k, "aave-v4", aaveOut[k], false);
    for (const [label, h] of Object.entries(aaveOut.hubs as Record<string, { proxy: string; irStrategy: string }>)) {
      await ext(`Hub ${label}`, "aave-v4", h.proxy, false);
      await ext(`Interest-rate strategy ${label}`, "aave-v4", h.irStrategy, false);
    }
  }
  const world = has("world") ? outputs("world") : null;
  if (world) {
    for (const [group, entries] of Object.entries((world.external as Record<string, Record<string, { address: string; standIn: boolean }>>) ?? {})) {
      for (const [name, e] of Object.entries(entries)) await ext(name, group, e.address, e.standIn);
    }
    for (const [sym, f] of Object.entries((world.feeds as Record<string, Record<string, string>>) ?? {})) {
      for (const [role, a] of Object.entries(f)) await ext(`${sym} / USD (${role})`, "feed", a, false);
    }
  }

  // The core stacks, aligned by integration (DeploymentOutput.sol).
  const ids = column<number>(avana, "integrationIds").map(Number);
  const n = ids.length;
  const kinds = column<string>(avana, "integrationKinds", n);
  const cols = (k: string) => column<string>(avana, k, n);
  const [lpVaults, riskModules, liquidationModules, aaveAdapters, flashloanRepays] = ["lpVaults", "riskModules", "liquidationModules", "aaveAdapters", "flashloanRepays"].map(cols) as [string[], string[], string[], string[], string[]];
  const integrations: Integration[] = [];
  for (let i = 0; i < n; i++) {
    integrations.push({
      integrationId: ids[i]!,
      kind: kinds[i]!,
      lpVault: await imm(lpVaults[i], integrationArtifacts(kinds[i]!).lpVault),
      riskModule: await imm(riskModules[i], art("RiskModule")),
      liquidationModule: await imm(liquidationModules[i], art("LiquidationModule")),
      aaveAdapter: await imm(aaveAdapters[i], art("AaveAdapter")),
      flashloanRepay: await imm(flashloanRepays[i], art("FlashloanRepay")),
    });
  }
  const integrationOfModule = new Map(integrations.map((x) => [x.liquidationModule.address.toLowerCase(), x.integrationId]));
  const flashLiquidators: FlashLiquidator[] = [];
  for (const a of column<string>(avana, "flashLiquidators")) {
    const address = getAddress(a);
    const module = await read<Address>(address, FLASH, "LIQUIDATION_MODULE");
    const integrationId = integrationOfModule.get(module.toLowerCase());
    if (integrationId === undefined) throw new Error(`FlashLiquidator ${address} serves LiquidationModule ${module}, which no integration lists`);
    flashLiquidators.push({ ...(await imm(address, "liquidator:FlashLiquidator.sol:FlashLiquidator")), integrationId, operator: getAddress(await read<Address>(address, FLASH, "OPERATOR")) });
  }

  const heartbeat = Number(at(config, "listing.feed.heartbeat") ?? 0);
  const markets = has("markets") ? await listedMarkets(outputs("markets"), integrations, heartbeat, imm, read) : [];
  const debtReserves = has("markets") ? await listedDebtReserves(config, outputs, integrations, heartbeat, read) : [];
  const coverage = has("coverage") ? await lossLayers(outputs("coverage"), imm) : { firstLossReserves: [], daoDeficitOffsets: [] };

  // The keeper registry of every RiskModule; the manifest records the keepers registered in all of them.
  const registries = await Promise.all(integrations.map((x) => read<readonly Address[]>(x.riskModule.address, riskModuleAbi, "getKeepers")));
  const keepers = (registries[0] ?? []).map((k) => getAddress(k)).filter((k) => registries.every((r) => r.some((x) => getAddress(x) === k)));
  // The top-up wallet as 11_FundKeepers reads it: KEEPER_TOPUP_WALLET when set, else the config's keeperTopUp.wallet.
  const topUpWallet = process.env.KEEPER_TOPUP_WALLET || (at(config, "keeperTopUp.wallet") as string | undefined);
  const uniswapV4 = await uniswapV4PoolManager(client, integrations, imm);
  const gov = (k: string) => cfgAddr(`governance.${k}`);

  const manifest: ReleaseManifest = {
    schemaVersion: 2,
    chainId,
    network,
    release: o.release ?? (avana.release as string),
    commit: o.commit,
    abiHash: ABI_HASH,
    deployer: getAddress(avana.deployer as string),
    create3Factory: getAddress(avana.create3Factory as string),
    feeRecipient: cfgAddr("parameters.globals.feeRecipient"),
    sequencerFeed: at(config, "chain.hasSequencer") ? cfgAddr("chain.sequencerFeed") : null,
    avana: {
      accessManager: await imm(avana.accessManager, art("AccessManager")),
      integrations,
      flashLiquidators,
    },
    markets,
    debtReserves,
    coverage,
    aave: {
      hubs,
      borrowSpokes,
      lendSpokes,
      v3Pool: await thirdPartyUpg(cfgAddr("aave.v3Pool")),
      accessManager: cfgAddr("aave.accessManager"),
    },
    roles: {
      aaveGovernanceExecutor: gov("aaveGovernanceExecutor"),
      governanceSafe: gov("governanceSafe"),
      emergencyGuardian: gov("emergencyGuardian"),
      aaveProtocolGuardian: gov("aaveProtocolGuardian"),
      jointConfigSafe: gov("jointConfigSafe"),
      keepers,
      keeperTopUp: topUpWallet
        ? {
            wallet: resolveAddress(topUpWallet, outputs),
            minBalanceWei: BigInt(String(at(config, "keeperTopUp.minBalanceWei") ?? "0")).toString(),
            targetBalanceWei: BigInt(String(at(config, "keeperTopUp.targetBalanceWei") ?? "0")).toString(),
          }
        : null,
    },
    external,
    ...(uniswapV4 ? { uniswapV4 } : {}),
  };
  const errors = validate(manifest);
  if (errors.length > 0) throw new Error(`produced manifest fails the schema:\n${errors.map((e) => `  ${e.path}: ${e.message}`).join("\n")}`);
  return manifest;
}

type Read = <T>(address: Address, abi: readonly unknown[], functionName: string, args?: readonly unknown[]) => Promise<T>;

/**
 * The markets 09_ListMarkets wrote (markets.json, aligned arrays), with the tokens from the LPVault, the vault token's
 * reserve from the RiskModule and every price-feed leg from the LPOracle.
 */
export async function listedMarkets(
  out: Json,
  integrations: readonly Integration[],
  heartbeatSeconds: number,
  imm: (a: unknown, artifact: string | null) => Promise<Immutable>,
  read: Read,
): Promise<Market[]> {
  const ids = column<number | string>(out, "marketIds");
  const n = ids.length;
  const c = <T>(k: string) => column<T>(out, k, n);
  const [names, integrationIds, pools, kinds, spokes, hubs, vaultTokens, lpOracles, unitDecimals, ltvBps, lowers, uppers] = [
    c<string>("names"),
    c<number>("integrationIds"),
    c<string>("pools"),
    c<number>("kinds"),
    c<string>("spokes"),
    c<string>("hubs"),
    c<string>("vaultTokens"),
    c<string>("lpOracles"),
    c<number>("unitDecimals"),
    c<number>("ltvBps"),
    c<number>("bandLowers"),
    c<number>("bandUppers"),
  ];
  const markets: Market[] = [];
  for (let i = 0; i < n; i++) {
    const marketId = BigInt(ids[i]!);
    const integration = integrations.find((x) => x.integrationId === Number(integrationIds[i]));
    if (!integration) throw new Error(`market ${marketId} names integration ${integrationIds[i]}, which avana.json does not list`);
    const v = await read<{ token0: Address; token1: Address }>(integration.lpVault.address, lpVaultAbi, "getMarket", [marketId]);
    const rm = await read<{ reserveId: bigint }>(integration.riskModule.address, riskModuleAbi, "getMarket", [marketId]);
    const lpOracle = getAddress(lpOracles[i]!);
    const feeds: Address[] = [];
    if (lpOracle !== zeroAddress) for (const k of [0n, 1n]) feeds.push(...(await read<readonly Address[]>(lpOracle, lpOracleAbi, "feedsOf", [k])));
    markets.push({
      marketId: marketId.toString(),
      name: names[i]!,
      integrationId: integration.integrationId,
      kind: Number(kinds[i]) === 0 ? "full-range" : "custom-range",
      pool: pools[i]!.toLowerCase() as Hex,
      spoke: getAddress(spokes[i]!),
      hub: getAddress(hubs[i]!),
      vaultToken: await imm(vaultTokens[i], art("VaultToken")),
      lpOracle: await imm(lpOracle, art("LPOracle")),
      reserveId: rm.reserveId.toString(),
      tokens: [getAddress(v.token0), getAddress(v.token1)],
      bandLower: Number(lowers[i]),
      bandUpper: Number(uppers[i]),
      ltvBps: Number(ltvBps[i]),
      unitDecimals: Number(unitDecimals[i]),
      feeds: [...new Set(feeds.map((f) => getAddress(f)))].map((feed) => ({ feed, heartbeatSeconds })),
    });
  }
  return markets;
}

const VIEWS = parseAbi([
  "function getAssetId(address underlying) view returns (uint256)",
  "function getReserveId(address hub, uint256 assetId) view returns (uint256)",
]);

/** The debt reserves of the config's `listing.debtReserves`, with their IDs and First-Loss Reserves read from the chain. */
async function listedDebtReserves(config: Json, outputs: (file: string) => Json, integrations: readonly Integration[], heartbeatSeconds: number, read: Read): Promise<DebtReserve[]> {
  const listing = (at(config, "listing") as Json | undefined) ?? {};
  const debtAssets = (listing.debtAssets as Json[]) ?? [];
  const out: DebtReserve[] = [];
  for (const r of (listing.debtReserves as Json[]) ?? []) {
    const symbol = r.symbol as string;
    const entry = debtAssets.find((a) => a.symbol === symbol);
    const spokeEntry = ((listing.spokes as Json[]) ?? []).find((s) => s.label === r.spoke);
    if (!entry || !spokeEntry) throw new Error(`listing.debtReserves ${String(r.spoke)}/${symbol}: no debt asset or Spoke entry`);
    const spoke = resolveAddress(spokeEntry.spoke, outputs);
    const hubEntry = ((at(config, "aave.hubs") as Json[]) ?? []).find((h) => h.label === spokeEntry.hub);
    if (!hubEntry) throw new Error(`listing.spokes ${String(spokeEntry.label)}: no Hub ${String(spokeEntry.hub)}`);
    const hub = resolveAddress(hubEntry.hub, outputs);
    const asset = resolveAddress(entry.address, outputs);
    const assetId = await read<bigint>(hub, VIEWS, "getAssetId", [asset]);
    const id = await read<bigint>(spoke, VIEWS, "getReserveId", [hub, assetId]);
    const integration = integrations.find((x) => x.integrationId === Number(spokeEntry.integrationId)) ?? integrations[0];
    if (!integration) throw new Error("no integration to read the debt reserve's First-Loss Reserve from");
    const registered = await read<{ firstLossReserve: Address }>(integration.riskModule.address, riskModuleAbi, "getDebtReserve", [spoke, id]);
    out.push({
      spoke,
      debtReserveId: id.toString(),
      asset,
      decimals: Number(await read<number>(asset, ERC20, "decimals")),
      isGho: symbol === "GHO",
      firstLossReserve: getAddress(registered.firstLossReserve),
      feeds: Object.values((entry.feeds as Record<string, string>) ?? {}).map((f) => ({ feed: resolveAddress(f, outputs), heartbeatSeconds })),
    });
  }
  return out;
}

/** coverage.json: one Avana First-Loss Reserve and one DAO deficit offset per (Hub, debt asset), aligned. */
async function lossLayers(out: Json, imm: (a: unknown, artifact: string | null) => Promise<Immutable>): Promise<{ firstLossReserves: LossLayer[]; daoDeficitOffsets: LossLayer[] }> {
  const hubs = column<string>(out, "hubs");
  const n = hubs.length;
  const [labels, symbols, assets, avana, offsets] = ["hubLabels", "symbols", "assets", "avanaLayers", "daoOffsets"].map((k) => column<string>(out, k, n)) as [string[], string[], string[], string[], string[]];
  const [minimums, offsetMinimums] = ["minimums", "offsetMinimums"].map((k) => column<number | string>(out, k, n)) as [(number | string)[], (number | string)[]];
  const firstLossReserves: LossLayer[] = [];
  const daoDeficitOffsets: LossLayer[] = [];
  for (let i = 0; i < n; i++) {
    const base = { hub: getAddress(hubs[i]!), hubLabel: labels[i]!, asset: getAddress(assets[i]!), symbol: symbols[i]! };
    firstLossReserves.push({ ...(await imm(avana[i], art("FirstLossReserve"))), ...base, minimum: BigInt(minimums[i]!).toString() });
    daoDeficitOffsets.push({ ...(await imm(offsets[i], null)), ...base, minimum: BigInt(offsetMinimums[i]!).toString() });
  }
  return { firstLossReserves, daoDeficitOffsets };
}

/** The PoolManager every Uniswap v4 LPVault reads (`POOL_MANAGER()`), or null without a v4 integration. */
async function uniswapV4PoolManager(
  client: PublicClient,
  integrations: readonly Integration[],
  imm: (a: unknown, artifact: string | null) => Promise<Immutable>,
): Promise<{ poolManager: Immutable } | null> {
  const abi = parseAbi(["function POOL_MANAGER() view returns (address)"]);
  let poolManager: Address | null = null;
  for (const x of integrations) {
    if (x.kind !== "uniswap-v4") continue;
    const pm = getAddress((await client.readContract({ address: x.lpVault.address, abi, functionName: "POOL_MANAGER" })) as string);
    if (poolManager && pm !== poolManager) throw new Error(`Uniswap v4 LPVaults name two PoolManagers: ${poolManager}, ${pm}`);
    poolManager = pm;
  }
  return poolManager ? { poolManager: await imm(poolManager, null) } : null;
}
