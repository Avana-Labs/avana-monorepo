// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Release manifest producer: reads what the deploy scripts wrote (contracts/deployments-local/<network>/*.json), the
// network's inputs (contracts/script/deploy/config/<network>.json) and the Foundry broadcast receipts, then reads every
// code hash, ERC-1967 implementation slot and the PositionProxy creation-code hash from the chain, and writes a
// manifest that validates against schema.ts.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { type Address, type Hex, type PublicClient, getAddress, parseAbi } from "viem";
import { ABI_HASH } from "../abis/index.ts";
import { broadcastBlocks, codeHash, firstBlockWithCode, implementationOf } from "./chain.ts";
import { validate } from "./schema.ts";
import type { External, Immutable, Logic, ReleaseManifest, Upgradeable } from "./types.ts";

export interface ProduceOptions {
  readonly client: PublicClient;
  /** contracts/ of the checkout that ran the deployment. */
  readonly contractsDir: string;
  readonly network: string;
  readonly commit: string;
  /** Overrides the release of the deploy output. */
  readonly release?: string;
}

/** Logic contract names in the order 03_DeployAvana deploys them (script/deploy/lib/AvanaCoreDeploy.sol). */
const LOGIC_NAMES = {
  marketRegistry: [
    "MarketRegistryHubsLogic",
    "MarketRegistryListingLogic",
    "MarketRegistryActivationLogic",
    "MarketRegistryRoutesLogic",
    "MarketRegistrySafetyLogic",
    "MarketRegistryWindDownLogic",
  ],
  parameterStore: [
    "ParameterStoreTightenLogic",
    "ParameterStoreLoosenLogic",
    "ParameterStoreListingLogic",
    "ParameterStoreAdminOracleLogic",
    "ParameterStoreAdminRiskLogic",
  ],
  riskModule: ["RiskModuleDriftLogic", "RiskModuleBreakerLogic", "RiskModulePledgeLogic", "RiskModuleBorrowLogic", "RiskModuleStatusLogic"],
  aaveAdapter: ["AaveAdapterUserLogic", "AaveAdapterExitLogic", "AaveAdapterCollateralLogic", "AaveAdapterSettlementLogic"],
  lpVaultSwap: ["LPVaultSwapLiquidationLogic", "LPVaultSwapPendingLogic", "LPVaultSwapDeleverageLogic"],
} as const;

const IMPLEMENTATION = {
  marketRegistry: "MarketRegistry",
  parameterStore: "ParameterStore",
  riskModule: "RiskModule",
  aaveAdapter: "AaveAdapter",
  lpVaultSwap: "LPVaultSwap",
} as const;

const LENS_MODULES = [
  "LensAccountModule",
  "LensMarketModule",
  "LensPriceModule",
  "LensLiquidationModule",
  "LensRiskModule",
  "LensPreviewModule",
  "LensMarketsModule",
  "LensPositionsModule",
] as const;

const art = (name: string) => `${name}.sol:${name}`;

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

