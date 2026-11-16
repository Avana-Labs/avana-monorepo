// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Adding a Hub to a local chain as one operator flow, built from plain functions with JSON inputs and outputs so an
// operations dashboard can call the same steps:
//   planHub(config, input)        pure: the chain's current config plus one Hub input file -> the next config and a
//                                 summary of what it adds (validation errors are thrown, nothing is touched)
//   releaseHub(chain, label, cfg) runs the release steps on the chain (Aave side, timelock, listing, activation) and
//                                 records the manifest; each step is recorded and a rerun resumes at the failed one
//   addHub({ chain, hubFile })    both, then the Hub's markets as listed (listing-markets.json)
// The indexer and Convex pick the Hub, its Spokes and markets up from the chain's events (HubRecorded, SpokeApproved,
// MarketRegistered, AddSpoke) and the listing metadata the release commits to: no Convex row is written by hand.
//
// The Hub input file (README.md in this folder has a full example, hubs/*.json):
// {
//   "hub": { "label": "growth", "tier": 3, "name": "Growth", "description": "…" },
//   "lendSpoke": "lendGrowth",
//   "spokes": [{ "label": "uniV3Growth", "integration": "uniswap-v3" }],
//   "lendAssets": [{ "symbol": "USDC", "category": "stable" }, { "symbol": "PEPE", "new": { … debt asset sizing … } }],
//   "borrowable": { "uniV3Growth": ["GHO", "USDC"] },
//   "collateral": [{ "symbol": "USDC" }, { "symbol": "PEPE", "deviationBps": 200, "collateralFactorBps": 4000, "tokenCapUsd": "2000000" }],
//   "markets": [{ "pool": "USDC-USDT-500", "spoke": "uniV3Growth", "poolRiskFactorBps": 4000, … }]
// }

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { addRoutePools, poolOf, routePair, type Route } from "../../e2e/routes.ts";
import { chainOf, outDir } from "../lib/env.ts";
import { LATER_RELEASE, type StepOutcome, currentConfig, miningMode, runRelease, setMining, testValues } from "../lib/chain.ts";

type Json = Record<string, any>;

export interface HubInput {
  /** A label already on the chain extends that Hub (its Spokes, assets and markets are added); a new one creates it. */
  readonly hub: { label: string; tier: 1 | 2 | 3; name?: string; description?: string };
  readonly lendSpoke?: string;
  readonly spokes: readonly SpokeInput[];
  readonly lendAssets: readonly { symbol: string; category?: "stable" | "crypto"; new?: NewDebtAsset; rateModel?: RateModel }[];
  readonly borrowable: Readonly<Record<string, readonly string[]>>;
  readonly collateral: readonly CollateralInput[];
  readonly markets: readonly MarketInput[];
}
export interface SpokeInput {
  label: string;
  integration: "uniswap-v3" | "slipstream";
  /** The Spoke's group within its venue (Stable, Volatile, Blue-chip, Governance, ...). */
  category?: string;
  /** The Spoke's page name, default `<venue> <category>`. */
  name?: string;
  description?: string;
}
/** An Aave V4 Hub asset's rate curve, in bps; set when the asset is listed on the Hub. */
export interface RateModel {
  optimalUsageBps: number;
  baseDrawnRateBps: number;
  rateGrowthBeforeOptimalBps: number;
  rateGrowthAfterOptimalBps: number;
}
/**
 * A token new to Aave on the chain. Its risk parameters are the file's; the amounts the Aave DAO sets (draw cap,
 * bootstrap supply, First-Loss Reserve and offset minimums, credit line, debt speed limit) are never in a Hub file:
 * on the local stack they come from test-values.json (`TestValues`).
 */
