import type { PortfolioActivityRow } from "@/app/lib/data/providers/portfolio"
import type { UmbrellaTransaction } from "./use-umbrella-session"

type UmbrellaPositionStatus =
  "active" | "partiallyCooling" | "coolingDown" | "readyToUnstake" | "cooldownExpired" | "slashed" | "closed"

/**
 * Lifecycle status from the persisted Convex position shape. `slashed` takes precedence over
 * `closed` so a wallet slashed to 0 still shows the incident rather than a neutral "closed".
 */
export function derivePersistedUmbrellaPositionStatus(position: {
  status: "open" | "closed"
  suppliedUsd6?: string
  cooldownAmountUsd6?: string
  cooldownEndsAt?: number
  withdrawalWindowEndsAt?: number
  slashedAmountUsd6?: string
  now: number
}): UmbrellaPositionStatus {
  const suppliedUsd6 = BigInt(position.suppliedUsd6 ?? "0")
  const cooldownUsd6 = BigInt(position.cooldownAmountUsd6 ?? "0")
  const slashedUsd6 = BigInt(position.slashedAmountUsd6 ?? "0")
  if (suppliedUsd6 <= 0n || position.status === "closed") return slashedUsd6 > 0n ? "slashed" : "closed"
  if (cooldownUsd6 <= 0n) return "active"
  if (position.withdrawalWindowEndsAt && position.now > position.withdrawalWindowEndsAt) return "cooldownExpired"
  if (position.cooldownEndsAt && position.now >= position.cooldownEndsAt) return "readyToUnstake"
  return cooldownUsd6 >= suppliedUsd6 ? "coolingDown" : "partiallyCooling"
}

/**
 * Map the session transaction log into dashboard "recent activity" rows, mirroring the
 * lend/borrow/multiply mappers. The tx hash must survive intact so the composite
 * hash/action/market dedup can collapse cross-store copies without hiding distinct actions.
 */
export function buildUmbrellaActivityRows(transactions: UmbrellaTransaction[]): PortfolioActivityRow[] {
  return transactions.map((tx) => {
    // Unstaking returns funds to the wallet (negative); stake/claim/start-cooldown are positive
    // commitments to the Umbrella product.
    const signedAmount = tx.kind === "unstake" ? -Math.abs(tx.amountUsd) : Math.abs(tx.amountUsd)

    return {
      id: tx.id,
      at: new Date(tx.timestamp).toISOString(),
      product: "umbrella" as const,
      kind:
        tx.kind === "stake"
          ? ("stake" as const)
          : tx.kind === "claim"
            ? ("claim" as const)
            : tx.kind === "startCooldown"
              ? ("startCooldown" as const)
              : ("unstake" as const),
      status: tx.status === "success" ? ("confirmed" as const) : ("failed" as const),
      amountUsd: signedAmount,
      primaryLabel:
        tx.kind === "stake"
          ? `Staked ${tx.symbol}`
          : tx.kind === "unstake"
            ? `Unstaked ${tx.symbol}`
            : tx.kind === "startCooldown"
              ? `Cooldown ${tx.symbol}`
              : `Claimed ${tx.symbol} rewards`,
      secondaryLabel:
        tx.kind === "claim"
          ? "Umbrella rewards claim"
          : `${tx.amount.toLocaleString("en-US", { maximumFractionDigits: 4 })} ${tx.symbol}`,
      txHash: tx.hash,
      marketId: tx.marketId,
    }
  })
}