export async function produceManifest(o: ProduceOptions): Promise<ReleaseManifest> {
  const { client, contractsDir, network } = o;
  const outDir = join(contractsDir, "deployments-local", network);
  const cache = new Map<string, Json>();
  const outputs = (file: string) => {
    if (!cache.has(file)) cache.set(file, readJson(join(outDir, `${file}.json`)));
    return cache.get(file)!;
  };
  const config = readJson(join(contractsDir, "script/deploy/config", `${network}.json`));
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
  const upg = async (key: keyof typeof LOGIC_NAMES): Promise<Upgradeable> => {
    const entry = avana[key] as { proxy: string; implementation: string; logics: string[] };
    const address = getAddress(entry.proxy);
    const implementation = (await implementationOf(client, address)) ?? getAddress(entry.implementation);
    if (implementation !== getAddress(entry.implementation)) {
      throw new Error(`${key}: implementation slot ${implementation} differs from the deploy output ${entry.implementation}`);
    }
    const logics: Logic[] = [];
    for (const [i, a] of entry.logics.entries()) {
      const name = LOGIC_NAMES[key][i]!;
      logics.push({ name, address: getAddress(a), codeHash: await codeHash(client, getAddress(a)), artifact: art(name) });
    }
    return {
      address,
      codeHash: await codeHash(client, address),
      implementation,
      implementationCodeHash: await codeHash(client, implementation),
      implementationArtifact: art(IMPLEMENTATION[key]),
      logics,
      startBlock: await startBlock(address),
    };
  };
  const external: External[] = [];
  const ext = async (name: string, group: string, a: unknown, standIn: boolean) => {
    const address = getAddress(a as string);
    external.push({ name, group, address, codeHash: await codeHash(client, address), implementation: await implementationOf(client, address), standIn });
  };
  const thirdPartyUpg = async (a: Address): Promise<Upgradeable> => {
    const implementation = (await implementationOf(client, a)) ?? a;
    return {
      address: a,
      codeHash: await codeHash(client, a),
      implementation,
      implementationCodeHash: await codeHash(client, implementation),
      implementationArtifact: "",
      logics: [],
      startBlock: await startBlock(a),
    };
  };

  // Aave V4: the network's own deployment (aave.json) on test networks, the config's literal addresses otherwise.
  const aaveOut = existsSync(join(outDir, "aave.json")) ? outputs("aave") : null;
  const hubCfg = (at(config, "aave.hubs") as { hub: string; tier: number; label?: string }[]) ?? [];
  const hubs: (Upgradeable & { label: string; tier: number })[] = [];
  for (const h of hubCfg) {
    const a = resolveAddress(h.hub, outputs);
    const label = h.label ?? Object.entries((aaveOut?.hubs as Record<string, { proxy: string }>) ?? {}).find(([, v]) => getAddress(v.proxy) === a)?.[0] ?? a;
    hubs.push({ ...(await thirdPartyUpg(a)), label, tier: h.tier });
  }
  const spokesOut = (aaveOut?.spokes as Record<string, { proxy: string; implementation: string; oracle: string }>) ?? {};
  const borrowSpokes: (Upgradeable & { label: string })[] = [];
  const lendSpokes: (Upgradeable & { label: string })[] = [];
  for (const [label, s] of Object.entries(spokesOut)) {
    const u = { ...(await thirdPartyUpg(getAddress(s.proxy))), label };
    (label.startsWith("lend") ? lendSpokes : borrowSpokes).push(u);
    await ext(`Spoke ${label}`, "aave-v4", s.proxy, false);
    await ext(`AaveOracle ${label}`, "aave-v4", s.oracle, false);
  }
  if (aaveOut) {
    for (const k of ["accessManager", "hubConfigurator", "spokeConfigurator", "treasurySpoke", "liquidationLogic"]) {
      await ext(k, "aave-v4", aaveOut[k], false);
    }
    for (const [label, h] of Object.entries(aaveOut.hubs as Record<string, { proxy: string; irStrategy: string }>)) {
      await ext(`Hub ${label}`, "aave-v4", h.proxy, false);
      await ext(`Interest-rate strategy ${label}`, "aave-v4", h.irStrategy, false);
    }
  }
  const world = existsSync(join(outDir, "world.json")) ? outputs("world") : null;
  if (world) {
    for (const [group, entries] of Object.entries((world.external as Record<string, Record<string, { address: string; standIn: boolean }>>) ?? {})) {
      for (const [name, e] of Object.entries(entries)) await ext(name, group, e.address, e.standIn);
    }
    for (const [sym, f] of Object.entries((world.feeds as Record<string, Record<string, string>>) ?? {})) {
      for (const [role, a] of Object.entries(f)) await ext(`${sym} / USD (${role})`, "feed", a, false);
    }
  }
  const v3Pool = cfgAddr("aave.v3Pool");

  // Coverage Spokes deployed by 06_AaveDeploymentPayload on test networks: "CoverageSpoke.<hub label>.<symbol>".
  const coverageSpokes = [];
  if (existsSync(join(outDir, "coverage.json"))) {
    const tokens = (world?.tokens as Record<string, string>) ?? {};
    for (const [name, a] of Object.entries(outputs("coverage") as Record<string, string>)) {
      const [, hubLabel, symbol] = name.split(".");
      const hub = getAddress(((aaveOut?.hubs as Record<string, { proxy: string }>) ?? {})[hubLabel!]!.proxy);
      coverageSpokes.push({ ...(await imm(a, "CoverageSpoke.sol:CoverageSpoke")), asset: getAddress(tokens[symbol!]!), hub });
    }
  }
  const hubOf = (tier: number) => hubs.find((h) => h.tier === tier) ?? hubs[0];
  if (!hubOf(1)) throw new Error("no Aave Hub in the config");

  const lpVaultAddrs = avana.lpVaults as string[];
  const ids = avana.integrationIds as number[];
  const kinds = avana.integrationKinds as string[];
  const helpersCfg = (at(config, "operatorHelpers") as { signer: string; fundingSafe: string }[]) ?? [];
  const pc = avana.clOraclePricing as string;
  const proxyManager = getAddress(avana.proxyManager as string);
  const proxyCreationCodeHash = (await client.readContract({
    address: proxyManager,
    abi: parseAbi(["function PROXY_CREATION_CODE_HASH() view returns (bytes32)"]),
    functionName: "PROXY_CREATION_CODE_HASH",
  })) as Hex;
  const gov = (k: string) => cfgAddr(`governance.${k}`);
  const governanceSafe = gov("governanceSafe");
  const emergencyGuardian = gov("emergencyGuardian");
  const aaveProtocolGuardian = gov("aaveProtocolGuardian");
  const aaveGovernanceExecutor = gov("aaveGovernanceExecutor");
  const jointConfigSafe = gov("jointConfigSafe");
  const timelock = getAddress(avana.timelock as string);
  const tl = parseAbi(["function normalDelay() view returns (uint256)", "function publicExecution() view returns (bool)"]);

  const manifest: ReleaseManifest = {
    schemaVersion: 1,
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
      aaveAdapter: await upg("aaveAdapter"),
      lpVaultSwap: await upg("lpVaultSwap"),
      marketRegistry: await upg("marketRegistry"),
      parameterStore: await upg("parameterStore"),
      riskModule: await upg("riskModule"),
      timelock: await imm(timelock, art("AvanaTimelock")),
      proxyManager: await imm(proxyManager, art("ProxyManager")),
      collateralization: await imm(avana.collateralization, art("Collateralization")),
      vaultTokenFactory: await imm(avana.vaultTokenFactory, art("VaultTokenFactory")),
      payoutEscrow: await imm(avana.payoutEscrow, art("PayoutEscrow")),
      lock: await imm(avana.lock, art("Lock")),
      lens: await imm(avana.lens, art("Lens")),
      lensModules: await Promise.all((avana.lensModules as string[]).map((a, i) => imm(a, art(LENS_MODULES[i]!)))),
      lensAaveSizing: await imm(avana.lensAaveSizing, "out-aave:LensAaveSizing.sol:LensAaveSizing"),
      flashSource: await imm(avana.flashSource, art("AaveV3FlashSource")),
      flashLiquidator: await imm(avana.flashLiquidator, art("FlashLiquidator")),
      operatorHelpers: await Promise.all(
        (avana.operatorHelpers as string[]).map(async (a, i) => ({
          ...(await imm(a, art("OperatorFlashLiquidator"))),
          signer: resolveAddress(helpersCfg[i]!.signer, outputs),
          fundingSafe: resolveAddress(helpersCfg[i]!.fundingSafe, outputs),
        })),
      ),
      lpVaults: await Promise.all(
        lpVaultAddrs.map(async (a, i) => ({
          ...(await imm(a, kinds[i] === "slipstream" ? art("SlipstreamIntegration") : art("UniswapV3Integration"))),
          integrationId: ids[i]!,
          kind: kinds[i]!,
        })),
      ),
      coverageSpokes,
      debtOracleImplementation: await imm(avana.debtOracleImplementation, art("DebtOracle")),
      clOraclePricing: BigInt(pc) === 0n ? null : await imm(pc, "LPOracleCL.sol:LPOracleCL"),
      proxyCreationCodeHash,
    },
    markets: [],
    debtReserves: [],
    aave: {
      hubs,
      borrowSpokes,
      lendSpokes,
      v3Pool: await thirdPartyUpg(v3Pool),
      accessManager: cfgAddr("aave.accessManager"),
    },
    roles: {
      timelock: {
        proposers: [governanceSafe, aaveGovernanceExecutor],
        executors: [governanceSafe],
        cancellers: [governanceSafe, aaveGovernanceExecutor, emergencyGuardian, aaveProtocolGuardian],
        daoCancellers: [aaveGovernanceExecutor],
        normalDelay: Number(await client.readContract({ address: timelock, abi: tl, functionName: "normalDelay" })),
        publicExecution: await client.readContract({ address: timelock, abi: tl, functionName: "publicExecution" }),
      },
      governanceSafe,
      emergencyGuardian,
      aaveProtocolGuardian,
      aaveGovernanceExecutor,
      jointConfigSafe,
      marketRegistryGuardians: [emergencyGuardian, aaveProtocolGuardian, jointConfigSafe],
      parameterStorePauseGuardians: [emergencyGuardian, aaveProtocolGuardian],
      riskStewards: [jointConfigSafe],
      keepers: ((at(config, "keepers") as unknown[]) ?? []).map((k) => resolveAddress(k, outputs)),
    },
    external,
  };
  const errors = validate(manifest);
  if (errors.length > 0) throw new Error(`produced manifest fails the schema:\n${errors.map((e) => `  ${e.path}: ${e.message}`).join("\n")}`);
  return manifest;
}
