import { cleanup, render } from "@testing-library/react"
import { afterEach, expect, it } from "vitest"
import { HeroMarketCard } from "@/app/borrow/borrow-hero-market-card"
import type { BorrowPoolRow } from "@/app/lib/data/borrow-domain"

afterEach(cleanup)

const visual = (symbol: string) => ({
  symbol,
  shortLabel: symbol,
  bgClassName: "",
  iconUrl: `/asset-icons/${symbol}.png`,
})
const row = (id: string) => ({
  id,
  href: `/borrow/markets/${id}`,
  pool: { visuals: [visual("GHO"), visual("USDC")] } as unknown as BorrowPoolRow,
  title: "GHO / USDC",
  value: "90% LTV",
  delta: "1.44% Fees",
  deltaClassName: "",
})

// The first explore card's first row is the mobile LCP element on /borrow; lazy + low priority
// made Lighthouse flag it and pushed LCP out.
it("loads only the first row's icons eagerly at high priority when asked", () => {
  const { container } = render(<HeroMarketCard rows={[row("a"), row("b")]} eagerFirstRow />)
  const imgs = [...container.querySelectorAll("img")]
  expect(imgs.slice(0, 2).map((img) => img.getAttribute("loading"))).toEqual(["eager", "eager"])
  expect(imgs.slice(0, 2).map((img) => img.getAttribute("fetchpriority"))).toEqual(["high", "high"])
  expect(imgs.slice(2).every((img) => img.getAttribute("loading") === "lazy")).toBe(true)
})

it("keeps every icon lazy by default", () => {
  const { container } = render(<HeroMarketCard rows={[row("a")]} />)
  expect([...container.querySelectorAll("img")].every((img) => img.getAttribute("loading") === "lazy")).toBe(true)
})
