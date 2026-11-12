// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Test data only. The rows below: one Ethereum Hub asset (USDC, 6 decimals) with a Lend Spoke, a Coverage Spoke, a fee
// receiver and two CDP Spokes, U and X, at one block; two markets on U; and the debt each market backs. The numbers
// are the worked example of services/README.md ("Scopes"): 10,000,000 added, 3,000,000 owed (U 1,000,000 and X
// 2,000,000), 7,000,000 liquidity. U's slice rounds its owed amount up by one base unit, as the Hub does per Spoke.
// The chain with several Hubs that the reader runs on is in fixtureHubs.ts.

import type { HubAssetRow, HubAssetSpokeRow, MarketReserveDebtRow, MarketRow, SpokeReserveRow } from "./types.ts";

export * from "./fixtureChain.ts";
export * from "./fixtureHubs.ts";

const USDC = (whole: number, extra = 0n): string => (BigInt(whole) * 1_000_000n + extra).toString(10);
const BLOCK = "21400000";

export const FIXTURE_HUB = "0x1111111111111111111111111111111111111111" as const;
export const FIXTURE_LEND = "0x2222222222222222222222222222222222222222" as const;
export const FIXTURE_COVERAGE = "0x3333333333333333333333333333333333333333" as const;
export const FIXTURE_FEES = "0x4444444444444444444444444444444444444444" as const;
export const FIXTURE_U = "0x5555555555555555555555555555555555555555" as const;
export const FIXTURE_X = "0x6666666666666666666666666666666666666666" as const;
export const FIXTURE_USDC = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48" as const;

export const fixtureHubAsset: HubAssetRow = {
  chainId: 1,
  hub: FIXTURE_HUB,
  assetId: "1",
  underlying: FIXTURE_USDC,
  decimals: 6,
  priceUsd8: "100000000",
  added: USDC(10_000_000),
  addedShares: USDC(10_000_000),
  drawn: USDC(2_990_000),
  premium: USDC(10_000),
  owed: USDC(3_000_000),
  liquidity: USDC(7_000_000),
  deficit: "0",
  accruedFees: "0",
  drawnIndexRay: (10n ** 27n).toString(10),
  drawnRateRay: (6n * 10n ** 25n).toString(10),
  supplyRateRay: (162n * 10n ** 23n).toString(10),
  utilizationBps: 3_000,
  liquidityFeeBps: 1_000,
  feeReceiver: FIXTURE_FEES,
  rateCurve: { optimalUsageBps: 8_000, baseDrawnRateBps: 0, rateGrowthBeforeOptimalBps: 400, rateGrowthAfterOptimalBps: 6_000 },
  lend: { spoke: FIXTURE_LEND, reserveId: "0", paused: false, frozen: false },
  lendReserves: [{ spoke: FIXTURE_LEND, reserveId: "0", paused: false, frozen: false }],
  exposure: {
    coverageSpoke: FIXTURE_COVERAGE,
    fundedBalance: USDC(200_000),
    line: USDC(7_000_000),
    coverageBoundHolds: true,
    uncovered: "0",
    priceAdj: "1000000",
  },
  blockNumber: BLOCK,
  timestamp: 1_767_225_600,
};

const slice = (spoke: `0x${string}`, kind: HubAssetSpokeRow["kind"], added: string, owed: string, drawCap: string): HubAssetSpokeRow => ({
  chainId: 1,
  hub: FIXTURE_HUB,
  assetId: "1",
  spoke,
  kind,
  homeHub: kind === "cdp" ? FIXTURE_HUB : "0x0000000000000000000000000000000000000000",
  added,
  addedShares: added,
  owed,
  drawnShares: owed,
  premiumShares: "0",
  deficit: "0",
  addCap: kind === "lend" ? "12000000" : "0",
  drawCap,
  active: true,
  halted: false,
  blockNumber: BLOCK,
});

