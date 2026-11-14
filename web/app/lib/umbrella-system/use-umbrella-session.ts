"use client"

import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { SESSION_CACHE_VERSION } from "@/app/lib/session-cache-version"
import { safeReadParsed, safeRemoveItem, safeSetItem } from "@/app/lib/safe-local-storage"
import { sandboxBaselinePriceUsd } from "@/app/lib/prices/sandbox-baseline-prices"

export type UmbrellaMarketId = "gho" | "usdc" | "usdt" | "weth"
export type UmbrellaActionKind = "stake" | "claim" | "startCooldown" | "unstake"

export type UmbrellaMarket = {
  id: UmbrellaMarketId
  asset: string
  symbol: string
  hubLabel: string
  coverage: string
  totalStakedUsd: number
  apy: number
  baseApy: number
  liquidationRecaptureApy: number
  incentiveApy: number
  rewardApy: number
  priceUsd: number
  targetCoverageUsd: number
  localDeductibleUsd: number
  hubTailTargetUsd: number
  coverageMode: string
  currentDeficitUsd: number
  deficitOffsetUsd: number
  amountInCooldownUsd: number
  /** Cumulative slashed USD. Optional: fallback markets have no live overlay row. */
  totalSlashedUsd?: number
}

/** Union used by cooldownLabel + UI: adds "expired" when the withdrawal window has passed. */
export type UmbrellaCooldownStatus = "idle" | "cooling" | "ready" | "expired"

/**
 * Local mirror of the server tranche shape. startCooldown appends one; unstake consumes them FIFO
 * across the "ready" bucket. Status is re-derived from Date.now() on every rule check, so idle
 * time needs no background sweep.
 */
export type UmbrellaTranche = {
  id: string
  amountUsd: number
  startedAt: number
  endsAt: number
  windowEndsAt: number
  status: "cooling" | "ready" | "expired"
}

export type UmbrellaPosition = {
  marketId: UmbrellaMarketId
  amount: number
  valueUsd: number
  pendingRewardsUsd: number
  claimedRewardsUsd: number
  cooldownAmount: number
  cooldownValueUsd: number
  cooldownStatus: UmbrellaCooldownStatus
  cooldownRemaining: string
  removesIn: string
  /** ms epoch — end of the earliest active tranche's 20-day cooldown; undefined when idle. */
  cooldownEndsAt?: number
  /** ms epoch — end of the earliest ready tranche's 2-day withdrawal window; undefined when idle. */
  withdrawalWindowEndsAt?: number
  /** True when at least one tranche is past its withdrawal window with cooling USD still on it. */
  withdrawalWindowExpired: boolean
  /**
   * Cumulative USD principal removed by slashes; 0 when never slashed. Convex-driven and
   * persisted by the `simulateSlash` mutation — "simulate" means no chain, not client-synthetic.
   */
  slashedValueUsd: number
  /**
   * Per-tranche breakdown, sorted by endsAt ascending and never containing an `"idle"` tranche.
   * `cooldownAmount`/`cooldownValueUsd` are the sum; `cooldownStatus` is the worst live status.
   */
  tranches: UmbrellaTranche[]
  updatedAt: number
}

export type UmbrellaTransaction = {
  id: string
  walletId: string
  kind: UmbrellaActionKind
  marketId: UmbrellaMarketId
  symbol: string
  amount: number
  amountUsd: number
  status: "success" | "failed"
  hash: string
  timestamp: number
}

type UmbrellaState = {
  walletId: string
  walletBalances: Record<UmbrellaMarketId, number>
  markets: Record<UmbrellaMarketId, UmbrellaMarket>
  positions: Record<UmbrellaMarketId, UmbrellaPosition>
  transactions: UmbrellaTransaction[]
}

