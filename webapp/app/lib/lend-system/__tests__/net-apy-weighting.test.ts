import { describe, expect, it } from "vitest"
import { lendNetApyPct } from "@/app/lib/lend-system/read-model"

describe("lendNetApyPct — canonical supplied-weighted blend", () => {
  it("weights each investment's apyPct by suppliedUsd, not a flat average", () => {
    // A: $100 @ 10%. B: $900 @ 2%.
    const investments = [
      { suppliedUsd: 100, apyPct: 10 },
      { suppliedUsd: 900, apyPct: 2 },
    ]
    // Supplied-weighted: (100*10 + 900*2) / 1000 = 2.8%
    expect(lendNetApyPct(investments)).toBeCloseTo(2.8, 10)
    // Flat average (the OLD detail-snapshot blend) would be (10 + 2)/2 = 6% — different.
    expect(lendNetApyPct(investments)).not.toBeCloseTo(6, 4)
  })

  it("returns 0 with no investments or zero total supplied", () => {
    expect(lendNetApyPct([])).toBe(0)
    expect(lendNetApyPct([{ suppliedUsd: 0, apyPct: 5 }])).toBe(0)
  })
})
