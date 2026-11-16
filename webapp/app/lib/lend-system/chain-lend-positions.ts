import { formatUnits, parseAbi, type Address } from "viem"
import type { LendPosition, LendSystemState } from "@/app/lib/lend-system/model"

/**
 * A wallet's Lend supplies on every chain the app reads, from the chain: per Hub asset (a Lend market), the Lend
 * Spokes' `getUserSuppliedAssets(reserveId, wallet)` summed over the asset's lend reserves, and the wallet's balance of
 * the underlying token (`balanceOf`), the amount it can supply. Hub assets come from services/convex
 * (`hubAssets.list`), keyed by the Lend market slug.
 */

export const LEND_SPOKE_ABI = parseAbi([
  "function getUserSuppliedAssets(uint256 reserveId, address user) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
])

export type LendChainClient = {
  readContract(args: {
    address: Address
    abi: readonly unknown[]
    functionName: string
    args?: readonly unknown[]
  }): Promise<unknown>
}

/** The fields of a services/convex `hubAssets` row the reader uses. */
export type LendHubAsset = {
  chainId: number
  slug: string
  underlying: string
  decimals: number
  lendReserves: readonly { spoke: string; reserveId: string }[]
}

/** Whole-token amounts per Lend market slug. */
export type ChainLendRead = { supplied: Record<string, number>; walletBalances: Record<string, number> }

/** Reads every Hub asset on a chain with a client; a market whose read fails is left out of both maps. */
export async function readChainLendPositions({
  client,
  wallet,
  hubAssets,
}: {
  client: (chainId: number) => LendChainClient | null
  wallet: Address
  hubAssets: readonly LendHubAsset[]
}): Promise<ChainLendRead> {
  const read: ChainLendRead = { supplied: {}, walletBalances: {} }
  await Promise.all(
    hubAssets.map(async (asset) => {
      const chain = client(asset.chainId)
      if (!chain) return
      try {
        const [supplied, balance] = await Promise.all([
          Promise.all(
            asset.lendReserves.map(
              (r) =>
                chain.readContract({
                  address: r.spoke as Address,
                  abi: LEND_SPOKE_ABI,
                  functionName: "getUserSuppliedAssets",
                  args: [BigInt(r.reserveId), wallet],
                }) as Promise<bigint>,
            ),
          ),
          chain.readContract({
            address: asset.underlying as Address,
            abi: LEND_SPOKE_ABI,
            functionName: "balanceOf",
            args: [wallet],
          }) as Promise<bigint>,
        ])
        read.supplied[asset.slug] = Number(
          formatUnits(
            supplied.reduce((sum, units) => sum + units, 0n),
            asset.decimals,
          ),
        )
        read.walletBalances[asset.slug] = Number(formatUnits(balance, asset.decimals))
      } catch {
        // Unreadable now; the next read tries again.
      }
    }),
  )
  return read
}

/**
 * The wallet's positions and wallet balances in a Lend state, from a chain read. A market with a supply is an active
 * position valued at the market's price; markets the read left out keep their previous position.
 *
 * The chain keeps no principal, so the principal is the current supply and the interest earned is 0.
 * TODO(activity): principal = Σ Supply − Σ Withdraw from the wallet's activity once it is read (PR 4).
 */
export function mergeChainLendPositions(
  state: LendSystemState,
  walletId: string,
  read: ChainLendRead,
  now = Date.now(),
): LendSystemState {
  const positions: Record<string, LendPosition> = { ...state.positions }
  for (const [slug, amount] of Object.entries(read.supplied)) {
    const positionId = `${walletId}:${slug}`
    const market = state.markets[slug]
    if (!market || amount <= 0) {
      delete positions[positionId]
      continue
    }
    const previous = positions[positionId]
    positions[positionId] = {
      positionId,
      walletId,
      marketId: slug,
      asset: market.asset.symbol,
      principalAmount: amount,
      scaledBalance: amount,
      liquidityIndexAtLastAction: market.liquidityIndex,
      currentSuppliedAmount: amount,
      interestEarned: 0,
      rewardsEarnedUsd: 0,
      suppliedValueUsd: amount * market.assetPriceUsd,
      openedAt: previous?.openedAt ?? now,
      updatedAt: now,
      status: "active",
    }
  }
  return {
    ...state,
    positions,
    walletBalances: {
      ...state.walletBalances,
      [walletId]: { ...state.walletBalances[walletId], ...read.walletBalances },
    },
  }
}
