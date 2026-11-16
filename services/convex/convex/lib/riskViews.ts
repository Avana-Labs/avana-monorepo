// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Risk parameters, the market risk premium card, liquidation activity and cashflow, each for the scope its page
// owns: a supply market shows supply cap, reserve factor, credit line and coverage (no collateral parameters); a
// debt reserve shows its Spoke's draw cap and price status; a collateral market shows its collateral factor, bonus,
// collateral risk and caps.

import { type HubAssetRow, type HubAssetSpokeRow, type MarketRow, type SpokeReserveRow, MAX_SPOKE_CAP, bpsToPct, capRoom, marketBorrowRateRay, rayToAprPct, spokeHeadroom, tokens, usd } from "@avana/services-common/views";
import { type Values } from "./charts.ts";
import { compactUsd, liquidationBonusBps, pct } from "./format.ts";
import type { Cashflow, LiquidationRisk, PageRisk, RiskAssessment, RiskLevel, RiskParameters } from "./uiTypes.ts";

const PAUSE = ["None", "Frozen", "Paused"] as const;
const PRICE = ["Live", "Drifting", "Cached", "Expired"] as const;
const cap = (whole: string) => (BigInt(whole) === MAX_SPOKE_CAP ? "Unlimited" : Number(whole).toLocaleString("en-US"));
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
  const otherHubs = slices.filter((s) => s.kind === "cdp" && s.homeHub !== asset.hub && !/^0x0{40}$/.test(s.homeHub)).reduce((acc, s) => acc + BigInt(s.owed), 0n);
  const status = (r: { paused: boolean; frozen: boolean }) => (r.paused ? "Paused" : r.frozen ? "Frozen" : "Active");
  const ex = asset.exposure;
  const p = (id: string, label: string, value: string, description?: string) => ({ id, label, value, ...(description ? { description } : {}) });
  return {
    slug,
    kind: "lend",
    parameters: [
      p("depositCapacity", "Deposit capacity", lends.length > 0 ? `${cap(supplyCap)} ${symbol}` : "—", "Most the Lend Spokes accept together on this Hub asset."),
      p("borrowCapacity", "Borrow capacity", ex ? `${tokens(ex.line, asset.decimals).toLocaleString("en-US")} ${symbol}` : "—", "Most the CDP Spokes may draw together: the Hub's credit line for this asset."),
      p("oracle", "Oracle source", "Aave oracle", "Aave V4's price for the asset, read by the Hub and the Spokes."),
      p("supplyCap", "Supply cap", lends.length > 0 ? `${cap(supplyCap)} ${symbol}` : "—", "Most the Lend Spokes accept together on this Hub asset."),
      p("reserveFactor", "Reserve factor", pct(bpsToPct(asset.liquidityFeeBps)), "Share of interest kept by the Hub as fees."),
      p("creditLine", "Credit line", ex ? `${tokens(ex.line, asset.decimals).toLocaleString("en-US")} ${symbol}` : "—", "Most the CDP Spokes may draw together."),
      p("drawCaps", "Draw caps (all CDP Spokes)", `${drawCaps.toLocaleString("en-US")} ${symbol}`),
      p("otherHubDraws", "Drawn by other Hubs", `${tokens(otherHubs, asset.decimals).toLocaleString("en-US")} ${symbol}`, "Owed by CDP Spokes of other Hubs on their credit lines."),
      p("firstLoss", "First-loss reserve", ex ? `${tokens(ex.fundedBalance, asset.decimals).toLocaleString("en-US")} ${symbol}` : "—", "Funded balance of the First-Loss Reserve, used before lenders."),
      p("coverageBound", "Coverage bound", ex ? (ex.coverageBoundHolds ? "Holds" : "Breached") : "—"),
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
      { id: "breaker", label: "Debt breaker", value: reserve.breakerReasons === 0 ? "Clear" : `Tripped (0x${reserve.breakerReasons.toString(16)})` },
      { id: "status", label: "Reserve", value: reserve.paused ? "Paused" : reserve.frozen ? "Frozen" : reserve.borrowable ? "Borrowable" : "Not borrowable" },
      { id: "hubPause", label: "Hub", value: PAUSE[reserve.pauseState] ?? String(reserve.pauseState) },
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

/** Room the market has to borrow now in USD, summed over its debt reserves' borrow speeds (BOR-024). */
export type BorrowRoomUsd = number | null;

export function poolRiskParameters(slug: string, market: MarketRow, headRateRay: string | null, borrowRoomUsd: BorrowRoomUsd = null): RiskParameters {
  const liq = market.liquidation;
  const caps = (market as Partial<MarketRow>).caps;
  const used = caps ? BigInt(caps.marketUsdCap8) - BigInt(market.marketHeadroomUsd8) : null;
  return {
    slug,
    kind: "pool",
    parameters: [
      { id: "collateralFactor", label: "Collateral factor", value: pct(bpsToPct(market.collateralFactorBps)), description: "Aave V4 liquidates below a health factor of 1.00 computed with this factor." },
      { id: "collateralRisk", label: "Collateral risk", value: pct(bpsToPct(market.collateralRiskBps)), description: "Borrowers of this market pay the base rate × (1 + this premium)." },
      ...(caps
        ? [{ id: "depositCapacity", label: "Deposit capacity", value: `${usd8(used !== null && used > 0n ? used.toString() : "0")} / ${usd8(caps.marketUsdCap8)}`, description: "Pledged value counted against the market's USD cap, and the cap." }]
        : []),
      { id: "liquidationPenalty", label: "Liquidation penalty", value: liquidationPenaltyRange(market.maxLiquidationBonusBps, liq?.liquidationBonusFactorBps ?? null), description: "Bonus a liquidator receives, from near a health factor of 1.00 to the max-bonus health factor." },
      ...(borrowRoomUsd !== null ? [{ id: "borrowCapacity", label: "Borrow capacity", value: compactUsd(borrowRoomUsd), description: "What the market's borrowers can draw now, within the market and debt speed limits." }] : []),
      ...(liq ? [{ id: "targetHealthFactor", label: "Target health factor", value: wadHf(liq.targetHealthFactorWad) }] : []),
      ...(caps ? [{ id: "liquidationThreshold", label: "Liquidation threshold", value: pct(bpsToPct(caps.liquidationThresholdBps)) }] : []),
      { id: "oracle", label: "Oracle source", value: `Avana LP oracle ${market.lpOracle.slice(0, 6)}…${market.lpOracle.slice(-4)}`, description: "Prices the vault token from the pool's token feeds and its TWAP." },
      { id: "maxBonus", label: "Max liquidation bonus", value: pct(bpsToPct(liquidationBonusBps(market.maxLiquidationBonusBps))) },
      ...(headRateRay ? [{ id: "borrowRate", label: "Borrow APR (this market)", value: pct(rayToAprPct(marketBorrowRateRay(headRateRay, market.collateralRiskBps))) }] : []),
      ...(caps
        ? [
            { id: "topUpSlice", label: "Top-up slice", value: usd8(caps.topUpSliceUsd8) },
            { id: "liquidationFee", label: "Liquidation fee", value: pct(bpsToPct(caps.liquidationFeeBps)), description: "Share of the bonus kept by the protocol." },
            { id: "hardHealthFloor", label: "Hard health floor", value: BigInt(caps.hardHealthFloorWad) === 0n ? "Off" : wadHf(caps.hardHealthFloorWad) },
          ]
        : []),
      { id: "capHeadroom", label: "Cap headroom", value: compactUsd(Number(BigInt(market.marketHeadroomUsd8)) / 1e8) },
      { id: "price", label: "Vault token price", value: `$${(Number(BigInt(market.acceptedPrice)) / 1e8).toFixed(4)} (${PRICE[market.priceState] ?? market.priceState})` },
      { id: "hubPause", label: "Hub", value: PAUSE[market.pauseState] ?? String(market.pauseState) },
    ],
    updatedAt: Date.now(),
    source: "chain",
  };
}

const level = (bps: number): RiskLevel => (bps < 200 ? "low" : bps < 500 ? "moderate" : bps < 1_000 ? "elevated" : "high");

const LEVEL_RANK: Readonly<Record<RiskLevel, number>> = { low: 0, moderate: 1, elevated: 2, high: 3 };
const worst = (levels: readonly RiskLevel[]): RiskLevel => levels.reduce<RiskLevel>((acc, l) => (LEVEL_RANK[l] > LEVEL_RANK[acc] ? l : acc), "low");

/** The factors of a page's listed risk text as card rows (no basis points: they are rated, not priced). */
const factorRows = (risk: PageRisk) => risk.factors.map((x) => ({ id: x.id, label: x.label, bps: 0, level: x.level, description: x.text }));

/**
 * The risk card of a Lend or Borrow asset page, from the risk text its listing published (metadata version 2). The
 * level is the worst rated factor; without listed risk text the card stays hidden (null).
 */
export function contentRiskAssessment(risk: PageRisk | undefined, headline: string): RiskAssessment | null {
  if (!risk) return null;
  const lvl = worst(risk.factors.map((x) => x.level));
  return { premiumBps: 0, level: lvl, score: LEVEL_RANK[lvl] * 25 + 10, headline, summary: risk.summary, breakdown: factorRows(risk), metrics: [] };
}

/** The pool page's premium card: the market's `collateralRisk`, the one premium every borrower of it pays. */
export function poolRiskAssessment(market: MarketRow, risk?: PageRisk): RiskAssessment {
  const bps = market.collateralRiskBps;
  const listed = risk ? factorRows(risk) : [];
  return {
    premiumBps: bps,
    level: level(bps),
    score: Math.min(100, Math.round(bps / 20)),
    headline: `${pct(bpsToPct(bps))} collateral risk premium`,
    summary: risk?.summary ?? `Every borrower against this market pays the Hub's base rate plus ${pct(bpsToPct(bps))} of it, set by the Aave DAO for this collateral.`,
    breakdown: [{ id: "collateralRisk", label: "Collateral risk", bps, level: level(bps), description: "Aave V4 collateral risk of the market's vault-token reserve." }, ...listed],
    metrics: [
      { id: "cf", label: "Collateral factor", value: pct(bpsToPct(market.collateralFactorBps)) },
      { id: "bonus", label: "Max liquidation bonus", value: pct(bpsToPct(liquidationBonusBps(market.maxLiquidationBonusBps))) },
      { id: "price", label: "Price state", value: PRICE[market.priceState] ?? String(market.priceState) },
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

/**
 * Interest paid over the last 12 months from daily Hub samples: each day's owed amount × that day's drawn rate /
 * 365, valued at that day's price. Lenders receive it less the reserve factor; the Hub keeps the rest. A Spoke's
 * cashflow uses its own owed amount, so the Spokes' cashflows add up to the Hub's.
 */
export function cashflow(days: readonly { t: number; hub: Values; owed?: string }[], decimals: number, liquidityFeeBps: number): Cashflow {
  const monthly = new Map<string, number>();
  let interest = 0;
  for (const d of days) {
    const owed = d.owed ?? d.hub.owed ?? "0";
    const rateApr = rayToAprPct(d.hub.drawnRateRay ?? "0") / 100;
    const value = (usd(owed, decimals, d.hub.priceUsd8 ?? "0") * rateApr) / 365;
    interest += value;
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
