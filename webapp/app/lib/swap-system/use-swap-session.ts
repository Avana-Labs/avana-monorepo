"use client"

import { useCallback, useMemo, useRef, useState } from "react"
import { formatUnits, type Address } from "viem"
import { TRANSACTIONS_UNAVAILABLE } from "@/app/lib/borrow-system/production-transaction-adapter"
import { SWAP_ASSETS } from "./catalog"
import { gasCostUsd, onchainPoolsConfig, quoteWithFrontendFee, swapChainClient } from "./onchain-config"
import { resolveSwapQuoteProvider } from "./providers"
import type { ExecutionRoute } from "./providers/onchain-pools"
import { useSwapContracts } from "./swap-contracts-sync"
import {
  readSwapAllowance,
  routeAmountIn,
  sendSwap,
  sendSwapApproval,
  venueRouter,
  type SwapApprovalResult,
  type SwapExecutionDeps,
} from "./swap-execution"
import { connectedSwapWallet, swapPublicClient, viemSwapChain } from "./swap-wallet"
import {
  type SwapExecutionOptions,
  type SwapQuote,
  type SwapQuoteRequest,
  type SwapSystemState,
  type SwapTransactionRecord,
} from "./quote-types"
import type { UserAssetBalance } from "./contracts"
import { refreshWalletBalances, useConvexProductWalletBalances } from "./use-convex-wallet-balances"

/**
 * Swap state of one wallet. Quotes come from the network's provider (NEXT_PUBLIC_AVANA_SWAP_PROVIDER):
 * the chain's own pools on the local chains, with the Q-409 fee taken from the input; CoW Swap,
 * which answers "unsupported" until connected, elsewhere. On the chain's own pools the approval and
 * the swap are sent from the connected wallet (`swap-execution.ts`); elsewhere none runs yet.
 */
