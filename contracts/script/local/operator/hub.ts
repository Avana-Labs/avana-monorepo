// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Adding a Hub to a local chain as one operator flow, built from plain functions with JSON inputs and outputs so an
// operations dashboard can call the same steps:
//   planHub(config, input, tv, chainId)  pure: the chain's current config plus one Hub input file -> the next config and a
//                                 summary of what it adds (validation errors are thrown, nothing is touched)
//   releaseHub(chain, label, cfg) runs the release steps on the chain (Aave side, timelock, listing, activation) and
//                                 records the manifest; each step is recorded and a rerun resumes at the failed one
//   addHub({ chain, hubFile })    both, then the Hub's markets as listed (listing-markets.json)
// The indexer and Convex pick the Hub, its Spokes and markets up from the chain's events (HubRecorded, SpokeApproved,
// MarketRegistered, AddSpoke) and the listing metadata the release commits to: no Convex row is written by hand.
//
// A Hub file holds structure only (Hub, Lend Spoke, CDP Spokes with venue and category, lend assets, collateral tokens,
// pools, borrowable assets per Spoke). Every number the Aave DAO, governance or a risk provider sets (collateral
// factors, liquidation bonus, pool risk factor, tolerances, slippage, rate models, liquidity fees, caps, amounts) comes
// from the local stack's test values (contracts/script/local/test-values.json), never from a Hub file.
// A Hub file also holds the text of the pages the listing adds (listing metadata version 2, written by
// script/deploy/market-metadata.ts): names, descriptions, FAQs, links, the risk card's text and the Hub's risk
// disclosures. On a chain that is not a development node (31337, 31338), every market, lend asset and borrowable asset
// needs its risk text (summary, reviewedAt, factors).
// The Hub input file (README.md in this folder; contracts/script/deploy/hubs/<chain>/*.json):
// {
//   "hub": { "label": "growth", "tier": 3, "name": "Growth", "description": "…", "faqs": [], "links": {…},
//            "disclosures": { "borrow": "…", "lend": "…" } },
//   "lendSpoke": "lendGrowth",
//   "spokes": [{ "label": "uniV3Growth", "integration": "uniswap-v3", "links": {…} }],
//   "lendAssets": [{ "symbol": "USDC", "category": "stable", "risk": {…} }],
//   "borrowAssets": [{ "symbol": "USDC", "description": "…", "risk": {…} }],
//   "tokens": [{ "symbol": "USDC", "name": "USD Coin", "iconUrl": "https://…", "links": {…} }],
//   "borrowable": { "uniV3Growth": ["GHO", "USDC"] },
//   "collateral": [{ "symbol": "USDC", "isUsdStable": true }],
//   "markets": [{ "pool": "USDC-USDT-500", "spoke": "uniV3Growth", "risk": {…}, "links": {…} }]
// }
// links = { website?, x?, docs?, github?, audits?: [{ label, href }] }
// risk  = { summary, reviewedAt: "YYYY-MM-DD", factors: [{ id, label, level: low|moderate|elevated|high, text }] }

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { addRoutePools, poolOf, routePair, type Route } from "../../e2e/routes.ts";
import { DEV_CHAIN_IDS } from "../../../../services/common/src/chains.ts";
import { chainOf, outDir } from "../lib/env.ts";
import { LATER_RELEASE, type StepOutcome, currentConfig, miningMode, runRelease, setMining, testValues } from "../lib/chain.ts";

type Json = Record<string, any>;

export type Category = "stable" | "crypto" | "stock";
export interface Faq {
  question: string;
  answer: string;
}
/** A page's project links (listing metadata version 2). */
export interface Links {
  website?: string;
  x?: string;
  docs?: string;
  github?: string;
  audits?: { label: string; href: string }[];
}
/** The risk card's text: a summary, the date it was last reviewed and the rated factors behind it. */
export interface Risk {
  summary: string;
  /** YYYY-MM-DD. */
  reviewedAt: string;
  factors: { id: string; label: string; level: "low" | "moderate" | "elevated" | "high"; text: string }[];
}
/** A page's text; generated where the Hub file gives none. */
export interface PageText {
  name?: string;
  description?: string;
  longText?: string;
  faqs?: Faq[];
  links?: Links;
  iconUrl?: string;
}

