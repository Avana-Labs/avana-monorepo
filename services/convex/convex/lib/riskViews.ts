// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Risk parameters, the market risk premium card, liquidation activity and cashflow, each for the scope its page
// owns: a supply market shows supply cap, reserve factor and draw-cap coverage (no collateral parameters); a
// debt reserve shows its Spoke's draw cap and price status; a collateral market shows its collateral factor, bonus,
// collateral risk and caps.

import { type HubAssetRow, type HubAssetSpokeRow, type MarketRow, type SpokeReserveRow, MAX_SPOKE_CAP, bpsToPct, capRoom, marketBorrowRateRay, rayToApyPct, rayToAprPct, spokeHeadroom, tokens, usd } from "@avana/services-common/views";
import { type Values } from "./charts.ts";
import { compactUsd, liquidationBonusBps, pct } from "./format.ts";
import type { Cashflow, LiquidationRisk, PageRisk, RiskAssessment, RiskLevel, RiskParameters } from "./uiTypes.ts";

/** The vault-token reserve's state on its Spoke: a depegged Stable or Correlated market is frozen (depeg = freeze). */
const reserveState = (m: Pick<MarketRow, "paused" | "frozen">) => (m.paused ? "Paused" : m.frozen ? "Frozen" : "Open");
const priceLabel = (m: Pick<MarketRow, "priceAvailable">) => (m.priceAvailable ? "Live" : "Unpriced");
const cap = (whole: string) => (BigInt(whole) === MAX_SPOKE_CAP ? "Unlimited" : Number(whole).toLocaleString("en-US"));
/** The registry counts an unbounded draw cap as 2^128 whole tokens in a draw-cap sum. */
const capSum = (whole: string) => (BigInt(whole) >= 2n ** 128n ? "Unlimited" : Number(whole).toLocaleString("en-US"));
const usd8 = (v: string) => compactUsd(Number(BigInt(v)) / 1e8);
const wadHf = (v: string) => (Number(BigInt(v)) / 1e18).toFixed(2);

/**
 * The detail pages' Risk Parameters grid has eight slots with these ids on every page type. Each page fills the slots
 * that mean something for its scope and leaves the rest out (the app shows "—"); its own extra rows follow the slots.
 */
export const RISK_SLOTS = ["collateralFactor", "collateralRisk", "depositCapacity", "liquidationPenalty", "borrowCapacity", "targetHealthFactor", "liquidationThreshold", "oracle"] as const;
export type RiskSlot = (typeof RISK_SLOTS)[number];

export function lendRiskParameters(slug: string, asset: HubAssetRow, slices: readonly HubAssetSpokeRow[], symbol: string): RiskParameters {
  // A Hub asset may have several Lend Spokes: the supply cap is theirs together, unlimited if any one is.
  const lends = slices.filter((s) => s.kind === "lend");
  const supplyCap = lends.some((s) => BigInt(s.addCap) === MAX_SPOKE_CAP) ? MAX_SPOKE_CAP.toString() : lends.reduce((acc, s) => acc + BigInt(s.addCap), 0n).toString();
  const drawCaps = slices.filter((s) => s.kind === "cdp").reduce((acc, s) => acc + BigInt(s.drawCap), 0n);
  const status = (r: { paused: boolean; frozen: boolean }) => (r.paused ? "Paused" : r.frozen ? "Frozen" : "Active");
  const ex = asset.exposure;
  const p = (id: string, label: string, value: string, description?: string) => ({ id, label, value, ...(description ? { description } : {}) });
  return {
    slug,
    kind: "lend",
    parameters: [
      p("depositCapacity", "Deposit capacity", lends.length > 0 ? `${cap(supplyCap)} ${symbol}` : "—", "Most the Lend Spokes accept together on this Hub asset."),
      p("borrowCapacity", "Borrow capacity", ex ? `${capSum(ex.drawCapSum)} ${symbol}` : "—", "Most the CDP Spokes may draw together: the sum of their draw caps on this Hub asset."),
      p("oracle", "Oracle source", "Aave oracle", "Aave V4's price for the asset, read by the Hub and the Spokes."),
      p("supplyCap", "Supply cap", lends.length > 0 ? `${cap(supplyCap)} ${symbol}` : "—", "Most the Lend Spokes accept together on this Hub asset."),
      p("reserveFactor", "Reserve factor", pct(bpsToPct(asset.liquidityFeeBps)), "Share of interest kept by the Hub as fees."),
      p("drawCaps", "Draw caps (all CDP Spokes)", `${drawCaps.toLocaleString("en-US")} ${symbol}`),
      p("firstLoss", "First-loss reserve", ex ? `${tokens(ex.fundedBalance, asset.decimals).toLocaleString("en-US")} ${symbol}` : "—", "Funded balance of the First-Loss Reserve, used before lenders."),
      p("coverageRequired", "Coverage required", ex ? `${tokens(ex.required, asset.decimals).toLocaleString("en-US")} ${symbol}` : "—", "First-loss balance the CDP Spokes' draw caps require at the coverage ratio."),
      p("coverageBound", "Coverage bound", ex ? (ex.coverageBoundHolds ? "Holds" : "Breached") : "—", "Holds while the First-Loss Reserve's balance covers the required amount; borrowing the asset stops otherwise."),
      p("status", asset.lendReserves.length > 1 ? "Lend reserves" : "Lend reserve", asset.lendReserves.map(status).join(", ")),
    ],
    updatedAt: asset.timestamp * 1000,
    source: "chain",
  };
}

