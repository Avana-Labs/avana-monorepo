// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Reads one network's deployment folder (manifest.json and the files the deploy writes beside it) into the values the
// address book's three pages show: every address, each market's listing values, the loss layers and the governance
// delay. Each value is looked up where the deploy recorded it; a value that is missing or still a placeholder is
// reported as a problem, never filled in.

import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
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
  /** An L2 with a sequencer (Base): a sequencer uptime feed may be recorded on it. */
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

/** The deploy's rehearsal mark (the operator test-network app's REHEARSAL_MARK): outputs of a run on local nodes. */
export const REHEARSAL_MARK = ".rehearsal";

/** The governance role's execution delay bounds (script/deploy/lib/AvanaAccess.sol `GOVERNANCE_DELAY_MIN`, `_MAX`). */
export const GOVERNANCE_DELAY_MIN = 4 * 86_400;
export const GOVERNANCE_DELAY_MAX = 5 * 86_400;

/** The deploy outputs the pages read beside the manifest (script/deploy/lib/DeploymentOutput.sol, 09, 07). */
export const OUTPUTS = ["avana", "markets", "coverage"] as const;

const ADDRESS = /^0x[0-9a-fA-F]{40}$/;
const HASH = /^0x[0-9a-fA-F]{64}$/;
const ZERO = /^0x0{40}$/;

/** A placeholder: 30 leading zero hex digits for an address, 56 for a 32-byte value (the site's convention). */
export function isPlaceholder(value: string): boolean {
  return (ADDRESS.test(value) && /^0x0{30}/.test(value)) || (HASH.test(value) && /^0x0{56}/.test(value));
}

export type Kind = "uniswap-v3" | "uniswap-v4" | "slipstream";
export const VENUE: Record<Kind, string> = { "uniswap-v3": "Uniswap v3", "uniswap-v4": "Uniswap v4", slipstream: "Aerodrome Slipstream" };
export const KIND_ORDER: readonly Kind[] = ["uniswap-v3", "uniswap-v4", "slipstream"];

/** One core stack (`03_DeployAvana`): an LPVault and the contracts bound to it. */
export interface Integration {
  readonly id: number;
  readonly kind: Kind;
  readonly lpVault: string;
  readonly riskModule: string;
  readonly liquidationModule: string;
  readonly aaveAdapter: string;
  /** Zero when the chain has no Aave V3 Pool (03 deploys none). */
  readonly flashloanRepay: string;
}

export interface Hub {
  readonly label: string;
  readonly tier: number;
  readonly address: string;
}

export interface Market {
  readonly marketId: string;
  /** The listing's name (`listing.markets[].name`), shared by the pool's two markets. */
  readonly name: string;
  readonly range: "Full range" | "Custom range";
  readonly integrationId: number;
  readonly kind: Kind;
  readonly spoke: string;
  readonly hub: string;
  /** The pool address of a Uniswap v3 or Slipstream market, the PoolId of a Uniswap v4 market. */
  readonly pool: string;
  /** "USDC/USDT", in pool order. */
  readonly pair: string;
  readonly tokens: readonly string[];
  readonly bandLower: number;
  readonly bandUpper: number;
  readonly ltvBps: number;
  readonly unitDecimals: number;
  /** The higher of the two tokens' max liquidation bonus on the price Spoke (markets.json). */
  readonly maxLiquidationBonus: number;
  /** The vault-token reserve's add cap in whole vault tokens (markets.json `addCaps`, the listing's `marketUsdCap`). */
  readonly addCap: string;
  readonly vaultToken: string;
  readonly lpOracle: string;
  readonly reserveId: string;
  readonly feeds: readonly { readonly feed: string; readonly heartbeatSeconds: number }[];
}

export interface CdpSpoke {
  readonly label: string;
  readonly address: string;
  /** The Hub label its markets or debt reserves name, if any. */
  readonly hub?: string;
  /** The integration its markets belong to, if any. */
  readonly kind?: Kind;
  /** Symbols of the debt reserves registered on it, in manifest order. */
  readonly borrowable: readonly string[];
  readonly markets: readonly Market[];
}

export interface DebtReserve {
  readonly spoke: string;
  readonly hub: string;
  readonly reserveId: string;
  readonly symbol: string;
  readonly asset: string;
  readonly decimals: number;
  readonly firstLossReserve: string;
  readonly feeds: readonly { readonly feed: string; readonly heartbeatSeconds: number }[];
}

