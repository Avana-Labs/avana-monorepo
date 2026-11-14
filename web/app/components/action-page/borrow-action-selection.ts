import type { useBorrowSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { usd6ToNumber } from "@/app/lib/credit-engine"

type BorrowSession = ReturnType<typeof useBorrowSessionContext>

/**
 * The Repay input and its Max are debt-token quantities, but the engine repays a USD value.
 * The preview, the submitted intent and the receipt all convert here so they cannot drift.
 */
export function repayUsdForTokenAmount(state: BorrowSession["state"], assetId: string, tokenAmount: number) {
  const priceUsd = usd6ToNumber(state.assets[assetId]?.snapshot.priceUsd6 ?? 0n)
  if (!(priceUsd > 0)) return null
  return { priceUsd, amountUsd: tokenAmount * priceUsd }
}

export function resolveClaimPositions(
  session: BorrowSession,
  walletId: string,
  marketId: string,
  claimPositionId?: string,
) {
  const positions = session.state.accounts[walletId]?.rewardPositions ?? []
  if (claimPositionId) {
    const selected = positions.find((position) => position.id === claimPositionId)
    if (selected) return [selected]
  }
  if (!marketId) return positions
  return positions.filter((position) => position.marketId === marketId)
}

export function selectionsFromPositions(positions: ReadonlyArray<{ id: string }>) {
  const selections: Record<string, boolean> = {}
  for (const position of positions) selections[position.id] = true
  return selections
}
