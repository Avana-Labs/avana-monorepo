import { describe, expect, it } from "vitest"
import { parseFixed } from "@/app/lib/borrow-system/model"
import { canonicalPriceUsd } from "@/app/lib/prices/canonical"
import { listSpokeBorrowables } from "@/app/lib/borrow-system/registry"
import { assetPriceUsd6 } from "@/app/lib/borrow-system/mock"

const expectedUsd6 = (price: number) => parseFixed(price.toFixed(6), 6)

describe("engine seed price uses the canonical basis (no third price copy)", () => {
  it("values every canonical-covered borrowable at the price the UI shows", () => {
    const mismatches: string[] = []
    for (const asset of listSpokeBorrowables()) {
      const sym = asset.baseAssetId ?? asset.id
      const canonical = canonicalPriceUsd(sym)
      if (canonical === undefined) continue // non-canonical token keeps its local seed price
      if (assetPriceUsd6(asset) !== expectedUsd6(canonical)) {
        mismatches.push(`${sym}: engine ${assetPriceUsd6(asset)} != canonical ${expectedUsd6(canonical)}`)
      }
    }
    expect(mismatches, `Engine price diverges from the canonical basis:\n${mismatches.join("\n")}`).toEqual([])
  })

  it("regression guard: ETH engine price is the $1934 canonical baseline, not the old $2021 copy", () => {
    const eth = listSpokeBorrowables().find((a) => {
      const sym = a.baseAssetId ?? a.id
      return sym === "weth" || sym === "eth"
    })
    expect(eth, "expected a WETH/ETH borrowable in the catalog").toBeDefined()
    expect(assetPriceUsd6(eth!)).toBe(expectedUsd6(canonicalPriceUsd("ETH")!))
    // And explicitly NOT the retired third-copy value.
    expect(assetPriceUsd6(eth!)).not.toBe(expectedUsd6(2021.44))
  })
})