export function useSwapSession({ walletId }: { walletId: string }) {
  const [state, setState] = useState<SwapSystemState>({ balances: [], allowances: {}, transactions: [] })

  // The wallet's balances on the active chain (`use-convex-wallet-balances.ts`); balances handed in through
  // `hydrateBalances` win while set.
  const chainBalances = useConvexProductWalletBalances(walletId)
  const walletBalances = useMemo(() => {
    const source = state.balances.length > 0 ? state.balances : (chainBalances ?? [])
    return source.filter((balance): balance is UserAssetBalance => balance.walletId === walletId)
  }, [chainBalances, state.balances, walletId])

  const contracts = useSwapContracts()
  const provider = useMemo(() => {
    const client = contracts ? swapChainClient() : null
    const config =
      contracts && client
        ? onchainPoolsConfig(contracts, SWAP_ASSETS, { networkFeeUsd: gasCostUsd(client, contracts.nativeUsdFeed) })
        : null
    return resolveSwapQuoteProvider(config && client ? { config, client } : null)
  }, [contracts])

  // Sending on the chain's own pools: the routes the provider priced, the chain and the connected wallet.
  const execution = useMemo((): SwapExecutionDeps | null => {
    const client = contracts ? swapPublicClient() : null
    if (!contracts || !client || !provider.executionRoute) return null
    return {
      contracts,
      assets: SWAP_ASSETS,
      chain: viemSwapChain(client),
      wallet: connectedSwapWallet,
      executionRoute: provider.executionRoute,
    }
  }, [contracts, provider])
  // The venue of the latest route per input asset, for an approval sent on its own.
  const lastVenue = useRef(new Map<string, ExecutionRoute["venue"]>())
  const lastApprovalHash = useRef<string | undefined>(undefined)

  const refreshAllowance = useCallback(
    async (assetId: string, venue: ExecutionRoute["venue"]) => {
      const asset = SWAP_ASSETS.find((a) => a.id === assetId)
      const token = execution?.contracts.tokens.find((t) => t.symbol.toUpperCase() === asset?.symbol.toUpperCase())?.address
      const router = execution ? venueRouter(execution.contracts, venue) : null
      if (!execution || !asset || asset.isNative || !token || !router) return
      const wallet = await execution.wallet()
      if (!wallet) return
      try {
        const allowance = await readSwapAllowance(execution.chain, wallet.account, token as Address, router, false)
        const amount = Number(formatUnits(allowance, asset.decimals))
        setState((current) => ({ ...current, allowances: { ...current.allowances, [`${walletId}:${assetId}`]: amount } }))
      } catch {
        // Unreadable now; the next quote reads it again.
      }
    },
    [execution, walletId],
  )

  const getQuote = useCallback(
    async (request: Omit<SwapQuoteRequest, "walletId">): Promise<SwapQuote> => {
      const quote = await quoteWithFrontendFee(provider, { ...request, walletId }, SWAP_ASSETS)
      const route = provider.executionRoute?.(quote.id)
      if (route) {
        lastVenue.current.set(quote.inputAssetId, route.venue)
        void refreshAllowance(quote.inputAssetId, route.venue)
      }
      return quote
    },
    [provider, refreshAllowance, walletId],
  )
  const getIndicativeQuote = getQuote
  const requiresApproval = useCallback(
    (assetId: string, amount: number) => {
      const asset = SWAP_ASSETS.find((a) => a.id === assetId)
      if (!execution || !asset || asset.isNative) return false
      const needed = Number(formatUnits(routeAmountIn(amount, asset).amountIn, asset.decimals))
      return (state.allowances[`${walletId}:${assetId}`] ?? 0) < needed
    },
    [execution, state.allowances, walletId],
  )
  const approve = useCallback(
    async (assetId: string, amount: number, _options?: SwapExecutionOptions): Promise<SwapApprovalResult> => {
      if (!execution) throw new Error(TRANSACTIONS_UNAVAILABLE)
      lastApprovalHash.current = undefined
      // A wallet that batches approves inside the swap's own batch, so the approval and the swap confirm together.
      const wallet = await execution.wallet()
      if (wallet && (await wallet.supportsAtomicBatch().catch(() => false))) {
        return { status: "approval_confirmed", hash: null, failureReason: null }
      }
      const venue =
        lastVenue.current.get(assetId) ??
        (execution.contracts.venues.find((v) => v.venue !== "uniswap-v4")?.venue as ExecutionRoute["venue"] | undefined)
      if (!venue) return { status: "failed", hash: null, failureReason: "Approval failed." }
      const result = await sendSwapApproval(execution, assetId, amount, venue)
      if (result.hash) lastApprovalHash.current = result.hash
      void refreshAllowance(assetId, venue)
      return result
    },
    [execution, refreshAllowance],
  )
  const executeSwap = useCallback(
    async (quote: SwapQuote, _options?: SwapExecutionOptions): Promise<SwapTransactionRecord> => {
      if (!execution) throw new Error(TRANSACTIONS_UNAVAILABLE)
      const record = await sendSwap(execution, quote, walletId, lastApprovalHash.current)
      lastApprovalHash.current = undefined
      setState((current) => ({ ...current, transactions: [record, ...current.transactions] }))
      refreshWalletBalances()
      const venue = lastVenue.current.get(quote.inputAssetId)
      if (venue) void refreshAllowance(quote.inputAssetId, venue)
      return record
    },
    [execution, refreshAllowance, walletId],
  )
  const hydrateBalances = useCallback(
    (balances: UserAssetBalance[]) => {
      setState((current) => ({
        ...current,
        balances: balances.map((balance) => ({ ...balance, walletId: balance.walletId || walletId })),
      }))
    },
    [walletId],
  )

  const isHydrated = true
  const transactionHistory = state.transactions

  return useMemo(
    () => ({
      walletId,
      isHydrated,
      state,
      walletBalances,
      transactionHistory,
      getQuote,
      getIndicativeQuote,
      requiresApproval,
      approve,
      executeSwap,
      hydrateBalances,
    }),
    [
      walletId,
      isHydrated,
      state,
      walletBalances,
      transactionHistory,
      getQuote,
      getIndicativeQuote,
      requiresApproval,
      approve,
      executeSwap,
      hydrateBalances,
    ],
  )
}