export function assetRiskParameters(slug: string, reserve: SpokeReserveRow, slice: HubAssetSpokeRow, asset: HubAssetRow, symbol: string): RiskParameters {
  const room = capRoom(slice, asset.decimals);
  const capWhole = BigInt(slice.drawCap);
  const used = capWhole === MAX_SPOKE_CAP || capWhole === 0n ? null : Number(((BigInt(slice.owed) + BigInt(slice.deficit)) * 10_000n) / (capWhole * 10n ** BigInt(asset.decimals))) / 100;
  return {
    slug,
    kind: "asset",
    parameters: [
      { id: "borrowCapacity", label: "Borrow capacity", value: `${cap(slice.drawCap)} ${symbol}`, description: "This Spoke's draw cap on the Hub asset." },
      { id: "oracle", label: "Oracle source", value: reserve.fixedPrice ? "Fixed price" : "Aave oracle", description: "Price of the debt asset used in health factors." },
      { id: "drawCap", label: "Draw cap (this Spoke)", value: `${cap(slice.drawCap)} ${symbol}` },
      { id: "capUsed", label: "Cap used", value: used === null ? "—" : pct(used), description: "Owed plus reported deficit over the draw cap." },
      { id: "headroom", label: "Available to borrow", value: `${tokens(spokeHeadroom(slice, asset), asset.decimals).toLocaleString("en-US")} ${symbol}`, description: "The smaller of the cap room and the Hub's liquidity." },
      { id: "capRoom", label: "Cap room", value: room === null ? "Unlimited" : `${tokens(room, asset.decimals).toLocaleString("en-US")} ${symbol}` },
      { id: "deficit", label: "Reported deficit", value: `${tokens(slice.deficit, asset.decimals).toLocaleString("en-US")} ${symbol}` },
      { id: "debtPrice", label: "Debt price", value: reserve.fixedPrice ? "Fixed" : `$${(Number(BigInt(reserve.debtPrice)) / 1e8).toFixed(4)}` },
      { id: "status", label: "Reserve", value: reserve.paused ? "Paused" : reserve.frozen ? "Frozen" : reserve.borrowable ? "Borrowable" : "Not borrowable" },
    ],
    updatedAt: Date.now(),
    source: "chain",
  };
}

/**
 * Liquidation bonus range from Aave V4's 10,000-based `maxLiquidationBonus`: the bonus scales from
 * `(maxBonus − 100 %) × bonusFactor` near HF 1 to `maxBonus − 100 %` at the max-bonus HF.
 */
