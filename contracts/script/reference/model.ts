// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Reads one network's deployment folder (manifest.json and the files the deploy writes beside it) into the values the
// website's three reference pages show: every address, the per-market and per-Spoke listing values, and the settings
// that differ per network. Each value is looked up where the deploy recorded it; a value that is missing or still a
// placeholder is reported as a problem, never filled in.

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { basename, join } from "node:path";
import { parseManifest } from "../../../packages/protocol/src/manifest/schema.ts";
import type { ReleaseManifest } from "../../../packages/protocol/src/manifest/types.ts";

export type Json = any;

export interface NetworkDef {
  /** The id the website's network selector uses (`- network:` line). */
  readonly id: string;
  readonly title: string;
  readonly chainId: number;
  /** The manifest's `network` field for this chain. */
  readonly manifestNetwork: string;
  readonly kind: "main" | "test" | "local";
  readonly explorer?: string;
  /** An L2 with a sequencer (Base): the sequencer uptime feed applies on its mainnet. */
  readonly layer2: boolean;
}

/** Every network the pages can show, in the order of their sections. */
export const NETWORKS: readonly NetworkDef[] = [
  { id: "ethereum", title: "Ethereum", chainId: 1, manifestNetwork: "ethereum", kind: "main", explorer: "https://etherscan.io", layer2: false },
  { id: "base", title: "Base", chainId: 8453, manifestNetwork: "base", kind: "main", explorer: "https://basescan.org", layer2: true },
  {
    id: "ethereum-sepolia",
    title: "Ethereum Sepolia",
    chainId: 11155111,
    manifestNetwork: "sepolia",
    kind: "test",
    explorer: "https://sepolia.etherscan.io",
    layer2: false,
  },
  {
    id: "base-sepolia",
    title: "Base Sepolia",
    chainId: 84532,
    manifestNetwork: "base-sepolia",
    kind: "test",
    explorer: "https://sepolia.basescan.org",
    layer2: true,
  },
  { id: "local-ethereum", title: "Local Ethereum development chain", chainId: 31337, manifestNetwork: "ethereum", kind: "local", layer2: false },
  { id: "local-base", title: "Local Base development chain", chainId: 31338, manifestNetwork: "base", kind: "local", layer2: true },
];

export function networkOf(id: string): NetworkDef {
  const n = NETWORKS.find((x) => x.id === id);
  if (!n) throw new Error(`unknown network "${id}"; one of: ${NETWORKS.map((x) => x.id).join(", ")}`);
  return n;
}

/** The deploy's rehearsal mark (script/testnet/app/plan.ts REHEARSAL_MARK): outputs of a run on local nodes. */
export const REHEARSAL_MARK = ".rehearsal";

/** Uniswap/Slipstream TWAP window every market lists with (09_ListMarkets.s.sol `twapWindow`). */
export const TWAP_WINDOW = 1800;

/** The rate curve 06_AaveDeploymentPayload applies when the config gives none (`_rateModel`), in bps. */
export const DEFAULT_RATE_MODEL = { optimalUsageBps: 9000, baseDrawnRateBps: 0, rateGrowthBeforeOptimalBps: 400, rateGrowthAfterOptimalBps: 6000 };

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const HASH = /^0x[0-9a-fA-F]{64}$/;

/** A placeholder: 30 leading zero hex digits for an address, 56 for a 32-byte value (the site's convention). */
export function isPlaceholder(value: string): boolean {
  return (ADDRESS.test(value) && /^0x0{30}/.test(value)) || (HASH.test(value) && /^0x0{56}/.test(value));
}

export type Kind = "uniswap-v3" | "uniswap-v4" | "slipstream";
export const VENUE: Record<Kind, string> = { "uniswap-v3": "Uniswap v3", "uniswap-v4": "Uniswap v4", slipstream: "Aero Slipstream" };
export const KIND_ORDER: readonly Kind[] = ["uniswap-v3", "uniswap-v4", "slipstream"];

export interface Route {
  readonly asset: string;
  readonly depthThreshold?: number;
  readonly backupDepthThreshold?: number;
}

