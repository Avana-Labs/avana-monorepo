// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The shapes the web app's screens consume. They are the app's contract: field names, units (float USD, percent
// as 5.2 = 5.2 %, basis points, `YYYY-MM-DD` days, ISO times) and nullability stay as the screens expect.

/** Page kinds: `lend` = a Hub asset, `asset` = one CDP Spoke's debt reserve, `pool` = one collateral market. */
export type PageScope = "lend" | "asset" | "pool";

export type Category = "stable" | "crypto" | "stock";

export interface Visual {
  readonly symbol: string;
  readonly shortLabel: string;
  readonly bgClassName: string;
  readonly textClassName: string;
  readonly iconUrl?: string;
}

/** Editorial content of a page, from its listing metadata. */
export interface PageContent {
  readonly slug: string;
  readonly name: string;
  readonly symbol?: string;
  readonly category?: Category;
  readonly venueLabel?: string;
  readonly iconUrl?: string;
  readonly description: string;
  readonly longText?: string;
  readonly stats: readonly { readonly label: string; readonly value: string; readonly href?: string }[];
  readonly history: readonly { readonly date: string; readonly title: string; readonly description?: string }[];
  readonly faqs: readonly { readonly question: string; readonly answer: string }[];
  readonly visuals?: readonly Visual[];
  readonly resources?: readonly { readonly label: string; readonly href: string }[];
}

/** One row of the market lists and the detail headers (`markets.listMarketSnapshots`). */
export interface MarketSnapshotRow {
  readonly slug: string;
  readonly scope: PageScope;
  readonly name: string;
  readonly symbol: string;
  readonly chainId: number;
  readonly venueLabel?: string;
  readonly category?: Category;
  readonly description?: string;
  readonly iconUrl?: string;
  readonly spokeId?: string;
  /** The Hub of a Lend or Borrow asset row (its address) and the Hub's label: the same token on two Hubs is two rows. */
  readonly hubId?: string;
  readonly hubLabel?: string;
  readonly feeTier?: string;
  readonly maxLtvPct?: number;
  readonly reserveFactorPct?: number;
  readonly rewardsApyPct?: number;
  readonly premiumBps?: number;
  readonly visuals?: readonly Visual[];
  readonly resources?: readonly { readonly label: string; readonly href: string }[];
  readonly suppliedUsd: number;
  readonly borrowedUsd: number;
  readonly availableUsd: number;
  readonly utilizationPct: number;
  readonly supplyApyPct: number;
  readonly borrowAprPct: number;
  readonly tvlUsd: number;
  readonly volumeUsd: number;
  readonly feesUsd: number;
  readonly lpPriceUsd?: number;
}

export interface QuickStat {
  readonly id: string;
  readonly label: string;
  readonly value: string;
  readonly delta: { readonly value: number; readonly direction: "up" | "down" | "flat"; readonly label: string };
}

/** A chart series of daily points (`t` = `YYYY-MM-DD`). */
export interface DaySeries {
  readonly id: string;
  readonly label: string;
  readonly points: readonly { readonly t: string; readonly v: number }[];
}

export type DetailTxKind = "supply" | "withdraw" | "borrow" | "repay" | "liquidation" | "rewards" | "open" | "add" | "reduce" | "close" | "interest" | "rebalance";

export interface DetailTxRow {
  readonly id: string;
  readonly at: string;
  readonly kind: DetailTxKind;
  readonly amountLabel: string;
  readonly amountUsd?: number;
  readonly tokenAmountLabel?: string;
  readonly token0AmountLabel?: string;
  readonly token1AmountLabel?: string;
  readonly tokenSymbol?: string;
  readonly tokenSymbolSecondary?: string;
  readonly walletLabel: string;
  readonly counterpartyLabel?: string;
  readonly txHashShort: string;
  /** The app's row origin flag; rows read from the chain are served as "seed". */
  readonly source: "sandbox" | "seed";
}

export interface InterestRateModel {
  readonly slug: string;
  readonly optimalUtilizationPct: number;
  readonly slopeBelowOptimalPct: number;
  readonly slopeAboveOptimalPct: number;
  readonly baseBorrowRatePct: number;
  readonly utilizationPct: number;
  /** The Hub's base drawn rate; a market's premium is shown on the market, never here. */
  readonly borrowAprPct: number;
  readonly updatedAt: number;
  readonly source: "seed" | "chain";
}

export interface RiskParameters {
  readonly slug: string;
  readonly kind: PageScope;
  readonly parameters: readonly { readonly id: string; readonly label: string; readonly value: string; readonly description?: string }[];
  readonly updatedAt: number;
  readonly source: "seed" | "chain";
}

export type RiskLevel = "low" | "moderate" | "elevated" | "high";

export interface RiskAssessment {
  readonly premiumBps: number;
  readonly level: RiskLevel;
  readonly score: number;
  readonly headline: string;
  readonly summary: string;
  readonly breakdown: readonly { readonly id: string; readonly label: string; readonly bps: number; readonly level: RiskLevel; readonly description: string }[];
  readonly metrics: readonly { readonly id: string; readonly label: string; readonly value: string; readonly hint?: string }[];
}

