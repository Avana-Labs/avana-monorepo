import { describe, expect, it } from "vitest"
import { readFileSync } from "node:fs"
import { resolve } from "node:path"

describe("MarketMobileCard surfaces", () => {
  it("uses the Dashboard snapshot surface instead of a hover overlay", () => {
    const source = readFileSync(resolve(__dirname, "../market-card-primitives.tsx"), "utf8")
    const cardBlock = source.slice(
      source.indexOf("export function MarketMobileCard"),
      source.indexOf("export function MarketMobileCardHeader"),
    )
    expect(cardBlock).toMatch(/rounded-radius-md border-0 bg-card/)
    expect(cardBlock).toMatch(/shadow-none/)
    expect(cardBlock).not.toMatch(/bg-hover/)
    expect(cardBlock).not.toMatch(/border-b/)
    expect(cardBlock).not.toMatch(/hover:bg-hover/)
    expect(cardBlock).not.toMatch(/shadow-elev-1/)
  })

  it("defines one mobile identity and supporting-value type hierarchy", () => {
    const source = readFileSync(resolve(__dirname, "../market-card-primitives.tsx"), "utf8")
    const identity = source.slice(
      source.indexOf("export function MarketMobileIdentityText"),
      source.indexOf("export function MarketMobileSupportingValue"),
    )

    expect(identity).toMatch(/text-\[15px\].*font-normal/)
    expect(identity).toMatch(/text-\[13px\].*font-normal/)
    expect(source).toMatch(/MarketMobileSupportingValue[\s\S]*text-\[13px\]/)
    // Stat rows: labels readable on mobile, values one step larger than labels.
    expect(source).toMatch(/MarketMobileStatRow[\s\S]*text-\[13px\][\s\S]*text-muted-foreground/)
    expect(source).toMatch(/MarketMobileStatRow[\s\S]*text-\[15px\]/)
  })

  it("defines one action footer with stable spacing and column variants", () => {
    const source = readFileSync(resolve(__dirname, "../market-card-primitives.tsx"), "utf8")
    const footer = source.slice(source.indexOf("export function MarketMobileActionFooter"))

    expect(footer).toMatch(/mt-4 grid gap-2/)
    expect(footer).toMatch(/columns === 1[\s\S]*grid-cols-1/)
    expect(footer).toMatch(/columns === 2[\s\S]*grid-cols-2[\s\S]*grid-cols-3/)
    expect(footer).toMatch(/\[&>button\]:mt-0/)
  })
})