export function liquidationPenaltyRange(maxLiquidationBonus: number, bonusFactorBps: number | null): string {
  const max = liquidationBonusBps(maxLiquidationBonus);
  if (bonusFactorBps === null) return pct(bpsToPct(max));
  const min = Math.floor((max * bonusFactorBps) / 10_000);
  return min === max ? pct(bpsToPct(max)) : `${pct(bpsToPct(min))} – ${pct(bpsToPct(max))}`;
}

/** Room the market has to borrow now in USD; null when not measured. */
export type BorrowRoomUsd = number | null;

export function poolRiskParameters(slug: string, market: MarketRow, headRateRay: string | null, borrowRoomUsd: BorrowRoomUsd = null): RiskParameters {
  const liq = market.liquidation;
  const band = market.kind === "full-range" ? "Full range" : `Custom range, ticks ${market.bandLower} to ${market.bandUpper}`;
  return {
    slug,
    kind: "pool",
    parameters: [
      { id: "collateralFactor", label: "Collateral factor", value: pct(bpsToPct(market.collateralFactorBps)), description: "Aave V4 liquidates below a health factor of 1.00 computed with this factor." },
      { id: "collateralRisk", label: "Collateral risk", value: pct(bpsToPct(market.collateralRiskBps)), description: "Borrowers of this market pay the base rate × (1 + this premium)." },
      { id: "range", label: "Market", value: band, description: "Each pool has a Full range and a Custom range market; a position goes to the one whose band it fits, and a band is fixed for life." },
      { id: "ltv", label: "LTV", value: pct(bpsToPct(market.ltvBps)), description: "The same for both markets of the pool." },
      { id: "liquidationPenalty", label: "Liquidation penalty", value: liquidationPenaltyRange(market.maxLiquidationBonusBps, liq?.liquidationBonusFactorBps ?? null), description: "Bonus a liquidator receives, from near a health factor of 1.00 to the max-bonus health factor." },
      ...(borrowRoomUsd !== null ? [{ id: "borrowCapacity", label: "Borrow capacity", value: compactUsd(borrowRoomUsd), description: "What the market's borrowers can draw now, within the market and debt speed limits." }] : []),
      ...(liq ? [{ id: "targetHealthFactor", label: "Target health factor", value: wadHf(liq.targetHealthFactorWad) }] : []),
      // Aave V4 liquidates below health factor 1 computed with the collateral factor: it is the liquidation threshold.
      { id: "liquidationThreshold", label: "Liquidation threshold", value: pct(bpsToPct(market.collateralFactorBps)) },
      { id: "oracle", label: "Oracle source", value: `Avana LP oracle ${market.lpOracle.slice(0, 6)}…${market.lpOracle.slice(-4)}`, description: "Prices the vault token from the pool tokens' Chainlink feeds at the floor of its band." },
      { id: "maxBonus", label: "Max liquidation bonus", value: pct(bpsToPct(liquidationBonusBps(market.maxLiquidationBonusBps))) },
      ...(headRateRay ? [{ id: "borrowRate", label: "Borrow APR (this market)", value: pct(rayToAprPct(marketBorrowRateRay(headRateRay, market.collateralRiskBps))) }] : []),
      { id: "liquidationFee", label: "Liquidation fee", value: pct(bpsToPct(market.liquidationFeeBps)), description: "Share of the bonus kept by the protocol." },
      { id: "price", label: "Vault token price", value: `$${(Number(BigInt(market.acceptedPrice)) / 1e8).toFixed(4)} (${priceLabel(market)})` },
      { id: "reserve", label: "Market state", value: reserveState(market), description: "A Stable or Correlated market that depegs by more than 1 % is frozen." },
    ],
    updatedAt: Date.now(),
    source: "chain",
  };
}

const level = (bps: number): RiskLevel => (bps < 200 ? "low" : bps < 500 ? "moderate" : bps < 1_000 ? "elevated" : "high");

const LEVEL_RANK: Readonly<Record<RiskLevel, number>> = { low: 0, moderate: 1, elevated: 2, high: 3 };
const worst = (levels: readonly RiskLevel[]): RiskLevel => levels.reduce<RiskLevel>((acc, l) => (LEVEL_RANK[l] > LEVEL_RANK[acc] ? l : acc), "low");

