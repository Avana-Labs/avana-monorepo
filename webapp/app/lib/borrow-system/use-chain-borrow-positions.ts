"use client"

import { useCallback, useEffect, useRef } from "react"
import { useQuery } from "convex/react"
import type { Address } from "viem"
import { api } from "@/convex/_generated/api"
import { chainPublicClient } from "@/app/lib/chain/public-client"
import { everyWhileVisible } from "@/app/lib/chain/visible-interval"
import { useBorrowSessionContext } from "@/app/lib/avana-session/avana-sessions-context"
import {
  chainBorrowPositions,
  type AccountViewLike,
  type ChainBorrowAccountRef,
  type ChainDebtReserveRef,
} from "@/app/lib/borrow-system/chain-positions"
import { lensAccountAbi } from "@/app/lib/borrow-system/lens-account-abi"
import {
  onBorrowPositionsRefresh,
  setChainBorrowRefs,
  type ChainMarketRef,
  type ChainTokenPrice,
} from "@/app/lib/borrow-system/chain-refs"
import { chainRewardPositions, type RewardsChain, type RewardsDeps, type RewardsMarket } from "@/app/lib/borrow-system/chain-rewards"

/** How often the wallet's accounts are re-read at the chain head. */
export const BORROW_POSITIONS_REFRESH_MS = 15_000

const isAddress = (value: string): value is Address => /^0x[0-9a-fA-F]{40}$/.test(value)

type BorrowAccountsResult = {
  lenses: readonly { chainId: number; lens: string }[]
  accounts: readonly ChainBorrowAccountRef[]
  markets?: readonly ChainMarketRef[]
  debtReserves: readonly ChainDebtReserveRef[]
  tokenPrices?: readonly ChainTokenPrice[]
}

/** What chainRewardPositions reads with: the chains' read clients, their Lenses and the pool tokens' prices. */
export function rewardsDeps(refs: BorrowAccountsResult): RewardsDeps {
  const prices = new Map((refs.tokenPrices ?? []).map((p) => [`${p.chainId}:${p.token.toLowerCase()}`, BigInt(p.priceUsd8)]))
  return {
    chain: (chainId) => chainPublicClient(chainId) as RewardsChain | null,
    lenses: refs.lenses,
    priceUsd8: (chainId, token) => prices.get(`${chainId}:${token.toLowerCase()}`) ?? null,
  }
}

/** The listed markets with their pool tokens, as chainRewardPositions values fees. */
export function rewardsMarkets(refs: BorrowAccountsResult): RewardsMarket[] {
  return (refs.markets ?? []).flatMap((m) =>
    m.tokens && m.tokenDecimals ? [{ chainId: m.chainId, marketId: m.marketId, tokens: m.tokens, tokenDecimals: m.tokenDecimals }] : [],
  )
}

/** The wallet's Lens accounts on every chain it has one, read at the chain head. */
export async function readChainAccountViews(
  wallet: Address,
  refs: BorrowAccountsResult,
): Promise<{ chainId: number; view: AccountViewLike }[]> {
  const out: { chainId: number; view: AccountViewLike }[] = []
  for (const { chainId, lens } of refs.lenses) {
    const client = chainPublicClient(chainId)
    const marketIds = refs.accounts.filter((a) => a.chainId === chainId).map((a) => BigInt(a.marketId))
    if (!client || marketIds.length === 0) continue
    const views = (await client.readContract({
      address: lens as Address,
      abi: lensAccountAbi,
      functionName: "getAccounts",
      args: [wallet, marketIds],
    })) as readonly AccountViewLike[]
    for (const view of views) out.push({ chainId, view })
  }
  return out
}

/**
 * Keeps the borrow session's account in step with the chain: services/convex names the wallet's accounts (markets it
 * opened, UserProxyCreated) and the Lens values them at the head. Re-read every {@link BORROW_POSITIONS_REFRESH_MS}
 * while the tab is visible, when it becomes visible again, and whenever `refresh` is called (after a transaction). A guest or a wallet with no account keeps an empty account.
 */
export function useChainBorrowPositions(walletId: string): { refresh: () => void } {
  const session = useBorrowSessionContext()
  const wallet = isAddress(walletId) ? walletId : undefined
  const refs = useQuery(api.wallet.positions.borrowAccounts, wallet ? { wallet } : "skip") as
    | BorrowAccountsResult
    | undefined
  const { hydrateAccountPositions, state } = session
  const markets = state.markets
  const generation = useRef(0)

  const refresh = useCallback(() => {
    if (!wallet || !refs) return
    const run = ++generation.current
    if (refs.accounts.length === 0) {
      hydrateAccountPositions(wallet, { collateralPositions: [], debtPositions: [], rewardPositions: [] })
      return
    }
    void Promise.all([
      readChainAccountViews(wallet, refs),
      chainRewardPositions(rewardsDeps(refs), wallet, refs.accounts, rewardsMarkets(refs)),
    ])
      .then(([views, rewardPositions]) => {
        if (run !== generation.current) return
        hydrateAccountPositions(wallet, { ...chainBorrowPositions(views, refs.accounts, refs.debtReserves, markets), rewardPositions })
      })
      .catch(() => {
        // A failed read keeps the last positions; the next tick retries.
      })
  }, [wallet, refs, markets, hydrateAccountPositions])

  useEffect(() => {
    setChainBorrowRefs(wallet && refs ? { wallet, ...refs } : null)
  }, [wallet, refs])

  useEffect(() => {
    refresh()
    // A hidden tab reads nothing; it catches up as soon as it is visible again.
    const stop = everyWhileVisible(refresh, BORROW_POSITIONS_REFRESH_MS)
    const off = onBorrowPositionsRefresh(refresh)
    return () => {
      stop()
      off()
    }
  }, [refresh])

  return { refresh }
}