/** Both loss layers of one (Hub, debt asset) (`07_DeployFirstLossReserves`, coverage.json). */
export interface LossLayers {
  readonly hub: string;
  readonly symbol: string;
  readonly asset: string;
  readonly firstLossReserve: string;
  readonly daoDeficitOffset: string;
  /** Raw asset units. */
  readonly minimum: string;
  readonly offsetMinimum: string;
  /** The asset's decimals, from a debt reserve of the asset; undefined when no debt reserve names it. */
  readonly decimals?: number;
}

export interface Model {
  readonly net: NetworkDef;
  readonly manifest: ReleaseManifest;
  readonly hubs: readonly Hub[];
  readonly cdpSpokes: readonly CdpSpoke[];
  readonly lendSpokes: readonly { readonly label: string; readonly address: string }[];
  readonly integrations: readonly Integration[];
  readonly markets: readonly Market[];
  readonly debtReserves: readonly DebtReserve[];
  readonly lossLayers: readonly LossLayers[];
  /** The manifest's `token` externals: symbol, address, test stand-in. */
  readonly tokens: readonly { readonly symbol: string; readonly address: string; readonly standIn: boolean }[];
  readonly isSafe: (address: string) => boolean;
  /** The governance role's execution delay for the governance Safe, seconds (operation-listing-activate.json). */
  readonly governanceDelay: number;
}

export interface Deployment {
  readonly net: NetworkDef;
  readonly dir: string;
  readonly manifest: ReleaseManifest;
  readonly avana: Json;
  readonly markets: Json;
  readonly coverage: Json;
  readonly activation: Json | undefined;
}

const readJson = (p: string): Json => JSON.parse(readFileSync(p, "utf8"));

/** Loads a deployment folder, refusing a rehearsal's outputs (unless allowed) and another chain's manifest. */
export function loadDeployment(net: NetworkDef, dir: string, opts: { allowRehearsal?: boolean } = {}): Deployment {
  if (!existsSync(join(dir, "manifest.json"))) throw new Error(`no manifest.json in ${dir}`);
  if (existsSync(join(dir, REHEARSAL_MARK)) && !opts.allowRehearsal) {
    throw new Error(`${dir} holds a rehearsal's outputs (${REHEARSAL_MARK}); pass --allow-rehearsal to use them anyway`);
  }
  const manifest = parseManifest(readFileSync(join(dir, "manifest.json"), "utf8"), join(dir, "manifest.json"));
  if (manifest.chainId !== net.chainId) throw new Error(`the manifest in ${dir} is for chain ${manifest.chainId}, not ${net.id} (${net.chainId})`);
  if (manifest.network !== net.manifestNetwork) {
    throw new Error(`the manifest in ${dir} names network "${manifest.network}", not "${net.manifestNetwork}" (${net.id})`);
  }
  for (const f of OUTPUTS) if (!existsSync(join(dir, `${f}.json`))) throw new Error(`no ${f}.json in ${dir}: run the deploy step that writes it`);
  const avana = readJson(join(dir, "avana.json"));
  if (Number(avana.chainId) !== net.chainId) throw new Error(`avana.json in ${dir} is for chain ${avana.chainId}, not ${net.chainId}`);
  const act = join(dir, "operation-listing-activate.json");
  return {
    net,
    dir,
    manifest,
    avana,
    markets: readJson(join(dir, "markets.json")),
    coverage: readJson(join(dir, "coverage.json")),
    activation: existsSync(act) ? readJson(act) : undefined,
  };
}

const same = (a: string | undefined | null, b: string | undefined | null) => !!a && !!b && a.toLowerCase() === b.toLowerCase();
const col = (out: Json, key: string): Json[] => (Array.isArray(out?.[key]) ? out[key] : []);

/** The pool a market's bytes32 key names: a left-padded address (Uniswap v3, Slipstream) or a v4 PoolId. */
function poolOf(key: string, kind: Kind): string {
  if (kind === "uniswap-v4") return key;
  return /^0x0{24}[0-9a-fA-F]{40}$/.test(key) ? `0x${key.slice(26)}` : key;
}

