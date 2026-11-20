// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The rows of one chain snapshot, by scope. A chain has several Hubs, each with its Lend and CDP Spokes, and every row
// names its Hub. Each number has one owner: Hub totals live only in `HubAssetRow`, a Spoke's draw on an asset only in
// `HubAssetSpokeRow`, a CDP reserve's own flags only in `SpokeReserveRow`, a collateral market's figures only in
// `MarketRow`. Every row of one snapshot is read at the same block, so the identities of the scope model hold exactly
// between them. Integers are decimal strings in base units; rates are RAY per year; prices are USD with 8 decimals.

import type { DecimalString } from "../export.ts";

export type Address = `0x${string}`;

/** One collateral market of the deployment, as the release manifest records it. */
export interface DeploymentMarket {
  readonly marketId: bigint;
  readonly integrationId: number;
  /** The RiskModule of the market's integration. */
  readonly riskModule: Address;
  readonly kind: MarketKind;
  readonly name: string;
  /** The bytes32 pool key (a v3/Slipstream pool address left-padded, or a v4 PoolId). */
  readonly pool: `0x${string}`;
  readonly spoke: Address;
  readonly hub: Address;
  readonly vaultToken: Address;
  readonly lpOracle: Address;
  readonly reserveId: bigint;
  readonly tokens: readonly Address[];
}

/** Each pool has two markets: Full range (exact full-range ticks) and Custom range (positions inside the band). */
export type MarketKind = "full-range" | "custom-range";

/**
 * The addresses one chain's snapshot reads, taken from the verified release manifest (`chainDeploymentOf`). Hubs,
 * CDP Spokes, markets and debt reserves are the manifest's; Lend Spokes on a Hub none of the manifest's supplies are
 * found on chain.
 */
export interface ChainDeployment {
  readonly chainId: number;
  /** The manifest's Hubs with the label the app shows and their risk tier. */
  readonly hubs: readonly { readonly address: Address; readonly label: string; readonly tier: number }[];
  /** The manifest's Lend Spokes: Aave standard Spokes, supply only; their reserves are the lend assets. */
  readonly lendSpokes: readonly Address[];
  /** The manifest's CDP Spokes with their home Hub (the Hub their markets' vault tokens are listed on). */
  readonly cdpSpokes: readonly { readonly address: Address; readonly hub: Address }[];
  /** Every First-Loss Reserve with the (Hub, asset) it covers. */
  readonly firstLossReserves: readonly { readonly address: Address; readonly asset: Address; readonly hub: Address }[];
  /** The Aave DAO's deficit offset behind each First-Loss Reserve. */
  readonly deficitOffsets: readonly { readonly address: Address; readonly asset: Address; readonly hub: Address }[];
  /** One RiskModule per integration; the draw-cap coverage of a (Hub, asset) is the sum over them. */
  readonly riskModules: readonly Address[];
  readonly markets: readonly DeploymentMarket[];
  /** Every CDP debt reserve the RiskModules registered; GHO's price source is fixed. */
  readonly debtReserves: readonly { readonly spoke: Address; readonly reserveId: bigint; readonly fixedPrice: boolean }[];
}

/**
 * What a Spoke is to one Hub asset. Only CDP Spokes draw; the others have `drawCap = 0` (REQ-HUB-015). A
 * `deficitOffset` is the asset's DAO deficit offset: a Spoke whose `FIRST_LOSS_LAYER()` is the asset's First-Loss Reserve,
 * the second loss layer behind it (REQ-FLR-046).
 */
export type SpokeKind = "lend" | "cdp" | "coverage" | "feeReceiver" | "other" | "deficitOffset";

export interface RateCurve {
  readonly optimalUsageBps: number;
  readonly baseDrawnRateBps: number;
  readonly rateGrowthBeforeOptimalBps: number;
  readonly rateGrowthAfterOptimalBps: number;
}

/** One Lend Spoke's reserve of a Hub asset. */
export interface LendReserve {
  readonly spoke: Address;
  readonly reserveId: DecimalString;
  readonly paused: boolean;
  readonly frozen: boolean;
}