export interface NewDebtAsset {
  stressRiseBps: number;
  floorRoundingAllowance: string;
}
/** The values the DAO sets, for the local stack only (contracts/script/local/test-values.json). */
export interface TestValues {
  debtAssets?: Record<string, { drawCap: number; bootstrapSupply: string; coverageMinimum: number; offsetMinimum: number; creditLineWhole?: number; debtMinWhole?: number; debtMaxWhole?: number }>;
  tokenCapUsd?: Record<string, string>;
  markets?: Record<string, { marketUsdCap: string; topUpSliceUsd: string }>;
}
export interface CollateralInput {
  symbol: string;
  isUsdStable?: boolean;
  deviationBps?: number;
  collateralFactorBps?: number;
}
export interface MarketInput {
  pool: string;
  spoke: string;
  /** A concentrated range (both, multiples of the pool's tick spacing); full range when omitted. The market key is
   * (integration, pool, range) chain-wide, so one pool on two Spokes needs two ranges. */
  tickLower?: number;
  tickUpper?: number;
  poolRiskFactorBps: number;
  maxLiquidationBonus: number;
  consistencyToleranceBps?: number;
  minPledgeUsd?: string;
  name?: string;
  slug?: string;
  category?: "stable" | "crypto";
  description?: string;
}

export interface HubPlan {
  readonly config: Json;
  readonly summary: {
    hub: string;
    tier: number;
    extended: boolean;
    spokes: string[];
    lendSpoke: string;
    newDebtAssets: string[];
    /** Assets already lent on the extended Hub with a rate model in the file: the release changes their curve with an
     * Aave rate change (11-changes, assetRates via the governance executor). */
    rateChanges: { symbol: string; rateModel: RateModel }[];
    lendAssets: string[];
    debtReserves: string[];
    collateralTokens: string[];
    markets: string[];
  };
}

/** The CDP Spokes' liquidation bonus factor, set by the Aave deployment payload (06_AaveDeploymentPayload). */
const LIQUIDATION_BONUS_FACTOR = 5000;
const INTEGRATION_ID = { "uniswap-v3": 1, slipstream: 2 } as const;
const VENUE = { "uniswap-v3": "Uniswap v3", slipstream: "Slipstream" } as const;
const slugify = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
const cap = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);