export type ConvexUmbrellaSessionState = {
  walletId: string
  markets?: Record<UmbrellaMarketId, UmbrellaMarket>
  walletBalances: Record<UmbrellaMarketId, number>
  positions: Array<{
    marketId: UmbrellaMarketId
    suppliedUsd: number
    amount: number
    pendingRewardsUsd: number
    claimedRewardsUsd: number
    cooldownUsd: number
    cooldownStartedAt?: number
    cooldownEndsAt?: number
    withdrawalWindowEndsAt?: number
    /** Server-computed: withdrawalWindowEndsAt < now && cooldownUsd > 0. */
    withdrawalWindowExpired: boolean
    /** Cumulative USD principal removed by slashes; persisted in Convex as slashedAmountUsd6
     *  by the simulateSlash mutation (Convex-driven, not client-synthetic). */
    slashedAmountUsd?: number
    status: "open" | "closed"
    lastUpdatedAt: number
    /**
     * Optional so pre-tranche seeds and older server payloads still hydrate; when absent the
     * aggregate cooldownUsd drives a synthetic single-tranche view.
     */
    tranches?: Array<{
      _id: string
      amountUsd: number
      startedAt: number
      endsAt: number
      windowEndsAt: number
      status: "cooling" | "ready" | "expired"
    }>
  }>
  transactions: Array<{
    id: string
    kind: UmbrellaActionKind
    marketId: UmbrellaMarketId
    amountUsd: number
    syntheticTxHash: string
    status: "success" | "failed" | "pending"
    at: number
  }>
}

export type PersistUmbrellaActionResult = { receipt?: { syntheticTxHash?: string } } | undefined | void | unknown

export type PersistUmbrellaAction = (args: {
  intentId: string
  kind: UmbrellaActionKind
  marketId: UmbrellaMarketId
  amount: number
}) => Promise<PersistUmbrellaActionResult>

/** Marks a Convex-backed session as pending so wallet metrics stay at zero until remote data arrives. */
export const pendingUmbrellaPersistAction: PersistUmbrellaAction = async () => {
  throw new Error("Umbrella session not ready")
}

const UMBRELLA_STATE_PREFIX = `avana.umbrella.session.${SESSION_CACHE_VERSION}`

export const UMBRELLA_MARKET_ORDER: UmbrellaMarketId[] = ["gho", "usdc", "usdt", "weth"]

function stateKey(walletId: string) {
  return `${UMBRELLA_STATE_PREFIX}:${walletId}`
}

function txHash(id: string) {
  let hash = 0
  for (const char of id) hash = (hash * 31 + char.charCodeAt(0)) >>> 0
  return `0xumb${hash.toString(16).padStart(8, "0")}`
}

