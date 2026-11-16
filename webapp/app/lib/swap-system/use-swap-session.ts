"use client"

import { useCallback, useMemo, useState } from "react"
import { TRANSACTIONS_UNAVAILABLE } from "@/app/lib/borrow-system/production-transaction-adapter"
import { SWAP_ASSETS } from "./catalog"
import { gasCostUsd, onchainPoolsConfig, quoteWithFrontendFee, swapChainClient } from "./onchain-config"
import { resolveSwapQuoteProvider } from "./providers"
import { useSwapContracts } from "./swap-contracts-sync"
import {
  type SwapExecutionOptions,
  type SwapQuote,
  type SwapQuoteRequest,
  type SwapSystemState,
  type SwapTransactionRecord,
} from "./quote-types"
import type { UserAssetBalance } from "./contracts"

/**
 * Swap state of one wallet. Quotes come from the network's provider (NEXT_PUBLIC_AVANA_SWAP_PROVIDER):
 * the chain's own pools on the local chains, with the Q-409 fee taken from the input; CoW Swap,
 * which answers "unsupported" until connected, elsewhere. Balances are empty and no approval or
 * swap runs yet.
 */
export function useSwapSession({ walletId }: { walletId: string }) {
  const [state, setState] = useState<SwapSystemState>({ balances: [], allowances: {}, transactions: [] })

  const walletBalances = useMemo(
    () => state.balances.filter((balance): balance is UserAssetBalance => balance.walletId === walletId),
    [state.balances, walletId],
  )

  const contracts = useSwapContracts()
  const provider = useMemo(() => {
    const client = contracts ? swapChainClient() : null
    const config =
      contracts && client
        ? onchainPoolsConfig(contracts, SWAP_ASSETS, { networkFeeUsd: gasCostUsd(client, contracts.nativeUsdFeed) })
        : null
    return resolveSwapQuoteProvider(config && client ? { config, client } : null)
  }, [contracts])

  const getQuote = useCallback(
    async (request: Omit<SwapQuoteRequest, "walletId">): Promise<SwapQuote> =>
      quoteWithFrontendFee(provider, { ...request, walletId }, SWAP_ASSETS),
    [provider, walletId],
  )
  const getIndicativeQuote = getQuote
  const requiresApproval = useCallback((_assetId: string, _amount: number) => false, [])
  const approve = useCallback(
    async (_assetId: string, _amount: number, _options?: SwapExecutionOptions): Promise<SwapTransactionRecord> => {
      throw new Error(TRANSACTIONS_UNAVAILABLE)
    },
    [],
  )
  const executeSwap = useCallback(
    async (_quote: SwapQuote, _options?: SwapExecutionOptions): Promise<SwapTransactionRecord> => {
      throw new Error(TRANSACTIONS_UNAVAILABLE)
    },
    [],
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
