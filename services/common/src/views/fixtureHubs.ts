// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Test data only: one Ethereum deployment with several Hubs, as an in-memory chain (fixtureChain.ts) at two moments.
//
// At start-up the manifest names Hub A ("Stable", tier 1) and Hub B ("Core", tier 2), three Lend Spokes (A and A2 on
// Hub A, B on Hub B) and two CDP Spokes (CDP A at home on Hub A, CDP B on Hub B). CDP A also draws USDC from Hub B
// through a Hub-to-Hub credit line. Later the MarketRegistry records Hub C (tier 3) with its own Lend Spoke, Coverage
// Spoke, CDP Spoke and the DAO deficit offset behind that First-Loss Reserve, none of which the manifest names; the reader
// must find all four and must not read the offset, supply-only like a Lend Spoke, as one.
//
// Amounts (whole tokens): Hub A USDC 10,000,000 added (Lend A 9,000,000, Lend A2 800,000, Coverage 200,000), 3,000,000
// owed by CDP A; Hub A USDT 4,000,000 added, 1,000,000 owed; Hub B USDC 6,000,000 added, 2,000,000 owed (CDP B
// 1,500,000, CDP A 500,000 on its line); Hub B GHO 1,000,000 added; Hub C USDC 2,050,000 added (50,000 by the deficit
// offset), 500,000 owed.

import type { FakeAsset, FakeChain, FakeHub } from "./fixtureChain.ts";
import type { Address, ChainDeployment } from "./types.ts";

const a = (prefix: string, n: number): Address => `0x${prefix}${"0".repeat(38 - prefix.length)}${n.toString(16).padStart(2, "0")}` as Address;
const six = (whole: number): bigint => BigInt(whole) * 10n ** 6n;
const wad = (whole: number): bigint => BigInt(whole) * 10n ** 18n;

export const HUBS_LENS = a("99", 1);
export const HUBS_REGISTRY = a("80", 1);
const IRS = a("77", 1);
export const HUB_A = a("aa", 1);
export const HUB_B = a("aa", 2);
export const HUB_C = a("aa", 3);
export const LEND_A = a("bb", 1);
export const LEND_A2 = a("bb", 2);
export const LEND_B = a("bb", 3);
export const LEND_C = a("bb", 4);
export const CDP_A = a("cc", 1);
export const CDP_B = a("cc", 2);
export const CDP_C = a("cc", 3);
export const COV_A = a("cd", 1);
export const COV_C = a("cd", 3);
export const OFFSET_C = a("ce", 3);
const FEE_A = a("fe", 1);
const FEE_B = a("fe", 2);
const FEE_C = a("fe", 3);
export const USDC: Address = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";
export const USDT: Address = "0xdac17f958d2ee523a2206206994597c13d831ec7";
export const GHO: Address = "0x40d16fc0246ad3160ccc09b8d0d3a2cd28ae6c2f";
const VT_A = a("dd", 1);
const VT_C = a("dd", 3);

const RATE_6 = 6n * 10n ** 25n;
const asset = (x: Partial<FakeAsset> & Pick<FakeAsset, "underlying" | "feeReceiver" | "slices">): FakeAsset => ({
  decimals: 6,
  liquidityFeeBps: 1_000,
  drawn: 0n,
  premium: 0n,
  liquidity: x.slices.reduce((acc, s) => acc + s.added, 0n),
  drawnRateRay: RATE_6,
  ...x,
});

const hubA: FakeHub = {
  hub: HUB_A,
  tier: 1,
  assets: [
    asset({
      underlying: USDC,
      feeReceiver: FEE_A,
      firstLossReserve: COV_A,
      drawn: six(2_990_000),
      premium: six(10_000),
      liquidity: six(7_000_000),
      slices: [
        { spoke: LEND_A, added: six(9_000_000), owed: 0n, addCap: 20_000_000, drawCap: 0 },
        { spoke: LEND_A2, added: six(800_000), owed: 0n, addCap: 5_000_000, drawCap: 0 },
        { spoke: COV_A, added: six(200_000), owed: 0n, addCap: 1_000_000, drawCap: 0 },
        { spoke: FEE_A, added: 0n, owed: 0n, addCap: 0, drawCap: 0 },
        { spoke: CDP_A, added: 0n, owed: six(3_000_000), addCap: 0, drawCap: 4_000_000 },
      ],
    }),
    asset({
      underlying: USDT,
      feeReceiver: FEE_A,
      drawn: six(1_000_000),
      liquidity: six(3_000_000),
      slices: [
        { spoke: LEND_A, added: six(4_000_000), owed: 0n, addCap: 10_000_000, drawCap: 0 },
        { spoke: CDP_A, added: 0n, owed: six(1_000_000), addCap: 0, drawCap: 2_000_000 },
      ],
    }),
    // The vault token of market 1, supplied as collateral through CDP A.
    asset({ underlying: VT_A, decimals: 18, feeReceiver: FEE_A, slices: [{ spoke: CDP_A, added: wad(1_000_000), owed: 0n, addCap: 5_000_000, drawCap: 0 }] }),
  ],
};