export function buildDefaultUmbrellaState(walletId: string): UmbrellaState {
  const now = Date.UTC(2026, 7, 14, 12)
  const markets: Record<UmbrellaMarketId, UmbrellaMarket> = {
    gho: {
      id: "gho",
      asset: "Stake GHO",
      symbol: "GHO",
      hubLabel: "Stable Hub",
      coverage: "GHO deficits",
      totalStakedUsd: 25_000_000,
      apy: 6.4,
      baseApy: 0,
      liquidationRecaptureApy: 2.25,
      incentiveApy: 4.15,
      rewardApy: 6.4,
      priceUsd: sandboxBaselinePriceUsd("GHO"),
      targetCoverageUsd: 22_000_000,
      localDeductibleUsd: 250_000,
      hubTailTargetUsd: 30_000_000,
      coverageMode: "Live Umbrella",
      currentDeficitUsd: 146,
      deficitOffsetUsd: 1_000_000,
      amountInCooldownUsd: 2_500_000,
    },
    usdc: {
      id: "usdc",
      asset: "Stake USDC",
      symbol: "USDC",
      hubLabel: "Stable Hub",
      coverage: "USDC deficits",
      totalStakedUsd: 12_000_000,
      apy: 4.84,
      baseApy: 1.72,
      liquidationRecaptureApy: 1.25,
      incentiveApy: 1.87,
      rewardApy: 3.12,
      priceUsd: sandboxBaselinePriceUsd("USDC"),
      targetCoverageUsd: 10_000_000,
      localDeductibleUsd: 100_000,
      hubTailTargetUsd: 15_000_000,
      coverageMode: "Live Umbrella",
      currentDeficitUsd: 51_371,
      deficitOffsetUsd: 500_000,
      amountInCooldownUsd: 1_150_000,
    },
    usdt: {
      id: "usdt",
      asset: "Stake USDT",
      symbol: "USDT",
      hubLabel: "Correlated Hub",
      coverage: "USDT deficits",
      totalStakedUsd: 11_000_000,
      apy: 4.19,
      baseApy: 1.34,
      liquidationRecaptureApy: 1.15,
      incentiveApy: 1.7,
      rewardApy: 2.85,
      priceUsd: sandboxBaselinePriceUsd("USDT"),
      targetCoverageUsd: 9_500_000,
      localDeductibleUsd: 100_000,
      hubTailTargetUsd: 14_000_000,
      coverageMode: "Live Umbrella",
      currentDeficitUsd: 32_420,
      deficitOffsetUsd: 400_000,
      amountInCooldownUsd: 980_000,
    },
    weth: {
      id: "weth",
      asset: "Stake WETH",
      symbol: "WETH",
      hubLabel: "Correlated Hub",
      coverage: "WETH deficits",
      totalStakedUsd: 7_000_000,
      apy: 5.05,
      baseApy: 2.65,
      liquidationRecaptureApy: 1.2,
      incentiveApy: 1.2,
      rewardApy: 2.4,
      // WETH priced from the app-wide baseline (1934); the seeded WETH position value
      // below is amount × this, so valueUsd === amount × priceUsd (how the session
      // recomputes displayed value after every action).
      priceUsd: sandboxBaselinePriceUsd("WETH"),
      targetCoverageUsd: 6_250_000,
      localDeductibleUsd: 150_000,
      hubTailTargetUsd: 10_000_000,
      coverageMode: "Live Umbrella",
      currentDeficitUsd: 52_973,
      deficitOffsetUsd: 250_000,
      amountInCooldownUsd: 520_000,
    },
  }

  return {
    walletId,
    walletBalances: { gho: 20_000, usdc: 25_000, usdt: 15_000, weth: 5 },
    markets,
    positions: {
      gho: {
        marketId: "gho",
        amount: 9500,
        valueUsd: 9500,
        pendingRewardsUsd: 26.14,
        claimedRewardsUsd: 0,
        cooldownAmount: 0,
        cooldownValueUsd: 0,
        cooldownStatus: "idle",
        cooldownRemaining: "-",
        removesIn: "After 20 days",
        withdrawalWindowExpired: false,
        slashedValueUsd: 0,
        tranches: [],
        updatedAt: now,
      },
      usdc: {
        marketId: "usdc",
        amount: 12_000,
        valueUsd: 12_000,
        pendingRewardsUsd: 18.72,
        claimedRewardsUsd: 0,
        cooldownAmount: 3000,
        cooldownValueUsd: 3000,
        cooldownStatus: "cooling",
        cooldownRemaining: "4d 11h",
        removesIn: "4d 11h",
        cooldownEndsAt: now + 4 * 24 * 60 * 60 * 1000 + 11 * 60 * 60 * 1000,
        withdrawalWindowEndsAt: now + 4 * 24 * 60 * 60 * 1000 + 11 * 60 * 60 * 1000 + 2 * 24 * 60 * 60 * 1000,
        withdrawalWindowExpired: false,
        slashedValueUsd: 0,
        tranches: [
          {
            id: `seed-usdc-cool`,
            amountUsd: 3000,
            startedAt: now - (20 - 4) * 24 * 60 * 60 * 1000 - 11 * 60 * 60 * 1000,
            endsAt: now + 4 * 24 * 60 * 60 * 1000 + 11 * 60 * 60 * 1000,
            windowEndsAt: now + 4 * 24 * 60 * 60 * 1000 + 11 * 60 * 60 * 1000 + 2 * 24 * 60 * 60 * 1000,
            status: "cooling",
          },
        ],
        updatedAt: now,
      },
      usdt: {
        marketId: "usdt",
        amount: 11_000,
        valueUsd: 11_000,
        pendingRewardsUsd: 12.4,
        claimedRewardsUsd: 0,
        cooldownAmount: 5000,
        cooldownValueUsd: 5000,
        cooldownStatus: "ready",
        cooldownRemaining: "Ready",
        removesIn: "0d 0h",
        cooldownEndsAt: now - 1000,
        withdrawalWindowEndsAt: now + 2 * 24 * 60 * 60 * 1000,
        withdrawalWindowExpired: false,
        slashedValueUsd: 0,
        tranches: [
          {
            id: `seed-usdt-ready`,
            amountUsd: 5000,
            startedAt: now - 20 * 24 * 60 * 60 * 1000 - 1000,
            endsAt: now - 1000,
            windowEndsAt: now + 2 * 24 * 60 * 60 * 1000,
            status: "ready",
          },
        ],
        updatedAt: now,
      },
      weth: {
        marketId: "weth",
        amount: 3.125,
        // 3.125 WETH × 1934 = 6043.75. Kept consistent with the market priceUsd above.
        valueUsd: 6043.75,
        pendingRewardsUsd: 9.2,
        claimedRewardsUsd: 0,
        cooldownAmount: 0,
        cooldownValueUsd: 0,
        cooldownStatus: "idle",
        cooldownRemaining: "-",
        removesIn: "After 20 days",
        withdrawalWindowExpired: false,
        slashedValueUsd: 0,
        tranches: [],
        updatedAt: now,
      },
    },
    transactions: [],
  }
}

