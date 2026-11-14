import { describe, expect, it } from "vitest"
import {
  TABLE_BASE,
  TABLE_BODY_ROW,
  TABLE_CELL_NUMERIC,
  TABLE_CELL_PRIMARY,
  TABLE_COLUMN_MIN_PX,
  TABLE_COLUMN_PHONE_CLASS,
  TABLE_HEADER_ROW,
  MARKET_TABLE_REFERENCE_PX,
  tableColumnLayout,
  tableStickyCell,
} from "@/app/lib/ui/table-row-hover"

describe("desktop table geometry", () => {
  it("uses one header height, row height, and edge padding", () => {
    expect(TABLE_HEADER_ROW).toContain("h-[33px]")
    expect(TABLE_HEADER_ROW).toContain("[&>th:first-child]:pl-6")
    expect(TABLE_HEADER_ROW).toContain("[&>th:last-child]:pr-5")
    expect(TABLE_HEADER_ROW).toContain("font-normal")
    expect(TABLE_BODY_ROW).toBe("h-[72px]")
    expect(TABLE_BASE).toBe("text-[12px]")
    expect(TABLE_CELL_PRIMARY).toContain("text-[15px]")
    expect(TABLE_CELL_PRIMARY).toContain("font-normal")
  })

  it("keeps token amounts on one line in numeric cells", () => {
    expect(TABLE_CELL_NUMERIC).toContain("whitespace-nowrap")
  })
})

describe("shared column layout", () => {
  const pct = (width: string) => Number.parseFloat(width)

  it("gives index, identity, and action the same share on every table so pinned edges line up", () => {
    const a = tableColumnLayout(["index", "identity", "compact", "metric", "gauge", "metric", "action"])
    const b = tableColumnLayout(["index", "identity", "compact", "metric", "compact", "compact", "gauge", "action"])
    expect(a.widths.slice(0, 2)).toEqual(b.widths.slice(0, 2))
    expect(a.widths.at(-1)).toBe(b.widths.at(-1))
    // At the reference width the anchors are exactly their px widths.
    expect((pct(a.widths[1]) / 100) * MARKET_TABLE_REFERENCE_PX).toBeCloseTo(TABLE_COLUMN_MIN_PX.identity, 0)
  })

  it("fills 100% and sets min width where the tightest column hits its minimum", () => {
    const layout = tableColumnLayout([
      "index",
      "identity",
      "compact",
      "metric",
      "compact",
      "compact",
      "gauge",
      "action",
    ])
    expect(layout.widths.reduce((sum, width) => sum + pct(width), 0)).toBeCloseTo(100, 1)
    // Every data column is at least its minimum at minWidth, and it fits the reference width.
    const gauge = (pct(layout.widths[6]) / 100) * layout.minWidth
    expect(gauge).toBeGreaterThanOrEqual(TABLE_COLUMN_MIN_PX.gauge - 0.5)
    expect(layout.minWidth).toBeLessThanOrEqual(MARKET_TABLE_REFERENCE_PX)
  })

  it("pins the identity column with an opaque background and no divider line", () => {
    expect(tableStickyCell("body")).toContain("left-0")
    expect(tableStickyCell("body")).toContain("bg-background")
    expect(tableStickyCell("body")).not.toContain("after:w-px")
    expect(tableStickyCell("body")).not.toContain("group-hover:bg-hover")
  })

  it("gives every column kind a fixed phone width and hides the index column on phones", () => {
    const layout = tableColumnLayout(["index", "identity", "compact", "action"])
    expect(layout.kinds).toEqual(["index", "identity", "compact", "action"])
    expect(TABLE_COLUMN_PHONE_CLASS.index).toBe("max-md:hidden")
    for (const kind of Object.keys(TABLE_COLUMN_MIN_PX) as Array<keyof typeof TABLE_COLUMN_MIN_PX>) {
      if (kind !== "index") expect(TABLE_COLUMN_PHONE_CLASS[kind]).toMatch(/^max-md:!w-\[\d+px\]$/)
    }
  })
})