/** One asset of one Hub, the scope of the Lend page and of the Hub block of every Borrow asset page. */
export interface HubAssetRow {
  readonly chainId: number;
  readonly hub: Address;
  readonly assetId: DecimalString;
  readonly underlying: Address;
  readonly decimals: number;
  /** The Lend Spoke's oracle price of the asset, USD with 8 decimals: the one price every page uses. */
  readonly priceUsd8: DecimalString;
  readonly added: DecimalString;
  readonly addedShares: DecimalString;
  readonly drawn: DecimalString;
  readonly premium: DecimalString;
  /** drawn + premium: what "borrowed" means on every page. */
  readonly owed: DecimalString;
  /** The Hub's liquidity: what lenders can withdraw and borrowers can draw (never added − owed). */
  readonly liquidity: DecimalString;
  /** ⌈deficitRay / RAY⌉. */
  readonly deficit: DecimalString;
  readonly accruedFees: DecimalString;
  readonly drawnIndexRay: DecimalString;
  readonly drawnRateRay: DecimalString;
  readonly supplyRateRay: DecimalString;
  readonly utilizationBps: number;
  readonly liquidityFeeBps: number;
  readonly feeReceiver: Address;
  readonly rateCurve: RateCurve | null;
  /** The Lend Spoke reserve whose oracle prices the asset: the first of `lendReserves`. */
  readonly lend: LendReserve;
  /** Every Lend Spoke reserve on this Hub asset, the manifest's Lend Spokes first. */
  readonly lendReserves: readonly LendReserve[];
  /** The asset's loss layers and draw-cap coverage; null when no First-Loss Reserve covers it. */
  readonly exposure: {
    readonly firstLossReserve: Address;
    /** `FirstLossReserve.fundedBalance()`, base units. */
    readonly fundedBalance: DecimalString;
    /** Σ over the RiskModules of `coverage(hub, asset).drawCapSum`: the CDP Spokes' draw caps, whole tokens. */
    readonly drawCapSum: DecimalString;
    /** Σ over the RiskModules of `coverage(hub, asset).required`, base units. */
    readonly required: DecimalString;
    /** required ≤ fundedBalance; borrowing the asset stops (`CoverageBelowRatio`) when it does not hold. */
    readonly coverageBoundHolds: boolean;
    /** The Hub's deficit beyond both loss layers: max(0, deficit − fundedBalance − offsetFunded). */
    readonly uncovered: DecimalString;
    /** The DAO deficit offset of the pair; the zero address when none is listed. */
    readonly deficitOffset: Address;
    /** Added assets of the deficit offset: the second loss layer. */
    readonly offsetFunded: DecimalString;
  } | null;
  readonly blockNumber: DecimalString;
  readonly timestamp: number;
}

/** One Spoke's slice of one Hub asset. */
export interface HubAssetSpokeRow {
  readonly chainId: number;
  readonly hub: Address;
  readonly assetId: DecimalString;
  readonly spoke: Address;
  readonly kind: SpokeKind;
  /** The CDP Spoke's home Hub from the manifest; the zero address for a Spoke that is not a CDP Spoke. */
  readonly homeHub: Address;
  readonly added: DecimalString;
  readonly addedShares: DecimalString;
  /** `getSpokeTotalOwed`: drawn + premium of this Spoke. */
  readonly owed: DecimalString;
  readonly drawnShares: DecimalString;
  readonly premiumShares: DecimalString;
  readonly deficit: DecimalString;
  /** Whole tokens, as the Hub stores them; `MAX_SPOKE_CAP` means unlimited. */
  readonly addCap: DecimalString;
  readonly drawCap: DecimalString;
  readonly active: boolean;
  readonly halted: boolean;
  readonly blockNumber: DecimalString;
}

/** One enabled debt reserve of one CDP Spoke. Hub totals are not copied here; join the `HubAssetRow`. */
export interface SpokeReserveRow {
  readonly chainId: number;
  readonly spoke: Address;
  readonly reserveId: DecimalString;
  readonly hub: Address;
  readonly assetId: DecimalString;
  readonly asset: Address;
  readonly decimals: number;
  /** The CDP Spoke's served debt price (the asset's Chainlink feed, or the fixed GHO source); shown as debt-price status only. */
  readonly debtPrice: DecimalString;
  readonly fixedPrice: boolean;
  readonly paused: boolean;
  readonly frozen: boolean;
  readonly borrowable: boolean;
  readonly blockNumber: DecimalString;
}

