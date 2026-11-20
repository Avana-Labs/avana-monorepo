// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Test data only: one Ethereum deployment with several Hubs, as an in-memory chain (fixtureChain.ts) at two moments.
//
// The manifest names Hub A ("Stable", tier 1), Hub B ("Core", tier 2) and Hub C ("Edge", tier 3), Lend Spokes (A and
// A2 on Hub A, B on Hub B, C on Hub C), CDP Spokes (CDP A at home on Hub A, CDP B on Hub B, CDP C on Hub C), the
// First-Loss Reserves of Hub A and Hub C USDC with the DAO deficit offset behind Hub C's, and one pool's two markets on
// CDP A (Full range and Custom range) and a market on CDP C. CDP A also has a USDC slice and debt reserve on Hub B,
// which the reader reads as the Hub reports it. At the first block read, Hub C and its Spokes have no code yet (a later
// release step deploys them): the reader leaves them out, then reads them once they exist.
//
// Amounts (whole tokens): Hub A USDC 10,000,000 added (Lend A 9,000,000, Lend A2 800,000, Coverage 200,000), 3,000,000
// owed by CDP A; Hub A USDT 4,000,000 added, 1,000,000 owed; Hub B USDC 6,000,000 added, 2,000,000 owed (CDP B
// 1,500,000, CDP A 500,000); Hub B GHO 1,000,000 added; Hub C USDC 2,050,000 added (50,000 by the deficit
// offset), 500,000 owed.

import type { FakeAsset, FakeCdpSpoke, FakeChain, FakeHub, FakeMarket } from "./fixtureChain.ts";
import type { Address, ChainDeployment } from "./types.ts";

const a = (prefix: string, n: number): Address => `0x${prefix}${"0".repeat(38 - prefix.length)}${n.toString(16).padStart(2, "0")}` as Address;
const six = (whole: number): bigint => BigInt(whole) * 10n ** 6n;
const wad = (whole: number): bigint => BigInt(whole) * 10n ** 18n;

export const HUBS_RISK_MODULE = a("80", 1);
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
const VT_A2 = a("dd", 2);
const VT_C = a("dd", 3);
const ORACLE_CDP = (n: number) => a("bd", n);

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
    // The vault tokens of markets 1 (Full range) and 2 (Custom range), supplied as collateral through CDP A.
    asset({ underlying: VT_A, decimals: 18, feeReceiver: FEE_A, slices: [{ spoke: CDP_A, added: wad(1_000), owed: 0n, addCap: 5_000_000, drawCap: 0 }] }),
    asset({ underlying: VT_A2, decimals: 18, feeReceiver: FEE_A, slices: [{ spoke: CDP_A, added: wad(500), owed: 0n, addCap: 5_000_000, drawCap: 0 }] }),
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
        // The Aave DAO's deficit offset behind COV_C: supply-only like a Lend Spoke, named by the manifest.
        { spoke: OFFSET_C, added: six(50_000), owed: 0n, addCap: 1_000_000, drawCap: 0 },
        { spoke: FEE_C, added: 0n, owed: 0n, addCap: 0, drawCap: 0 },
        { spoke: CDP_C, added: 0n, owed: six(500_000), addCap: 0, drawCap: 1_000_000 },
      ],
    }),
    asset({ underlying: VT_C, decimals: 18, feeReceiver: FEE_C, slices: [{ spoke: CDP_C, added: wad(10_000), owed: 0n, addCap: 1_000_000, drawCap: 0 }] }),
  ],
};

/** One pool's key; its two markets share it and the LTV. */
const POOL_KEY = `0x${"00".repeat(12)}${a("ee", 1).slice(2)}` as `0x${string}`;
const market = (marketId: bigint, kind: 0 | 1, hub: Address, spoke: Address, vaultToken: Address, hubAssetId: bigint): FakeMarket => ({
  marketId,
  kind,
  pool: POOL_KEY,
  spoke,
  hub,
  hubAssetId,
  vaultToken,
  lpOracle: a("ef", Number(marketId)),
  reserveId: 10n + marketId,
  bandLower: kind === 0 ? -887_270 : -100,
  bandUpper: kind === 0 ? 887_270 : 100,
  ltvBps: 9_000,
  active: true,
  price: 2n * 10n ** 8n,
  collateralRiskBps: 500,
});

