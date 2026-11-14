import { describe, expect, it } from "vitest"
import { getDefaultWalletProfileId, getWalletProfile } from "@/app/lib/data/mock/wallet/portfolio/profiles"

describe("wallet profiles", () => {
  it("keeps demo-wallet as the default profile", () => {
    expect(getDefaultWalletProfileId()).toBe("demo-wallet")
    expect(getWalletProfile("demo-wallet").id).toBe("demo-wallet")
  })

  it("resolves the home workspace wallet to its own profile (not the demo fallback)", () => {
    // Regression: getWalletProfile used to fall back to demo-wallet for any
    // unknown id, which collapsed the home "Express" workspace onto the seeded
    // demo session and re-introduced its debt. The home wallet must keep its
    // own id so buildMockBorrowSystemState seeds a neutral, debt-free state.
    expect(getWalletProfile("home-demo-wallet").id).toBe("home-demo-wallet")
  })

  it("still falls back to the default profile for genuinely unknown ids", () => {
    expect(getWalletProfile("does-not-exist").id).toBe("demo-wallet")
  })
})
