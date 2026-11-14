import { describe, expect, it } from "vitest"
import { getWalletActivity } from "@/app/lib/data/mock/wallet/portfolio/activity"

const REAL_TX_HASH = /^0x[0-9a-fA-F]{64}$/

describe("getWalletActivity", () => {
  it("emits simulated (non-Etherscan) tx hashes so rows route to the in-app receipt", () => {
    const rows = getWalletActivity("demo-wallet")
    expect(rows.length).toBeGreaterThan(0)
    for (const row of rows) {
      // A canonical 0x+64hex hash would be sent to Etherscan and dead-link, since
      // these are seeded sandbox rows, not real on-chain transactions.
      expect(REAL_TX_HASH.test(row.txHash)).toBe(false)
      expect(row.txHash.startsWith("sim-")).toBe(true)
    }
  })

  it("is deterministic per wallet and unique per row", () => {
    const first = getWalletActivity("demo-wallet")
    const second = getWalletActivity("demo-wallet")
    expect(first.map((row) => row.txHash)).toEqual(second.map((row) => row.txHash))
    // Distinct rows get distinct hashes so the activity table's hash-dedup keeps them all.
    expect(new Set(first.map((row) => row.txHash)).size).toBe(first.length)
  })
})
