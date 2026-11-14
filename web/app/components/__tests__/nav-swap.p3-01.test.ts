import { readFileSync } from "node:fs"
import { resolve } from "node:path"
import { describe, expect, it } from "vitest"
import { SITE_STATIC_ROUTES } from "@/app/lib/site-static-routes"

describe("nav and runtime routes", () => {
  it("P3-01: keeps Express in primary nav at /, /swap reachable via sitemap but not primary nav, and drops dead /rewards runtime route", () => {
    const nav = readFileSync(resolve(__dirname, "../site-nav.ts"), "utf8")
    const runtime = readFileSync(resolve(__dirname, "../product-runtime-providers.tsx"), "utf8")
    const nextConfig = readFileSync(resolve(__dirname, "../../../next.config.mjs"), "utf8")

    expect(nav).toMatch(/href: "\/"/)
    expect(nav).toMatch(/label: "Express"/)
    expect(nav).not.toMatch(/href: "\/swap"/)
    expect(SITE_STATIC_ROUTES.some((route) => route.route === "/swap")).toBe(true)
    // /express stays retired (404) — no edge redirect back to home.
    expect(nextConfig).not.toMatch(/source:\s*"\/express"/)
    expect(runtime).not.toMatch(/"\/rewards"/)
  })
})
