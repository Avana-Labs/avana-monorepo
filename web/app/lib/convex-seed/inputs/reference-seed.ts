// SEED ONLY — imported by build-seed.ts. Not for UI code.

/**
 * Global reference seed rows — spokes, dexes, and homepage editorial content.
 *
 * Values are extracted verbatim from the current mock catalogs so the Convex
 * tables stay byte-for-byte in sync with the in-repo source:
 *   - SPOKES_SEED_ROWS      ← BORROW_SPOKES        (app/lib/borrow-sim.ts:428-676)
 *                             + SPOKE_SLUGS         (app/lib/borrow-system/registry.ts:44-60)
 *                             + SMART_SPOKES        (app/borrow/components/borrow-workspace.tsx:24-33)
 *   - DEXES_SEED_ROWS       ← BORROW_DEXES         (app/lib/borrow-sim.ts:388-421)
 *   - HOME_CHAINS_SEED_ROWS ← HOME_CHAINS          (app/lib/home-data.ts:22-101)
 *   - HOME_STEPS_SEED_ROWS  ← HOME_HOW_IT_WORKS_STEPS (app/lib/home-data.ts:106-122)
 *
 * Icon URLs are resolved through `getLocalAssetIcon()` at seed-build time so the
 * on-disk asset path stays a single source of truth. `bgClass`/`textClass` on a
 * spoke or dex map to the mock's `pillBgClass`/`pillTextClass` (the pill color
 * pair the UI renders as the section header background). The mock's boolean
 * `eMode` flag is encoded as the string "enabled" on spokes where it is `true`
 * and omitted otherwise, matching the optional string field in the schema.
 */

import { getLocalAssetIcon } from "@/app/lib/local-asset-icons"

import type { SeedDexRow, SeedSpokeRow } from "../build-seed"

// -----------------------------------------------------------------------------
// Local token-visual dictionary. Mirrors the file-local `VISUALS` map in
// app/lib/borrow-sim.ts:142-380. Duplicated here so seed data stays independent
// of any UI-side changes to the visual catalog. Every token referenced by
// BORROW_SPOKES.borrowableTokens is covered.
// -----------------------------------------------------------------------------
const V = {
  USDC: {
    symbol: "USDC",
    iconUrl: getLocalAssetIcon("USDC"),
    shortLabel: "U",
    bgClass: "bg-sky-100",
    textClass: "text-sky-700",
  },
  USDT: {
    symbol: "USDT",
    iconUrl: getLocalAssetIcon("USDT"),
    shortLabel: "T",
    bgClass: "bg-emerald-100",
    textClass: "text-emerald-700",
  },
  DAI: {
    symbol: "DAI",
    iconUrl: getLocalAssetIcon("DAI"),
    shortLabel: "D",
    bgClass: "bg-orange-100",
    textClass: "text-orange-700",
  },
  GHO: {
    symbol: "GHO",
    iconUrl: getLocalAssetIcon("GHO"),
    shortLabel: "G",
    bgClass: "bg-violet-100",
    textClass: "text-violet-700",
  },
  crvUSD: {
    symbol: "crvUSD",
    iconUrl: getLocalAssetIcon("crvUSD"),
    shortLabel: "cU",
    bgClass: "bg-rose-100",
    textClass: "text-rose-700",
  },
  EURC: {
    symbol: "EURC",
    iconUrl: getLocalAssetIcon("EURC"),
    shortLabel: "€",
    bgClass: "bg-blue-100",
    textClass: "text-blue-700",
  },
  ETH: {
    symbol: "ETH",
    iconUrl: getLocalAssetIcon("ETH"),
    shortLabel: "E",
    bgClass: "bg-indigo-100",
    textClass: "text-indigo-700",
  },
  WETH: {
    symbol: "WETH",
    iconUrl: getLocalAssetIcon("WETH"),
    shortLabel: "W",
    bgClass: "bg-indigo-100",
    textClass: "text-indigo-700",
  },
  WBTC: {
    symbol: "WBTC",
    iconUrl: getLocalAssetIcon("WBTC"),
    shortLabel: "B",
    bgClass: "bg-amber-100",
    textClass: "text-amber-700",
  },
  cbBTC: {
    symbol: "cbBTC",
    iconUrl: getLocalAssetIcon("cbBTC"),
    shortLabel: "cB",
    bgClass: "bg-blue-100",
    textClass: "text-blue-700",
  },
  stETH: {
    symbol: "stETH",
    iconUrl: getLocalAssetIcon("stETH"),
    shortLabel: "st",
    bgClass: "bg-sky-100",
    textClass: "text-sky-600",
  },
  wstETH: {
    symbol: "wstETH",
    iconUrl: getLocalAssetIcon("wstETH"),
    shortLabel: "ws",
    bgClass: "bg-sky-100",
    textClass: "text-sky-600",
  },
  rETH: {
    symbol: "rETH",
    iconUrl: getLocalAssetIcon("rETH"),
    shortLabel: "r",
    bgClass: "bg-orange-100",
    textClass: "text-orange-600",
  },
  cbETH: {
    symbol: "cbETH",
    iconUrl: getLocalAssetIcon("cbETH"),
    shortLabel: "cE",
    bgClass: "bg-blue-100",
    textClass: "text-blue-600",
  },
  USDG: {
    symbol: "USDG",
    iconUrl: getLocalAssetIcon("USDG"),
    shortLabel: "G$",
    bgClass: "bg-teal-100",
    textClass: "text-teal-700",
  },
}