/** The next config: `config` (the chain's current one, unchanged) with everything `input` adds. Throws on any error. */
export function planHub(config: Json, input: HubInput, tv: TestValues = {}): HubPlan {
  const c = structuredClone(config) as Json;
  const errors: string[] = [];
  const label = input.hub.label;
  if (!/^[a-z][a-zA-Z0-9]*$/.test(label)) errors.push(`hub.label ${label}: letters and digits, starting with a lower-case letter`);
  const extend = (c.aaveLocal.hubs as string[]).includes(label);
  const tier = extend ? ((c.aave.hubs as Json[]).find((h) => h.label === label)!.tier as number) : input.hub.tier;
  if (![1, 2, 3].includes(tier)) errors.push("hub.tier must be 1 (stable), 2 (correlated) or 3 (volatile)");
  const lend = extend ? ((c.aavePayload.hubs as Json[]).find((h) => h.label === label)!.lendSpoke as string) : (input.lendSpoke ?? `lend${cap(label)}`);
  const spokeLabels = new Set([...Object.keys(c.aave.spokes), ...(c.aaveLocal.spokes as Json[]).map((s) => s.label)]);
  for (const s of [...input.spokes.map((x) => x.label), ...(extend ? [] : [lend])]) if (spokeLabels.has(s)) errors.push(`spoke ${s} is already in the config`);
  for (const m of input.markets) {
    if ((m.tickLower === undefined) !== (m.tickUpper === undefined)) errors.push(`market ${m.pool}: give both tickLower and tickUpper, or neither`);
    if (m.tickLower !== undefined && m.tickUpper !== undefined && m.tickLower >= m.tickUpper) errors.push(`market ${m.pool}: tickLower must be below tickUpper`);
  }
  const worldSymbols = new Set((c.world.tokens as Json[]).map((t) => t.symbol as string));
  const sym = (s: string, where: string) => {
    if (!worldSymbols.has(s)) errors.push(`${where}: ${s} is not a token of this chain's world`);
  };
  const spokeOf = (l: string) => input.spokes.find((s) => s.label === l);
  for (const [s, assets] of Object.entries(input.borrowable)) {
    if (!spokeOf(s)) errors.push(`borrowable: ${s} is not one of this Hub's CDP Spokes`);
    for (const a of assets) {
      sym(a, `borrowable.${s}`);
      if (!input.lendAssets.some((x) => x.symbol === a) && !(c.aavePayload.debtAssets as Json[]).some((d) => d.symbol === a && !d.hubs)) errors.push(`borrowable.${s}: ${a} is not lent on this Hub (lendAssets)`);
    }
  }
  for (const m of input.markets) {
    if (!poolOf(c, m.pool)) errors.push(`market ${m.pool}: no such pool in this chain's world`);
    const s = spokeOf(m.spoke);
    if (!s) errors.push(`market ${m.pool}: spoke ${m.spoke} is not one of this Hub's CDP Spokes`);
    else if (!(input.borrowable[m.spoke] ?? []).length) errors.push(`market ${m.pool}: spoke ${m.spoke} lends nothing (borrowable)`);
    const p = poolOf(c, m.pool);
    if (p && s && (s.integration === "slipstream") !== (p.tickSpacing !== undefined)) errors.push(`market ${m.pool}: a ${s.integration} spoke needs a ${s.integration} pool`);
    if (p) for (const t of [p.a, p.b]) if (!input.collateral.some((x) => x.symbol === t) && !(c.listing.tokens as Json[]).some((x) => x.symbol === t)) errors.push(`market ${m.pool}: ${t} is neither listed collateral nor in collateral`);
  }
  for (const a of input.lendAssets) sym(a.symbol, "lendAssets");
  for (const t of input.collateral) sym(t.symbol, "collateral");
  if (errors.length) throw new Error(`Hub input refused:\n- ${errors.join("\n- ")}`);

  // 1. The Hub, its Lend Spoke and its CDP Spokes (Aave side, then Avana's CDP Spoke records). Extending a Hub adds
  // only its new CDP Spokes.
  if (!extend) {
    c.aaveLocal.hubs.push(label);
    c.aaveLocal.spokes.push({ label: lend, userReservesLimit: 65535 });
    c.aave.hubs.push({ hub: `$aave:.hubs.${label}.proxy`, tier, label });
    c.aave.irStrategies[label] = `$aave:.hubs.${label}.irStrategy`;
    c.aave.spokes[lend] = `$aave:.spokes.${lend}.proxy`;
    c.aavePayload.hubs.push({
      label,
      lendSpoke: lend,
      cdpSpokes: [],
      ...(input.hub.name ? { content: { slug: slugify(`${input.hub.name}`), name: input.hub.name, description: input.hub.description ?? "", faqs: [] } } : {}),
    });
  }
  const hubEntry = (c.aavePayload.hubs as Json[]).find((h) => h.label === label)!;
  for (const s of input.spokes) {
    c.aaveLocal.spokes.push({ label: s.label, userReservesLimit: 8 });
    c.aave.spokes[s.label] = `$aave:.spokes.${s.label}.proxy`;
    hubEntry.cdpSpokes.push(s.label);
    const name = s.name ?? `${VENUE[s.integration]}${s.category ? ` ${s.category}` : ""}`;
    c.listing.spokes.push({
      label: s.label,
      hub: label,
      integrationId: INTEGRATION_ID[s.integration],
      tier,
      spoke: `$aave:.spokes.${s.label}.proxy`,
      content: { slug: slugify(`${name}-${label}`), name, description: s.description ?? `${name} positions on the ${input.hub.name ?? label} Hub.`, faqs: [] },
    });
  }

  // 2. What the Hub lends: an existing debt asset limited to some Hubs gets this one; a new one is sized from input.
  const newDebt: string[] = [];
  const rateKept: { symbol: string; rateModel: RateModel }[] = [];
  for (const a of input.lendAssets) {
    const d = (c.aavePayload.debtAssets as Json[]).find((x) => x.symbol === a.symbol);
    const w = (c.world.tokens as Json[]).find((t) => t.symbol === a.symbol)!;
    const wasLent = extend && d !== undefined && (!d.hubs || d.hubs.includes(label));
    if (d) {
      if (d.hubs && !d.hubs.includes(label)) d.hubs.push(label);
      if (d.lendOnly && (Object.values(input.borrowable) as string[][]).some((x) => x.includes(a.symbol))) throw new Error(`${a.symbol} is lend-only on this chain and cannot be borrowed`);
    } else {
      if (!a.new) throw new Error(`lendAssets: ${a.symbol} is new to Aave on this chain: give its risk parameters in "new"`);
      const dao = tv.debtAssets?.[a.symbol];
      if (!dao) throw new Error(`lendAssets: ${a.symbol} has no DAO-set amounts in the test values`);
      newDebt.push(a.symbol);
      c.aavePayload.debtAssets.push({
        symbol: a.symbol,
        token: `$world:.tokens.${a.symbol}`,
        decimals: w.decimals,
        priceSource: `$world:.feeds.${a.symbol}.primary`,
        drawCap: dao.drawCap,
        bootstrapSupply: dao.bootstrapSupply,
        coverageMinimum: dao.coverageMinimum,
        offsetMinimum: dao.offsetMinimum,
        hubs: [label],
      });
    }
    // The asset's rate curve on this Hub, applied by 06 when the asset is listed on it (an asset listed earlier keeps
    // its curve: the summary says so).
    if (a.rateModel) {
      const target = (c.aavePayload.debtAssets as Json[]).find((x) => x.symbol === a.symbol)!;
      target.rateModelByHub ??= {};
      target.rateModelByHub[label] = a.rateModel;
      if (wasLent) rateKept.push({ symbol: a.symbol, rateModel: a.rateModel });
    }
    // A debt asset borrowable on a CDP Spoke needs its listing entry (its DebtOracle) once per chain.
    const borrowed = (Object.values(input.borrowable) as string[][]).some((x) => x.includes(a.symbol));
    if (borrowed && !(c.listing.debtAssets as Json[]).some((x) => x.symbol === a.symbol)) {
      if (!a.new) throw new Error(`${a.symbol} has no DebtOracle on this chain: give its sizing in "new"`);
      c.listing.debtAssets.push({
        symbol: a.symbol,
        fixedPrice: false,
        stressRiseBps: a.new.stressRiseBps,
        floorRoundingAllowance: a.new.floorRoundingAllowance,
        debtOraclePokeMinGas: 1000000,
        ...(tv.debtAssets?.[a.symbol]?.creditLineWhole ? { creditLineWhole: tv.debtAssets[a.symbol]!.creditLineWhole } : {}),
        ...(tv.debtAssets?.[a.symbol]?.debtMinWhole ? { debtMinWhole: tv.debtAssets[a.symbol]!.debtMinWhole, debtMaxWhole: tv.debtAssets[a.symbol]!.debtMaxWhole } : {}),
        address: `$world:.tokens.${a.symbol}`,
        feeds: { primary: `$world:.feeds.${a.symbol}.primary` },
      });
    }
  }
  hubEntry.lendContent ??= {};
  Object.assign(hubEntry.lendContent, Object.fromEntries(
    input.lendAssets.map((a) => [a.symbol, { slug: slugify(`${label}-${a.symbol}`), name: `${a.symbol} on the ${input.hub.name ?? label} Hub`, symbol: a.symbol, category: a.category ?? "crypto", description: `Lend ${a.symbol} on Aave V4's ${input.hub.name ?? label} Hub.`, faqs: [] }]),
  ));

  // 3. Debt reserves: what each CDP Spoke lends (the first is each market's default debt asset).
  const debtReserves: string[] = [];
  for (const s of input.spokes) {
    for (const a of input.borrowable[s.label] ?? []) {
      debtReserves.push(`${s.label}:${a}`);
      c.listing.debtReserves.push({
        spoke: s.label,
        symbol: a,
        content: {
          slug: slugify(`${a}-${VENUE[s.integration]}-${label}`),
          name: `${a} on ${VENUE[s.integration]} (${input.hub.name ?? label} Hub)`,
          symbol: a,
          category: input.lendAssets.find((x) => x.symbol === a)?.category ?? (/USD|DAI|GHO/.test(a) ? "stable" : "crypto"),
          description: `Borrow ${a} from Aave V4's ${input.hub.name ?? label} Hub against ${VENUE[s.integration]} liquidity positions.`,
          faqs: [{ question: `Where does the ${a} come from?`, answer: `From the ${input.hub.name ?? label} Hub of Aave V4, through the ${VENUE[s.integration]} CDP Spoke.` }],
        },
      });
    }
  }

  // 4. Collateral tokens: an existing one is accepted on this Hub too; a new one is listed with its limits. The
  // agreement tolerance is the ParameterStore's least (two routes' deviation plus the margin) plus 50 bps.
  const tokens: string[] = [];
  for (const t of input.collateral) {
    const have = (c.listing.tokens as Json[]).find((x) => x.symbol === t.symbol);
    if (have) {
      if (!have.hubs.includes(label)) have.hubs.push(label);
      tokens.push(`${t.symbol} (listed)`);
      continue;
    }
    const dev = t.deviationBps ?? 100;
    const tol = 2 * dev + (c.parameters.globals.feedAgreementMarginBps as number) + 50;
    c.listing.tokens.push({
      symbol: t.symbol,
      isUsdStable: t.isUsdStable ?? false,
      deviationBps: dev,
      collateralFactorBps: t.collateralFactorBps ?? 6000,
      agreementToleranceBps: tol,
      secondToleranceBps: tol,
      tokenCapUsd: tv.tokenCapUsd?.[t.symbol] ?? tv.tokenCapUsd?.default ?? "0",
      hubs: [label],
      address: `$world:.tokens.${t.symbol}`,
      feeds: { primary: `$world:.feeds.${t.symbol}.primary`, alternate: `$world:.feeds.${t.symbol}.alternate`, standby: `$world:.feeds.${t.symbol}.standby`, second: `$world:.feeds.${t.symbol}.second` },
    });
    tokens.push(t.symbol);
  }

  // 5. Markets, from the chain's first market of the same venue as a template; routes from each pool token into each
  // asset the Spoke lends, two pool-disjoint paths each, found over the world's pools.
  const template = (id: number) => {
    const m = (c.listing.markets as Json[]).find((x) => x.integrationId === id) ?? c.listing.marketDefaults?.[String(id)];
    if (!m) throw new Error(`no market parameters for integration ${id} to start from (listing.marketDefaults)`);
    return m;
  };
  const tokenCf = (s: string) => (c.listing.tokens as Json[]).find((x) => x.symbol === s)!.collateralFactorBps as number;
  const f = c.parameters.globals.avanaFeeShareBps as number;
  const markets: string[] = [];
  for (const mi of input.markets) {
    const s = spokeOf(mi.spoke)!;
    const p = poolOf(c, mi.pool)!;
    const slip = s.integration === "slipstream";
    const range = mi.tickLower !== undefined ? `-r${mi.tickLower}_${mi.tickUpper}` : "";
    const name = mi.name ?? `${slip ? "slip" : "uni"}-${mi.pool}${range}-${s.label}`;
    const own = (c.world.uniswapPools as Json[]).some((x) => x.name === mi.pool) ? mi.pool : "";
    const lends = input.borrowable[s.label]!;
    const routes: Route[] = lends.flatMap((asset) => [p.a, p.b].filter((t: string) => t !== asset).map((t: string) => routePair(c, name, t, asset, own)));
    addRoutePools(c, routes);
    c.listing.pools[mi.pool] = slip ? `$world:.slipstreamPools['${mi.pool}']` : `$world:.uniswapPools['${mi.pool}']`;
    const cf = Math.floor((Math.min(tokenCf(p.a), tokenCf(p.b)) * mi.poolRiskFactorBps) / 1e4);
    // The largest slippage allowance s with s x minLB <= (1e4 - f)(minLB - 1e4), minLB the smallest bonus (LIQ-I1).
    const minLb = 10_000 + Math.floor(((mi.maxLiquidationBonus - 10_000) * LIQUIDATION_BONUS_FACTOR) / 10_000);
    const venue = VENUE[s.integration];
    const fee = slip ? `tick spacing ${p.tickSpacing}` : `${p.fee / 10_000}% fee tier`;
    c.listing.markets.push({
      ...template(INTEGRATION_ID[s.integration]),
      name,
      spoke: s.label,
      pool: mi.pool,
      generation: slip ? p.generation : 0,
      tickLower: mi.tickLower ?? 0,
      tickUpper: mi.tickUpper ?? 0,
      collateralFactorBps: cf,
      maxLiquidationBonus: mi.maxLiquidationBonus,
      consistencyToleranceBps: mi.consistencyToleranceBps ?? 100,
      poolRiskFactorBps: mi.poolRiskFactorBps,
      slippageAllowanceBps: Math.floor(((10_000 - f) * (minLb - 10_000)) / minLb),
      slippageAllowanceMinBps: 50,
      ...(mi.minPledgeUsd ? { minPledgeUsd: mi.minPledgeUsd } : {}),
      // Caps are the DAO's: the local stack's test values (per market name, else the default).
      marketUsdCap: (tv.markets?.[name] ?? tv.markets?.default)?.marketUsdCap ?? "0",
      topUpSliceUsd: (tv.markets?.[name] ?? tv.markets?.default)?.topUpSliceUsd ?? "0",
      routes,
      content: {
        slug: mi.slug ?? slugify(`${venue}-${p.a}-${p.b}-${slip ? `cl${p.tickSpacing}` : String(p.fee)}${range}-${s.label}`),
        name: `${p.a}/${p.b} ${venue}${mi.name ? "" : ` (${input.hub.name ?? label} Hub)`}`,
        category: mi.category ?? (p.a.match(/USD|DAI|GHO/) && p.b.match(/USD|DAI|GHO/) ? "stable" : "crypto"),
        venueLabel: venue,
        description: mi.description ?? `Borrow ${lends.join(", ")} from the ${input.hub.name ?? label} Hub against a full-range ${p.a}/${p.b} liquidity position in the ${venue} pool with ${fee}.`,
        faqs: [{ question: "What can I borrow?", answer: `${lends.join(", ")} from the ${input.hub.name ?? label} Hub, up to ${cf / 100}% of the position's value.` }],
      },
    });
    markets.push(name);
  }

  return {
    config: c,
    summary: {
      hub: label,
      tier,
      extended: extend,
      spokes: input.spokes.map((s) => s.label),
      lendSpoke: lend,
      newDebtAssets: newDebt,
      rateChanges: rateKept,
      lendAssets: input.lendAssets.map((a) => a.symbol),
      debtReserves,
      collateralTokens: tokens,
      markets,
    },
  };
}