function readUmbrellaState(walletId: string) {
  return safeReadParsed<UmbrellaState>(
    stateKey(walletId),
    (raw) => JSON.parse(raw) as UmbrellaState,
    () => buildDefaultUmbrellaState(walletId),
  )
}

function writeUmbrellaState(walletId: string, state: UmbrellaState) {
  safeSetItem(stateKey(walletId), JSON.stringify(state))
}

function clampAmount(value: number) {
  return Number.isFinite(value) ? Math.max(0, value) : 0
}

function emptyPosition(marketId: UmbrellaMarketId, now: number): UmbrellaPosition {
  return {
    marketId,
    amount: 0,
    valueUsd: 0,
    pendingRewardsUsd: 0,
    claimedRewardsUsd: 0,
    cooldownAmount: 0,
    cooldownValueUsd: 0,
    cooldownStatus: "idle",
    cooldownRemaining: "-",
    removesIn: "After 20 days",
    withdrawalWindowExpired: false,
    slashedValueUsd: 0,
    tranches: [],
    updatedAt: now,
  }
}

/** Worst live tranche status (expired > ready > cooling > idle). Mirrors the server rule. */
function statusFromTranches(tranches: UmbrellaTranche[]): UmbrellaCooldownStatus {
  if (tranches.length === 0) return "idle"
  if (tranches.some((t) => t.status === "expired" && t.amountUsd > 0)) return "expired"
  if (tranches.some((t) => t.status === "ready")) return "ready"
  if (tranches.some((t) => t.status === "cooling")) return "cooling"
  return "idle"
}

/** Refresh tranche statuses against `now`; shared by the offline path and stateFromConvex. */
function refreshTranches(tranches: UmbrellaTranche[], now: number): UmbrellaTranche[] {
  return tranches
    .filter((t) => t.amountUsd > 0)
    .map((t) => ({
      ...t,
      status: now < t.endsAt ? ("cooling" as const) : now < t.windowEndsAt ? ("ready" as const) : ("expired" as const),
    }))
}

function formatRemaining(ms: number) {
  const remainingHours = Math.ceil(ms / (60 * 60 * 1000))
  const days = Math.floor(remainingHours / 24)
  const hours = remainingHours % 24
  return `${days}d ${hours}h`
}

