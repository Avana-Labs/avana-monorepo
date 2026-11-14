import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("Dashboard quick-action placement", () => {
  it("P2-03: quick actions sit under claim cards on mobile and in the stat header on desktop", () => {
    const heroSource = readFileSync(resolve(__dirname, "../_rewards-components/rewards-balance-hero.tsx"), "utf8")
    expect(heroSource).toMatch(/showQuickActions/)
    expect(heroSource).toMatch(/DashboardQuickActions/)

    const pageSource = readFileSync(resolve(__dirname, "../dashboard-page-client.tsx"), "utf8")
    expect(pageSource).not.toMatch(/Mobile: compact quick-action rail/)
    expect(pageSource).not.toMatch(/<DashboardQuickActions/)

    const actionsSource = readFileSync(resolve(__dirname, "../dashboard-quick-actions.tsx"), "utf8")
    expect(actionsSource).toMatch(/grid w-full grid-cols-2 gap-2 lg:flex/)
    expect(actionsSource).toMatch(/variant="outline"/)
    expect(actionsSource).not.toMatch(/DashboardHeroActions/)
    expect(actionsSource).not.toMatch(/min-h-\[94px\]/)
  })
})