export interface HubInput {
  /** A label already on the chain extends that Hub (its Spokes, assets and markets are added); a new one creates it. */
  readonly hub: { label: string; tier: 1 | 2 | 3; disclosures?: { borrow?: string; lend?: string } } & PageText;
  readonly lendSpoke?: string;
  readonly spokes: readonly SpokeInput[];
  readonly lendAssets: readonly ({ symbol: string; category?: Category; risk?: Risk } & PageText)[];
  /** The page of each borrowable asset, used for its debt reserve on every CDP Spoke of the Hub. */
  readonly borrowAssets?: readonly ({ symbol: string; risk?: Risk } & PageText)[];
  /** Token pages (every symbol on every page), and the links and icon of the token's lend and borrow pages. */
  readonly tokens?: readonly { symbol: string; name?: string; iconUrl?: string; links?: Links }[];
  readonly borrowable: Readonly<Record<string, readonly string[]>>;
  readonly collateral: readonly CollateralInput[];
  readonly markets: readonly MarketInput[];
}
export interface SpokeInput extends PageText {
  label: string;
  integration: "uniswap-v3" | "slipstream";
  /** The Spoke's group within its venue (Stable, Volatile, Blue-chip, Governance, ...). */
  category?: string;
}
/** An Aave V4 Hub asset's rate curve, in bps; set when the asset is listed on the Hub. */
export interface RateModel {
  optimalUsageBps: number;
  baseDrawnRateBps: number;
  rateGrowthBeforeOptimalBps: number;
  rateGrowthAfterOptimalBps: number;
}
/** A debt asset's values (amounts in whole tokens unless noted); `byHub.<label>` overrides the curve and fee per Hub. */
export interface DebtAssetValues {
  drawCap?: number;
  bootstrapSupply?: string;
  coverageMinimum?: number;
  offsetMinimum?: number;
  stressRiseBps?: number;
  floorRoundingAllowance?: string;
  creditLineWhole?: number;
  debtMinWhole?: number;
  debtMaxWhole?: number;
  rateModel?: RateModel;
  liquidityFeeBps?: number;
  byHub?: Record<string, { rateModel?: RateModel; liquidityFeeBps?: number }>;
}
export interface TokenValues {
  deviationBps?: number;
  collateralFactorBps?: number;
  agreementToleranceBps?: number;
  secondToleranceBps?: number;
  tokenCapUsd?: string;
}
export interface MarketValues {
  collateralFactorBps?: number;
  poolRiskFactorBps?: number;
  maxLiquidationBonus?: number;
  consistencyToleranceBps?: number;
  slippageAllowanceBps?: number;
  slippageAllowanceMinBps?: number;
  collateralRisk?: number;
  minPledgeUsd?: string;
  stressFloorUsd?: string;
  marketUsdCap?: string;
  topUpSliceUsd?: string;
  /** The risk card's bps per factor id, local only: the chain has one premium, and a split needs the risk team's method. */
  riskFactorBps?: Record<string, number>;
}
/** Every number the DAO, governance or a risk provider sets, for the local stack only (test-values.json); `default`
 * entries apply where a token or market has none of its own. */
