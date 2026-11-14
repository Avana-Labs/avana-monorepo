import { describe, expect, it } from "vitest"
import { rankResults, scoreResult } from "@/app/lib/search-ranking"

const make = (over: Partial<Parameters<typeof scoreResult>[0]>) => ({
  title: "",
  subtitle: "",
  eyebrow: "",
  keywords: "",
  ...over,
})

describe("search ranking", () => {
  it("ranks a token-containing pool above one that does not contain the token", () => {
    const results = [
      make({ title: "Stable Vault", subtitle: "usdc lending market", keywords: "usdc supply" }),
      make({ title: "USDC Pool", subtitle: "prime collateral", keywords: "usdc collateral lp" }),
    ]

    const ranked = rankResults(results, "usdc")

    // The result with the query in its TITLE should come first.
    expect(ranked[0]?.title).toBe("USDC Pool")
    expect(ranked).toHaveLength(2)
  })

  it("drops results that do not match the query at all", () => {
    const results = [make({ title: "ETH Pool", keywords: "eth weth" }), make({ title: "USDC Pool", keywords: "usdc" })]

    const ranked = rankResults(results, "usdc")

    expect(ranked).toHaveLength(1)
    expect(ranked[0]?.title).toBe("USDC Pool")
  })

  it("scores exact-title higher than prefix higher than word-boundary higher than fuzzy", () => {
    const exact = scoreResult(make({ title: "usdc" }), "usdc")
    const prefix = scoreResult(make({ title: "usdc pool" }), "usdc")
    const word = scoreResult(make({ title: "prime usdc pool" }), "usdc")
    const fuzzy = scoreResult(make({ keywords: "susdcx" }), "usdc")

    expect(exact).toBeGreaterThan(prefix)
    expect(prefix).toBeGreaterThan(word)
    expect(word).toBeGreaterThan(fuzzy)
    expect(fuzzy).toBeGreaterThan(0)
  })

  it("returns all results unfiltered for an empty query", () => {
    const results = [make({ title: "A" }), make({ title: "B" })]
    expect(rankResults(results, "   ")).toHaveLength(2)
  })

  it("keeps original order for equal-score ties (stable sort)", () => {
    const results = [make({ title: "usdc alpha" }), make({ title: "usdc beta" })]
    const ranked = rankResults(results, "usdc")
    expect(ranked.map((r) => r.title)).toEqual(["usdc alpha", "usdc beta"])
  })
})