/** One debt reserve a market can borrow: the market's own borrow rate. */
export interface MarketBorrowRow {
  readonly reserveId: DecimalString;
  /** `⌈drawnRate × (10⁴ + collateralRiskBps) / 10⁴⌉`, RAY per year. */
  readonly borrowRateRay: DecimalString;
}

/**
 * One collateral market: one of a pool's two markets (Full range or Custom range) on one CDP Spoke. Its band is fixed
 * for life; both markets of a pool have the same LTV. A market whose price leaves a stable or correlated peg is frozen
 * on its Spoke (depeg = freeze): `frozen` is the Spoke reserve's flag.
 */
export interface MarketRow {
  readonly chainId: number;
  readonly marketId: DecimalString;
  readonly kind: MarketKind;
  /** `RiskModule.getMarket(marketId).active`: listed and activated. */
  readonly active: boolean;
  readonly pool: `0x${string}`;
  readonly tokens: readonly Address[];
  readonly tokenDecimals: readonly number[];
  readonly bandLower: number;
  readonly bandUpper: number;
  readonly integrationId: number;
  readonly vaultToken: Address;
  /** Decimals of the vault token, from the Hub asset it is listed as. */
  readonly vaultDecimals: number;
  readonly unitDecimals: number;
  readonly name: string;
  readonly symbol: string;
  readonly lpOracle: Address;
  readonly hub: Address;
  readonly spoke: Address;
  readonly reserveId: DecimalString;
  readonly hubAssetId: DecimalString;
  /** `LPOracle.latestAnswer()`, USD with 8 decimals per whole vault token; "0" when the oracle refuses to price. */
  readonly acceptedPrice: DecimalString;
  /** False when `latestAnswer` reverted (a stale or invalid feed leg): the Spoke cannot price the collateral. */
  readonly priceAvailable: boolean;
  readonly suppliedUnits: DecimalString;
  readonly suppliedUsd8: DecimalString;
  /** The RiskModule's LTV, the same for both markets of a pool. */
  readonly ltvBps: number;
  /** The Spoke's dynamic reserve configuration of the vault token. */
  readonly collateralFactorBps: number;
  readonly maxLiquidationBonusBps: number;
  readonly liquidationFeeBps: number;
  /** `collateralRisk` of the vault-token reserve: every borrower of the market pays `drawnRate × (1 + this)`. */
  readonly collateralRiskBps: number;
  readonly paused: boolean;
  readonly frozen: boolean;
  readonly liquidation: {
    readonly targetHealthFactorWad: DecimalString;
    readonly healthFactorForMaxBonusWad: DecimalString;
    readonly liquidationBonusFactorBps: number;
  } | null;
  /** Every debt reserve of the market's Spoke, with the market's rate. */
  readonly borrow: readonly MarketBorrowRow[];
  readonly blockNumber: DecimalString;
}

/** Debt one market backs in one debt reserve of its CDP Spoke (Σ over the market's accounts). */
export interface MarketReserveDebtRow {
  readonly chainId: number;
  readonly marketId: DecimalString;
  readonly spoke: Address;
  readonly reserveId: DecimalString;
  readonly debt: DecimalString;
  readonly borrowers: number;
  readonly blockNumber: DecimalString;
}

/**
 * One Aave V4 Hub: its label, tier and the Spokes and lend assets it has at the block. Hub totals are not copied here;
 * they are the sum of the Hub's `HubAssetRow`s.
 */
export interface HubRow {
  readonly chainId: number;
  readonly hub: Address;
  /** The manifest's label. */
  readonly label: string;
  /** The manifest's risk tier (1 to 3). */
  readonly tier: number;
  /** Every Hub asset, lend assets and vault tokens alike. */
  readonly assetCount: number;
  /** Hub assets some Lend Spoke supplies: the Hub's rows of the Lend page. */
  readonly lendAssetIds: readonly DecimalString[];
  readonly lendSpokes: readonly Address[];
  /** CDP Spokes whose home Hub is this one. */
  readonly cdpSpokes: readonly Address[];
  readonly blockNumber: DecimalString;
}

export interface ChainSnapshot {
  readonly chainId: number;
  readonly blockNumber: DecimalString;
  readonly timestamp: number;
  readonly hubs: readonly HubRow[];
  readonly hubAssets: readonly HubAssetRow[];
  readonly slices: readonly HubAssetSpokeRow[];
  readonly spokeReserves: readonly SpokeReserveRow[];
  readonly markets: readonly MarketRow[];
}
