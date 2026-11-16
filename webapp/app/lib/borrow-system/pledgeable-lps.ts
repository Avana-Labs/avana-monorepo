import type { WalletLpPosition } from "@/app/lib/swap-system/chain-wallet-balances"
import type { PledgeableLp } from "@/app/lib/borrow-system/chain-refs"

/** The wallet's LP NFTs that a market accepts, in the shape a pledge sends; NFTs with no market are left out. */
export function pledgeableFromWallet(rows: readonly WalletLpPosition[]): PledgeableLp[] {
  return rows.flatMap((row) =>
    row.market
      ? [
          {
            chainId: row.chainId,
            marketId: row.market.marketId,
            integrationId: row.market.integrationId,
            positionKey: row.positionKey,
            npm: row.npm,
            tokenId: row.tokenId,
            lpVault: row.market.lpVault,
            valueUsd6: row.market.valueUsd6,
          },
        ]
      : [],
  )
}
