import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { liqUtilizationBarClass, liqUtilizationPercentTextClass } from "@/app/lib/borrow-system/liq-utilization-tone"

describe("CurrentLtvCard liq utilization tone", () => {
  it("P2-01: tones % of liq. max by utilization band instead of always rose", () => {
    expect(liqUtilizationPercentTextClass(17)).toBe("text-success")
    expect(liqUtilizationPercentTextClass(62)).toMatch(/amber/)
    expect(liqUtilizationPercentTextClass(82)).toMatch(/orange/)
    expect(liqUtilizationPercentTextClass(95)).toBe("text-rose-500")
    expect(liqUtilizationBarClass(17)).toBe("bg-emerald-500")
    expect(liqUtilizationBarClass(95)).toBe("bg-rose-500")

    const source = readFileSync(resolve(__dirname, "../debts-table.tsx"), "utf8")
    expect(source).toMatch(/liqUtilizationPercentTextClass/)
    expect(source).not.toMatch(/text-rose-500[\s\S]{0,120}liqUtilizationPct/)
  })
})
