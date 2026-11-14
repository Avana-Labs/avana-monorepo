import { describe, expect, it } from "vitest"
import {
  assertClose,
  liquidationThresholdFromMaxLtv,
  numberToUsd6,
  ratioToWad,
  requireUnsignedInteger,
} from "./transactionInvariants"

describe("sandbox transaction invariants", () => {
  it("keeps fixed-point conversions and liquidation policy stable", () => {
    expect(numberToUsd6(1.25)).toBe("1250000")
    expect(ratioToWad(1.5)).toBe("1500000000000000000")
    expect(liquidationThresholdFromMaxLtv(78)).toBe(88)
  })

  it("rejects malformed amounts and transition drift", () => {
    expect(() => requireUnsignedInteger("1.2", "amount")).toThrow(/unsigned integer/)
    expect(() => assertClose(1, 2, "amount")).toThrow(/server recomputation/)
  })
})
