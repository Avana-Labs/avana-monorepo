import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("Dashboard and Express surface tokens", () => {
  it("P2-10: aligns dashboard metric cards with hero card surfaces", () => {
    const debts = readFileSync(resolve(__dirname, "../borrow-tab/debts-table.tsx"), "utf8")
    const supplies = readFileSync(resolve(__dirname, "../borrow-tab/supplies-table.tsx"), "utf8")
    const hero = readFileSync(resolve(__dirname, "../_rewards-components/rewards-balance-hero.tsx"), "utf8")
    const token = readFileSync(resolve(__dirname, "../../components/card-surface-tokens.ts"), "utf8")

    expect(hero).toMatch(/bg-card/)
    expect(token).toContain('"rounded-radius-md border-0 bg-card shadow-none"')
    expect(debts).toMatch(/export function CurrentLtvCard[\s\S]*DASHBOARD_SNAPSHOT_SURFACE_CLASS/)
    expect(supplies).toContain("DASHBOARD_SNAPSHOT_SURFACE_CLASS")
    expect(debts).not.toMatch(/export function CurrentLtvCard[\s\S]*bg-background/)
  })
})
