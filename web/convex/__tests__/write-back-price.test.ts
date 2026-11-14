import { describe, expect, it } from "vitest"
import { resolveWriteBackPriceUsd } from "@/convex/sandbox/writeBackPrice"

describe("resolveWriteBackPriceUsd", () => {
  it("heals a USD-in-amount row (implied ≈ 1) to the oracle price for a non-$1 token", () => {
    // Corrupt LDO row: valueUsd/amount == 1 exactly, oracle says $2. Trusting implied would re-derive
    // amount = valueUsd/1 forever; the oracle heals it.
    expect(resolveWriteBackPriceUsd(1, 2)).toBe(2)
    expect(resolveWriteBackPriceUsd(1, 0.6)).toBe(0.6) // CRV
    expect(resolveWriteBackPriceUsd(1, 18)).toBe(18) // LINK — also outside the drift band
  })

  it("keeps the implied price for a genuine (non-$1) row that agrees with the oracle", () => {
    // 500 LDO at $2 basis, oracle drifted to $2.20 → still a real token quantity, keep implied.
    expect(resolveWriteBackPriceUsd(2, 2.2)).toBe(2)
  })

  it("keeps the implied price for a ~$1 token whose oracle is also ~$1 (harmless)", () => {
    // A genuine USDC row implies ≈1 and the oracle is ≈1 — no healing needed.
    expect(resolveWriteBackPriceUsd(1, 0.9997)).toBe(1)
  })

  it("falls back to the implied price when the oracle is unavailable", () => {
    expect(resolveWriteBackPriceUsd(2, null)).toBe(2)
    expect(resolveWriteBackPriceUsd(1, null)).toBe(1)
  })

  it("uses the oracle when there is no implied price (new row)", () => {
    expect(resolveWriteBackPriceUsd(null, 2)).toBe(2)
    expect(resolveWriteBackPriceUsd(null, null)).toBeNull()
  })

  it("heals when implied disagrees with the oracle beyond the drift band even if not ≈1", () => {
    // A row whose implied unit price is wildly off the oracle (units error that isn't exactly $1).
    expect(resolveWriteBackPriceUsd(0.01, 2)).toBe(2)
  })
})
