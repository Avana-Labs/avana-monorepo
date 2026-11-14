import { existsSync, readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"

const root = resolve(__dirname, "../../..")
const read = (file: string) => readFileSync(resolve(root, file), "utf8")

// Each lazy section inside the deferred analytics stack suspended on its own and popped in at full
// height above content the reader was looking at (scroll CLS up to 0.68). The stack is now ONE lazy
// module: it arrives whole, off screen, while the shared placeholder holds its slot.
const PAGES = [
  ["app/borrow/pool/[poolId]/pool-detail-client.tsx", "app/borrow/pool/[poolId]/pool-analytics-stack.tsx"],
  ["app/borrow/assets/[assetId]/asset-detail-client.tsx", "app/borrow/assets/[assetId]/asset-analytics-stack.tsx"],
  ["app/lend/markets/[marketId]/market-detail-client.tsx", "app/lend/markets/[marketId]/lend-analytics-stack.tsx"],
  [
    "app/multiply/markets/[marketId]/market-detail-client.tsx",
    "app/multiply/markets/[marketId]/multiply-analytics-stack.tsx",
  ],
] as const

describe.each(PAGES)("%s analytics stack", (client, stack) => {
  it("loads the whole stack as one lazy module behind the shared placeholder", () => {
    const source = read(client)
    const deferred = source.split("<DeferredDetailContent")[1]?.split("</DeferredDetailContent>")[0] ?? ""
    expect(deferred).toMatch(/AnalyticsStack\b/)
    expect(deferred).not.toMatch(/CashflowCard|DetailFaqSection|DetailMarketTransactions/)
    expect(source).toMatch(/loading: \(\) => <DeferredDetailPlaceholder \/>/)
  })

  it("imports its sections statically, with no nested lazy loading", () => {
    expect(existsSync(resolve(root, stack))).toBe(true)
    const source = read(stack)
    expect(source).not.toMatch(/next\/dynamic|import\(/)
    expect(source).toMatch(/import \{[^}]*\bDetailMarketTransactions\b/)
  })
})