const LEND_SPOKES = [
  { spoke: LEND_A, oracle: a("bc", 1), oracleDecimals: 8, reserves: [{ hub: HUB_A, assetId: 0, price: 100_000_000n }, { hub: HUB_A, assetId: 1, price: 99_990_000n }] },
  { spoke: LEND_A2, oracle: a("bc", 2), oracleDecimals: 18, reserves: [{ hub: HUB_A, assetId: 0, price: 999_900_000_000_000_000n, frozen: true }] },
  { spoke: LEND_B, oracle: a("bc", 3), oracleDecimals: 8, reserves: [{ hub: HUB_B, assetId: 0, price: 100_010_000n }, { hub: HUB_B, assetId: 1, price: 100_000_000n }] },
];
const CDP_SPOKES: FakeCdpSpoke[] = [
  {
    spoke: CDP_A,
    homeHub: HUB_A,
    oracle: ORACLE_CDP(1),
    debtReserves: [
      { reserveId: 1n, hub: HUB_A, hubAssetId: 0n, asset: USDC, decimals: 6 },
      { reserveId: 2n, hub: HUB_A, hubAssetId: 1n, asset: USDT, decimals: 6 },
      { reserveId: 3n, hub: HUB_B, hubAssetId: 0n, asset: USDC, decimals: 6 },
    ],
  },
  {
    spoke: CDP_B,
    homeHub: HUB_B,
    oracle: ORACLE_CDP(2),
    debtReserves: [
      { reserveId: 1n, hub: HUB_B, hubAssetId: 0n, asset: USDC, decimals: 6 },
      { reserveId: 2n, hub: HUB_B, hubAssetId: 1n, asset: GHO, decimals: 18 },
    ],
  },
];
const MARKETS_A = [market(1n, 0, HUB_A, CDP_A, VT_A, 2n), market(2n, 1, HUB_A, CDP_A, VT_A2, 3n)];
const MARKET_C = market(3n, 0, HUB_C, CDP_C, VT_C, 1n);

const START: FakeChain = {
  riskModule: HUBS_RISK_MODULE,
  rateStrategy: IRS,
  hubs: [hubA, hubB],
  lendSpokes: LEND_SPOKES,
  cdpSpokes: CDP_SPOKES,
  markets: MARKETS_A,
};

/** The same chain after the later release step deployed Hub C, Lend C, CDP C and market 3. */
const LATER: FakeChain = {
  ...START,
  hubs: [hubA, hubB, hubC],
  lendSpokes: [...LEND_SPOKES, { spoke: LEND_C, oracle: a("bc", 4), oracleDecimals: 8, reserves: [{ hub: HUB_C, assetId: 0, price: 100_000_000n }] }],
  cdpSpokes: [...CDP_SPOKES, { spoke: CDP_C, homeHub: HUB_C, oracle: ORACLE_CDP(3), debtReserves: [{ reserveId: 1n, hub: HUB_C, hubAssetId: 0n, asset: USDC, decimals: 6 }] }],
  markets: [...MARKETS_A, MARKET_C],
};

export const fixtureHubsChain = { start: START, later: LATER } as const;

const deploymentMarket = (m: FakeMarket, name: string) => ({
  marketId: m.marketId,
  integrationId: 1,
  riskModule: HUBS_RISK_MODULE,
  kind: m.kind === 0 ? ("full-range" as const) : ("custom-range" as const),
  name,
  pool: m.pool,
  spoke: m.spoke,
  hub: m.hub,
  vaultToken: m.vaultToken,
  lpOracle: m.lpOracle,
  reserveId: m.reserveId,
  tokens: [USDC, USDT],
});

/**
 * What the manifest gives the services: every Hub, Spoke and market of the release, Hub C's included. `lens` and
 * `marketRegistry` are the replaced core's addresses, kept only for the web app's local seed script until it writes the
 * new deployment record; no reader uses them.
 */
export const fixtureHubsDeployment: ChainDeployment & { readonly lens: Address; readonly marketRegistry: Address } = {
  chainId: 1,
  lens: a("99", 1),
  marketRegistry: a("80", 2),
  hubs: [
    { address: HUB_A, label: "Stable", tier: 1 },
    { address: HUB_B, label: "Core", tier: 2 },
    { address: HUB_C, label: "Edge", tier: 3 },
  ],
  lendSpokes: [LEND_A, LEND_A2, LEND_B, LEND_C],
  cdpSpokes: [
    { address: CDP_A, hub: HUB_A },
    { address: CDP_B, hub: HUB_B },
    { address: CDP_C, hub: HUB_C },
  ],
  firstLossReserves: [
    { address: COV_A, asset: USDC, hub: HUB_A },
    { address: COV_C, asset: USDC, hub: HUB_C },
  ],
  deficitOffsets: [{ address: OFFSET_C, asset: USDC, hub: HUB_C }],
  riskModules: [HUBS_RISK_MODULE],
  markets: [deploymentMarket(MARKETS_A[0]!, "USDC-USDT-100 full"), deploymentMarket(MARKETS_A[1]!, "USDC-USDT-100 custom"), deploymentMarket(MARKET_C, "USDC-USDT edge full")],
  debtReserves: [
    ...CDP_SPOKES.flatMap((sp) => sp.debtReserves.map((r) => ({ spoke: sp.spoke, reserveId: r.reserveId, fixedPrice: r.asset === GHO }))),
    { spoke: CDP_C, reserveId: 1n, fixedPrice: false },
  ],
};
