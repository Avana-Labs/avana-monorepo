import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"
import { DASHBOARD_SNAPSHOT_SURFACE_CLASS } from "@/app/components/card-surface-tokens"

describe("Dashboard snapshot surfaces", () => {
  it("uses one borderless, shadowless card surface", () => {
    expect(DASHBOARD_SNAPSHOT_SURFACE_CLASS).toBe("rounded-radius-md border-0 bg-card shadow-none")
  })

  it("reuses the snapshot surface for every Health card", () => {
    for (const path of [
      "../../dashboard/borrow-tab/supplies-table.tsx",
      "../../dashboard/borrow-tab/debts-table.tsx",
    ]) {
      expect(readFileSync(resolve(__dirname, path), "utf8")).toContain("DASHBOARD_SNAPSHOT_SURFACE_CLASS")
    }
  })
})