/** The factors of a page's listed risk text as card rows, with the share of the premium the listing gives each (else 0). */
const factorRows = (risk: PageRisk) => risk.factors.map((x) => ({ id: x.id, label: x.label, bps: x.bps ?? 0, level: x.level, description: x.text }));

/**
 * The risk card of a Lend or Borrow asset page, from the risk text its listing published (metadata version 2). The
 * level is the worst rated factor; without listed risk text the card stays hidden (null).
 */
export function contentRiskAssessment(risk: PageRisk | undefined, headline: string): RiskAssessment | null {
  if (!risk) return null;
  const lvl = worst(risk.factors.map((x) => x.level));
  return { premiumBps: 0, level: lvl, score: LEVEL_RANK[lvl] * 25 + 10, headline, summary: risk.summary, breakdown: factorRows(risk), metrics: [] };
}

/**
 * The collateral premiums a Borrow asset's borrowers pay: the `collateralRisk` of every market whose CDP Spoke lists the
 * asset as borrowable on the same Hub. Null when no market can borrow it.
 */
export function debtPremiumRange(
  reserve: { chainId: number; hub: string; assetId: string },
  reserves: readonly SpokeReserveRow[],
  markets: readonly MarketRow[],
): { min: number; max: number } | null {
  const spokes = new Set(
    reserves.filter((r) => r.chainId === reserve.chainId && r.hub === reserve.hub && r.assetId === reserve.assetId && r.borrowable).map((r) => r.spoke),
  );
  const bps = markets.filter((m) => m.chainId === reserve.chainId && spokes.has(m.spoke)).map((m) => m.collateralRiskBps);
  return bps.length > 0 ? { min: Math.min(...bps), max: Math.max(...bps) } : null;
}

const pctRange = (r: { min: number; max: number }) => (r.min === r.max ? pct(bpsToPct(r.min)) : `${pct(bpsToPct(r.min))}–${pct(bpsToPct(r.max))}`);

/** A Borrow asset page's premium card: the premiums of the markets that can borrow it, one value when they all match. */
export function debtRiskAssessment(range: { min: number; max: number }, symbol: string, risk?: PageRisk): RiskAssessment {
  const lvl = level(range.max);
  return {
    premiumBps: range.min,
    ...(range.max !== range.min ? { premiumMaxBps: range.max } : {}),
    premiumBasis: "baseRate",
    level: lvl,
    score: Math.min(100, Math.round(range.max / 20)),
    headline: `${pctRange(range)} collateral risk premium`,
    summary: risk?.summary ?? `Borrowers of ${symbol} pay the Hub's base rate plus their collateral's premium (${pctRange(range)}), set by the Aave DAO for each collateral.`,
    breakdown: [
      { id: "collateralRisk", label: "Collateral risk (% of base rate)", bps: range.max, level: lvl, description: "Aave V4 collateral risk of the markets that can borrow this asset: a borrower pays the base rate × (1 + their collateral's premium)." },
      ...(risk ? factorRows(risk) : []),
    ],
    metrics: [],
  };
}

/**
 * The part of a Lend asset's supply rate paid by borrowers' collateral premiums, as an APY in basis points:
 * drawnRate × premium × (10⁴ − liquidityFee) / (added × 10⁴), the supply rate less its drawn-only part.
 */
export function lendPremiumYieldBps(a: Pick<HubAssetRow, "drawnRateRay" | "premium" | "added" | "liquidityFeeBps">): number {
  const added = BigInt(a.added);
  if (added === 0n) return 0;
  const rate = (BigInt(a.drawnRateRay) * BigInt(a.premium) * (10_000n - BigInt(a.liquidityFeeBps))) / (added * 10_000n);
  return Math.round(rayToApyPct(rate) * 100);
}

