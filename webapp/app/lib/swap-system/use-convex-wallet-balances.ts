"use client"

/**
 * A wallet's balances by product, read live from the chain. Lend and borrow positions are read by their own
 * sessions; this hook gives the wallet's tokens and unpledged LP NFTs.
 */

import { useCallback, useEffect, useMemo, useSyncExternalStore } from "react"
import { useQuery } from "convex/react"
import { isAddress, type Address } from "viem"
import { api } from "@/convex/_generated/api"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import { chainPublicClient } from "@/app/lib/chain/public-client"
import { chainIds } from "@/app/lib/chains"
import { useActiveChainKey } from "@/app/lib/web3/active-chain"
import { SWAP_ASSETS } from "./catalog"
import { readChainWallet, type WalletLpPosition } from "./chain-wallet-balances"
import type { UserAssetBalance } from "./contracts"

/**
 * Per-token cost basis of the wallet's holdings, keyed by lowercased assetId. No source exists yet
 * (it needs the indexer's per-wallet history), so it is always empty and the P/L shows as unavailable.
 */
export function useConvexClaimBasis(_walletId: string | null | undefined): Record<string, number> | undefined {
  return EMPTY_BASIS
}

const EMPTY_BASIS: Record<string, number> = {}

/** "Member since" and boost of the Wallet Overview tiles: no source yet, so both are null. */
export function useConvexWalletOnboardingSummary(
  _walletId: string | null | undefined,
): { sinceMs: number | null; boost: number | null } | undefined {
  return NO_SUMMARY
}

const NO_SUMMARY = { sinceMs: null, boost: null }

const NO_BALANCES: UserAssetBalance[] = []

/**
 * The wallet's balances on the chain picked in the Network preference, read from the chain (`chain-wallet-balances.ts`):
 * its tokens as "wallet" rows and its LP NFTs that an Avana market accepts as "borrow_collateral_unpledged" rows. The
 * tokens and markets come from Convex (`deployments.swapContractsOf`, `collateralMarkets.list`). Read again on each new
 * block and after a swap. Undefined while loading; empty for a guest id or without a Convex deployment.
 */
export function useConvexProductWalletBalances(walletId: string | null | undefined): UserAssetBalance[] | undefined {
  // Without a deployment there is no ConvexProvider and nothing to read. `hasConvexClient` is a
  // build-time constant, so every render takes the same branch.
  if (!hasConvexClient) return NO_BALANCES
  return useChainWalletBalances(walletId)
}

function useChainWalletBalances(walletId: string | null | undefined): UserAssetBalance[] | undefined {
  const read = useChainWalletRead(walletId)
  // Rows carry the session's wallet id as given (it may be checksummed), as the row builders match on it.
  return useMemo(
    () => (read === null ? NO_BALANCES : read?.rows.map((row) => ({ ...row, walletId: walletId ?? row.walletId }))),
    [read, walletId],
  )
}

const NO_LP_POSITIONS: WalletLpPosition[] = []

/**
 * The wallet's LP NFTs on the active chain, from the same read as its balances: each with the market that accepts it
 * (`market`, with the position key, units and value to pledge it), or `market: null` for an NFT no market accepts,
 * which cannot be pledged. Undefined while loading; empty for a guest id, without Convex or without an RPC.
 */
export function useWalletLpPositions(walletId: string | null | undefined): WalletLpPosition[] | undefined {
  if (!hasConvexClient) return NO_LP_POSITIONS
  // `hasConvexClient` is a build-time constant, so every render takes the same branch.
  const read = useChainWalletRead(walletId)
  return read === null ? NO_LP_POSITIONS : read?.lpPositions
}

type ChainWalletRead = { rows: UserAssetBalance[]; lpPositions: WalletLpPosition[] }

/** The shared chain read of a wallet on the active chain: null when there is nothing to read, undefined while loading. */
function useChainWalletRead(walletId: string | null | undefined): ChainWalletRead | null | undefined {
  const chainId = chainIds()[useActiveChainKey()]
  const wallet = walletId && isAddress(walletId) ? (walletId.toLowerCase() as Address) : null
  const contracts = useQuery(api.deployments.swapContractsOf, wallet ? { chainId } : "skip")
  const markets = useQuery(api.collateralMarkets.list, wallet ? { chainId } : "skip")
  // A chain without an RPC on this network has nothing to read.
  const client = wallet ? chainPublicClient(chainId) : null
  const key = wallet && client ? `${chainId}:${wallet}` : null
  const balances = useSyncExternalStore(
    useCallback((listener: () => void) => (key ? subscribeBalances(key, listener) : () => {}), [key]),
    () => (key ? balancesSnapshot(key) : null),
    () => undefined,
  )

  useEffect(() => {
    if (!key || !wallet || !client || contracts === undefined || markets === undefined) return
    return startBalanceReads(
      key,
      () =>
        readChainWallet({
          client,
          chainId,
          wallet,
          tokens: contracts?.tokens ?? [],
          markets,
          assets: SWAP_ASSETS,
        }),
      client,
    )
  }, [key, wallet, client, chainId, contracts, markets])

  return key ? balances : null
}

type BalanceEntry = { read: ChainWalletRead | undefined; listeners: Set<() => void>; refresh: (() => void) | null }

const entries = new Map<string, BalanceEntry>()

function entryOf(key: string): BalanceEntry {
  let entry = entries.get(key)
  if (!entry) {
    entry = { read: undefined, listeners: new Set(), refresh: null }
    entries.set(key, entry)
  }
  return entry
}

function subscribeBalances(key: string, listener: () => void) {
  const entry = entryOf(key)
  entry.listeners.add(listener)
  return () => entry.listeners.delete(listener)
}

function balancesSnapshot(key: string): ChainWalletRead | undefined {
  return entries.get(key)?.read
}

/**
 * Reads now, then on each new block, one read at a time; returns the stop function. Several hooks on the same wallet
 * and chain share one read: a second start only adds a reference.
 */
const readers = new Map<string, { count: number; read: () => Promise<ChainWalletRead>; stop: () => void }>()

function startBalanceReads(
  key: string,
  read: () => Promise<ChainWalletRead>,
  client: { watchBlockNumber(args: { onBlockNumber: () => void; emitOnBegin?: boolean }): () => void },
): () => void {
  const running = readers.get(key)
  if (running) {
    // The latest tokens and markets win.
    running.count++
    running.read = read
    return () => release(key)
  }
  const entry = entryOf(key)
  let inFlight = false
  let again = false
  const refresh = () => {
    if (inFlight) {
      again = true
      return
    }
    inFlight = true
    ;(readers.get(key)?.read ?? read)()
      .then((next) => {
        entry.read = next
        for (const listener of entry.listeners) listener()
      })
      .catch(() => {
        // Unreadable now (RPC down); the next block reads again and the last rows stay shown.
      })
      .finally(() => {
        inFlight = false
        if (again) {
          again = false
          refresh()
        }
      })
  }
  entry.refresh = refresh
  const unwatch = client.watchBlockNumber({ onBlockNumber: refresh, emitOnBegin: true })
  readers.set(key, {
    count: 1,
    read,
    stop: () => {
      unwatch()
      entry.refresh = null
    },
  })
  return () => release(key)
}

function release(key: string) {
  const running = readers.get(key)
  if (!running) return
  running.count--
  if (running.count > 0) return
  running.stop()
  readers.delete(key)
}

/** Reads every watched wallet's balances again now, e.g. after a swap confirms. */
export function refreshWalletBalances() {
  for (const entry of entries.values()) entry.refresh?.()
}