export interface Market {
  readonly name: string;
  /** "USDC/USDT". */
  readonly pair: string;
  readonly tokens: readonly string[];
  readonly spoke: string;
  readonly kind: Kind;
  /** The pool address, or the PoolId of a Uniswap v4 market. */
  readonly pool: string;
  readonly referencePool?: string;
  readonly referenceFee?: number;
  /** Uniswap fee in hundredths of a bp (v3, v4), or undefined for Slipstream. */
  readonly fee?: number;
  readonly tickSpacing?: number;
  readonly collateralFactorBps: number;
  readonly maxLiquidationBonus: number;
  readonly collateralRisk: number;
  readonly poolRiskFactorBps: number;
  readonly consistencyToleranceBps: number;
  readonly slippageAllowanceBps: number;
  readonly slippageAllowanceMinBps: number;
  readonly marketUsdCap: string;
  readonly marketId: string;
  readonly vaultToken: string;
  readonly lpOracle: string;
  readonly routes: readonly Route[];
}

export interface Spoke {
  readonly label: string;
  readonly name: string;
  readonly category: string;
  readonly kind: Kind;
  readonly address: string;
  readonly borrowable: readonly string[];
  readonly markets: readonly Market[];
}

export interface DebtAsset {
  readonly symbol: string;
  readonly address: string;
  readonly drawCap: number;
  readonly coverageMinimum: number;
  readonly offsetMinimum: number;
  readonly rate: typeof DEFAULT_RATE_MODEL;
  readonly liquidityFeeBps: number;
  /** Borrowable on the CDP Spokes (a listing debt asset). */
  readonly listed: boolean;
  readonly fixedPrice: boolean;
  /** The fixed price source the listing deployed for a fixed-price asset (a test-network stand-in), if any. */
  readonly fixedPriceSource?: string;
  readonly debtOracle?: string;
  readonly debtOraclePokeMinGas?: number;
  readonly creditLineWhole?: number;
  readonly firstLossReserve: string;
  readonly daoDeficitOffset: string;
}

export interface Model {
  readonly net: NetworkDef;
  readonly manifest: ReleaseManifest;
  readonly hub: { readonly label: string; readonly name: string; readonly address: string };
  readonly lendSpoke: { readonly label: string; readonly address: string };
  /** CDP Spokes in the Hub file's order. */
  readonly spokes: readonly Spoke[];
  readonly debtAssets: readonly DebtAsset[];
  readonly tokens: readonly { readonly symbol: string; readonly collateralFactorBps: number; readonly tokenCapUsd: string }[];
  readonly tokenAddress: (symbol: string) => string;
  readonly external: (group: string, name: string) => string;
  readonly isSafe: (address: string) => boolean;
  readonly blockTime: number;
  readonly sequencerGraceSeconds: number;
  readonly shortDelay: number;
  readonly maxMarketCount: number;
  readonly avanaFeeShareBps: number;
  /** Signers the config gives the gas vault (lower-case). */
  readonly gasVaultSigners: readonly string[];
}

export interface Deployment {
  readonly net: NetworkDef;
  readonly dir: string;
  readonly manifest: ReleaseManifest;
  readonly world: Json;
  readonly config: Json;
  readonly configFile: string;
  readonly activation: Json | undefined;
  readonly listingOracles: Record<string, string>;
}

const readJson = (p: string): Json => JSON.parse(readFileSync(p, "utf8"));

/** The deploy config the folder's last release ran with: `--config`, stack-status.json's `config`, or the only one. */
export function configFileOf(dir: string, explicit?: string): string {
  if (explicit) return explicit;
  const status = join(dir, "stack-status.json");
  if (existsSync(status)) {
    const s = readJson(status);
    if (typeof s.config === "string") {
      const p = join(dir, basename(s.config));
      if (!existsSync(p)) throw new Error(`stack-status.json names ${s.config}, which is not in ${dir}`);
      return p;
    }
  }
  const hubs = readdirSync(dir).filter((f) => /^config-hub-.+\.json$/.test(f));
  if (hubs.length === 1) return join(dir, hubs[0]);
  if (hubs.length > 1) throw new Error(`${dir} holds several config-hub-*.json files and no stack-status.json naming the last; pass --config`);
  if (existsSync(join(dir, "config-base.json"))) return join(dir, "config-base.json");
  throw new Error(`${dir} holds no deploy config (config-*.json); pass --config`);
}