const hubB: FakeHub = {
  hub: HUB_B,
  tier: 2,
  assets: [
    asset({
      underlying: USDC,
      feeReceiver: FEE_B,
      drawn: six(2_000_000),
      liquidity: six(4_000_000),
      drawnRateRay: 8n * 10n ** 25n,
      slices: [
        { spoke: LEND_B, added: six(6_000_000), owed: 0n, addCap: 10_000_000, drawCap: 0 },
        { spoke: CDP_B, added: 0n, owed: six(1_500_000), addCap: 0, drawCap: 3_000_000 },
        { spoke: CDP_A, added: 0n, owed: six(500_000), addCap: 0, drawCap: 1_000_000 },
      ],
    }),
    asset({ underlying: GHO, decimals: 18, feeReceiver: FEE_B, slices: [{ spoke: LEND_B, added: wad(1_000_000), owed: 0n, addCap: 5_000_000, drawCap: 0 }, { spoke: CDP_B, added: 0n, owed: 0n, addCap: 0, drawCap: 500_000 }] }),
  ],
};

const hubC: FakeHub = {
  hub: HUB_C,
  tier: 3,
  assets: [
    asset({
      underlying: USDC,
      feeReceiver: FEE_C,
      firstLossReserve: COV_C,
      drawn: six(500_000),
      liquidity: six(1_550_000),
      slices: [
        { spoke: LEND_C, added: six(1_900_000), owed: 0n, addCap: 10_000_000, drawCap: 0 },
        { spoke: COV_C, added: six(100_000), owed: 0n, addCap: 1_000_000, drawCap: 0 },
        // The Aave DAO's deficit offset behind COV_C: supply-only like a Lend Spoke, found by its FIRST_LOSS_LAYER().
        { spoke: OFFSET_C, added: six(50_000), owed: 0n, addCap: 1_000_000, drawCap: 0, firstLossLayer: COV_C },
        { spoke: FEE_C, added: 0n, owed: 0n, addCap: 0, drawCap: 0 },
        { spoke: CDP_C, added: 0n, owed: six(500_000), addCap: 0, drawCap: 1_000_000 },
      ],
    }),
    asset({ underlying: VT_C, decimals: 18, feeReceiver: FEE_C, slices: [{ spoke: CDP_C, added: wad(10_000), owed: 0n, addCap: 1_000_000, drawCap: 0 }] }),
  ],
};

const market = (marketId: bigint, hub: Address, spoke: Address, vaultToken: Address, hubAssetId: bigint, debtReserveIds: readonly bigint[]) => ({
  marketId, status: 1, pool: a("ee", Number(marketId)), poolId: `0x${"00".repeat(32)}`, tokens: [USDC, USDT], tokenDecimals: [6, 6], feeTier: 100, tickLower: -10,
  tickUpper: 10, integrationId: 1, ammProtocol: `0x${"00".repeat(31)}01`, vaultToken, name: `USDC/USDT ${marketId}`, symbol: `av-${marketId}`, lpOracle: a("ef", Number(marketId)),
  hub, spoke, reserveId: 10n + marketId, hubAssetId, acceptedPrice: 2n * 10n ** 8n, priceState: 0, suppliedUnits: wad(1_000), suppliedUsd: 2_000n * 10n ** 8n,
  collateralFactorBps: 8_000n, liquidationThresholdBps: 8_000n, maxLiquidationBonusBps: 500n, marketHeadroomUsd: 0n, sliceHeadroomUsd: 0n, addHeadroom: 0n, pauseState: 0, breakerReasons: 0,
  collateralRiskBps: 500n, liquidationFeeBps: 1_000n, targetHealthFactor: 11n * 10n ** 17n, healthFactorForMaxBonus: 95n * 10n ** 16n, liquidationBonusFactorBps: 5_000n,
  hardHealthFloor: 0n, marketUsdCap: 5_000_000n * 10n ** 8n, topUpSliceUsd: 500_000n * 10n ** 8n, depositorUsdCap: 1_000_000n * 10n ** 8n, tokenUsdCaps: [10n ** 15n, 10n ** 15n],
  addCap: 5_000_000n, debtReserveIds,
  // ⌈6 % × 1.05⌉ RAY on each debt reserve.
  borrowRatesRay: debtReserveIds.map(() => 63n * 10n ** 24n),
});

