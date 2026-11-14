/**
 * Targeted reseed: About contract-address tables + siloed market content stats.
 *   npx tsx scripts/seed-contract-addresses.ts
 */
import { ConvexHttpClient } from "convex/browser"
import { api } from "../convex/_generated/api"
import { buildBorrowSeed } from "../app/lib/convex-seed/build-seed"

const BATCH = 400
const throttleMs = 70
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

function chunk<T>(rows: T[], size: number): T[][] {
  const out: T[][] = []
  for (let i = 0; i < rows.length; i += size) out.push(rows.slice(i, i + size))
  return out
}

async function main() {
  const url = process.env.NEXT_PUBLIC_CONVEX_URL
  if (!url || !/^https?:\/\//.test(url)) {
    throw new Error("NEXT_PUBLIC_CONVEX_URL is not set.")
  }
  const seedSecret = process.env.CONVEX_SEED_SECRET
  if (!seedSecret) throw new Error("CONVEX_SEED_SECRET is not set.")

  const client = new ConvexHttpClient(url)
  const seed = buildBorrowSeed({ days: 1 })
  console.log(
    `[seed] contract rows pool=${seed.poolContractAddresses?.length ?? 0} asset=${seed.assetContractAddresses?.length ?? 0} lend=${seed.lendContractAddresses?.length ?? 0} multiply=${seed.multiplyContractAddresses?.length ?? 0}`,
  )

  const remap = <K extends string>(key: K, rows: Array<{ slug: string } & Record<string, unknown>>) =>
    rows.map(({ slug, ...rest }) => ({ [key]: slug, ...rest }))

  const push = async (label: string, action: typeof api.seedAdmin.upsertPoolContractAddresses, rows: unknown[]) => {
    let written = 0
    for (const batch of chunk(rows, BATCH)) {
      await client.action(action, { seedSecret, rows: batch })
      written += batch.length
      await sleep(throttleMs)
    }
    console.log(`[seed] upserted ${written} ${label}`)
  }

  await push(
    "pool contract addresses",
    api.seedAdmin.upsertPoolContractAddresses,
    remap("poolSlug", seed.poolContractAddresses ?? []),
  )
  await push(
    "asset contract addresses",
    api.seedAdmin.upsertAssetContractAddresses,
    remap("assetSlug", seed.assetContractAddresses ?? []),
  )
  await push(
    "lend contract addresses",
    api.seedAdmin.upsertLendContractAddresses,
    remap("marketSlug", seed.lendContractAddresses ?? []),
  )
  await push(
    "multiply contract addresses",
    api.seedAdmin.upsertMultiplyContractAddresses,
    remap("marketSlug", seed.multiplyContractAddresses ?? []),
  )

  await push("lend market content", api.seedAdmin.upsertLendMarketContent, seed.lendMarketContent)
  await push("multiply market content", api.seedAdmin.upsertMultiplyMarketContent, seed.multiplyMarketContent)
  await push("borrow market content", api.seedAdmin.upsertBorrowMarketContent, seed.borrowMarketContent)

  console.log("[seed] done")
}

main().catch((error) => {
  console.error("[seed] failed:", error)
  process.exit(1)
})