/** Loads a deployment folder, refusing a rehearsal's outputs (unless allowed) and another chain's manifest. */
export function loadDeployment(net: NetworkDef, dir: string, opts: { allowRehearsal?: boolean; config?: string } = {}): Deployment {
  if (!existsSync(join(dir, "manifest.json"))) throw new Error(`no manifest.json in ${dir}`);
  if (existsSync(join(dir, REHEARSAL_MARK)) && !opts.allowRehearsal) {
    throw new Error(`${dir} holds a rehearsal's outputs (${REHEARSAL_MARK}); pass --allow-rehearsal to use them anyway`);
  }
  const manifest = parseManifest(readFileSync(join(dir, "manifest.json"), "utf8"), join(dir, "manifest.json"));
  if (manifest.chainId !== net.chainId) throw new Error(`the manifest in ${dir} is for chain ${manifest.chainId}, not ${net.id} (${net.chainId})`);
  if (manifest.network !== net.manifestNetwork) {
    throw new Error(`the manifest in ${dir} names network "${manifest.network}", not "${net.manifestNetwork}" (${net.id})`);
  }
  if (!existsSync(join(dir, "world.json"))) throw new Error(`no world.json in ${dir}`);
  const configFile = configFileOf(dir, opts.config);
  const config = readJson(configFile);
  if (config.chainId !== undefined && config.chainId !== net.chainId) throw new Error(`${configFile} is for chain ${config.chainId}, not ${net.chainId}`);
  const act = join(dir, "operation-listing-activate.json");
  const oracles = join(dir, "listing-oracles.json");
  return {
    net,
    dir,
    manifest,
    world: readJson(join(dir, "world.json")),
    config,
    configFile,
    activation: existsSync(act) ? readJson(act) : undefined,
    listingOracles: existsSync(oracles) ? readJson(oracles) : {},
  };
}

const same = (a: string | undefined | null, b: string | undefined | null) => !!a && !!b && a.toLowerCase() === b.toLowerCase();
const sameSet = (a: readonly string[], b: readonly string[]) => a.length === b.length && a.every((x) => b.some((y) => same(x, y)));