const START: FakeChain = {
  lens: HUBS_LENS,
  registry: HUBS_REGISTRY,
  rateStrategy: IRS,
  hubs: [hubA, hubB],
  recordedHubs: [HUB_A, HUB_B],
  lendSpokes: [
    { spoke: LEND_A, oracle: a("bc", 1), oracleDecimals: 8, reserves: [{ hub: HUB_A, assetId: 0, price: 100_000_000n }, { hub: HUB_A, assetId: 1, price: 99_990_000n }] },
    { spoke: LEND_A2, oracle: a("bc", 2), oracleDecimals: 18, reserves: [{ hub: HUB_A, assetId: 0, price: 999_900_000_000_000_000n, frozen: true }] },
    { spoke: LEND_B, oracle: a("bc", 3), oracleDecimals: 8, reserves: [{ hub: HUB_B, assetId: 0, price: 100_010_000n }, { hub: HUB_B, assetId: 1, price: 100_000_000n }] },
  ],
  cdpSpokes: [
    {
      spoke: CDP_A,
      homeHub: HUB_A,
      debtReserves: [
        { reserveId: 1n, hub: HUB_A, hubAssetId: 0n, asset: USDC, decimals: 6 },
        { reserveId: 2n, hub: HUB_A, hubAssetId: 1n, asset: USDT, decimals: 6 },
        { reserveId: 3n, hub: HUB_B, hubAssetId: 0n, asset: USDC, decimals: 6 },
      ],
    },
    {
      spoke: CDP_B,
      homeHub: HUB_B,
      debtReserves: [
        { reserveId: 1n, hub: HUB_B, hubAssetId: 0n, asset: USDC, decimals: 6 },
        { reserveId: 2n, hub: HUB_B, hubAssetId: 1n, asset: GHO, decimals: 18 },
      ],
    },
  ],
  crossHubLines: [{ fundingHub: HUB_B, asset: USDC, spoke: CDP_A, cap: six(1_000_000) }],
  crossHubLinesEnabled: true,
  markets: [market(1n, HUB_A, CDP_A, VT_A, 2n, [1n, 2n, 3n])],
};

/** The same chain after the registry recorded Hub C and approved CDP C, and Lend C and market 2 were listed. */
const LATER: FakeChain = {
  ...START,
  hubs: [hubA, hubB, hubC],
  recordedHubs: [HUB_A, HUB_B, HUB_C],
  lendSpokes: [...START.lendSpokes, { spoke: LEND_C, oracle: a("bc", 4), oracleDecimals: 8, reserves: [{ hub: HUB_C, assetId: 0, price: 100_000_000n }] }],
  cdpSpokes: [...START.cdpSpokes, { spoke: CDP_C, homeHub: HUB_C, debtReserves: [{ reserveId: 1n, hub: HUB_C, hubAssetId: 0n, asset: USDC, decimals: 6 }] }],
  markets: [...START.markets, market(2n, HUB_C, CDP_C, VT_C, 1n, [1n])],
};

export const fixtureHubsChain = { start: START, later: LATER } as const;

/** What the manifest gives the services at start-up; it never names Hub C, Lend C or CDP C. */
export const fixtureHubsDeployment: ChainDeployment = {
  chainId: 1,
  lens: HUBS_LENS,
  marketRegistry: HUBS_REGISTRY,
  hubs: [
    { address: HUB_A, label: "Stable" },
    { address: HUB_B, label: "Core" },
  ],
  lendSpokes: [LEND_A, LEND_A2, LEND_B],
  cdpSpokes: [CDP_A, CDP_B],
  firstLossReserves: [{ address: COV_A, asset: USDC, hub: HUB_A }],
};
