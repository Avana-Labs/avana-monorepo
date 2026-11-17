import { getAddress, isAddress, zeroAddress } from "viem"
import { isSafeExternalUrl } from "@/app/lib/safe-links"

/** The contract a detail hero shows: a checksummed address and its explorer page, when known. */
export type HeroContract = {
  address: `0x${string}`
  explorerHref: string | null
}

/** A contract row from services/convex (`contractAddresses.list*Addresses`), read from the release manifest. */
type ContractRow = {
  address: string
  label: string
  href: string
  /** The row's slot: vault, token, riskManager or oracleRouter (`aboutContracts.ts`). */
  salt?: string
  isSynthetic?: boolean
}

/** The contract each detail hero shows: a market's vault (else its token), or an asset's token. */
export type HeroContractLabel = "Pool" | "Token"

const HERO_SLOTS: Record<HeroContractLabel, readonly string[]> = {
  Pool: ["vault", "token"],
  Token: ["token"],
}

/**
 * The hero contract from the services/convex contract rows, or null when there is no real
 * address. The address is checksummed; the explorer link is kept only when it is an https URL
 * whose path ends in `/address/<that address>`.
 */
export function heroContractFromRows(
  rows: readonly ContractRow[] | null | undefined,
  label: HeroContractLabel,
): HeroContract | null {
  const real = rows?.filter((candidate) => candidate.isSynthetic !== true) ?? []
  const row = HERO_SLOTS[label].map((slot) => real.find((candidate) => candidate.salt === slot)).find(Boolean)
  if (!row || !isAddress(row.address, { strict: false })) return null
  const address = getAddress(row.address)
  if (address === zeroAddress) return null
  return { address, explorerHref: explorerAddressHref(row.href, address) }
}

function explorerAddressHref(href: string, address: `0x${string}`): string | null {
  if (!isSafeExternalUrl(href)) return null
  const url = new URL(href)
  const match = url.pathname.match(/^(.*)\/address\/(0x[0-9a-fA-F]{40})\/?$/)
  if (!match || match[2].toLowerCase() !== address.toLowerCase()) return null
  return `${url.origin}${match[1]}/address/${address}`
}