/** Builds the pages' values; every missing or placeholder value is pushed to `problems` as one line. */
export function buildModel(d: Deployment, problems: string[]): Model {
  const m = d.manifest;
  const cfg = d.config;
  const w = d.world;
  const need = (label: string, v: unknown): string => {
    if (v === undefined || v === null || v === "") {
      problems.push(`missing: ${label}`);
      return "MISSING";
    }
    const s = String(v);
    if (isPlaceholder(s)) problems.push(`placeholder: ${label} = ${s}`);
    return s;
  };
  const num = (label: string, v: unknown): number => {
    if (typeof v !== "number" && !(typeof v === "string" && /^[0-9]+$/.test(v))) {
      problems.push(`missing: ${label}`);
      return Number.NaN;
    }
    return Number(v);
  };

  const ext = (group: string, name: string) => need(`external ${group} "${name}"`, m.external.find((e) => e.group === group && e.name === name)?.address);
  const tokenAddress = (symbol: string) => ext("token", symbol);
  const isSafe = (a: string) => m.external.some((e) => e.group === "safe" && same(e.address, a));

  // The Hub: the chain has exactly one.
  const hubs = (cfg.aavePayload?.hubs ?? []) as Json[];
  if (hubs.length !== 1) problems.push(`the deploy config names ${hubs.length} Hubs; the pages describe one Hub per chain`);
  const ph = hubs[0] ?? {};
  const hubLabel = need("aavePayload.hubs[0].label", ph.label);
  const hub = {
    label: hubLabel,
    name: need(`Hub ${hubLabel} name (aavePayload.hubs[0].content.name)`, ph.content?.name),
    address: need(`aave.hubs[label=${hubLabel}]`, m.aave.hubs.find((h) => h.label === hubLabel)?.address),
  };
  const lendLabel = need("aavePayload.hubs[0].lendSpoke", ph.lendSpoke);
  const lendSpoke = { label: lendLabel, address: need(`aave.lendSpokes[label=${lendLabel}]`, m.aave.lendSpokes.find((s) => s.label === lendLabel)?.address) };

  const kindOf = new Map<number, Kind>(((cfg.integrations ?? []) as Json[]).map((i) => [i.integrationId, i.kind as Kind]));
  const listing = cfg.listing ?? {};
  const worldPools = {
    v3: new Map<string, Json>(((cfg.world?.uniswapPools ?? []) as Json[]).map((p) => [p.name, p])),
    slip: new Map<string, Json>(((cfg.world?.slipstreamPools ?? []) as Json[]).map((p) => [p.name, p])),
    v4: new Map<string, Json>(((cfg.world?.uniswapV4Pools ?? []) as Json[]).map((p) => [p.name, p])),
  };
  const v3ByAddress = new Map<string, string>(Object.entries((w.uniswapPools ?? {}) as Record<string, string>).map(([n, a]) => [a.toLowerCase(), n]));

  const debtReserves = ((listing.debtReserves ?? []) as Json[]).map((r) => ({ spoke: r.spoke as string, symbol: r.symbol as string }));
  const payloadDebt = (cfg.aavePayload?.debtAssets ?? []) as Json[];
  const listingDebt = (listing.debtAssets ?? []) as Json[];

  // CDP Spokes of the Hub, in the Hub files' order.
  const cdpLabels: string[] = ph.cdpSpokes ?? [];
  const spokes: Spoke[] = [];
  for (const s of (listing.spokes ?? []) as Json[]) {
    if (s.hub !== hubLabel) continue;
    if (!cdpLabels.includes(s.label)) problems.push(`Spoke ${s.label} is listed but not a CDP Spoke of Hub ${hubLabel}`);
    const kind = kindOf.get(s.integrationId);
    if (!kind || !VENUE[kind]) {
      problems.push(`Spoke ${s.label}: unknown integration ${s.integrationId}`);
      continue;
    }
    const name = need(`Spoke ${s.label} name (listing.spokes[].content.name)`, s.content?.name);
    const venue = VENUE[kind];
    const category = name.startsWith(`${venue} `) ? name.slice(venue.length + 1) : name.replace(/^(Aero )?Slipstream /, "");
    const address = need(`aave.borrowSpokes[label=${s.label}]`, m.aave.borrowSpokes.find((b) => b.label === s.label)?.address);
    const markets: Market[] = [];
    for (const mk of (listing.markets ?? []) as Json[]) {
      if (mk.spoke !== s.label) continue;
      const mkind = kindOf.get(mk.integrationId);
      if (mkind !== kind) problems.push(`market ${mk.name}: integration ${mk.integrationId} differs from its Spoke's`);
      const spec = kind === "uniswap-v3" ? worldPools.v3.get(mk.pool) : kind === "slipstream" ? worldPools.slip.get(mk.pool) : worldPools.v4.get(mk.pool);
      if (!spec) problems.push(`market ${mk.name}: pool ${mk.pool} is not in the deploy config's world`);
      let pool: string;
      let referencePool: string | undefined;
      let referenceFee: number | undefined;
      let found: Json;
      if (kind === "uniswap-v4") {
        const v4 = w.uniswapV4Pools?.[mk.pool];
        pool = need(`market ${mk.name} PoolId (world.json uniswapV4Pools["${mk.pool}"].poolId)`, v4?.poolId);
        referencePool = need(`market ${mk.name} v3 reference pool (world.json uniswapV4Pools["${mk.pool}"].referencePool)`, v4?.referencePool);
        const refName = v3ByAddress.get(String(referencePool).toLowerCase());
        referenceFee = refName ? worldPools.v3.get(refName)?.fee : undefined;
        found = m.markets.find((x) => same(x.spoke, address) && same(x.poolId, pool));
      } else {
        const pools = kind === "uniswap-v3" ? w.uniswapPools : w.slipstreamPools;
        pool = need(`market ${mk.name} pool (world.json ${kind === "uniswap-v3" ? "uniswapPools" : "slipstreamPools"}["${mk.pool}"])`, pools?.[mk.pool]);
        found = m.markets.find((x) => same(x.spoke, address) && same(x.pool, pool));
      }
      if (!found) problems.push(`missing: manifest market for ${mk.name} (Spoke ${s.label}, pool ${pool})`);
      const tokens = spec ? [spec.a as string, spec.b as string] : [];
      markets.push({
        name: mk.name,
        pair: tokens.join("/"),
        tokens,
        spoke: s.label,
        kind,
        pool,
        referencePool,
        referenceFee,
        fee: kind === "slipstream" ? undefined : spec?.fee,
        tickSpacing: spec?.tickSpacing,
        collateralFactorBps: num(`market ${mk.name} collateralFactorBps`, mk.collateralFactorBps),
        maxLiquidationBonus: num(`market ${mk.name} maxLiquidationBonus`, mk.maxLiquidationBonus),
        collateralRisk: num(`market ${mk.name} collateralRisk`, mk.collateralRisk),
        poolRiskFactorBps: num(`market ${mk.name} poolRiskFactorBps`, mk.poolRiskFactorBps),
        consistencyToleranceBps: num(`market ${mk.name} consistencyToleranceBps`, mk.consistencyToleranceBps),
        slippageAllowanceBps: num(`market ${mk.name} slippageAllowanceBps`, mk.slippageAllowanceBps),
        slippageAllowanceMinBps: num(`market ${mk.name} slippageAllowanceMinBps`, mk.slippageAllowanceMinBps),
        marketUsdCap: need(`market ${mk.name} marketUsdCap`, mk.marketUsdCap),
        marketId: need(`market ${mk.name} marketId (manifest)`, found?.marketId),
        vaultToken: need(`market ${mk.name} vault token (manifest)`, found?.vaultToken?.address),
        lpOracle: need(`market ${mk.name} LPOracle (manifest)`, found?.lpOracle?.address),
        routes: ((mk.routes ?? []) as Json[]).map((r) => ({ asset: r.asset, depthThreshold: r.depthThreshold, backupDepthThreshold: r.backupDepthThreshold })),
      });
    }
    spokes.push({
      label: s.label,
      name,
      category,
      kind,
      address,
      // In the Hub's debt-asset order (GHO, USDC, ...), whatever order the listing enabled them in.
      borrowable: payloadDebt.map((p) => p.symbol as string).filter((sym) => debtReserves.some((r) => r.spoke === s.label && r.symbol === sym)),
      markets,
    });
  }
  for (const l of cdpLabels) if (!spokes.some((s) => s.label === l)) problems.push(`missing: listing of CDP Spoke ${l}`);
  if (m.markets.length !== spokes.reduce((n, s) => n + s.markets.length, 0)) {
    problems.push(`the manifest lists ${m.markets.length} markets, the deploy config ${spokes.reduce((n, s) => n + s.markets.length, 0)}`);
  }

  // Debt assets: every asset the Hub lists; the listing's are borrowable on the CDP Spokes.
  const debtAssets: DebtAsset[] = payloadDebt.map((p) => {
    const sym = p.symbol as string;
    const address = tokenAddress(sym);
    const l = listingDebt.find((x) => x.symbol === sym);
    const byHub = (field: string) => p[`${field}ByHub`]?.[hubLabel] ?? p[field];
    const rate = byHub("rateModel") ?? DEFAULT_RATE_MODEL;
    const oracles = [...new Set(m.debtReserves.filter((r) => same(r.asset, address) && r.debtOracle).map((r) => r.debtOracle!.address.toLowerCase()))];
    if (oracles.length > 1) problems.push(`${sym}: the debt reserves name ${oracles.length} different DebtOracles`);
    const debtOracle = oracles.length ? m.debtReserves.find((r) => same(r.debtOracle?.address, oracles[0]))!.debtOracle!.address : undefined;
    const fixedPrice = l?.fixedPrice === true;
    if (l && !fixedPrice) need(`${sym} DebtOracle (manifest debtReserves)`, debtOracle);
    const flr = m.avana.firstLossReserves.find((x) => same(x.asset, address) && same(x.hub, hub.address));
    const offset = m.avana.daoDeficitOffsets.find((x) => same(x.asset, address) && same(x.hub, hub.address));
    return {
      symbol: sym,
      address,
      drawCap: num(`${sym} drawCap`, p.drawCap),
      coverageMinimum: num(`${sym} coverageMinimum`, p.coverageMinimum),
      offsetMinimum: num(`${sym} offsetMinimum`, p.offsetMinimum),
      rate: {
        optimalUsageBps: num(`${sym} optimalUsageBps`, rate.optimalUsageBps),
        baseDrawnRateBps: num(`${sym} baseDrawnRateBps`, rate.baseDrawnRateBps),
        rateGrowthBeforeOptimalBps: num(`${sym} rateGrowthBeforeOptimalBps`, rate.rateGrowthBeforeOptimalBps),
        rateGrowthAfterOptimalBps: num(`${sym} rateGrowthAfterOptimalBps`, rate.rateGrowthAfterOptimalBps),
      },
      liquidityFeeBps: Number(byHub("liquidityFeeBps") ?? 0),
      listed: !!l,
      fixedPrice,
      fixedPriceSource: fixedPrice && d.listingOracles[sym] ? need(`${sym} fixed price source (listing-oracles.json)`, d.listingOracles[sym]) : undefined,
      debtOracle,
      debtOraclePokeMinGas: l && !fixedPrice ? num(`${sym} debtOraclePokeMinGas`, l.debtOraclePokeMinGas) : undefined,
      creditLineWhole: l ? num(`${sym} creditLineWhole`, l.creditLineWhole ?? listing.creditLineWhole) : undefined,
      firstLossReserve: need(`First-Loss Reserve of ${sym} (manifest avana.firstLossReserves)`, flr?.address),
      daoDeficitOffset: need(`DAO deficit offset of ${sym} (manifest avana.daoDeficitOffsets)`, offset?.address),
    };
  });
  for (const r of debtReserves) if (!debtAssets.some((a) => a.symbol === r.symbol && a.listed)) problems.push(`debt reserve ${r.spoke}:${r.symbol} names no listing debt asset`);

  const tokens = ((listing.tokens ?? []) as Json[])
    .filter((t) => !t.hubs || t.hubs.includes(hubLabel))
    .map((t) => ({
      symbol: t.symbol as string,
      collateralFactorBps: num(`token ${t.symbol} collateralFactorBps`, t.collateralFactorBps),
      tokenCapUsd: need(`token ${t.symbol} tokenCapUsd`, t.tokenCapUsd),
    }));

  // Short delay: the market activation is a short-delay operation (activateMarket is on the short list).
  let shortDelay = Number.NaN;
  if (!d.activation) problems.push("missing: operation-listing-activate.json (its delay is the timelock's short delay)");
  else if (!((d.activation.labels ?? []) as string[]).every((l) => /activateMarket/.test(l))) {
    problems.push("operation-listing-activate.json holds calls other than activateMarket; its delay is not the short delay");
  } else shortDelay = num("operation-listing-activate.json delay", d.activation.delay);

  // Role holders as the pages word them.
  const r = m.roles;
  const checks: [string, boolean][] = [
    ["timelock proposers are the governance Safe and the Aave governance executor", sameSet(r.timelock.proposers, [r.governanceSafe, r.aaveGovernanceExecutor])],
    ["the governance Safe is a timelock executor", r.timelock.executors.some((x) => same(x, r.governanceSafe))],
    [
      "timelock cancellers are the governance Safe, the Aave governance executor and both guardians",
      sameSet(r.timelock.cancellers, [r.governanceSafe, r.aaveGovernanceExecutor, r.emergencyGuardian, r.aaveProtocolGuardian]),
    ],
    ["the only DAO canceller is the Aave governance executor", sameSet(r.timelock.daoCancellers, [r.aaveGovernanceExecutor])],
    ["MarketRegistry guardians are both guardians and the Joint Configuration Safe", sameSet(r.marketRegistryGuardians, [r.emergencyGuardian, r.aaveProtocolGuardian, r.jointConfigSafe])],
    ["ParameterStore pause guardians are both guardians", sameSet(r.parameterStorePauseGuardians, [r.emergencyGuardian, r.aaveProtocolGuardian])],
    ["the only risk steward is the Joint Configuration Safe", sameSet(r.riskStewards, [r.jointConfigSafe])],
    ["every operator helper's signer is a keeper", m.avana.operatorHelpers.every((h) => r.keepers.some((k) => same(k, h.signer)))],
    ["no keeper is the deployer or the fee recipient", r.keepers.every((k) => !same(k, m.deployer) && !same(k, m.feeRecipient))],
  ];
  for (const [what, ok] of checks) if (!ok) problems.push(`role holders differ from the page wording: ${what}`);
  if (r.keepers.length === 0) problems.push("missing: roles.keepers (no keeper)");
  if (m.avana.operatorHelpers.length === 0) problems.push("missing: avana.operatorHelpers (no OperatorFlashLiquidator)");
  if (m.sequencerFeed && !d.net.layer2) problems.push("a sequencer feed is recorded on a chain without a sequencer");

  return {
    net: d.net,
    manifest: m,
    hub,
    lendSpoke,
    spokes,
    debtAssets,
    tokens,
    tokenAddress,
    external: ext,
    isSafe,
    blockTime: num("chain.blockTime", cfg.chain?.blockTime),
    sequencerGraceSeconds: Number(cfg.chain?.sequencerGraceSeconds ?? 0),
    shortDelay,
    maxMarketCount: num("parameters.maxMarketCount", cfg.parameters?.maxMarketCount),
    avanaFeeShareBps: num("parameters.globals.avanaFeeShareBps", cfg.parameters?.globals?.avanaFeeShareBps),
    gasVaultSigners: ((cfg.gasVault?.signers ?? []) as Json[]).map((s) => String(s.signer).toLowerCase()),
  };
}