/** A Lend asset page's premium card: the yield lenders earn above the base rate from borrowers' collateral premiums. */
export function lendRiskAssessment(a: Pick<HubAssetRow, "drawnRateRay" | "premium" | "added" | "liquidityFeeBps">, symbol: string, risk?: PageRisk): RiskAssessment {
  const bps = lendPremiumYieldBps(a);
  const listed = risk ? factorRows(risk) : [];
  const lvl = listed.length > 0 ? worst(listed.map((x) => x.level)) : level(bps);
  return {
    premiumBps: bps,
    level: lvl,
    score: LEVEL_RANK[lvl] * 25 + 10,
    headline: `${pct(bpsToPct(bps))} premium yield`,
    summary: risk?.summary ?? `${symbol} lenders earn ${pct(bpsToPct(bps))} a year above the base rate from the premiums borrowers pay for their collateral.`,
    breakdown: [{ id: "premiumYield", label: "Premium yield", bps, level: level(bps), description: "The part of the supply APY paid by borrowers' collateral premiums." }, ...listed],
    metrics: [],
  };
}

/**
 * What a collateral premium costs a borrower: the base rate × (1 + premium), so the extra APY points are the base rate ×
 * premium (with today's base rate when known).
 */
export function collateralRiskDescription(bps: number, baseRateRay?: string | null): string {
  const factor = `×${(1 + bps / 10_000).toFixed(2)}`;
  if (!baseRateRay) return `Aave V4 collateral risk of the market's vault-token reserve: borrowers pay the base rate ${factor}.`;
  const basePct = rayToAprPct(baseRateRay);
  const extra = rayToAprPct(marketBorrowRateRay(baseRateRay, bps)) - basePct;
  return `Aave V4 collateral risk of the market's vault-token reserve: borrowers pay the base rate ${factor}, ${extra.toFixed(2)} extra APR points at today's ${pct(basePct)} base rate.`;
}

/** The pool page's premium card: the market's `collateralRisk`, the one premium every borrower of it pays. */
export function poolRiskAssessment(market: MarketRow, risk?: PageRisk, baseRateRay?: string | null): RiskAssessment {
  const bps = market.collateralRiskBps;
  const listed = risk ? factorRows(risk) : [];
  // When the listing splits the premium over its factors, the factors are the breakdown; else the premium is one row.
  const split = risk?.factors.some((x) => x.bps !== undefined) ?? false;
  const premiumRow = { id: "collateralRisk", label: "Collateral risk (% of base rate)", bps, level: level(bps), description: collateralRiskDescription(bps, baseRateRay) };
  return {
    premiumBps: bps,
    premiumBasis: "baseRate",
    level: level(bps),
    score: Math.min(100, Math.round(bps / 20)),
    headline: `${pct(bpsToPct(bps))} collateral risk premium`,
    summary: risk?.summary ?? `Every borrower against this market pays the Hub's base rate plus ${pct(bpsToPct(bps))} of it, set by the Aave DAO for this collateral.`,
    breakdown: split ? listed : [premiumRow, ...listed],
    metrics: [
      { id: "cf", label: "Collateral factor", value: pct(bpsToPct(market.collateralFactorBps)) },
      { id: "bonus", label: "Max liquidation bonus", value: pct(bpsToPct(liquidationBonusBps(market.maxLiquidationBonusBps))) },
      { id: "price", label: "Price state", value: priceLabel(market) },
    ],
  };
}

export interface LiquidationWindow {
  readonly liquidations: number;
  readonly collateralSeizedUsd: number;
  readonly debtRepaidUsd: number;
  readonly badDebtUsd: number;
}

export interface AtRisk {
  readonly collateralAtRiskUsd: number;
  readonly walletsAtRisk: number;
}

/** Health factor of an account from its sampled collateral and debt value: collateral × CF / debt. */
export function sampledHealthFactor(collateralUsd8: bigint, debtUsd8: bigint, collateralFactorBps: number): number | null {
  if (debtUsd8 === 0n) return null;
  return Number((collateralUsd8 * BigInt(collateralFactorBps) * 10_000n) / (debtUsd8 * 10_000n)) / 10_000;
}

