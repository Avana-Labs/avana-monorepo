import { afterAll, beforeAll, describe, expect, it } from "vitest"
import { formatChartPointLabel } from "../format"

describe("formatChartPointLabel", () => {
  const originalTz = process.env.TZ
  // A zone west of UTC, where a UTC day key rendered in local time falls on the previous day.
  // Pinned so the test also guards CI, which runs in UTC and would pass either way.
  beforeAll(() => {
    process.env.TZ = "America/New_York"
  })
  afterAll(() => {
    if (originalTz === undefined) delete process.env.TZ
    else process.env.TZ = originalTz
  })

  it("labels a UTC day key with that day, not the previous one", () => {
    expect(formatChartPointLabel("2026-09-21")).toBe("Sep 21")
  })

  it("keeps a 1st-of-month key in its own month on the yearly range", () => {
    expect(formatChartPointLabel("2026-09-01", "1Y")).toBe("Sep 26")
  })

  it("keeps timestamps on the viewer's local clock", () => {
    expect(formatChartPointLabel("2026-09-21T16:00:00Z")).toMatch(/^12:00\sPM$/)
  })
})