export interface TestValues {
  debtAssets?: Record<string, DebtAssetValues>;
  tokens?: Record<string, TokenValues>;
  markets?: Record<string, MarketValues>;
}
export interface CollateralInput {
  symbol: string;
  /** A fact about the token (a USD stablecoin), not a parameter. */
  isUsdStable?: boolean;
}
export interface MarketInput extends PageText {
  pool: string;
  spoke: string;
  /** A concentrated range (both, multiples of the pool's tick spacing); full range when omitted. The market key is
   * (integration, pool, range) chain-wide, so one pool on two Spokes needs two ranges. */
  tickLower?: number;
  tickUpper?: number;
  /** The market's config name, also its key in the test values' markets (default `<venue>-<pool>[-range]-<spoke>`). */
  name?: string;
  slug?: string;
  category?: Category;
  risk?: Risk;
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
    rateChanges: { symbol: string; rateModel?: RateModel; liquidityFeeBps?: number }[];
    /** Numbers that came from the test values, for the record. */
    values: Record<string, unknown>;
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
const LEVELS = ["low", "moderate", "elevated", "high"];
const CATEGORIES = ["stable", "crypto", "stock"];

/** The risk text's problems, if any (the listing metadata loader checks the rest when the file is written). */
function riskErrors(where: string, r: Risk | undefined, required: boolean): string[] {
  if (r === undefined) return required ? [`${where}: risk (summary, reviewedAt, factors) is required on a chain that is not a development node`] : [];
  const e: string[] = [];
  if (typeof r.summary !== "string" || !r.summary) e.push(`${where}.risk.summary missing`);
  if (typeof r.reviewedAt !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(r.reviewedAt) || Number.isNaN(Date.parse(r.reviewedAt))) e.push(`${where}.risk.reviewedAt must be a date, YYYY-MM-DD`);
  if (!Array.isArray(r.factors) || r.factors.length === 0) e.push(`${where}.risk.factors must list at least one factor`);
  for (const f of r.factors ?? []) {
    if (!/^[a-z][a-zA-Z0-9]{0,47}$/.test(f.id ?? "")) e.push(`${where}.risk factor ${f.id}: id must be camelCase`);
    if (!f.label || !f.text || !LEVELS.includes(f.level)) e.push(`${where}.risk factor ${f.id}: needs a label, text and a level (${LEVELS.join(", ")})`);
  }
  return e;
}

/** The fields of a page's text that are set, for merging over generated text. */
function given(t: PageText): Partial<PageText> {
  const out: Json = {};
  for (const k of ["name", "description", "longText", "faqs", "links", "iconUrl"] as const) if (t[k] !== undefined) out[k] = t[k];
  return out;
}

/**
 * The next config: `config` (the chain's current one, unchanged) with everything `input` adds. Throws on any error.
 * `chainId` is the target chain's: on one that is not a development node, every page the Hub adds needs its risk text.
 */
export function planHub(config: Json, input: HubInput, tv: TestValues, chainId: number): HubPlan {
  const c = structuredClone(config) as Json;
  const errors: string[] = [];
  const label = input.hub.label;
  const needRisk = !DEV_CHAIN_IDS.has(chainId);
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
  for (const t of input.tokens ?? []) sym(t.symbol, "tokens");
  // Page text: categories, and the risk text of every market, lend asset and borrowable asset.
  const borrowed = new Set((Object.values(input.borrowable) as string[][]).flat());
  for (const a of input.lendAssets) {
    if (a.category !== undefined && !CATEGORIES.includes(a.category)) errors.push(`lendAssets ${a.symbol}: category must be one of ${CATEGORIES.join(", ")}`);
    errors.push(...riskErrors(`lendAssets ${a.symbol}`, a.risk, needRisk));
  }
  for (const b of input.borrowAssets ?? []) if (!borrowed.has(b.symbol)) errors.push(`borrowAssets ${b.symbol}: no CDP Spoke of this Hub lends it (borrowable)`);
  for (const s of borrowed) errors.push(...riskErrors(`borrowAssets ${s}`, input.borrowAssets?.find((b) => b.symbol === s)?.risk, needRisk));
  for (const m of input.markets) {
    if (m.category !== undefined && !CATEGORIES.includes(m.category)) errors.push(`market ${m.pool}: category must be one of ${CATEGORIES.join(", ")}`);
    errors.push(...riskErrors(`market ${m.name ?? m.pool}`, m.risk, needRisk));
    const bps = tv.markets?.[m.name ?? ""]?.riskFactorBps ?? {};
    for (const id of Object.keys(bps)) if (!m.risk?.factors.some((f) => f.id === id)) errors.push(`test values: market ${m.name} sets riskFactorBps.${id}, which is no factor of its risk text`);
  }
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
    });
  }
  const hubEntry = (c.aavePayload.hubs as Json[]).find((h) => h.label === label)!;
  // The Hub's page: the Hub file's text over what the chain's config has (written once, with the Hub's first market).
  const hubText = { ...given(input.hub), ...(input.hub.disclosures ? { disclosures: input.hub.disclosures } : {}) };
  if (hubEntry.content || Object.keys(hubText).length) {
    const name = input.hub.name ?? hubEntry.content?.name ?? `Avana ${cap(label)} Hub`;
    hubEntry.content = { slug: slugify(name), description: "", faqs: [], ...hubEntry.content, ...hubText, name };
  }
  const hubName = (hubEntry.content?.name as string | undefined) ?? `${label} Hub`;
  const tokenText = (symbol: string) => {
    const t = input.tokens?.find((x) => x.symbol === symbol);
    return { ...(t?.links ? { links: t.links } : {}), ...(t?.iconUrl ? { iconUrl: t.iconUrl } : {}) };
  };
  // Token pages, by symbol: the listing metadata writes one for each token the listing first adds.
  for (const t of input.tokens ?? []) {
    c.listing.tokenContent ??= {};
    c.listing.tokenContent[t.symbol] = { ...c.listing.tokenContent[t.symbol], ...t };
  }
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
      content: { slug: slugify(`${name}-${label}`), venueLabel: VENUE[s.integration], description: `${name} positions on the ${hubName}.`, faqs: [], ...given(s), name },
    });
  }

  // 2. What the Hub lends: an existing debt asset limited to some Hubs gets this one; a new one is sized from input.
  const newDebt: string[] = [];
  const rateKept: { symbol: string; rateModel?: RateModel; liquidityFeeBps?: number }[] = [];
  for (const a of input.lendAssets) {
    const d = (c.aavePayload.debtAssets as Json[]).find((x) => x.symbol === a.symbol);
    const w = (c.world.tokens as Json[]).find((t) => t.symbol === a.symbol)!;
    const wasLent = extend && d !== undefined && (!d.hubs || d.hubs.includes(label));
    if (d) {
      if (d.hubs && !d.hubs.includes(label)) d.hubs.push(label);
      if (d.lendOnly && (Object.values(input.borrowable) as string[][]).some((x) => x.includes(a.symbol))) throw new Error(`${a.symbol} is lend-only on this chain and cannot be borrowed`);
    } else {
      const dao = tv.debtAssets?.[a.symbol];
      if (!dao?.drawCap || !dao.bootstrapSupply || !dao.coverageMinimum || !dao.offsetMinimum) throw new Error(`lendAssets: ${a.symbol} is new to Aave on this chain and test values have no drawCap, bootstrapSupply, coverageMinimum and offsetMinimum for it`);
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
    const dv = tv.debtAssets?.[a.symbol];
    const rateModel = dv?.byHub?.[label]?.rateModel ?? dv?.rateModel;
    const liquidityFeeBps = dv?.byHub?.[label]?.liquidityFeeBps ?? dv?.liquidityFeeBps;
    if (rateModel || liquidityFeeBps !== undefined) {
      const target = (c.aavePayload.debtAssets as Json[]).find((x) => x.symbol === a.symbol)!;
      if (rateModel) (target.rateModelByHub ??= {})[label] = rateModel;
      if (liquidityFeeBps !== undefined) (target.liquidityFeeByHub ??= {})[label] = liquidityFeeBps;
      if (wasLent) rateKept.push({ symbol: a.symbol, ...(rateModel ? { rateModel } : {}), ...(liquidityFeeBps !== undefined ? { liquidityFeeBps } : {}) });
    }
    // A debt asset borrowable on a CDP Spoke needs its listing entry (its DebtOracle) once per chain.
    const borrowed = (Object.values(input.borrowable) as string[][]).some((x) => x.includes(a.symbol));
    if (borrowed && !(c.listing.debtAssets as Json[]).some((x) => x.symbol === a.symbol)) {
      if (dv?.stressRiseBps === undefined || !dv.floorRoundingAllowance) throw new Error(`${a.symbol} has no DebtOracle on this chain and test values have no stressRiseBps and floorRoundingAllowance for it`);
      c.listing.debtAssets.push({
        symbol: a.symbol,
        fixedPrice: false,
        stressRiseBps: dv.stressRiseBps,
        floorRoundingAllowance: dv.floorRoundingAllowance,
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
    input.lendAssets.map((a) => [
      a.symbol,
      {
        slug: slugify(`${label}-${a.symbol}`),
        name: `${a.symbol} on the ${hubName}`,
        description: `Lend ${a.symbol} on Aave V4's ${hubName}.`,
        faqs: [],
        ...tokenText(a.symbol),
        ...given(a),
        symbol: a.symbol,
        category: a.category ?? "crypto",
        ...(a.risk ? { risk: a.risk } : {}),
      },
    ]),
  ));

  // 3. Debt reserves: what each CDP Spoke lends (the first is each market's default debt asset).
  const debtReserves: string[] = [];
  for (const s of input.spokes) {
    for (const a of input.borrowable[s.label] ?? []) {
      debtReserves.push(`${s.label}:${a}`);
      const text = input.borrowAssets?.find((x) => x.symbol === a);
      const spokeName = (c.listing.spokes as Json[]).find((x) => x.label === s.label)!.content.name as string;
      c.listing.debtReserves.push({
        spoke: s.label,
        symbol: a,
        content: {
          name: `${a} on ${spokeName} (${hubName})`,
          description: `Borrow ${a} from Aave V4's ${hubName} against ${VENUE[s.integration]} liquidity positions.`,
          faqs: [{ question: `Where does the ${a} come from?`, answer: `From the ${hubName} of Aave V4, through the ${spokeName} CDP Spoke.` }],
          ...tokenText(a),
          ...(text ? given(text) : {}),
          // One page per Spoke: the slug and name carry the Spoke, whatever the shared text.
          slug: slugify(`${a}-${spokeName}-${label}`),
          symbol: a,
          category: input.lendAssets.find((x) => x.symbol === a)?.category ?? (/USD|DAI|GHO/.test(a) ? "stable" : "crypto"),
          ...(text?.risk ? { risk: text.risk } : {}),
        },
      });
      if (text?.name) c.listing.debtReserves.at(-1).content.name = `${text.name} (${spokeName})`;
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
    const tvals: TokenValues = { ...tv.tokens?.default, ...tv.tokens?.[t.symbol] };
    if (tvals.deviationBps === undefined || tvals.collateralFactorBps === undefined || !tvals.tokenCapUsd) throw new Error(`collateral ${t.symbol}: test values have no deviationBps, collateralFactorBps and tokenCapUsd for it`);
    // The ParameterStore's least agreement tolerance (two routes' deviation plus the margin) plus 50 bps, unless set.
    const tol = 2 * tvals.deviationBps + (c.parameters.globals.feedAgreementMarginBps as number) + 50;
    c.listing.tokens.push({
      symbol: t.symbol,
      isUsdStable: t.isUsdStable ?? false,
      deviationBps: tvals.deviationBps,
      collateralFactorBps: tvals.collateralFactorBps,
      agreementToleranceBps: tvals.agreementToleranceBps ?? tol,
      secondToleranceBps: tvals.secondToleranceBps ?? tol,
      tokenCapUsd: tvals.tokenCapUsd,
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
  const values: Record<string, unknown> = {};
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
    const mv: MarketValues = { ...tv.markets?.default, ...tv.markets?.[name] };
    if (mv.poolRiskFactorBps === undefined || mv.maxLiquidationBonus === undefined || mv.consistencyToleranceBps === undefined || !mv.marketUsdCap || !mv.topUpSliceUsd)
      throw new Error(`market ${name}: test values have no poolRiskFactorBps, maxLiquidationBonus, consistencyToleranceBps, marketUsdCap and topUpSliceUsd for it`);
    // Unless the test values set them: the collateral factor min(token factors) x pool risk factor (SPEC-CF-001), and
    // the largest slippage allowance s with s x minLB <= (1e4 - f)(minLB - 1e4), minLB the smallest bonus (LIQ-I1).
    const cf = mv.collateralFactorBps ?? Math.floor((Math.min(tokenCf(p.a), tokenCf(p.b)) * mv.poolRiskFactorBps) / 1e4);
    const minLb = 10_000 + Math.floor(((mv.maxLiquidationBonus - 10_000) * LIQUIDATION_BONUS_FACTOR) / 10_000);
    values[name] = mv;
    const venue = VENUE[s.integration];
    const fee = slip ? `tick spacing ${p.tickSpacing}` : `${p.fee / 10_000}% fee tier`;
    const bps = mv.riskFactorBps ?? {};
    const risk = mi.risk ? { ...mi.risk, factors: mi.risk.factors.map((x) => (bps[x.id] !== undefined ? { ...x, bps: bps[x.id] } : x)) } : undefined;
    c.listing.markets.push({
      ...template(INTEGRATION_ID[s.integration]),
      name,
      spoke: s.label,
      pool: mi.pool,
      generation: slip ? p.generation : 0,
      tickLower: mi.tickLower ?? 0,
      tickUpper: mi.tickUpper ?? 0,
      collateralFactorBps: cf,
      maxLiquidationBonus: mv.maxLiquidationBonus,
      consistencyToleranceBps: mv.consistencyToleranceBps,
      poolRiskFactorBps: mv.poolRiskFactorBps,
      slippageAllowanceBps: mv.slippageAllowanceBps ?? Math.floor(((10_000 - f) * (minLb - 10_000)) / minLb),
      ...(mv.slippageAllowanceMinBps !== undefined ? { slippageAllowanceMinBps: mv.slippageAllowanceMinBps } : {}),
      ...(mv.collateralRisk !== undefined ? { collateralRisk: mv.collateralRisk } : {}),
      ...(mv.minPledgeUsd ? { minPledgeUsd: mv.minPledgeUsd } : {}),
      ...(mv.stressFloorUsd ? { stressFloorUsd: mv.stressFloorUsd } : {}),
      marketUsdCap: mv.marketUsdCap,
      topUpSliceUsd: mv.topUpSliceUsd,
      routes,
      content: {
        slug: mi.slug ?? slugify(`${venue}-${p.a}-${p.b}-${slip ? `cl${p.tickSpacing}` : String(p.fee)}${range}-${s.label}`),
        category: mi.category ?? (p.a.match(/USD|DAI|GHO/) && p.b.match(/USD|DAI|GHO/) ? "stable" : "crypto"),
        venueLabel: slip ? `${venue} · CL${p.tickSpacing}` : `${venue} · ${p.fee / 10_000} %`,
        description: `Borrow ${lends.join(", ")} from the ${hubName} against a ${mi.tickLower !== undefined ? "concentrated" : "full-range"} ${p.a}/${p.b} liquidity position in the ${venue} pool with ${fee}.`,
        faqs: [{ question: "What can I borrow?", answer: `${lends.join(", ")} from the ${hubName}, against the position's value.` }],
        // A market's `name` is its config name (the test values' key), not its page's.
        ...{ ...given(mi), name: `${p.a}/${p.b} ${venue}${mi.name ? "" : ` (${hubName})`}` },
        ...(risk ? { risk } : {}),
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
      values,
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
                ...(r.rateModel
                  ? {
                      optimalUsageRatio: r.rateModel.optimalUsageBps,
                      baseDrawnRate: r.rateModel.baseDrawnRateBps,
                      rateGrowthBeforeOptimal: r.rateModel.rateGrowthBeforeOptimalBps,
                      rateGrowthAfterOptimal: r.rateModel.rateGrowthAfterOptimalBps,
                    }
                  : {}),
                ...(r.liquidityFeeBps !== undefined ? { liquidityFee: r.liquidityFeeBps } : {}),
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
      const p = planHub(JSON.parse(readFileSync(currentConfig(c), "utf8")), input, testValues(), c.chainId);
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