export const fixtureSlices: HubAssetSpokeRow[] = [
  slice(FIXTURE_LEND, "lend", USDC(9_800_000), "0", "0"),
  slice(FIXTURE_COVERAGE, "coverage", USDC(200_000), "0", "0"),
  slice(FIXTURE_FEES, "feeReceiver", "0", "0", "0"),
  slice(FIXTURE_U, "cdp", "0", USDC(1_000_000, 1n), "4000000"),
  slice(FIXTURE_X, "cdp", "0", USDC(2_000_000), "3000000"),
];

const reserve = (spoke: `0x${string}`, reserveId: string): SpokeReserveRow => ({
  chainId: 1,
  spoke,
  reserveId,
  hub: FIXTURE_HUB,
  assetId: "1",
  asset: FIXTURE_USDC,
  decimals: 6,
  debtPrice: "100000000",
  fixedPrice: false,
  paused: false,
  frozen: false,
  borrowable: true,
  breakerReasons: 0,
  pauseState: 0,
  blockNumber: BLOCK,
});

export const fixtureSpokeReserves: SpokeReserveRow[] = [reserve(FIXTURE_U, "1"), reserve(FIXTURE_X, "1")];

const market = (marketId: string, name: string, suppliedWhole: bigint, collateralRiskBps: number): MarketRow => ({
  chainId: 1,
  marketId,
  status: 1,
  pool: `0x00000000000000000000000000000000000000a${marketId}` as `0x${string}`,
  poolId: "0x0000000000000000000000000000000000000000000000000000000000000000",
  tokens: [FIXTURE_USDC, "0xdac17f958d2ee523a2206206994597c13d831ec7"],
  tokenDecimals: [6, 6],
  feeTier: 100,
  tickLower: -10,
  tickUpper: 10,
  integrationId: 1,
  ammProtocol: "0x0000000000000000000000000000000000000000000000000000000000000001",
  vaultToken: `0x00000000000000000000000000000000000000b${marketId}` as `0x${string}`,
  vaultDecimals: 18,
  name,
  symbol: `av-${marketId}`,
  lpOracle: `0x00000000000000000000000000000000000000c${marketId}` as `0x${string}`,
  hub: FIXTURE_HUB,
  spoke: FIXTURE_U,
  reserveId: String(10 + Number(marketId)),
  hubAssetId: String(10 + Number(marketId)),
  acceptedPrice: "200000000",
  priceState: 0,
  suppliedUnits: (suppliedWhole * 10n ** 18n).toString(10),
  suppliedUsd8: (suppliedWhole * 2n * 10n ** 8n).toString(10),
  collateralFactorBps: 8_000,
  maxLiquidationBonusBps: 500,
  collateralRiskBps,
  liquidation: { targetHealthFactorWad: "1100000000000000000", healthFactorForMaxBonusWad: "950000000000000000", liquidationBonusFactorBps: 5_000 },
  marketHeadroomUsd8: (1_000_000n * 10n ** 8n).toString(10),
  sliceHeadroomUsd8: (500_000n * 10n ** 8n).toString(10),
  addHeadroom: "0",
  pauseState: 0,
  breakerReasons: 0,
  blockNumber: BLOCK,
});

export const fixtureMarkets: MarketRow[] = [market("1", "USDC/USDT 0.01%", 1_000_000n, 500), market("2", "USDC/DAI 0.01%", 500_000n, 300)];

/** U's owed amount split by market; each account rounds up, so Σ markets ≥ U's slice by at most one unit per account. */
export const fixtureMarketDebt: MarketReserveDebtRow[] = [
  { chainId: 1, marketId: "1", spoke: FIXTURE_U, reserveId: "1", debt: USDC(600_000, 1n), borrowers: 12, blockNumber: BLOCK },
  { chainId: 1, marketId: "2", spoke: FIXTURE_U, reserveId: "1", debt: USDC(400_000, 1n), borrowers: 7, blockNumber: BLOCK },
];
