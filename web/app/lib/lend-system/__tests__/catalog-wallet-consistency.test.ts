import { describe, expect, it } from "vitest"
import { getWalletLendAssets } from "@/app/lib/data/mock/wallet/portfolio/lend-wallet-assets"
import { getLendMarketById, resolveLendMarketId } from "@/app/lib/lend-system/catalog"

describe("lend catalog ↔ wallet consistency", () => {
  it("every funded wallet asset maps to a real lend market", () => {
    const missing = getWalletLendAssets("demo-wallet")
      .filter((asset) => !getLendMarketById(resolveLendMarketId(asset.symbol)))
      .map((asset) => asset.symbol)
    expect(missing).toEqual([])
  })
})