export interface ReleaseResult {
  readonly ok: boolean;
  readonly chain: string;
  readonly release: string;
  readonly steps: readonly StepOutcome[];
  readonly manifest?: string;
}

/**
 * Runs the release of `configPath` on the chain: every later-release step, each acting only on what the config adds,
 * ending with the manifest produced and verified. The chain mines a block per transaction meanwhile and returns to its
 * own block time afterwards.
 */
export async function releaseHub(network: string, release: string, configPath: string, onStep?: (o: StepOutcome) => void, plan?: HubPlan["summary"]): Promise<ReleaseResult> {
  const c = chainOf(network);
  const before = await miningMode(c);
  await setMining(c, "auto");
  try {
    // Rate curves of assets the Hub already lent: one Aave rate change before the manifest.
    let sequence = LATER_RELEASE;
    if (plan?.rateChanges.length) {
      const file = `changes-${release}-rates.json`;
      writeFileSync(
        join(outDir(c), file),
        `${JSON.stringify(
          {
            name: `${release}-rates`,
            description: `the rate curves of the ${plan.hub} Hub's assets, from its Hub file`,
            via: "aip",
            changes: plan.rateChanges.map((r) => ({
              aave: "assetRates",
              hub: `hub:${plan.hub}`,
              asset: `token:${r.symbol}`,
              set: {
                optimalUsageRatio: r.rateModel.optimalUsageBps,
                baseDrawnRate: r.rateModel.baseDrawnRateBps,
                rateGrowthBeforeOptimal: r.rateModel.rateGrowthBeforeOptimalBps,
                rateGrowthAfterOptimal: r.rateModel.rateGrowthAfterOptimalBps,
              },
            })),
          },
          null,
          2,
        )}\n`,
      );
      sequence = [...LATER_RELEASE.slice(0, -1), `changes:${file}`, LATER_RELEASE.at(-1)!];
    }
    const steps = await runRelease(c, release, sequence, configPath, onStep);
    const ok = steps.every((s) => s.outcome !== "fail");
    return { ok, chain: c.network, release, steps, ...(ok ? { manifest: join(outDir(c), "manifest.json") } : {}) };
  } finally {
    if (before === "interval") await setMining(c, "interval");
  }
}

export interface AddHubResult extends ReleaseResult {
  readonly plan?: HubPlan["summary"];
  readonly config?: string;
  readonly markets?: readonly Json[];
  readonly error?: string;
}

/** Plan, write the config, release, and return the Hub's listed markets. A rerun after a failure resumes the release. */
export async function addHub(args: { chain: string; hubFile: string }, onStep?: (o: StepOutcome) => void): Promise<AddHubResult> {
  const c = chainOf(args.chain);
  const input = JSON.parse(readFileSync(args.hubFile, "utf8")) as HubInput;
  const release = `hub-${input.hub.label}`;
  const configPath = join(outDir(c), `config-${release}.json`);
  let plan: HubPlan["summary"] | undefined;
  // A release that started earlier keeps its config (its steps are on record); a new one is planned on the current.
  if (!existsSync(configPath)) {
    try {
      const p = planHub(JSON.parse(readFileSync(currentConfig(c), "utf8")), input, testValues());
      writeFileSync(configPath, `${JSON.stringify(p.config, null, 2)}\n`);
      writeFileSync(join(outDir(c), `plan-${release}.json`), `${JSON.stringify(p.summary, null, 2)}\n`);
      plan = p.summary;
    } catch (e) {
      return { ok: false, chain: c.network, release, steps: [], error: (e as Error).message };
    }
  } else plan = JSON.parse(readFileSync(join(outDir(c), `plan-${release}.json`), "utf8"));
  const r = await releaseHub(c.network, release, configPath, onStep, plan);
  const listed = existsSync(join(outDir(c), "listing-markets.json")) ? (Object.values(JSON.parse(readFileSync(join(outDir(c), "listing-markets.json"), "utf8"))) as Json[]) : [];
  return { ...r, plan, config: configPath, markets: listed.filter((m) => plan?.markets.includes(m.name)) };
}
