import { describe, expect, it } from "vitest"
import {
  formatMultiplyLoopPairLabel,
  formatMultiplyLoopBorrowLabel,
  formatMultiplyLoopSupplyLabel,
  translateMultiplyLoopBorrowLabel,
  translateMultiplyLoopSupplyLabel,
} from "@/app/lib/multiply-system/market-labels"

const identityT = (key: string) => key

describe("multiply market labels", () => {
  it("formats pair and role labels", () => {
    expect(formatMultiplyLoopPairLabel("USDC", "GHO")).toBe("USDC / GHO")
    expect(formatMultiplyLoopSupplyLabel("USDC")).toBe("Supply USDC")
    expect(formatMultiplyLoopBorrowLabel("GHO")).toBe("Borrow GHO")
  })

  it("normalizes canonical symbols to user-facing tickers", () => {
    expect(formatMultiplyLoopSupplyLabel("CRVUSD")).toBe("Supply crvUSD")
    expect(formatMultiplyLoopBorrowLabel("CRVUSD")).toBe("Borrow crvUSD")
    expect(formatMultiplyLoopPairLabel("CRV", "CRVUSD")).toBe("CRV / crvUSD")
  })

  it("uses capitalized verb keys when phrase templates are untranslated", () => {
    expect(translateMultiplyLoopSupplyLabel(identityT, "USDC")).toBe("Supply USDC")
    expect(translateMultiplyLoopBorrowLabel(identityT, "GHO")).toBe("Borrow GHO")
  })

  it("uses localized phrase templates when provided", () => {
    const t = (key: string) => (key === "Borrow {borrow}" ? "Emprunter {borrow}" : key)
    expect(translateMultiplyLoopBorrowLabel(t, "GHO")).toBe("Emprunter GHO")
  })
})
