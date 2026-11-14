import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { buildNewsItems } from "@/app/borrow/_detail/lib/news"

describe("detail page content honesty", () => {
  it("p1-21: news builder does not inject picsum placeholders", () => {
    const items = buildNewsItems({
      summary: "x",
      stats: [],
      history: [{ date: "2025-01-01", title: "Onboarded", description: "Added" }],
    } as never)
    expect(items.every((item) => !item.imageUrl?.includes("picsum"))).toBe(true)
  })

  it("moves deployment metadata into the risk parameters feed", () => {
    const items = buildNewsItems({
      summary: "x",
      stats: [{ label: "Deployed On", value: "March 18, 2024" }],
      history: [{ date: "2025-01-01", title: "Onboarded", description: "Added" }],
    } as never)
    expect(items[0]).toMatchObject({
      title: "Deployed",
      source: "Deployment",
      time: "March 18, 2024",
    })
  })

  it("p1-21: AboutNewsSection does not default to governance.aave.com", () => {
    const source = readFileSync(resolve(__dirname, "../ui/AboutNewsSection.tsx"), "utf8")
    expect(source).not.toMatch(/governance\.aave\.com/)
  })

  it("p1-21: pool/asset about stats do not emit fake-repeated etherscan hex", () => {
    const pool = readFileSync(resolve(__dirname, "../../../lib/borrow-detail/pool.mock.ts"), "utf8")
    const asset = readFileSync(resolve(__dirname, "../../../lib/borrow-detail/asset.mock.ts"), "utf8")
    expect(pool).not.toMatch(/fakeAddressSeed/)
    expect(asset).not.toMatch(/fakeAddressSeed/)
  })
})