/** Accounts below the 1.10 band at the last daily sample. */
export function atRisk(positions: readonly { collateralUsd8: string; debtUsd8: string }[], collateralFactorBps: number, band = 1.1): AtRisk {
  let collateralAtRiskUsd = 0;
  let walletsAtRisk = 0;
  for (const p of positions) {
    const hf = sampledHealthFactor(BigInt(p.collateralUsd8), BigInt(p.debtUsd8), collateralFactorBps);
    if (hf !== null && hf < band) {
      walletsAtRisk += 1;
      collateralAtRiskUsd += Number(BigInt(p.collateralUsd8)) / 1e8;
    }
  }
  return { collateralAtRiskUsd, walletsAtRisk };
}

export function liquidationRisk(slug: string, day: string, last: LiquidationWindow & AtRisk, prior: LiquidationWindow & AtRisk): LiquidationRisk {
  const stat = (id: LiquidationRisk["stats"][number]["id"], label: string, curr: number, prev: number, format: "usd" | "number") => {
    const d = curr - prev;
    return { id, label, value: format === "usd" ? compactUsd(curr) : String(curr), deltaValue: d, deltaLabel: format === "usd" ? compactUsd(Math.abs(d)) : String(Math.abs(d)), goodDirection: "down" as const, format };
  };
  return {
    slug,
    day,
    stats: [
      stat("liquidations", "Liquidations (24h)", last.liquidations, prior.liquidations, "number"),
      stat("collateralSeized", "Collateral seized (24h)", last.collateralSeizedUsd, prior.collateralSeizedUsd, "usd"),
      stat("debtRepaid", "Debt repaid (24h)", last.debtRepaidUsd, prior.debtRepaidUsd, "usd"),
      stat("collateralAtRisk", "Collateral at risk", last.collateralAtRiskUsd, prior.collateralAtRiskUsd, "usd"),
      stat("walletsAtRisk", "Wallets at risk", last.walletsAtRisk, prior.walletsAtRisk, "number"),
      stat("badDebt", "Bad debt", last.badDebtUsd, prior.badDebtUsd, "usd"),
    ],
  };
}

/** Days the cashflow rows total. */
export const CASHFLOW_ROW_DAYS = 90;

/**
 * Interest paid from daily Hub samples: each day's owed amount × that day's drawn rate / 365, valued at that day's
 * price. Lenders receive it less the reserve factor; the Hub keeps the rest. A Spoke's cashflow uses its own owed
 * amount, so the Spokes' cashflows add up to the Hub's. The bars cover every day given (12 months); the rows are the
 * last 90 days, the period the card's 1D / 30D / 90D columns are scaled from.
 */
export function cashflow(days: readonly { t: number; hub: Values; owed?: string }[], decimals: number, liquidityFeeBps: number): Cashflow {
  const monthly = new Map<string, number>();
  const rowsFrom = (days.at(-1)?.t ?? 0) - CASHFLOW_ROW_DAYS * 86_400;
  let interest = 0;
  for (const d of days) {
    const owed = d.owed ?? d.hub.owed ?? "0";
    const rateApr = rayToAprPct(d.hub.drawnRateRay ?? "0") / 100;
    const value = (usd(owed, decimals, d.hub.priceUsd8 ?? "0") * rateApr) / 365;
    if (d.t > rowsFrom) interest += value;
    const month = new Date(d.t * 1000).toISOString().slice(0, 7) + "-01";
    monthly.set(month, (monthly.get(month) ?? 0) + value);
  }
  const fee = liquidityFeeBps / 10_000;
  const months = [...monthly.keys()].sort();
  return {
    bars: [
      { id: "interest", label: "Interest", points: months.map((t) => ({ t, v: monthly.get(t)! })) },
      { id: "rewards", label: "Rewards", points: months.map((t) => ({ t, v: 0 })) },
    ],
    periodLabel: "Last 12 months",
    rows: [
      { label: "Interest paid by borrowers", reported: compactUsd(interest) },
      { label: "Net to suppliers", reported: compactUsd(interest * (1 - fee)), highlighted: true },
      { label: "Reserve (to the Hub)", reported: compactUsd(interest * fee) },
    ],
  };
}
