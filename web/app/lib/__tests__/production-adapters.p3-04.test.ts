import { describe, expect, it } from "vitest"
import { ProductionBorrowReadAdapter } from "@/app/lib/borrow-system/production-read-adapter"
import { ProductionLendReadAdapter } from "@/app/lib/lend-system/production-read-adapter"
import { ProductionMultiplyReadAdapter } from "@/app/lib/multiply-system/production-read-adapter"

describe("production adapter hard block", () => {
  it("P3-04: live adapters fail fast with a blocked marker instead of opaque throws", async () => {
    const borrow = new ProductionBorrowReadAdapter()
    const lend = new ProductionLendReadAdapter()
    const multiply = new ProductionMultiplyReadAdapter()
    await expect(borrow.readMarkets()).rejects.toThrow(/BLOCKED:/)
    await expect(lend.readMarkets()).rejects.toThrow(/BLOCKED:/)
    await expect(multiply.readMarkets()).rejects.toThrow(/BLOCKED:/)
  })
})
