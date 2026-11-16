import { parseAbi, type Address } from "viem"
import type { ChainBorrowAccountRef } from "@/app/lib/borrow-system/chain-positions"
import type { UserRewardPosition } from "@/app/lib/borrow-system/model"

/**
 * The claimable LP fees of a wallet's Borrow accounts, from the Lens at the latest block (`getAccountFees`: what
 * `collectFees` would pay for each pledged record), one reward position per account, valued in USD. And the wallet's
 * unclaimed payouts held by the PayoutEscrow (`getEscrowClaimable`), per token.
 */

export const LENS_FEES_ABI = parseAbi([
  "struct PositionFeesView { uint256 blockNumber; uint256 timestamp; uint256 marketId; bytes32 positionKey; bool supported; bool inCustody; address depositor; uint128 liquidity; uint256[] tokensOwed; uint256[] amounts; }",
  "function getAccountFees(address wallet, uint256 marketId) view returns (PositionFeesView[])",
  "function getEscrowClaimable(address account, address[] tokens) view returns (uint256[])",
])

type FeesView = { supported: boolean; amounts: readonly bigint[] }

export type RewardsChain = {
  readContract(args: {
    address: Address
    abi: readonly unknown[]
    functionName: string
    args?: readonly unknown[]
  }): Promise<unknown>
}

/** A market's pool tokens, in pool order (Convex `markets` row: `tokens`, `tokenDecimals`). */
export type RewardsMarket = {
  chainId: number
  marketId: string
  tokens: readonly string[]
  tokenDecimals: readonly number[]
}

export type RewardsDeps = {
  chain(chainId: number): RewardsChain | null
  lenses: readonly { chainId: number; lens: string }[]
  /** USD with 8 decimals per whole token, or null when unpriced (that token's fees then count 0). */
  priceUsd8(chainId: number, token: string): bigint | null
}

function pow10(n: number): bigint {
  return BigInt(`1${"0".repeat(n)}`)
}

function usd6(units: bigint, decimals: number, priceUsd8: bigint | null): bigint {
  return priceUsd8 && priceUsd8 > 0n ? (units * priceUsd8) / pow10(decimals) / 100n : 0n
}

function lensOf(deps: RewardsDeps, chainId: number): Address | null {
  return (deps.lenses.find((l) => l.chainId === chainId)?.lens as Address | undefined) ?? null
}

/**
 * One reward position per account whose market is listed (`poolSlug`): id `fees:<chainId>:<marketId>`, `marketId` the
 * pool slug, claimable and earned the account's uncollected fees in USD. An account the Lens cannot read is left out.
 */
export async function chainRewardPositions(
  deps: RewardsDeps,
  wallet: string,
  accounts: readonly ChainBorrowAccountRef[],
  markets: readonly RewardsMarket[],
): Promise<UserRewardPosition[]> {
  const rows = await Promise.all(
    accounts.map(async (account): Promise<UserRewardPosition | null> => {
      const chain = deps.chain(account.chainId)
      const lens = lensOf(deps, account.chainId)
      const market = markets.find((m) => m.chainId === account.chainId && m.marketId === account.marketId)
      if (!account.poolSlug || !chain || !lens || !market) return null
      try {
        const fees = (await chain.readContract({
          address: lens,
          abi: LENS_FEES_ABI,
          functionName: "getAccountFees",
          args: [wallet as Address, BigInt(account.marketId)],
        })) as readonly FeesView[]
        let total = 0n
        for (const record of fees) {
          if (!record.supported) continue
          record.amounts.forEach((amount, i) => {
            const token = market.tokens[i]
            const decimals = market.tokenDecimals[i]
            if (token === undefined || decimals === undefined) return
            total += usd6(amount, decimals, deps.priceUsd8(account.chainId, token))
          })
        }
        return {
          id: `fees:${account.chainId}:${account.marketId}`,
          marketId: account.poolSlug,
          claimableUsd6: total,
          earnedUsd6: total,
        }
      } catch {
        return null
      }
    }),
  )
  return rows.filter((row): row is UserRewardPosition => row !== null)
}

/** The wallet's unclaimed PayoutEscrow payouts on one chain, per requested token, in base units; null when unreadable. */
export async function chainEscrowClaimable(
  deps: RewardsDeps,
  chainId: number,
  wallet: string,
  tokens: readonly string[],
): Promise<{ token: string; amount: bigint }[] | null> {
  const chain = deps.chain(chainId)
  const lens = lensOf(deps, chainId)
  if (!chain || !lens || tokens.length === 0) return tokens.length === 0 ? [] : null
  try {
    const amounts = (await chain.readContract({
      address: lens,
      abi: LENS_FEES_ABI,
      functionName: "getEscrowClaimable",
      args: [wallet as Address, tokens as Address[]],
    })) as readonly bigint[]
    return tokens.map((token, i) => ({ token, amount: amounts[i] ?? 0n }))
  } catch {
    return null
  }
}
