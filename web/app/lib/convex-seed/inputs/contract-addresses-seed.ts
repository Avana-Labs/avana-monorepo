// SEED ONLY — imported by build-seed.ts. Not for UI code.
//
// Deterministic contract-address seed rows for pool, asset, lend, and multiply
// detail pages. The mock's `contractAddressFor(slug, salt)` (see
// app/lib/borrow-detail/pool.mock.ts) FNV-1a hashes `${slug}:${salt}` and
// formats the result as a 40-hex 0x-prefixed pseudo-address. That same
// algorithm is inlined here so the seed produces byte-identical values to the
// mock without importing it (the mock pulls in the whole detail-page graph,
// which the seed pipeline must stay clean of).

import { BORROW_POOL_CATALOG } from "@/app/lib/borrow-sim"
import { listSpokeBorrowables } from "@/app/lib/borrow-system/registry"
import { ABOUT_CONTRACT_ADDRESS_SALTS } from "@/app/lib/detail-page/about-contract-addresses"
import { LEND_MARKET_CATALOG } from "@/app/lib/lend-system/catalog"
import { MULTIPLY_MARKET_CATALOG } from "@/app/lib/multiply-system/catalog"
import type { SeedContractAddressRow } from "../build-seed"

/** FNV-1a 32-bit hash of `${slug}:${salt}`, formatted as a 40-hex 0x-address. */
function contractAddressFor(slug: string, salt: string): string {
  const seed = `${slug}:${salt}`
  let hash = 0x811c9dc5
  for (let index = 0; index < seed.length; index += 1) {
    hash ^= seed.charCodeAt(index)
    hash = Math.imul(hash, 0x01000193)
  }
  const chunk = (hash >>> 0).toString(16).padStart(8, "0").toUpperCase()
  return `0x${chunk}${chunk}${chunk}${chunk}${chunk}`.slice(0, 42)
}

function shortAddress(address: string): string {
  return `${address.slice(0, 6)}...${address.slice(-4)}`
}

function buildRow(slug: string, salt: string, chain: string): SeedContractAddressRow {
  const address = contractAddressFor(slug, salt)
  return {
    slug,
    salt,
    address,
    label: shortAddress(address),
    href: `https://etherscan.io/address/${address}`,
    chain,
    isSynthetic: true,
  }
}

/** Shared About salts: vault, token, riskManager, oracleRouter. */
const DETAIL_SALTS = ABOUT_CONTRACT_ADDRESS_SALTS

/** Pool detail-page contract rows — 4 salts × every entry in BORROW_POOL_CATALOG. */
export const POOL_CONTRACT_SEED_ROWS: SeedContractAddressRow[] = BORROW_POOL_CATALOG.flatMap((pool) => {
  // BorrowPoolRow has no `chain` field today; the `?? "Ethereum"` guard keeps
  // the seed forward-compatible if one is added later without changing values.
  const chain = (pool as { chain?: string }).chain ?? "Ethereum"
  return DETAIL_SALTS.map((salt) => buildRow(pool.id, salt, chain))
})

/** Asset detail-page contract rows — 4 salts × every spoke-bound borrowable asset. */
export const ASSET_CONTRACT_SEED_ROWS: SeedContractAddressRow[] = listSpokeBorrowables().flatMap((asset) =>
  DETAIL_SALTS.map((salt) => buildRow(asset.id, salt, "Ethereum")),
)

/** Lend detail-page contract rows — 4 salts × every entry in LEND_MARKET_CATALOG. */
export const LEND_CONTRACT_SEED_ROWS: SeedContractAddressRow[] = LEND_MARKET_CATALOG.flatMap((market) =>
  DETAIL_SALTS.map((salt) => buildRow(market.marketId, salt, "Ethereum")),
)

/** Multiply detail-page contract rows — 4 salts × every entry in MULTIPLY_MARKET_CATALOG. */
export const MULTIPLY_CONTRACT_SEED_ROWS: SeedContractAddressRow[] = MULTIPLY_MARKET_CATALOG.flatMap((market) =>
  DETAIL_SALTS.map((salt) => buildRow(market.id, salt, "Ethereum")),
)

// isSynthetic: true marks every row here as a seeded FNV-1a hash of the mock,
// NOT a real on-chain address. The Etherscan-sync job (when it lands) will
// overwrite each row's address/href with the discovered on-chain contract and
// flip isSynthetic to false; the UI keys off that flag to decide whether an
// address is trustworthy to display as a real link.