export interface LiquidationRisk {
  readonly slug: string;
  readonly day: string;
  readonly stats: readonly {
    readonly id: "liquidations" | "collateralSeized" | "debtRepaid" | "collateralAtRisk" | "walletsAtRisk" | "badDebt";
    readonly label: string;
    readonly value: string;
    readonly deltaValue: number;
    readonly deltaLabel: string;
    readonly goodDirection: "down";
    readonly format: "usd" | "number";
  }[];
}

export interface AllocationRow {
  readonly id: string;
  readonly poolSlug: string;
  readonly poolName: string;
  readonly venueLabel: string;
  readonly sharePct: number;
  readonly valueUsd: number;
  readonly utilizationPct: number;
  readonly borrowAprPct: number;
}

export interface PoolBorrowable {
  readonly id: string;
  readonly name: string;
  readonly symbol: string;
  readonly borrowAprPct: number;
  /**
   * "Available to borrow now" (BOR-024): what fits both speed windows, the market's and the (Hub, asset)'s, in whole
   * tokens and USD at the asset's price; null when the Lens refused the read.
   */
  readonly availableNow: number | null;
  readonly availableNowUsd: number | null;
  /** "More from": when the next charges stop counting (ISO time); null when nothing is counting. */
  readonly moreFrom: string | null;
}

export interface Cashflow {
  readonly bars: readonly DaySeries[];
  readonly periodLabel: string;
  readonly rows: readonly { readonly label: string; readonly reported: string; readonly highlighted?: boolean }[];
}

export interface ContractAddressRow {
  readonly slug: string;
  readonly salt: string;
  readonly address: string;
  readonly label: string;
  readonly href: string;
  readonly chain: string;
  readonly isSynthetic: false;
}

export interface ChangelogRow {
  readonly id: string;
  readonly parameter: string;
  readonly previous: string;
  readonly current: string;
  readonly date: string;
  readonly source: string;
  readonly executor: string;
  readonly category: string;
  readonly href?: string;
}

/** USD totals over some Hub assets; utilization is borrowed / supplied of those totals. */
export interface HubTotals {
  readonly suppliedUsd: number;
  readonly borrowedUsd: number;
  readonly availableUsd: number;
  readonly utilizationPct: number;
}

/** One Hub's share of the Lend totals. */
export interface HubBreakdownRow extends HubTotals {
  readonly chainId: number;
  readonly hub: string;
  readonly slug: string;
  readonly label: string;
  /** 1 to 3; 0 for a Hub the registry has not recorded. */
  readonly tier: number;
  readonly lendAssets: number;
}

/** One token's Lend totals over every Hub that lists it, with one row per Hub. */
export interface LendTokenTotals extends HubTotals {
  readonly chainId: number;
  readonly underlying: string;
  readonly symbol: string;
  /** Supply-weighted over its Hubs. */
  readonly supplyApyPct: number;
  readonly hubs: readonly (HubTotals & { readonly hub: string; readonly label: string; readonly slug: string; readonly supplyApyPct: number; readonly borrowAprPct: number })[];
}

/** `markets.getLendTotals`: every Hub asset of every Hub added up, by Hub and by token. */
export interface LendTotals extends HubTotals {
  readonly hubCount: number;
  readonly byHub: readonly HubBreakdownRow[];
  readonly byToken: readonly LendTokenTotals[];
}

/** A Hub-to-Hub credit line: a CDP Spoke of `homeHub` drawing `asset` from `fundingHub`. Base units as decimal strings. */
export interface CreditLineView {
  readonly chainId: number;
  readonly fundingHub: string;
  readonly fundingHubLabel: string;
  readonly homeHub: string;
  readonly homeHubLabel: string;
  readonly spoke: string;
  readonly assetId: string;
  readonly asset: string;
  readonly symbol: string;
  readonly enabled: boolean;
  readonly cap: string;
  readonly owed: string;
  readonly capUsd: number;
  readonly owedUsd: number;
  /** What the Spoke can still draw on the line: min(cap − owed, its draw-cap room, the Hub's liquidity). */
  readonly headroomUsd: number;
  readonly usedPct: number;
  /** Σ caps of every cross-Hub line on the funding Hub's asset. */
  readonly fundingHubTotalCapUsd: number;
  readonly blockNumber: string;
}

/** `hubs.get`: one Hub with its totals, Spokes and credit lines. */
export interface HubSummary extends HubBreakdownRow {
  readonly recorded: boolean;
  readonly applicationState: number | null;
  readonly assetCount: number;
  readonly lendSpokes: readonly string[];
  readonly cdpSpokes: readonly string[];
  /** Lines this Hub funds: CDP Spokes of other Hubs drawing on its assets. */
  readonly fundsLines: readonly CreditLineView[];
  /** Lines this Hub's CDP Spokes draw on at other Hubs. */
  readonly drawsOnLines: readonly CreditLineView[];
  readonly blockNumber: string;
}