/** Aggregate cooldown labels; the status follows the worst-status rule so the CTA matches Convex. */
function trancheLabels(
  tranches: UmbrellaTranche[],
  now: number,
): {
  status: UmbrellaCooldownStatus
  remaining: string
  removesIn: string
  cooldownEndsAt?: number
  withdrawalWindowEndsAt?: number
  withdrawalWindowExpired: boolean
} {
  const status = statusFromTranches(tranches)
  if (status === "idle") {
    return {
      status,
      remaining: "-",
      removesIn: "After 20 days",
      withdrawalWindowExpired: false,
    }
  }
  const activeEnds = tranches.filter((t) => t.status !== "expired").map((t) => t.endsAt)
  const readyWindows = tranches.filter((t) => t.status === "ready").map((t) => t.windowEndsAt)
  const cooldownEndsAt = activeEnds.length > 0 ? Math.min(...activeEnds) : tranches[0]?.endsAt
  const withdrawalWindowEndsAt = readyWindows.length > 0 ? Math.min(...readyWindows) : tranches[0]?.windowEndsAt
  const withdrawalWindowExpired = tranches.some((t) => t.status === "expired" && t.amountUsd > 0)
  if (status === "expired") {
    return {
      status,
      remaining: "Expired",
      removesIn: "Restart",
      cooldownEndsAt,
      withdrawalWindowEndsAt,
      withdrawalWindowExpired,
    }
  }
  if (status === "ready") {
    return {
      status,
      remaining: "Ready",
      removesIn: "0d 0h",
      cooldownEndsAt,
      withdrawalWindowEndsAt,
      withdrawalWindowExpired,
    }
  }
  const remaining = cooldownEndsAt !== undefined ? formatRemaining(cooldownEndsAt - now) : "-"
  return { status, remaining, removesIn: remaining, cooldownEndsAt, withdrawalWindowEndsAt, withdrawalWindowExpired }
}

function stateFromConvex(walletId: string, remote: ConvexUmbrellaSessionState): UmbrellaState {
  const fallback = buildDefaultUmbrellaState(walletId)
  // Convex can briefly return an older market shape while client and server roll forward
  // independently, so merge each remote row over the local catalog: new surface metadata stays
  // available and Convex still owns every live wallet/risk value.
  const markets = Object.fromEntries(
    UMBRELLA_MARKET_ORDER.map((marketId) => [
      marketId,
      { ...fallback.markets[marketId], ...remote.markets?.[marketId] },
    ]),
  ) as Record<UmbrellaMarketId, UmbrellaMarket>
  const now = Date.now()
  // Positions and balances come from Convex — never fold in the demo seed here or the UI
  // shows fake stakes for a real wallet that hasn't onboarded. Start every market at idle
  // and let the remote payload fill in the ones this wallet actually holds.
  const positions: Record<UmbrellaMarketId, UmbrellaPosition> = {
    gho: emptyPosition("gho", now),
    usdc: emptyPosition("usdc", now),
    usdt: emptyPosition("usdt", now),
    weth: emptyPosition("weth", now),
  }
  for (const remotePosition of remote.positions) {
    const market = markets[remotePosition.marketId]
    // Prefer the server's per-tranche breakdown; fall back to a single
    // synthetic tranche derived from the aggregate for older/seeded payloads.
    const remoteTranches: UmbrellaTranche[] = (remotePosition.tranches ?? []).map((t) => ({
      id: t._id,
      amountUsd: t.amountUsd,
      startedAt: t.startedAt,
      endsAt: t.endsAt,
      windowEndsAt: t.windowEndsAt,
      status: t.status,
    }))
    const tranches =
      remoteTranches.length > 0
        ? refreshTranches(remoteTranches, now)
        : remotePosition.cooldownUsd > 0 &&
            remotePosition.cooldownStartedAt !== undefined &&
            remotePosition.cooldownEndsAt !== undefined &&
            remotePosition.withdrawalWindowEndsAt !== undefined
          ? refreshTranches(
              [
                {
                  id: `synthetic-${remotePosition.marketId}`,
                  amountUsd: remotePosition.cooldownUsd,
                  startedAt: remotePosition.cooldownStartedAt,
                  endsAt: remotePosition.cooldownEndsAt,
                  windowEndsAt: remotePosition.withdrawalWindowEndsAt,
                  status: "cooling",
                },
              ],
              now,
            )
          : []
    const labels = trancheLabels(tranches, now)
    positions[remotePosition.marketId] = {
      marketId: remotePosition.marketId,
      amount: remotePosition.amount,
      valueUsd: remotePosition.suppliedUsd,
      pendingRewardsUsd: remotePosition.pendingRewardsUsd,
      claimedRewardsUsd: remotePosition.claimedRewardsUsd,
      cooldownAmount: market.priceUsd > 0 ? remotePosition.cooldownUsd / market.priceUsd : remotePosition.cooldownUsd,
      cooldownValueUsd: remotePosition.cooldownUsd,
      cooldownStatus: labels.status,
      cooldownRemaining: labels.remaining,
      removesIn: labels.removesIn,
      cooldownEndsAt: labels.cooldownEndsAt ?? remotePosition.cooldownEndsAt,
      withdrawalWindowEndsAt: labels.withdrawalWindowEndsAt ?? remotePosition.withdrawalWindowEndsAt,
      withdrawalWindowExpired: labels.withdrawalWindowExpired || remotePosition.withdrawalWindowExpired,
      slashedValueUsd: remotePosition.slashedAmountUsd ?? 0,
      tranches,
      updatedAt: remotePosition.lastUpdatedAt,
    }
  }
  const emptyBalances: Record<UmbrellaMarketId, number> = { gho: 0, usdc: 0, usdt: 0, weth: 0 }
  return {
    walletId,
    walletBalances: { ...emptyBalances, ...remote.walletBalances },
    markets,
    positions,
    transactions: remote.transactions.map((row) => {
      const market = markets[row.marketId]
      return {
        id: row.id,
        walletId,
        kind: row.kind,
        marketId: row.marketId,
        symbol: market.symbol,
        amount: market.priceUsd > 0 ? row.amountUsd / market.priceUsd : row.amountUsd,
        amountUsd: row.amountUsd,
        status: row.status === "pending" ? "success" : row.status,
        hash: row.syntheticTxHash,
        timestamp: row.at,
      }
    }),
  }
}

