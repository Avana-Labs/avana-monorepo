// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The rows of one chain snapshot, by scope. Each number has one owner: Hub totals live only in `HubAssetRow`, a
// Spoke's draw on an asset only in `HubAssetSpokeRow`, a CDP reserve's own flags only in `SpokeReserveRow`, a
// collateral market's figures only in `MarketRow`. Every row of one snapshot is read at the same block, so the
// identities of the scope model hold exactly between them. Integers are decimal strings in base units; rates are RAY
// per year; prices are USD with 8 decimals.

import type { DecimalString } from "../export.ts";

export type Address = `0x${string}`;

/** The addresses one chain's snapshot reads, taken from the verified release manifest. */
export interface ChainDeployment {
  readonly chainId: number;
  readonly lens: Address;
  /** The Lend Spoke: Aave standard Spoke, supply only; its reserves are the lend assets. */
  readonly lendSpoke: Address;
  /** Every CDP Spoke, one per AMM protocol. */
  readonly cdpSpokes: readonly Address[];
  /** Every Coverage Spoke with the asset it covers. */
  readonly coverageSpokes: readonly { readonly address: Address; readonly asset: Address }[];
}

/** What a Spoke is to one Hub asset. Only CDP Spokes draw; the others have `drawCap = 0` (REQ-HUB-015). */
export type SpokeKind = "lend" | "cdp" | "coverage" | "feeReceiver" | "other";

export interface RateCurve {
  readonly optimalUsageBps: number;
  readonly baseDrawnRateBps: number;
  readonly rateGrowthBeforeOptimalBps: number;
  readonly rateGrowthAfterOptimalBps: number;
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
  readonly lend: {
    readonly spoke: Address;
    readonly reserveId: DecimalString;
    readonly paused: boolean;
    readonly frozen: boolean;
  };
  /** From `Lens.getHubAssetExposure`; null when the Lens refuses the asset. */
  readonly exposure: {
    readonly coverageSpoke: Address;
    readonly fundedBalance: DecimalString;
    readonly line: DecimalString;
    readonly coverageBoundHolds: boolean;
    readonly uncovered: DecimalString;
    readonly priceAdj: DecimalString;
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
  /** `MarketRegistry.hubOf(spoke)` as the Lens reports it; the zero address for a Spoke that is not a CDP Spoke. */
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
  /** The CDP Spoke's served debt price (DebtOracle, or the fixed GHO source); shown as debt-price status only. */
  readonly debtPrice: DecimalString;
  readonly fixedPrice: boolean;
  readonly paused: boolean;
  readonly frozen: boolean;
  readonly borrowable: boolean;
  readonly breakerReasons: number;
  /** None, Frozen or Paused, of the funding Hub. */
  readonly pauseState: number;
  readonly blockNumber: DecimalString;
}

/** One collateral market (one pool range on one CDP Spoke). */
export interface MarketRow {
  readonly chainId: number;
  readonly marketId: DecimalString;
  /** MarketRegistry `MarketStatus` index. */
  readonly status: number;
  readonly pool: Address;
  readonly poolId: `0x${string}`;
  readonly tokens: readonly Address[];
  readonly tokenDecimals: readonly number[];
  /** Pips; 0 for a dynamic-fee pool. */
  readonly feeTier: number;
  readonly tickLower: number;
  readonly tickUpper: number;
  readonly integrationId: number;
  readonly ammProtocol: `0x${string}`;
  readonly vaultToken: Address;
  /** Decimals of the vault token (6 to 18), from the Hub asset it is listed as. */
  readonly vaultDecimals: number;
  readonly name: string;
  readonly symbol: string;
  readonly lpOracle: Address;
  readonly hub: Address;
  readonly spoke: Address;
  readonly reserveId: DecimalString;
  readonly hubAssetId: DecimalString;
  /** USD, 8 decimals, per whole vault token. */
  readonly acceptedPrice: DecimalString;
  readonly priceState: number;
  readonly suppliedUnits: DecimalString;
  readonly suppliedUsd8: DecimalString;
  readonly collateralFactorBps: number;
  readonly maxLiquidationBonusBps: number;
  /** `collateralRisk` of the vault-token reserve: every borrower of the market pays `drawnRate × (1 + this)`. */
  readonly collateralRiskBps: number;
  readonly liquidation: {
    readonly targetHealthFactorWad: DecimalString;
    readonly healthFactorForMaxBonusWad: DecimalString;
    readonly liquidationBonusFactorBps: number;
  } | null;
  readonly marketHeadroomUsd8: DecimalString;
  readonly sliceHeadroomUsd8: DecimalString;
  readonly addHeadroom: DecimalString;
  readonly pauseState: number;
  readonly breakerReasons: number;
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

export interface ChainSnapshot {
  readonly chainId: number;
  readonly blockNumber: DecimalString;
  readonly timestamp: number;
  readonly hubAssets: readonly HubAssetRow[];
  readonly slices: readonly HubAssetSpokeRow[];
  readonly spokeReserves: readonly SpokeReserveRow[];
  readonly markets: readonly MarketRow[];
}