// -----------------------------------------------------------------------------
// Spokes — 15 entries in source order (Uniswap, Curve, Balancer, Aerodrome).
// -----------------------------------------------------------------------------
export const SPOKES_SEED_ROWS: SeedSpokeRow[] = [
  // -------- Uniswap --------
  {
    id: "uni-v2",
    slug: "uniswap-v2",
    dex: "uniswap",
    label: "Uniswap v2 LPs",
    description: "Constant-product LP tokens",
    maxLtvPct: 65,
    aprApproxPct: 4.8,
    riskPremiumBps: 80,
    liquidityUsd: 820_000_000,
    liquidationUsdApprox: 1_800,
    bgClass: "bg-pink-50",
    textClass: "text-pink-700",
    borrowableTokens: [V.USDC, V.USDT, V.DAI, V.WETH, V.WBTC],
    isSmartSpoke: true,
  },
  {
    id: "uni-v3-stable",
    slug: "uniswap-stable",
    dex: "uniswap",
    label: "Uniswap v3 Stable LPs",
    description: "Concentrated-liquidity LP positions",
    eMode: "enabled",
    maxLtvPct: 92,
    aprApproxPct: 3.2,
    riskPremiumBps: 25,
    liquidityUsd: 1_250_000_000,
    liquidationUsdApprox: 2_300,
    bgClass: "bg-emerald-50",
    textClass: "text-emerald-700",
    borrowableTokens: [V.USDC, V.USDT, V.DAI, V.crvUSD, V.GHO],
    isSmartSpoke: true,
  },
  {
    id: "uni-v3-bluechip",
    slug: "uniswap-bluechip",
    dex: "uniswap",
    label: "Uniswap v3 Blue-Chip LPs",
    description: "Concentrated-liquidity LP positions",
    maxLtvPct: 78,
    aprApproxPct: 5.8,
    riskPremiumBps: 70,
    liquidityUsd: 2_400_000_000,
    liquidationUsdApprox: 3_400,
    bgClass: "bg-blue-50",
    textClass: "text-blue-700",
    borrowableTokens: [V.USDC, V.USDT, V.DAI, V.WETH, V.WBTC],
    isSmartSpoke: true,
  },
  {
    id: "uni-v3-gov",
    slug: "uniswap-governance",
    dex: "uniswap",
    label: "Uniswap v3 Governance & DAO LPs",
    description: "Concentrated-liquidity LP positions",
    maxLtvPct: 55,
    aprApproxPct: 7.8,
    riskPremiumBps: 180,
    liquidityUsd: 1_210_000_000,
    liquidationUsdApprox: 1_200,
    bgClass: "bg-amber-50",
    textClass: "text-amber-700",
    borrowableTokens: [V.USDC, V.USDT, V.DAI, V.WETH],
    isSmartSpoke: false,
  },

  // -------- Curve --------
  {
    id: "curve-stable",
    slug: "curve-stable",
    dex: "curve",
    label: "Curve Stable LPs",
    description: "StableSwap LP tokens",
    eMode: "enabled",
    maxLtvPct: 92,
    aprApproxPct: 2.9,
    riskPremiumBps: 20,
    liquidityUsd: 720_000_000,
    liquidationUsdApprox: 2_100,
    bgClass: "bg-emerald-50",
    textClass: "text-emerald-700",
    borrowableTokens: [V.USDC, V.USDT, V.DAI, V.crvUSD, V.GHO],
    isSmartSpoke: false,
  },
  {
    id: "curve-correlated",
    slug: "curve-correlated",
    dex: "curve",
    label: "Curve Correlated LPs",
    description: "StableSwap LP tokens",
    eMode: "enabled",
    maxLtvPct: 90,
    aprApproxPct: 3.4,
    riskPremiumBps: 40,
    liquidityUsd: 680_000_000,
    liquidationUsdApprox: 2_900,
    bgClass: "bg-sky-50",
    textClass: "text-sky-700",
    borrowableTokens: [V.ETH, V.stETH, V.wstETH, V.rETH],
    isSmartSpoke: false,
  },
  {
    id: "curve-crypto",
    slug: "curve-crypto",
    dex: "curve",
    label: "Curve Crypto LPs",
    description: "CryptoSwap LP tokens",
    maxLtvPct: 70,
    aprApproxPct: 6.1,
    riskPremiumBps: 110,
    liquidityUsd: 430_000_000,
    liquidationUsdApprox: 2_400,
    bgClass: "bg-orange-50",
    textClass: "text-orange-700",
    borrowableTokens: [V.USDC, V.USDT, V.DAI, V.WETH, V.WBTC],
    isSmartSpoke: true,
  },

  // -------- Balancer --------
  {
    id: "bal-stable",
    slug: "balancer-stable",
    dex: "balancer",
    label: "Balancer Stable LPs",
    description: "Stable / Composable Stable BPT",
    eMode: "enabled",
    maxLtvPct: 90,
    aprApproxPct: 3.4,
    riskPremiumBps: 25,
    liquidityUsd: 52_000_000,
    liquidationUsdApprox: 2_050,
    bgClass: "bg-emerald-50",
    textClass: "text-emerald-700",
    borrowableTokens: [V.USDC, V.DAI, V.USDT, V.EURC, V.GHO],
    isSmartSpoke: false,
  },
  {
    id: "bal-correlated",
    slug: "balancer-correlated",
    dex: "balancer",
    label: "Balancer Correlated LPs",
    description: "Stable / Composable Stable BPT",
    eMode: "enabled",
    maxLtvPct: 88,
    aprApproxPct: 3.0,
    riskPremiumBps: 45,
    liquidityUsd: 38_000_000,
    liquidationUsdApprox: 2_700,
    bgClass: "bg-sky-50",
    textClass: "text-sky-700",
    borrowableTokens: [V.WETH, V.wstETH, V.rETH, V.cbETH],
    isSmartSpoke: false,
  },
  {
    id: "bal-weighted",
    slug: "balancer-weighted",
    dex: "balancer",
    label: "Balancer Weighted LPs",
    description: "Weighted BPT",
    maxLtvPct: 60,
    aprApproxPct: 6.8,
    riskPremiumBps: 140,
    liquidityUsd: 24_000_000,
    liquidationUsdApprox: 1_350,
    bgClass: "bg-amber-50",
    textClass: "text-amber-700",
    borrowableTokens: [V.USDC, V.USDT, V.DAI, V.WETH],
    isSmartSpoke: true,
  },
  {
    id: "bal-boosted",
    slug: "balancer-boosted",
    dex: "balancer",
    label: "Balancer Boosted LPs",
    description: "Boosted BPT",
    maxLtvPct: 85,
    aprApproxPct: 4.5,
    riskPremiumBps: 55,
    liquidityUsd: 26_000_000,
    liquidationUsdApprox: 2_200,
    bgClass: "bg-teal-50",
    textClass: "text-teal-700",
    borrowableTokens: [V.USDC, V.USDT, V.DAI, V.GHO],
    isSmartSpoke: true,
  },
  {
    id: "bal-reclamm",
    slug: "balancer-reclamm",
    dex: "balancer",
    label: "Balancer reCLAMM LPs",
    description: "reCLAMM BPT",
    maxLtvPct: 72,
    aprApproxPct: 5.4,
    riskPremiumBps: 85,
    liquidityUsd: 18_000_000,
    liquidationUsdApprox: 1_900,
    bgClass: "bg-indigo-50",
    textClass: "text-indigo-700",
    borrowableTokens: [V.USDC, V.USDT, V.DAI, V.WETH],
    isSmartSpoke: true,
  },

  // -------- Aerodrome --------
  {
    id: "aero-basic-stable",
    slug: "aerodrome-stable",
    dex: "aerodrome",
    label: "Aerodrome Basic Stable LPs",
    description: "Stable LP tokens",
    eMode: "enabled",
    maxLtvPct: 88,
    aprApproxPct: 4.2,
    riskPremiumBps: 30,
    liquidityUsd: 86_000_000,
    liquidationUsdApprox: 2_050,
    bgClass: "bg-emerald-50",
    textClass: "text-emerald-700",
    borrowableTokens: [V.USDC, V.DAI, V.EURC],
    isSmartSpoke: false,
  },
  {
    id: "aero-basic-volatile",
    slug: "aerodrome-volatile",
    dex: "aerodrome",
    label: "Aerodrome Basic Volatile LPs",
    description: "Constant-product LP tokens",
    maxLtvPct: 50,
    aprApproxPct: 12.5,
    riskPremiumBps: 240,
    liquidityUsd: 64_000_000,
    liquidationUsdApprox: 950,
    bgClass: "bg-rose-50",
    textClass: "text-rose-700",
    borrowableTokens: [V.USDC, V.DAI, V.WETH],
    isSmartSpoke: false,
  },
  {
    id: "aero-slipstream-bluechip",
    slug: "aerodrome-bluechip",
    dex: "aerodrome",
    label: "Aerodrome Slipstream Blue-Chip LPs",
    description: "Concentrated-liquidity LP positions",
    maxLtvPct: 76,
    aprApproxPct: 6.2,
    riskPremiumBps: 80,
    liquidityUsd: 112_000_000,
    liquidationUsdApprox: 2_500,
    bgClass: "bg-blue-50",
    textClass: "text-blue-700",
    borrowableTokens: [V.USDC, V.DAI, V.WETH, V.cbBTC],
    isSmartSpoke: true,
  },

  // -------- Tokenized stocks --------
  {
    id: "aero-concentrated-stocks",
    slug: "aerodrome-concentrated-10",
    dex: "aerodrome",
    label: "Aerodrome Concentrated 10",
    description: "Tokenized-equity concentrated LP positions",
    maxLtvPct: 55,
    aprApproxPct: 40,
    riskPremiumBps: 180,
    liquidityUsd: 10_000_000,
    liquidationUsdApprox: 900,
    bgClass: "bg-blue-50",
    textClass: "text-blue-700",
    borrowableTokens: [V.USDC, V.GHO, V.USDT],
    isSmartSpoke: false,
  },
  {
    id: "uni-robinhood-stocks",
    slug: "uniswap-robinhood-stocks",
    dex: "uniswap",
    label: "Uniswap Robinhood Stocks",
    description: "Tokenized-equity concentrated LP positions",
    maxLtvPct: 55,
    aprApproxPct: 12,
    riskPremiumBps: 180,
    liquidityUsd: 30_000_000,
    liquidationUsdApprox: 1_100,
    bgClass: "bg-pink-50",
    textClass: "text-pink-700",
    borrowableTokens: [V.USDG, V.GHO, V.USDC, V.USDT],
    isSmartSpoke: false,
  },
]

// -----------------------------------------------------------------------------
// Dexes — 4 entries. `bgClass`/`textClass` map to the mock's `pillBgClass`/
// `pillTextClass`; `dotClass` is UI chrome and not carried into Convex.
// -----------------------------------------------------------------------------
export const DEXES_SEED_ROWS: SeedDexRow[] = [
  { id: "uniswap", label: "Uniswap", tvlUsd: 5_680_000_000, bgClass: "bg-pink-50", textClass: "text-pink-700" },
  { id: "curve", label: "Curve", tvlUsd: 1_830_000_000, bgClass: "bg-rose-50", textClass: "text-rose-700" },
  { id: "balancer", label: "Balancer", tvlUsd: 158_180_000, bgClass: "bg-muted", textClass: "text-foreground" },
  { id: "aerodrome", label: "Aerodrome", tvlUsd: 356_440_000, bgClass: "bg-blue-50", textClass: "text-blue-700" },
]