function emptyConvexUmbrellaState(walletId: string): UmbrellaState {
  return stateFromConvex(walletId, {
    walletId,
    walletBalances: { gho: 0, usdc: 0, usdt: 0, weth: 0 },
    positions: [],
    transactions: [],
  })
}

export function useUmbrellaSession({
  walletId,
  persistState = true,
  remoteState,
  persistAction,
  seedDemoState = true,
}: {
  walletId: string
  persistState?: boolean
  remoteState?: ConvexUmbrellaSessionState | null
  persistAction?: PersistUmbrellaAction
  /** Seed the local-test demo stakes and balances. False for Convex sessions (a guest has none). */
  seedDemoState?: boolean
}) {
  const expectsRemoteState = Boolean(persistAction)
  const seededState = useMemo(
    () => (seedDemoState ? buildDefaultUmbrellaState(walletId) : emptyConvexUmbrellaState(walletId)),
    [seedDemoState, walletId],
  )
  const [state, setState] = useState<UmbrellaState>(() =>
    expectsRemoteState ? emptyConvexUmbrellaState(walletId) : seededState,
  )
  const stateRef = useRef(state)
  stateRef.current = state
  // Hydrated (mirrors lend/borrow) once Convex has responded at least once, or immediately when
  // no remoteState is expected (test / SSR-only); otherwise still fetching.
  const remoteSettledRef = useRef(false)
  const [isHydrated, setIsHydrated] = useState(() => !expectsRemoteState && !persistState && remoteState === undefined)

  useEffect(() => {
    if (remoteState !== undefined) {
      remoteSettledRef.current = true
      setIsHydrated(true)
    } else if (!persistState && !expectsRemoteState) {
      remoteSettledRef.current = false
      setIsHydrated(true)
    } else {
      remoteSettledRef.current = false
      setIsHydrated(false)
    }
  }, [expectsRemoteState, persistState, remoteState])

  useEffect(() => {
    if (remoteState) {
      setState(stateFromConvex(walletId, remoteState))
      return
    }
    if (expectsRemoteState) {
      setState(emptyConvexUmbrellaState(walletId))
      return
    }
    setState(persistState ? readUmbrellaState(walletId) : seededState)
  }, [expectsRemoteState, persistState, remoteState, seededState, walletId])

  useEffect(() => {
    if (!persistState || state.walletId !== walletId) return
    writeUmbrellaState(walletId, state)
  }, [persistState, state, walletId])

  const execute = useCallback(
    async (kind: UmbrellaActionKind, marketId: UmbrellaMarketId, rawAmount: number): Promise<UmbrellaTransaction> => {
      const amount = clampAmount(rawAmount)
      if (kind !== "claim" && amount <= 0) throw new Error("Amount must be positive")

      // Convex owns validation, accrual and withdrawal-window checks when it is the source of
      // truth. Do NOT re-apply those rules locally here — a partial local copy makes the UI
      // disagree with the server for the round-trip.
      if (persistAction) {
        const currentState = stateRef.current
        const market = currentState.markets[marketId]
        const timestamp = Date.now()
        const intentId = `umbrella-${kind}-${marketId}-${timestamp}`
        let result: PersistUmbrellaActionResult
        try {
          result = await persistAction({ intentId, kind, marketId, amount })
        } catch (error) {
          throw error instanceof Error ? error : new Error(String(error))
        }
        const amountUsd =
          kind === "claim" ? (currentState.positions[marketId]?.pendingRewardsUsd ?? 0) : amount * market.priceUsd
        const receipt =
          result && typeof result === "object" && "receipt" in result
            ? (result as { receipt?: { syntheticTxHash?: string } }).receipt
            : undefined
        const hash = receipt?.syntheticTxHash ?? `pending-${intentId}`
        return {
          id: intentId,
          walletId,
          kind,
          marketId,
          symbol: market.symbol,
          amount,
          amountUsd,
          status: "success",
          hash,
          timestamp,
        }
      }

      // Local-only (tests / offline): must mirror the Convex `recordAction` rules exactly,
      // including multiple concurrent tranches per market each on its own 20-day / 2-day clock.
      let result: UmbrellaTransaction | null = null
      setState((current) => {
        const market = current.markets[marketId]
        const position = current.positions[marketId]
        const balance = current.walletBalances[marketId] ?? 0
        const amountUsd = amount * market.priceUsd
        const timestamp = Date.now()
        const liveTranches = refreshTranches(position.tranches, timestamp)
        // Expired tranches (past the 2-day withdrawal window) release their stake back to the
        // active pool — the withdrawal never happened — so only cooling/ready tranches lock stake
        // against the "active supplied" budget. Mirrors the Convex read model.
        const activeCoolingUsd = liveTranches
          .filter((t) => t.status !== "expired")
          .reduce((sum, t) => sum + t.amountUsd, 0)

        if (kind === "stake" && amount > balance) throw new Error(`Insufficient ${market.symbol} balance`)
        if (kind === "startCooldown") {
          if (amount > position.amount - activeCoolingUsd + 1e-9) {
            throw new Error(`Insufficient active ${market.symbol}`)
          }
        }
        if (kind === "unstake") {
          const readyTranches = liveTranches.filter((t) => t.status === "ready").sort((a, b) => a.endsAt - b.endsAt)
          const expiredWithCooling = liveTranches.some((t) => t.status === "expired" && t.amountUsd > 0)
          const readyUsd = readyTranches.reduce((sum, t) => sum + t.amountUsd, 0)
          if (readyTranches.length === 0) {
            if (expiredWithCooling) throw new Error(`Withdrawal window expired — restart cooldown`)
            throw new Error(`Cooldown not ready`)
          }
          if (amount > readyUsd + 1e-9) throw new Error(`Insufficient cooled ${market.symbol}`)
        }
        if (kind === "claim" && position.pendingRewardsUsd <= 0) throw new Error("No Umbrella rewards to claim")

        // Post-mutation tranche list.
        let nextTranches = liveTranches
        if (kind === "startCooldown") {
          // Drop expired tranches: their stake has already returned to the active
          // pool, so carrying them forward would leave the position stuck showing
          // "expired" and keep counting that stake as cooling.
          nextTranches = [
            ...liveTranches.filter((t) => t.status !== "expired"),
            {
              id: `local-tranche-${marketId}-${timestamp}`,
              amountUsd,
              startedAt: timestamp,
              endsAt: timestamp + 20 * 24 * 60 * 60 * 1000,
              windowEndsAt: timestamp + 22 * 24 * 60 * 60 * 1000,
              status: "cooling",
            },
          ]
        } else if (kind === "unstake") {
          const sorted = [...liveTranches].sort((a, b) => a.endsAt - b.endsAt)
          let remaining = amount
          const consumed: UmbrellaTranche[] = []
          for (const t of sorted) {
            // Expired tranches return to active — never carry them forward.
            if (t.status === "expired") continue
            if (remaining <= 1e-9 || t.status !== "ready") {
              consumed.push(t)
              continue
            }
            const take = Math.min(t.amountUsd, remaining)
            remaining -= take
            const nextUsd = t.amountUsd - take
            if (nextUsd > 1e-9) consumed.push({ ...t, amountUsd: nextUsd })
          }
          nextTranches = consumed
        }
        nextTranches = refreshTranches(nextTranches, timestamp)
        const nextLabels = trancheLabels(nextTranches, timestamp)
        const nextCoolingUsd = nextTranches.reduce((sum, t) => sum + t.amountUsd, 0)

        const nextBalance = kind === "stake" ? balance - amount : kind === "unstake" ? balance + amount : balance
        const nextPositionAmount =
          kind === "stake" ? position.amount + amount : kind === "unstake" ? position.amount - amount : position.amount
        const nextPositionValueUsd = nextPositionAmount * market.priceUsd
        const id = `umbrella-${kind}-${marketId}-${timestamp}`
        const txAmountUsd = kind === "claim" ? position.pendingRewardsUsd : amountUsd
        result = {
          id,
          walletId,
          kind,
          marketId,
          symbol: market.symbol,
          amount,
          amountUsd: txAmountUsd,
          status: "success",
          hash: txHash(id),
          timestamp,
        }

        return {
          ...current,
          walletBalances: { ...current.walletBalances, [marketId]: nextBalance },
          markets: {
            ...current.markets,
            [marketId]: {
              ...market,
              totalStakedUsd:
                kind === "stake"
                  ? market.totalStakedUsd + amountUsd
                  : kind === "unstake"
                    ? Math.max(0, market.totalStakedUsd - amountUsd)
                    : market.totalStakedUsd,
            },
          },
          positions: {
            ...current.positions,
            [marketId]: {
              ...position,
              amount: nextPositionAmount,
              valueUsd: nextPositionValueUsd,
              pendingRewardsUsd: kind === "claim" ? 0 : position.pendingRewardsUsd,
              claimedRewardsUsd:
                kind === "claim" ? position.claimedRewardsUsd + position.pendingRewardsUsd : position.claimedRewardsUsd,
              cooldownAmount: market.priceUsd > 0 ? nextCoolingUsd / market.priceUsd : nextCoolingUsd,
              cooldownValueUsd: nextCoolingUsd,
              cooldownStatus: nextLabels.status,
              cooldownRemaining: nextLabels.remaining,
              removesIn: nextLabels.removesIn,
              cooldownEndsAt: nextLabels.cooldownEndsAt,
              withdrawalWindowEndsAt: nextLabels.withdrawalWindowEndsAt,
              withdrawalWindowExpired: nextLabels.withdrawalWindowExpired,
              tranches: nextTranches,
              updatedAt: timestamp,
            },
          },
          transactions: [result, ...current.transactions],
        }
      })

      if (!result) throw new Error("Umbrella transaction failed")
      return result
    },
    [persistAction, walletId],
  )

  const reset = useCallback(() => {
    if (persistState) safeRemoveItem(stateKey(walletId))
    setState(buildDefaultUmbrellaState(walletId))
  }, [persistState, walletId])

  const stake = useCallback(
    (marketId: UmbrellaMarketId, amount: number) => execute("stake", marketId, amount),
    [execute],
  )
  const claim = useCallback((marketId: UmbrellaMarketId) => execute("claim", marketId, 0), [execute])
  const startCooldown = useCallback(
    (marketId: UmbrellaMarketId, amount: number) => execute("startCooldown", marketId, amount),
    [execute],
  )
  const unstake = useCallback(
    (marketId: UmbrellaMarketId, amount: number) => execute("unstake", marketId, amount),
    [execute],
  )

  const markets = state.markets
  const walletBalances = state.walletBalances
  const positions = state.positions
  const transactionHistory = state.transactions

  return useMemo(
    () => ({
      walletId,
      markets,
      marketOrder: UMBRELLA_MARKET_ORDER,
      walletBalances,
      positions,
      transactionHistory,
      isHydrated,
      stake,
      claim,
      startCooldown,
      unstake,
      reset,
    }),
    [
      walletId,
      markets,
      walletBalances,
      positions,
      transactionHistory,
      isHydrated,
      stake,
      claim,
      startCooldown,
      unstake,
      reset,
    ],
  )
}