/** Builds the pages' values; every missing or placeholder value is pushed to `problems` as one line. */
export function buildModel(d: Deployment, problems: string[]): Model {
  const m = d.manifest;
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
  const differ = (file: string, what: string, a: unknown, b: unknown) => {
    if (String(a).toLowerCase() !== String(b).toLowerCase()) problems.push(`the manifest and ${file} differ: ${what} (${String(a)} against ${String(b)})`);
  };
  const isSafe = (a: string) => m.external.some((e) => e.group === "safe" && same(e.address, a));

  const tokens = m.external.filter((e) => e.group === "token").map((e) => ({ symbol: e.name, address: e.address, standIn: e.standIn }));
  const symbolOf = (address: string, where: string) => need(`symbol of token ${address} (manifest external, group token; ${where})`, tokens.find((t) => same(t.address, address))?.symbol);

  // Avana's core: avana.json (03_DeployAvana) and the manifest name the same contracts.
  const av = d.avana;
  differ("avana.json", "accessManager", m.avana.accessManager.address, av.accessManager);
  differ("avana.json", "create3Factory", m.create3Factory, av.create3Factory);
  differ("avana.json", "deployer", m.deployer, av.deployer);
  need("avana.accessManager", m.avana.accessManager.address);
  const ids = col(av, "integrationIds").map(Number);
  if (ids.length !== m.avana.integrations.length) problems.push(`the manifest lists ${m.avana.integrations.length} integrations, avana.json ${ids.length}`);
  const integrations: Integration[] = m.avana.integrations.map((x) => {
    const i = ids.indexOf(x.integrationId);
    if (i === -1) problems.push(`missing: integration ${x.integrationId} in avana.json`);
    const cols = { lpVault: "lpVaults", riskModule: "riskModules", liquidationModule: "liquidationModules", aaveAdapter: "aaveAdapters", flashloanRepay: "flashloanRepays" } as const;
    for (const [k, c] of Object.entries(cols)) {
      if (i !== -1) differ("avana.json", `integration ${x.integrationId} ${k}`, x[k as keyof typeof cols].address, col(av, c)[i]);
    }
    const kind = x.kind as Kind;
    const tag = `integration ${x.integrationId}`;
    return {
      id: x.integrationId,
      kind,
      lpVault: need(`${tag} LPVault`, x.lpVault.address),
      riskModule: need(`${tag} RiskModule`, x.riskModule.address),
      liquidationModule: need(`${tag} LiquidationModule`, x.liquidationModule.address),
      aaveAdapter: need(`${tag} AaveAdapter`, x.aaveAdapter.address),
      flashloanRepay: ZERO.test(x.flashloanRepay.address) ? x.flashloanRepay.address : need(`${tag} FlashloanRepay`, x.flashloanRepay.address),
    };
  });
  const flash = col(av, "flashLiquidators");
  for (const f of m.avana.flashLiquidators) {
    if (!flash.some((a) => same(a, f.address))) problems.push(`missing: FlashLiquidator ${f.address} in avana.json`);
    if (!integrations.some((x) => x.id === f.integrationId)) problems.push(`FlashLiquidator ${f.address} names integration ${f.integrationId}, which the manifest does not list`);
    need(`FlashLiquidator of integration ${f.integrationId}`, f.address);
    need(`operator of FlashLiquidator ${f.address}`, f.operator);
  }

  // Aave V4: the Hubs and Spokes the manifest records.
  if (m.aave.hubs.length === 0) problems.push("missing: aave.hubs (no Hub)");
  const hubs: Hub[] = m.aave.hubs.map((h) => ({ label: h.label, tier: h.tier, address: need(`aave.hubs[label=${h.label}]`, h.address) }));
  const hubLabel = (a: string, where: string) => need(`Hub ${a} (aave.hubs; ${where})`, hubs.find((h) => same(h.address, a))?.label);
  const spokeLabel = (a: string, where: string) => need(`CDP Spoke ${a} (aave.borrowSpokes; ${where})`, m.aave.borrowSpokes.find((s) => same(s.address, a))?.label);
  if (m.aave.lendSpokes.length === 0) problems.push("missing: aave.lendSpokes (no Lend Spoke)");
  const lendSpokes = m.aave.lendSpokes.map((s) => ({ label: s.label, address: need(`aave.lendSpokes[label=${s.label}]`, s.address) }));

  // Markets: the manifest's, with the listing values only markets.json (09_ListMarkets) records.
  const mj = d.markets;
  // Each RiskModule numbers its own markets, so a market is its integration and its ID.
  const mKeys = col(mj, "marketIds").map((id, k) => `${col(mj, "integrationIds")[k]}:${id}`);
  if (mKeys.length !== m.markets.length) problems.push(`the manifest lists ${m.markets.length} markets, markets.json ${mKeys.length}`);
  const markets: Market[] = m.markets.map((x) => {
    const tag = `market ${x.marketId} of integration ${x.integrationId}`;
    const i = mKeys.indexOf(`${x.integrationId}:${x.marketId}`);
    if (i === -1) problems.push(`missing: ${tag} in markets.json`);
    else {
      differ("markets.json", `${tag} vault token`, x.vaultToken.address, col(mj, "vaultTokens")[i]);
      differ("markets.json", `${tag} LPOracle`, x.lpOracle.address, col(mj, "lpOracles")[i]);
      differ("markets.json", `${tag} Spoke`, x.spoke, col(mj, "spokes")[i]);
      differ("markets.json", `${tag} LTV`, x.ltvBps, col(mj, "ltvBps")[i]);
      differ("markets.json", `${tag} band`, `${x.bandLower}:${x.bandUpper}`, `${col(mj, "bandLowers")[i]}:${col(mj, "bandUppers")[i]}`);
    }
    const integration = integrations.find((y) => y.id === x.integrationId);
    const kind = integration?.kind ?? "uniswap-v3";
    if (!integration) problems.push(`${tag} names integration ${x.integrationId}, which the manifest does not list`);
    const syms = x.tokens.map((t, k) => symbolOf(t, `${tag} token${k}`));
    return {
      marketId: x.marketId,
      name: x.name,
      range: x.kind === "full-range" ? "Full range" : "Custom range",
      integrationId: x.integrationId,
      kind,
      spoke: spokeLabel(x.spoke, tag),
      hub: hubLabel(x.hub, tag),
      pool: need(`${tag} pool`, poolOf(x.pool, kind)),
      pair: syms.join("/"),
      tokens: syms,
      bandLower: x.bandLower,
      bandUpper: x.bandUpper,
      ltvBps: x.ltvBps,
      unitDecimals: x.unitDecimals,
      maxLiquidationBonus: num(`${tag} maxLiquidationBonus (markets.json)`, i === -1 ? undefined : col(mj, "maxLiquidationBonus")[i]),
      addCap: need(`${tag} addCaps (markets.json)`, i === -1 ? undefined : col(mj, "addCaps")[i]),
      vaultToken: need(`${tag} vault token`, x.vaultToken.address),
      lpOracle: need(`${tag} LPOracle`, x.lpOracle.address),
      reserveId: x.reserveId,
      feeds: x.feeds,
    };
  });

  // Loss layers: the manifest's coverage, aligned with coverage.json (07_DeployFirstLossReserves).
  const cj = d.coverage;
  const cAvana = col(cj, "avanaLayers");
  if (cAvana.length !== m.coverage.firstLossReserves.length) problems.push(`the manifest lists ${m.coverage.firstLossReserves.length} First-Loss Reserves, coverage.json ${cAvana.length}`);
  const lossLayers: LossLayers[] = m.coverage.firstLossReserves.map((f) => {
    const hub = hubLabel(f.hub, `First-Loss Reserve ${f.symbol}`);
    const tag = `${f.symbol} on Hub ${f.hubLabel}`;
    const o = m.coverage.daoDeficitOffsets.find((x) => same(x.hub, f.hub) && same(x.asset, f.asset));
    const i = cAvana.findIndex((a) => same(a, f.address));
    if (i === -1) problems.push(`missing: First-Loss Reserve of ${tag} in coverage.json`);
    else if (o) differ("coverage.json", `DAO deficit offset of ${tag}`, o.address, col(cj, "daoOffsets")[i]);
    return {
      hub,
      symbol: f.symbol,
      asset: f.asset,
      firstLossReserve: need(`First-Loss Reserve of ${tag} (manifest coverage.firstLossReserves)`, f.address),
      daoDeficitOffset: need(`DAO deficit offset of ${tag} (manifest coverage.daoDeficitOffsets)`, o?.address),
      minimum: f.minimum,
      offsetMinimum: o?.minimum ?? "0",
      decimals: m.debtReserves.find((r) => same(r.asset, f.asset))?.decimals,
    };
  });

  // Debt reserves: each names its First-Loss Reserve, whose Hub is the reserve's.
  const debtReserves: DebtReserve[] = m.debtReserves.map((r) => {
    const spoke = spokeLabel(r.spoke, `debt reserve ${r.debtReserveId}`);
    const symbol = symbolOf(r.asset, `debt reserve ${r.debtReserveId} on ${spoke}`);
    const layer = lossLayers.find((l) => same(l.firstLossReserve, r.firstLossReserve));
    if (!layer) problems.push(`debt reserve ${symbol} on ${spoke}: First-Loss Reserve ${r.firstLossReserve} is not in the manifest's coverage`);
    else if (!same(layer.asset, r.asset)) problems.push(`debt reserve ${symbol} on ${spoke}: its First-Loss Reserve covers another asset`);
    return { spoke, hub: layer?.hub ?? "MISSING", reserveId: r.debtReserveId, symbol, asset: r.asset, decimals: r.decimals, firstLossReserve: r.firstLossReserve, feeds: r.feeds };
  });
  for (const l of lossLayers) if (l.decimals === undefined) problems.push(`missing: a debt reserve of ${l.symbol} (its decimals size the loss-layer minimums)`);

  // CDP Spokes, each with the Hub and integration its markets and debt reserves name.
  const cdpSpokes: CdpSpoke[] = m.aave.borrowSpokes.map((s) => {
    const mk = markets.filter((x) => x.spoke === s.label);
    const dr = debtReserves.filter((x) => x.spoke === s.label);
    const hubsOf = [...new Set([...mk.map((x) => x.hub), ...dr.map((x) => x.hub)])];
    const kinds = [...new Set(mk.map((x) => x.kind))];
    if (hubsOf.length > 1) problems.push(`CDP Spoke ${s.label}: its markets and debt reserves name ${hubsOf.length} Hubs`);
    if (kinds.length > 1) problems.push(`CDP Spoke ${s.label}: its markets belong to ${kinds.length} integrations`);
    return { label: s.label, address: need(`aave.borrowSpokes[label=${s.label}]`, s.address), hub: hubsOf[0], kind: kinds[0], borrowable: dr.map((x) => x.symbol), markets: mk };
  });

  // The governance delay: activateMarket is a governance-role call, so the activation operation waits that delay.
  let governanceDelay = Number.NaN;
  if (!d.activation) problems.push("missing: operation-listing-activate.json (its delay is the governance role's)");
  else if (!((d.activation.labels ?? []) as string[]).every((l) => /^activateMarket\b/.test(l))) {
    problems.push("operation-listing-activate.json holds calls other than activateMarket; its delay is not the governance delay");
  } else {
    if (!same(d.activation.accessManager, m.avana.accessManager.address)) problems.push("operation-listing-activate.json names another AccessManager than the manifest");
    if (!same(d.activation.scheduler, m.roles.governanceSafe)) problems.push("operation-listing-activate.json is not scheduled by the governance Safe");
    governanceDelay = num("operation-listing-activate.json delay", d.activation.delay);
    if (governanceDelay < GOVERNANCE_DELAY_MIN || governanceDelay > GOVERNANCE_DELAY_MAX) {
      problems.push(`operation-listing-activate.json delay ${governanceDelay} s is outside the governance delay's 4 to 5 days (AvanaAccess.governanceDelay)`);
    }
  }

  // Role holders as the pages word them.
  const r = m.roles;
  for (const k of ["aaveGovernanceExecutor", "governanceSafe", "emergencyGuardian", "aaveProtocolGuardian", "jointConfigSafe"] as const) need(`roles.${k}`, r[k]);
  need("feeRecipient", m.feeRecipient);
  if (same(r.jointConfigSafe, r.governanceSafe)) problems.push("role holders differ from the page wording: the Joint Configuration Safe is the governance Safe");
  if (r.keepers.length === 0) problems.push("missing: roles.keepers (no keeper; borrowing stops while none is registered)");
  if (r.keeperTopUp && r.keepers.some((k) => same(k, r.keeperTopUp?.wallet))) problems.push("role holders differ from the page wording: the keeper top-up wallet is a keeper");
  if (m.sequencerFeed && !d.net.layer2) problems.push("a sequencer feed is recorded on a chain without a sequencer");

  return { net: d.net, manifest: m, hubs, cdpSpokes, lendSpokes, integrations, markets, debtReserves, lossLayers, tokens, isSafe, governanceDelay };
}
