import { cleanup, render, screen } from "@testing-library/react"
import Link from "next/link"
import { afterEach, describe, expect, it } from "vitest"
import { MobileDetailActionBar } from "@/app/components/detail-page-primitives"
import { TransactAccessContext, type TransactAccess } from "@/app/lib/transact-access"

afterEach(() => cleanup())

const renderBar = (access: TransactAccess) =>
  render(
    <TransactAccessContext.Provider value={access}>
      <MobileDetailActionBar className="grid grid-cols-2 gap-3">
        <Link href="/actions/lend/deposit">Deposit</Link>
        <Link href="/actions/lend/withdraw">Withdraw</Link>
      </MobileDetailActionBar>
    </TransactAccessContext.Provider>,
  )

describe("MobileDetailActionBar", () => {
  it("collapses to one Get Started button for a guest", () => {
    renderBar("guest")
    const links = screen.getAllByRole("link")
    expect(links).toHaveLength(1)
    expect(links[0]).toHaveTextContent("Get Started")
    expect(links[0]).toHaveAttribute("href", "/dashboard")
  })

  it("collapses to one Complete onboarding button for a wallet still onboarding", () => {
    renderBar("needs-onboarding")
    expect(screen.getAllByRole("link")).toHaveLength(1)
    expect(screen.getByRole("link")).toHaveTextContent("Complete onboarding")
  })

  it("keeps the product actions for a ready wallet", () => {
    renderBar("ready")
    expect(screen.getAllByRole("link").map((link) => link.textContent)).toEqual(["Deposit", "Withdraw"])
  })
})
